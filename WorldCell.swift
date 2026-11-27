import Foundation

// A small static sample, not a streamed world or an interpreted LOD hierarchy.
enum WorldCell {
    static let region = "-2420,-970,-2340,-890" // RAGE XY metres, in the supported local dump.
    struct Transform: Decodable {
        let translation:[Double]
        let rotation:[Double]
        let scale:[Double]
        var valid:Bool {translation.count==3 && rotation.count==4 && scale.count==3 && (translation+rotation+scale).allSatisfy{$0.isFinite}}
    }
    struct Entity: Decodable {
        let name:String?
        let model_id:String?
        let render:Bool?
        let gltf:Transform?
        var supported:Bool {
            guard let name,let model_id,let gltf else {return false}
            return render != false && gltf.valid && name.range(of:"^[A-Za-z0-9_]{1,100}$",options:.regularExpression) != nil && model_id.range(of:"^levels\\.rpf@[0-9a-fA-F]{1,16}$",options:.regularExpression) != nil
        }
        var inRegion:Bool {
            guard let t=gltf?.translation,t.count==3 else {return false}
            return t[0] >= -2420 && t[0] <= -2340 && -t[2] >= -970 && -t[2] <= -890
        }
        var anchor:Bool {guard let name else {return false};return !["slod","_lod","proxy"].contains(where:{name.lowercased().contains($0)})}
    }
    struct Document:Decodable {let space:String?;let entities:[Entity]?}
    struct Selection {let file:URL;let origin:[Double];let entities:[Entity]}
    static func select(_ directory:URL,checkCancelled:() throws -> Void) throws -> Selection {
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        guard files.count<=50000 else {throw GLB.failure("Placement cache exceeds the file limit.")}
        for file in files {
            try checkCancelled()
            let handle=try FileHandle(forReadingFrom:file)
            let data:Data
            do {data=try handle.read(upToCount:32*1024*1024+1) ?? Data();try handle.close()} catch {try? handle.close();throw error}
            guard data.count<=32*1024*1024,let document=try? JSONDecoder().decode(Document.self,from:data),document.space=="world" else {continue}
            let candidates=(document.entities ?? []).filter{$0.supported}
            let anchors=candidates.filter{$0.anchor && $0.inRegion}
            guard anchors.count>=4,let origin=anchors.first?.gltf?.translation else {continue}
            var chosen:[Entity]=[],models=Set<String>()
            for entity in candidates {
                guard let t=entity.gltf?.translation,let id=entity.model_id else {continue}
                let distance=zip(t,origin).reduce(0.0){$0+pow($1.0-$1.1,2)}
                guard distance<=40*40,models.contains(id) || models.count<6 else {continue}
                chosen.append(entity);models.insert(id)
                if chosen.count==2048 {break}
            }
            if models.count>=3 {return Selection(file:file,origin:origin,entities:chosen)}
        }
        throw GLB.failure("No supported world-space sample was found in this region. This dump version may use different placements.")
    }
    static func write(_ selection:Selection,models:[String:String],failures:[String],to output:URL) throws -> URL {
        let instances:[[String:Any]]=selection.entities.compactMap {entity in
            guard let id=entity.model_id,let model=models[id],let t=entity.gltf else {return nil}
            return ["name":entity.name ?? "", "source_id":id,"model":model,"translation":zip(t.translation,selection.origin).map{$0-$1},"rotation":t.rotation,"scale":t.scale]
        }
        guard !instances.isEmpty else {throw GLB.failure("None of the selected models could be converted. See the import log.")}
        let manifest:[String:Any]=["version":1,"kind":"sixm-static-cell","source_placement_file":selection.file.lastPathComponent,"world_origin":selection.origin,"radius":40,"region":region,"instances":instances,"unique_models":models.count,"failed_models":failures,"limitations":["Static geometry only","No collision or gameplay","LOD relationships not interpreted","Specialized materials, tint rows and animations not reproduced"]]
        let path=output.appendingPathComponent("cell.json")
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:path,options:.atomic)
        return path
    }
}
