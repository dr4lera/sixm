import Cocoa
import WebKit
import SceneKit

// Deterministic asset verification, independent of the active launcher window.
func snapshotPreview(_ url:URL,to output:URL) throws {
    _ = NSApplication.shared
    let (scene,vertices,triangles)=try (url.pathExtension.lowercased()=="json" ? GLB.cell(url) : GLB.load(url))
    let (low,high)=scene.rootNode.boundingBox
    let center=SCNVector3((low.x+high.x)/2,(low.y+high.y)/2,(low.z+high.z)/2)
    let extent=max(high.x-low.x,max(high.y-low.y,high.z-low.z))
    guard extent.isFinite,extent>0 else {throw GLB.failure("Scene has no finite bounds.")}
    let camera=SCNNode();camera.camera=SCNCamera();camera.camera?.zNear=Double(max(0.01,extent/1000));camera.camera?.zFar=Double(extent*10)
    camera.position=SCNVector3(center.x+extent,center.y+extent*0.7,center.z+extent*1.3);camera.look(at:center);scene.rootNode.addChildNode(camera)
    let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera;renderer.autoenablesDefaultLighting=true
    scene.background.contents=NSColor(calibratedRed:0.035,green:0.045,blue:0.09,alpha:1)
    let image=renderer.snapshot(atTime:0,with:CGSize(width:1280,height:800),antialiasingMode:.multisampling4X)
    guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {throw GLB.failure("Unable to encode preview.")}
    try png.write(to:output,options:.atomic)
    print("PREVIEW_RENDERED vertices=\(vertices) triangles=\(triangles) output=\(output.path)")
}

final class Launcher: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var sandboxes: [Sandbox] = []
    var modelWindows: [NSWindow] = []
    var dump: URL?
    var importer: AssetImporter?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu();let appItem = NSMenuItem();menu.addItem(appItem);let appMenu = NSMenu();appMenu.addItem(withTitle:"Quit Sixm",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu = appMenu;NSApp.mainMenu = menu
        if CommandLine.arguments.contains("--smoke-render") {
            let sandbox = Sandbox();sandbox.smokeFrames = 180
            if let i = CommandLine.arguments.firstIndex(of:"--report"),i+1<CommandLine.arguments.count {sandbox.smokePath = CommandLine.arguments[i+1]}
            sandboxes.append(sandbox);sandbox.open();return
        }
        let config = WKWebViewConfiguration();config.userContentController.add(self,name:"sixm")
        web = WKWebView(frame:.zero,configuration:config);web.navigationDelegate = self
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1240,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "Sixm";window.titlebarAppearsTransparent = true;window.titleVisibility = .hidden;window.backgroundColor = NSColor(calibratedRed:0.035,green:0.045,blue:0.09,alpha:1);window.minSize = NSSize(width:960,height:690);window.contentView = web
        if let i=CommandLine.arguments.firstIndex(of:"--preview-glb"),i+1<CommandLine.arguments.count {DispatchQueue.main.async {self.preview(URL(fileURLWithPath:CommandLine.arguments[i+1]))}}
        if let html = Bundle.main.url(forResource:"index",withExtension:"html") {web.loadFileURL(html,allowingReadAccessTo:html.deletingLastPathComponent())}
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func emit(_ value: [String:Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject:value),let json = String(data:data,encoding:.utf8) else {return}
        web.evaluateJavaScript("window.receive(\(json))",completionHandler:nil)
    }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard let request = message.body as? [String:Any],let action = request["action"] as? String else {return}
        if action == "server" {
            guard let address=request["url"] as? String,address.count<=2048,let url=URL(string:address),["http","https"].contains(url.scheme?.lowercased() ?? ""),url.host != nil,url.user==nil,url.password==nil else {emit(["type":"error","message":"Enter an HTTP or HTTPS server client URL."]);return}
            NSWorkspace.shared.open(url);return
        }
        if action == "cancelImport" {importer?.cancel();return}
        if action == "recover" || action == "recoverCell" {
            let name:String? = action == "recoverCell" ? nil : (request["name"] as? String ?? "phoenix_mid")
            if let dump {recover(dump,model:name)} else {
                let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.message="Select the Xbox archive folder containing levels.rpf. The original archives remain unchanged."
                panel.beginSheetModal(for:window) { [weak self] response in if response == .OK,let url=panel.url {self?.dump=url;self?.recover(url,model:name)} }
            }
            return
        }
        if action == "sandbox" {let sandbox = Sandbox();sandboxes.append(sandbox);sandbox.open()}
        if action == "model" {
            let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.message="Choose a locally converted GLB or cell.json. Static geometry only; gameplay is not imported."
            panel.beginSheetModal(for:window) { [weak self] response in if response == .OK,let url=panel.url {self?.preview(url)} }
        }
        if action == "import" {
            let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.allowsMultipleSelection = false;panel.message = "Choose your extracted Xbox dump. Sixm reads headers only; your files stay in place."
            panel.beginSheetModal(for:window) { [weak self] response in
                guard response == .OK,let url = panel.url,let self else {return}
                self.inspect(url)
            }
        }
        if action == "inspect",let root = request["path"] as? String {inspect(URL(fileURLWithPath:root))}
    }
    func recover(_ dump:URL,model:String?) {
        guard importer==nil else {emit(["type":"error","message":"An import is already running."]);return}
        guard let helper=Bundle.main.url(forResource:"sixng",withExtension:nil,subdirectory:"tools") else {emit(["type":"error","message":"This build has no SixNG extractor. Use a build with the separate extractor bundled, or open an already converted GLB."]);return}
        let task=AssetImporter(helper:helper,workspace:AssetImporter.cacheFolder(dump:dump));importer=task
        emit(["type":"importProgress","message":"Starting local asset import…"])
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let progress:(String)->Void = {message in DispatchQueue.main.async {self?.emit(["type":"importProgress","message":message])}}
                let glb:URL
                if let model {glb=try task.recover(dump:dump,model:model,status:progress)} else {glb=try task.recoverCell(dump:dump,status:progress)}
                var completion="Imported \(model ?? "map sample"). Opening static preview."
                if model==nil,let data=try? Data(contentsOf:glb),let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                    let placed=(result["instances"] as? [Any])?.count ?? 0,missing=(result["failed_models"] as? [String])?.count ?? 0
                    completion="Imported \(placed) placements; \(missing) unsupported models. Opening static preview."
                }
                let message=completion
                DispatchQueue.main.async {self?.importer=nil;self?.emit(["type":"importDone","message":message]);self?.preview(glb)}
            } catch {DispatchQueue.main.async {self?.importer=nil;self?.emit(["type":"error","message":error.localizedDescription])}}
        }
    }
    func preview(_ url: URL) {
        do {
            let (scene,vertices,triangles) = try (url.pathExtension.lowercased()=="json" ? GLB.cell(url) : GLB.load(url))
            let view = SCNView();view.scene=scene;view.allowsCameraControl=true;view.autoenablesDefaultLighting=true;view.backgroundColor=NSColor(calibratedWhite:0.08,alpha:1);view.preferredFramesPerSecond=60
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            w.title="Sixm · \(url.lastPathComponent) · \(vertices) vertices / \(triangles) triangles · static mesh preview";w.contentView=view;modelWindows.append(w);w.center();w.makeKeyAndOrderFront(nil)
        } catch {emit(["type":"error","message":error.localizedDescription])}
    }
    func inspect(_ url: URL) {
        dump=url
        emit(["type":"scanning"])
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let inventory = try DumpInventory.scan(url)
                let data = try JSONEncoder().encode(inventory)
                let object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
                DispatchQueue.main.async {self?.emit(["type":"inventory","data":object])}
            } catch {DispatchQueue.main.async {self?.emit(["type":"error","message":error.localizedDescription])}}
        }
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        guard let url = navigationAction.request.url else {decisionHandler(.cancel);return}
        decisionHandler(url.isFileURL || url.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func applicationWillTerminate(_ notification:Notification) {importer?.cancel()}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}

