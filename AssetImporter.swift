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
    func checkCancelled() throws {
        lock.lock();let stop=cancelled;lock.unlock()
        if stop {throw GLB.failure("Import cancelled. Existing cache is retained.")}
    }
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
    func recoverCell(dump:URL,status:@escaping(String)->Void) throws -> URL {
        try checkCancelled()
        guard FileManager.default.isExecutableFile(atPath:helper.path),FileManager.default.fileExists(atPath:dump.appendingPathComponent("levels.rpf").path) else {throw GLB.failure("A bundled SixNG extractor and an Xbox folder containing levels.rpf are required.")}
        let base=["--game",dump.path,"--work",workspace.path]
        _=try run(base+["index","levels"],stage:"Preparing world index…",status:status)
        let regionFolder=workspace.appendingPathComponent("world-sample-v1")
        let placements=regionFolder.appendingPathComponent("placements/levels")
        let ready=regionFolder.appendingPathComponent("placements-ready.json")
        if !FileManager.default.fileExists(atPath:ready.path) {
            _=try run(base+["placements","levels","--bbox",WorldCell.region,"--out",regionFolder.path],stage:"Recovering placements in the sample region…",status:status)
            try Data("{\"region\":\"\(WorldCell.region)\"}".utf8).write(to:ready,options:.atomic)
        }
        status("Selecting up to six models in a 40-metre cell…")
        let selection=try WorldCell.select(placements,checkCancelled:checkCancelled)
        let output=regionFolder.appendingPathComponent("converted")
        var models:[String:String]=[:],failures:[String]=[],seen=Set<String>()
        for entity in selection.entities {
            try checkCancelled()
            guard let id=entity.model_id,let name=entity.name,seen.insert(id).inserted,let offset=id.split(separator:"@").last else {continue}
            do {
                _=try run(base+["extract","levels","--id",id,"--out",output.path],stage:"Converting \(name) (\(seen.count) of at most six)…",status:status)
                let relative="models/levels/\(name)_\(offset)/model.glb"
                guard FileManager.default.fileExists(atPath:output.appendingPathComponent(relative).path) else {throw GLB.failure("Model conversion produced no GLB.")}
                models[id]=relative
            } catch {try checkCancelled();failures.append(id)}
        }
        try checkCancelled()
        let cell=try WorldCell.write(selection,models:models,failures:failures,to:output)
        status("Static cell ready: \(models.count) models; \(failures.count) unsupported conversions.")
        return cell
    }
    static func cacheFolder(dump:URL) -> URL {
        let identity=SHA256.hash(data:Data(dump.standardizedFileURL.path.utf8)).prefix(8).map{String(format:"%02x",$0)}.joined()
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Sixm/Imports/"+identity)
    }
}
