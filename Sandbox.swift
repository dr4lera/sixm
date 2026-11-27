import Cocoa
import SceneKit
import GameController

final class InputView: SCNView {
    var keys = Set<UInt16>()
    var action: ((UInt16)->Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys.insert(event.keyCode); if !event.isARepeat { action?(event.keyCode) } }
    override func keyUp(with event: NSEvent) { keys.remove(event.keyCode) }
    override func resignFirstResponder() -> Bool { keys.removeAll(); return super.resignFirstResponder() }
}
final class Sandbox: NSObject, SCNSceneRendererDelegate, NSWindowDelegate {
    var window: NSWindow!
    let view = InputView()
    let actor = SCNNode()
    let camera = SCNNode()
    let character = SCNNode()
    let car = SCNNode()
    var simulation = FixedSimulation()
    var lastTime: TimeInterval?
    var frameDurations: [Double] = []
    var reportTime: TimeInterval = 0
    var avatarIndex = 0
    var paintIndex = 0
    let paints: [NSColor] = [.systemPink, .systemTeal, .systemOrange, .white]
    let hud = NSTextField(labelWithString: "")
    let controlLock = NSLock()
    var throttle: Double = 0
    var steering: Double = 0
    var swapRequested = false
    var renderCount = 0
    var smokeFrames = 0
    var smokePath: String?
    var smokeStarted = Date()
    func material(_ color: NSColor, metal: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .physicallyBased; m.metalness.contents = metal; m.roughness.contents = 0.55; return m
    }
    @discardableResult func box(_ parent: SCNNode, _ size: SCNVector3, _ position: SCNVector3, _ color: NSColor) -> SCNNode {
        let n = SCNNode(geometry: SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.08))
        n.position = position; n.geometry?.materials = [material(color)]; parent.addChildNode(n); return n
    }
    func open() {
        let scene = SCNScene(); scene.background.contents = NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.30, alpha: 1)
        scene.fogColor = NSColor(calibratedRed: 0.57, green: 0.32, blue: 0.48, alpha: 1); scene.fogStartDistance = 100; scene.fogEndDistance = 290
        view.scene = scene; view.delegate = self; view.preferredFramesPerSecond = 60; view.isPlaying = true; view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        scene.rootNode.addChildNode(actor); actor.addChildNode(character); actor.addChildNode(car); car.isHidden = true
        rebuildCharacter()
        buildCar()
        box(scene.rootNode, SCNVector3(75,0.2,550), SCNVector3(0,-0.2,150), NSColor(white: 0.15, alpha: 1))
        box(scene.rootNode, SCNVector3(80,0.25,550), SCNVector3(-77,-0.3,150), NSColor(calibratedRed: 0.78, green: 0.61, blue: 0.52, alpha: 1))
        box(scene.rootNode, SCNVector3(200,0.2,550), SCNVector3(-215,-0.5,150), .systemTeal)
        for i in -5...18 {
            let z = Float(i*22)
            box(scene.rootNode, SCNVector3(0.3,0.02,7), SCNVector3(0,0,z), NSColor(calibratedRed: 1, green: 0.83, blue: 0.58, alpha: 1))
            for side in [-1.0,1.0] {
                let x = Float(side*28)
                let trunk = SCNNode(geometry: SCNCylinder(radius: 0.25, height: 7)); trunk.position = SCNVector3(x,3.5,z)
                trunk.geometry?.materials = [material(.brown)]; scene.rootNode.addChildNode(trunk)
                for leaf in 0..<6 {
                    let n = box(trunk, SCNVector3(0.4,0.15,4.8), SCNVector3(0,3.4,1.6), .systemGreen)
                    n.eulerAngles = SCNVector3(0.4,Float(leaf)*Float.pi/3,0)
                }
            }
            let height = Float(10 + (i+5)%5*4)
            let building = box(scene.rootNode, SCNVector3(22,height,17), SCNVector3(52,height/2,z), NSColor(calibratedRed: CGFloat(0.25+Double((i+5)%3)*0.12), green: 0.25, blue: 0.42, alpha: 1))
            for floor in 0..<Int(height/3) {
                let neon = box(building, SCNVector3(20,0.13,0.2), SCNVector3(0,Float(floor*3)-height/2+2,-8.6), i%2 == 0 ? .systemPink : .systemTeal)
                neon.geometry?.firstMaterial?.emission.contents = i%2 == 0 ? NSColor.systemPink : NSColor.systemTeal
            }
        }
        let sun = SCNNode(geometry: SCNSphere(radius: 25)); sun.position = SCNVector3(-130,42, -180);sun.geometry?.firstMaterial?.diffuse.contents = NSColor.systemOrange; sun.geometry?.firstMaterial?.emission.contents = NSColor.systemOrange;scene.rootNode.addChildNode(sun)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .directional;light.light?.intensity = 1500;light.light?.color = NSColor(calibratedRed: 1, green: 0.74, blue: 0.61, alpha: 1);light.eulerAngles = SCNVector3(-0.7,-0.5,0);scene.rootNode.addChildNode(light)
        let ambient = SCNNode();ambient.light = SCNLight();ambient.light?.type = .ambient;ambient.light?.intensity = 550;ambient.light?.color = NSColor(calibratedRed: 0.55, green: 0.65, blue: 1, alpha: 1);scene.rootNode.addChildNode(ambient)
        camera.camera = SCNCamera();camera.camera?.zFar = 500;camera.camera?.fieldOfView = 64;scene.rootNode.addChildNode(camera);view.pointOfView = camera
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:1120,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Sixm · Native sandbox · Procedural test scene";window.delegate = self;window.contentView = view
        hud.textColor = .white;hud.font = .monospacedSystemFont(ofSize:13, weight:.medium);hud.maximumNumberOfLines = 0;hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud);NSLayoutConstraint.activate([hud.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:22),hud.topAnchor.constraint(equalTo:view.topAnchor,constant:20)])
        hud.stringValue = "SIXM / NATIVE TEST SCENE\nW/S move · A/D turn · E enter/exit car · C character · V paint\nController: sticks + triggers · A enter/exit\nProcedural placeholders; no GTA assets loaded."
        view.action = { [weak self] key in
            guard let self else {return}
            if key == 14 {self.controlLock.lock();self.swapRequested = true;self.controlLock.unlock()}
            if key == 8 {self.avatarIndex = (self.avatarIndex+1)%4;self.rebuildCharacter()}
            if key == 9 {self.paintIndex = (self.paintIndex+1)%self.paints.count;self.car.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = self.paints[self.paintIndex]}
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] _ in self?.sampleInput() }
        window.center();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(view);NSApp.activate(ignoringOtherApps:true)
    }
    func sampleInput() {
        var t = (view.keys.contains(1) ? -1.0 : 0) + (view.keys.contains(13) ? 1.0 : 0)
        var s = (view.keys.contains(0) ? 1.0 : 0) + (view.keys.contains(2) ? -1.0 : 0)
        if let pad = GCController.controllers().first?.extendedGamepad {
            if abs(pad.leftThumbstick.xAxis.value)>0.12 { s = -Double(pad.leftThumbstick.xAxis.value) }
            if abs(pad.leftThumbstick.yAxis.value)>0.12 { t = Double(pad.leftThumbstick.yAxis.value) }
            if pad.rightTrigger.value>0.1 || pad.leftTrigger.value>0.1 {t = Double(pad.rightTrigger.value-pad.leftTrigger.value)}
            pad.buttonA.pressedChangedHandler = { [weak self] _,_,pressed in if pressed { self?.controlLock.lock();self?.swapRequested = true;self?.controlLock.unlock() } }
        }
        controlLock.lock();throttle = t;steering = s;controlLock.unlock()
    }
    func rebuildCharacter() {
        character.childNodes.forEach { $0.removeFromParentNode() }
        let skin: [NSColor] = [NSColor(calibratedRed:0.44,green:0.27,blue:0.19,alpha:1),NSColor(calibratedRed:0.84,green:0.61,blue:0.44,alpha:1),NSColor(calibratedRed:0.64,green:0.42,blue:0.29,alpha:1),NSColor(calibratedRed:0.94,green:0.75,blue:0.61,alpha:1)]
        let h = Float(1.7+Double(avatarIndex)*0.08)
        box(character,SCNVector3(0.65,h*0.4,0.35),SCNVector3(0,h*0.55,0),paints[avatarIndex])
        let head = SCNNode(geometry:SCNSphere(radius:0.22));head.position = SCNVector3(0,h*0.88,0);head.geometry?.materials = [material(skin[avatarIndex])];character.addChildNode(head)
        for x: Float in [-0.18,0.18] { box(character,SCNVector3(0.24,h*0.4,0.25),SCNVector3(x,h*0.2,0),.darkGray) }
        if avatarIndex%2 == 1 { box(character,SCNVector3(0.5,0.24,0.5),SCNVector3(0,h*0.97,0),.black) }
    }
    func buildCar() {
        box(car,SCNVector3(1.9,0.6,4.1),SCNVector3(0,0.7,0),paints[0])
        box(car,SCNVector3(1.65,0.65,1.8),SCNVector3(0,1.2,-0.2),NSColor(calibratedRed:0.12,green:0.2,blue:0.3,alpha:1))
        for x: Float in [-1,1] {for z: Float in [-1.3,1.3] {
            let wheel = SCNNode(geometry:SCNCylinder(radius:0.4,height:0.25));wheel.eulerAngles.z = .pi/2;wheel.position = SCNVector3(x,0.4,z);wheel.geometry?.materials = [material(.black)];car.addChildNode(wheel)
        }}
    }
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime.map { max(0,time-$0) } ?? 0;lastTime = time
        controlLock.lock();let t = throttle,s = steering,swap = swapRequested;swapRequested = false;controlLock.unlock()
        if swap {simulation.driving.toggle();character.isHidden = simulation.driving;car.isHidden = !simulation.driving}
        simulation.advance(elapsed:dt,throttle:t,steering:s)
        let m = simulation.rendered;actor.position = SCNVector3(m.x,0,m.z);actor.eulerAngles.y = CGFloat(m.heading)
        camera.position = SCNVector3(m.x-sin(m.heading)*9,4.8,m.z-cos(m.heading)*9);camera.look(at:SCNVector3(m.x,1.2,m.z))
        if dt>0 {frameDurations.append(dt);if frameDurations.count>120 {frameDurations.removeFirst()}}
        renderCount += 1
        if time-reportTime>1 {
            reportTime = time;let average = frameDurations.reduce(0,+)/Double(max(frameDurations.count,1));let fps = average>0 ? 1/average : 0
            let sorted = frameDurations.sorted();let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]*1000
            DispatchQueue.main.async { [weak self] in self?.window.title = String(format:"Sixm · Native prototype · %.1f FPS · p95 %.1f ms · 60 Hz simulation",fps,p95) }
        }
        if smokeFrames>0 && renderCount>=smokeFrames {
            let result: [String:Any] = ["frames":renderCount,"simulationTicks":simulation.ticks,"meanFrameMs":frameDurations.reduce(0,+)/Double(max(frameDurations.count,1))*1000,"scene":"procedural placeholders","gameAssetsLoaded":false]
            if let path = smokePath,let data = try? JSONSerialization.data(withJSONObject:result,options:.prettyPrinted) {try? data.write(to:URL(fileURLWithPath:path))}
            smokeFrames = 0;DispatchQueue.main.async {NSApp.terminate(nil)}
        }
    }
    func windowWillClose(_ notification: Notification) {view.isPlaying = false;view.delegate = nil}
}