func selfTest() throws {
    var states: [Motion] = []
    for fps in [30,60,120,144] {
        var sim = FixedSimulation();sim.driving = true
        for _ in 0..<(fps*10) {sim.advance(elapsed:1/Double(fps),throttle:1,steering:0.15)}
        guard sim.ticks == 600 else {throw NSError(domain:"SixmTests",code:1)}
        states.append(sim.current)
    }
    for state in states {guard abs(state.x-states[0].x)<1e-7 && abs(state.z-states[0].z)<1e-7 else {throw NSError(domain:"SixmTests",code:2)}}
    var paused = FixedSimulation();paused.advance(elapsed:30,throttle:1,steering:0)
    guard paused.ticks<=15 else {throw NSError(domain:"SixmTests",code:3)}
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:directory)}
    try Data([0x39,0x46,0x50,0x52]+Array(repeating:0,count:28)).write(to:directory.appendingPathComponent("data.rpf"))
    try Data([0x39]).write(to:directory.appendingPathComponent("bad.rpf"))
    let inventory = try DumpInventory.scan(directory)
    guard inventory.archives.count == 2,inventory.archives.contains(where:{$0.magic == "RPF9"}),!inventory.warnings.isEmpty,!inventory.executablePresent else {throw NSError(domain:"SixmTests",code:4)}
    let placements=directory.appendingPathComponent("placements")
    try FileManager.default.createDirectory(at:placements,withIntermediateDirectories:true)
    let entities:[[String:Any]]=(0..<4000).map {i in ["name":"fixture_\(i%10)","model_id":"levels.rpf@\(i%10)","gltf":["translation":[-2380.0,4.0,925.0],"rotation":[0.0,0.0,0.0,1.0],"scale":[1.0,1.0,1.0]]]}
    let fixture=placements.appendingPathComponent("map.json")
    try JSONSerialization.data(withJSONObject:["space":"world","entities":entities]).write(to:fixture)
    let selection=try WorldCell.select(placements,checkCancelled:{})
    guard selection.entities.count==2048,Set(selection.entities.compactMap{$0.model_id}).count==6 else {throw NSError(domain:"SixmTests",code:5)}
    var cancelled=false
    do {_=try WorldCell.select(placements,checkCancelled:{throw GLB.failure("test cancellation")})} catch {cancelled=error.localizedDescription=="test cancellation"}
    guard cancelled else {throw NSError(domain:"SixmTests",code:6)}
    let manifest=try WorldCell.write(selection,models:["levels.rpf@0":"models/fixture.glb"],failures:["levels.rpf@1"],to:directory)
    let doc=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any]
    let instances=doc["instances"] as! [[String:Any]]
    guard instances.count>0,instances.count<selection.entities.count,instances.allSatisfy({($0["translation"] as? [Double])==[0,0,0]}),(doc["failed_models"] as? [String])==["levels.rpf@1"] else {throw NSError(domain:"SixmTests",code:7)}
    print("PASS: fixed-step invariance at 30/60/120/144 FPS; pause catch-up bound; archive inspection; cell model/instance budgets, cancellation, rebasing and partial conversion reporting.")
}

