import Foundation
import CryptoKit

// Runs a separately built SixNG executable, never a command shell.
// Its indexes and converted content stay outside the source/app bundle.
final class AssetImporter {
    let helper: URL
    let workspace: URL
    var process: Process?
    let lock=NSLock()
    var cancelled=false
    init(helper:URL, workspace:URL) {self.helper=helper;self.workspace=workspace}
    func cancel() {lock.lock();cancelled=true;let p=process;lock.unlock();if p?.isRunning==true {p?.terminate()}}
    func run(_ args:[String], stage:String, status:@escaping(String)->Void) throws -> Data {
        lock.lock();let stop=cancelled;lock.unlock()
        if stop {throw GLB.failure("Import cancelled. Existing cache is retained.")}
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        let log=workspace.appendingPathComponent("import.log")
        if !FileManager.default.fileExists(atPath:log.path) {FileManager.default.createFile(atPath:log.path,contents:nil)}
        let stderr=try FileHandle(forWritingTo:log);try stderr.seekToEnd();defer {try? stderr.close()}
        let output=Pipe(),p=Process();p.executableURL=helper;p.arguments=args;p.standardOutput=output;p.standardError=stderr
        status(stage)
        lock.lock()
        if cancelled {lock.unlock();throw GLB.failure("Import cancelled.")}
        do {try p.run();process=p;lock.unlock()} catch {lock.unlock();throw error}
        let bytes=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        lock.lock();process=nil;let wasCancelled=cancelled;lock.unlock()
        if wasCancelled {throw GLB.failure("Import cancelled. Existing cache is retained.")}
        guard p.terminationStatus==0 else {throw GLB.failure("\(stage) failed (exit \(p.terminationStatus)). See \(log.path).")}
        return bytes
    }
    func recover(dump:URL,model:String,status:@escaping(String)->Void) throws -> URL {
        guard model.range(of:"^[A-Za-z0-9_]{1,100}$",options:.regularExpression) != nil else {throw GLB.failure("Use a model name containing only letters, numbers and underscores.")}
        guard FileManager.default.isExecutableFile(atPath:helper.path) else {throw GLB.failure("SixNG extractor is not installed in this build. Build with SIXNG_BIN and its source/license files.")}
        guard FileManager.default.fileExists(atPath:dump.appendingPathComponent("levels.rpf").path) else {throw GLB.failure("Choose the Xbox archive folder containing levels.rpf.")}
        let base=["--game",dump.path,"--work",workspace.path]
        _=try run(base+["index","levels"],stage:"Indexing world archive. First import can take several minutes…",status:status)
        let listing=try run(base+["list","levels","--rtype","ft,dr","--name","^"+model+"$","--limit","1"],stage:"Finding \(model)…",status:status)
        guard let json=try JSONSerialization.jsonObject(with:listing) as? [String:Any],let entry=(json["entries"] as? [[String:Any]])?.first,let id=entry["id"] as? String,let name=entry["name"] as? String,name==model,let offset=id.split(separator:"@").last,offset.allSatisfy({$0.isHexDigit}) else {throw GLB.failure("No supported drawable or fragment named \(model) was recovered.")}
        let out=workspace.appendingPathComponent("extracted")
        _=try run(base+["extract","levels","--id",id,"--out",out.path],stage:"Converting \(model) and available textures…",status:status)
        let glb=out.appendingPathComponent("models/levels/\(name)_\(offset)/model.glb")
        guard FileManager.default.fileExists(atPath:glb.path) else {throw GLB.failure("Extractor completed without a model GLB. This resource may not be supported.")}
        return glb
    }
    static func cacheFolder(dump:URL) -> URL {
        let identity=SHA256.hash(data:Data(dump.standardizedFileURL.path.utf8)).prefix(8).map{String(format:"%02x",$0)}.joined()
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Sixm/Imports/"+identity)
    }
}
