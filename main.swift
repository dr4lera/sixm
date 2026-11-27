import Cocoa
import WebKit
import SceneKit

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
        if action == "cancelImport" {importer?.cancel();return}
        if action == "recover" {
            let name=request["name"] as? String ?? "phoenix_mid"
            if let dump {recover(dump,model:name)} else {
                let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.message="Select the Xbox archive folder containing levels.rpf. The original archives remain unchanged."
                panel.beginSheetModal(for:window) { [weak self] response in if response == .OK,let url=panel.url {self?.dump=url;self?.recover(url,model:name)} }
            }
            return
        }
        if action == "sandbox" {let sandbox = Sandbox();sandboxes.append(sandbox);sandbox.open()}
        if action == "model" {
            let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.message="Choose a locally converted GLB. Static geometry/material preview; animation and gameplay are not imported."
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
    func recover(_ dump:URL,model:String) {
        guard importer==nil else {emit(["type":"error","message":"An import is already running."]);return}
        guard let helper=Bundle.main.url(forResource:"sixng",withExtension:nil,subdirectory:"tools") else {emit(["type":"error","message":"This build has no SixNG extractor. Use a build with the separate extractor bundled, or open an already converted GLB."]);return}
        let task=AssetImporter(helper:helper,workspace:AssetImporter.cacheFolder(dump:dump));importer=task
        emit(["type":"importProgress","message":"Starting local asset import…"])
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let glb=try task.recover(dump:dump,model:model) {message in DispatchQueue.main.async {self?.emit(["type":"importProgress","message":message])}}
                DispatchQueue.main.async {self?.importer=nil;self?.emit(["type":"importDone","message":"Imported \(model). Opening static preview."]);self?.preview(glb)}
            } catch {DispatchQueue.main.async {self?.importer=nil;self?.emit(["type":"error","message":error.localizedDescription])}}
        }
    }
    func preview(_ url: URL) {
        do {
            let (scene,vertices,triangles) = try GLB.load(url)
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
    print("PASS: fixed-step invariance at 30/60/120/144 FPS; pause catch-up bound; RPF9 header recognition; truncated archive handling; missing executable handling.")
}

if let i=CommandLine.arguments.firstIndex(of:"--recover-asset"),i+1<CommandLine.arguments.count {
    do {
        func value(_ flag:String)->String? {guard let at=CommandLine.arguments.firstIndex(of:flag),at+1<CommandLine.arguments.count else {return nil};return CommandLine.arguments[at+1]}
        let dump=URL(fileURLWithPath:CommandLine.arguments[i+1])
        guard let helper=Bundle.main.url(forResource:"sixng",withExtension:nil,subdirectory:"tools") else {throw GLB.failure("SixNG helper is not bundled.")}
        let workspace=value("--asset-work").map{URL(fileURLWithPath:$0)} ?? AssetImporter.cacheFolder(dump:dump)
        let job=AssetImporter(helper:helper,workspace:workspace)
        let glb=try job.recover(dump:dump,model:value("--asset-name") ?? "phoenix_mid") {message in fputs(message+"\n",stderr)}
        print(glb.path);exit(0)
    } catch {fputs("Import failed: \(error.localizedDescription)\n",stderr);exit(1)}
}
if CommandLine.arguments.contains("--self-test") {
    do {try selfTest();exit(0)} catch {fputs("Tests failed: \(error)\n",stderr);exit(1)}
}
if let i=CommandLine.arguments.firstIndex(of:"--validate-glb"),i+1<CommandLine.arguments.count {
    do {let (_,vertices,triangles)=try GLB.load(URL(fileURLWithPath:CommandLine.arguments[i+1]));print("GLB_VALID vertices=\(vertices) triangles=\(triangles)");exit(0)} catch {fputs("GLB invalid: \(error.localizedDescription)\n",stderr);exit(1)}
}
if let i = CommandLine.arguments.firstIndex(of:"--inspect"),i+1<CommandLine.arguments.count {
    do {let report = try DumpInventory.scan(URL(fileURLWithPath:CommandLine.arguments[i+1]));let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys];let data = try encoder.encode(report);FileHandle.standardOutput.write(data);print("");exit(0)} catch {fputs("Inspection failed: \(error.localizedDescription)\n",stderr);exit(1)}
}
let app = NSApplication.shared
let delegate = Launcher();app.delegate = delegate;app.setActivationPolicy(.regular);app.run()