if let i=CommandLine.arguments.firstIndex(where:{$0=="--recover-asset" || $0=="--recover-cell"}),i+1<CommandLine.arguments.count {
    do {
        func value(_ flag:String)->String? {guard let at=CommandLine.arguments.firstIndex(of:flag),at+1<CommandLine.arguments.count else {return nil};return CommandLine.arguments[at+1]}
        let dump=URL(fileURLWithPath:CommandLine.arguments[i+1])
        guard let helper=Bundle.main.url(forResource:"sixng",withExtension:nil,subdirectory:"tools") else {throw GLB.failure("SixNG helper is not bundled.")}
        let workspace=value("--asset-work").map{URL(fileURLWithPath:$0)} ?? AssetImporter.cacheFolder(dump:dump)
        let job=AssetImporter(helper:helper,workspace:workspace)
        let progress:(String)->Void = {message in fputs(message+"\n",stderr)}
        let glb:URL
        if CommandLine.arguments[i]=="--recover-cell" {glb=try job.recoverCell(dump:dump,status:progress)} else {glb=try job.recover(dump:dump,model:value("--asset-name") ?? "phoenix_mid",status:progress)}
        print(glb.path);exit(0)
    } catch {fputs("Import failed: \(error.localizedDescription)\n",stderr);exit(1)}
}
if CommandLine.arguments.contains("--self-test") {
    do {try selfTest();exit(0)} catch {fputs("Tests failed: \(error)\n",stderr);exit(1)}
}
if let i=CommandLine.arguments.firstIndex(of:"--snapshot-preview"),i+1<CommandLine.arguments.count {
    do {
        guard let at=CommandLine.arguments.firstIndex(of:"--snapshot-output"),at+1<CommandLine.arguments.count else {throw GLB.failure("--snapshot-output <PNG path> is required.")}
        try snapshotPreview(URL(fileURLWithPath:CommandLine.arguments[i+1]),to:URL(fileURLWithPath:CommandLine.arguments[at+1]));exit(0)
    } catch {fputs("Preview failed: \(error.localizedDescription)\n",stderr);exit(1)}
}
if let i=CommandLine.arguments.firstIndex(of:"--validate-cell"),i+1<CommandLine.arguments.count {
    do {let (_,v,t)=try GLB.cell(URL(fileURLWithPath:CommandLine.arguments[i+1]));print("CELL_VALID vertices=\(v) triangles=\(t)");exit(0)} catch {fputs("Cell invalid: \(error.localizedDescription)\n",stderr);exit(1)}
}
if let i=CommandLine.arguments.firstIndex(of:"--validate-glb"),i+1<CommandLine.arguments.count {
    do {let (_,vertices,triangles)=try GLB.load(URL(fileURLWithPath:CommandLine.arguments[i+1]));print("GLB_VALID vertices=\(vertices) triangles=\(triangles)");exit(0)} catch {fputs("GLB invalid: \(error.localizedDescription)\n",stderr);exit(1)}
}
if let i = CommandLine.arguments.firstIndex(of:"--inspect"),i+1<CommandLine.arguments.count {
    do {let report = try DumpInventory.scan(URL(fileURLWithPath:CommandLine.arguments[i+1]));let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys];let data = try encoder.encode(report);FileHandle.standardOutput.write(data);print("");exit(0)} catch {fputs("Inspection failed: \(error.localizedDescription)\n",stderr);exit(1)}
}
let app = NSApplication.shared
let delegate = Launcher();app.delegate = delegate;app.setActivationPolicy(.regular);app.run()
