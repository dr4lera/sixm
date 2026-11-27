import Cocoa
import SceneKit

// Static glTF 2.0 geometry preview. Not an animation, skinning or gameplay importer.
enum GLB {
    static func failure(_ text: String) -> NSError {NSError(domain:"SixmGLB",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
    static func cell(_ url:URL) throws -> (SCNScene,Int,Int) {
        let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
        let data=try handle.read(upToCount:4*1024*1024+1) ?? Data();guard data.count<=4*1024*1024 else {throw failure("Cell manifest too large.")}
        guard let doc=try JSONSerialization.jsonObject(with:data) as? [String:Any],doc["kind"] as? String == "sixm-static-cell",let instances=doc["instances"] as? [[String:Any]],instances.count<=2048 else {throw failure("Invalid or oversized static cell.")}
        let base=url.deletingLastPathComponent().resolvingSymlinksInPath();let scene=SCNScene();var cached:[String:(SCNScene,Int,Int)]=[:];var vertices=0,triangles=0
        for item in instances {
            guard let model=item["model"] as? String,let t=item["translation"] as? [Double],let q=item["rotation"] as? [Double],let scale=item["scale"] as? [Double],t.count==3,q.count==4,scale.count==3,(t+q+scale).allSatisfy({$0.isFinite}) else {throw failure("Invalid cell transform.")}
            let path=base.appendingPathComponent(model).standardizedFileURL.resolvingSymlinksInPath();guard path.path.hasPrefix(base.path+"/") else {throw failure("Model escapes cell folder.")}
            let asset:(SCNScene,Int,Int)
            if let known=cached[model] {asset=known} else {asset=try load(path);cached[model]=asset}
            let node=asset.0.rootNode.clone();node.position=SCNVector3(t[0],t[1],t[2]);node.orientation=SCNQuaternion(q[0],q[1],q[2],q[3]);node.scale=SCNVector3(scale[0],scale[1],scale[2]);scene.rootNode.addChildNode(node);vertices+=asset.1;triangles+=asset.2
        }
        guard !instances.isEmpty else {throw failure("Cell contains no imported instances.")}
        return (scene,vertices,triangles)
    }
    static func load(_ url: URL) throws -> (SCNScene,Int,Int) {
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count>=20,data.count<=256*1024*1024 else {throw failure("GLB must be between 20 bytes and 256 MB.")}
        func u32(_ at:Int) throws -> Int {
            guard at>=0,at+4<=data.count else {throw failure("GLB integer outside file.")}
            return (0..<4).reduce(0) {$0 | Int(data[at+$1]) << (8*$1)}
        }
        guard try u32(0)==0x46546c67,try u32(4)==2,try u32(8)==data.count else {throw failure("Expected a complete glTF 2.0 binary.")}
        var offset = 12,jsonData:Data?,binary = Data()
        while offset<data.count {
            let size = try u32(offset),type = try u32(offset+4);offset += 8
            guard size<=data.count-offset else {throw failure("GLB chunk exceeds file.")}
            if type==0x4e4f534a {jsonData = data.subdata(in:offset..<offset+size)}
            if type==0x004e4942 {binary = data.subdata(in:offset..<offset+size)}
            offset += size
        }
        guard let jsonData,let root = try JSONSerialization.jsonObject(with:jsonData) as? [String:Any] else {throw failure("Missing GLB JSON.")}
        var permittedRoot = url.deletingLastPathComponent().resolvingSymlinksInPath()
        var candidate = permittedRoot
        for _ in 0..<5 {
            if FileManager.default.fileExists(atPath:candidate.appendingPathComponent("manifest.jsonl").path) {permittedRoot=candidate;break}
            let next=candidate.deletingLastPathComponent();if next==candidate {break};candidate=next
        }
        let accessors = root["accessors"] as? [[String:Any]] ?? [],views = root["bufferViews"] as? [[String:Any]] ?? []
        func bytes(_ index:Int,_ dimensions:Int) throws -> (Data,Int,Int) {
            guard accessors.indices.contains(index) else {throw failure("Missing accessor.")}
            let a = accessors[index]
            guard ["SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4][a["type"] as? String ?? ""] == dimensions else {throw failure("Accessor shape does not match its use.")}
            guard let v = a["bufferView"] as? Int,views.indices.contains(v),a["sparse"]==nil else {throw failure("Sparse or missing buffers are not supported.")}
            let view = views[v],count = a["count"] as? Int ?? 0,type = a["componentType"] as? Int ?? 0
            let width = [5120:1,5121:1,5122:2,5123:2,5125:4,5126:4][type] ?? 0
            let start = (view["byteOffset"] as? Int ?? 0)+(a["byteOffset"] as? Int ?? 0)
            let stride = view["byteStride"] as? Int ?? width*dimensions
            let viewEnd = (view["byteOffset"] as? Int ?? 0)+(view["byteLength"] as? Int ?? 0)
            guard (view["buffer"] as? Int ?? 0)==0,width>0,count>=0,count<=10000000,stride>=width*dimensions,start>=0,viewEnd<=binary.count,start<=viewEnd else {throw failure("Invalid accessor bounds.")}
            if count>0 {guard (count-1)<=max(0,(viewEnd-start-width*dimensions)/stride),start+(count-1)*stride+width*dimensions<=viewEnd else {throw failure("Accessor exceeds buffer view.")}}
            var packed = Data(capacity:count*width*dimensions)
            for i in 0..<count {let at=start+i*stride;packed.append(binary[at..<at+width*dimensions])}
            return (packed,count,type)
        }
        func floatSource(_ index:Int,_ dimension:Int,_ semantic:SCNGeometrySource.Semantic) throws -> SCNGeometrySource {
            let (b,count,type) = try bytes(index,dimension)
            guard type==5126 else {throw failure("This preview requires floating-point vertex attributes.")}
            return SCNGeometrySource(data:b,semantic:semantic,vectorCount:count,usesFloatComponents:true,componentsPerVector:dimension,bytesPerComponent:4,dataOffset:0,dataStride:dimension*4)
        }
        let scene = SCNScene();var meshNodes:[SCNNode] = [];var vertexCount=0,triangles=0
        let materials = root["materials"] as? [[String:Any]] ?? []
        let textures = root["textures"] as? [[String:Any]] ?? [],images = root["images"] as? [[String:Any]] ?? []
        func material(_ index:Int?) -> SCNMaterial {
            let result=SCNMaterial();result.lightingModel = .physicallyBased;result.diffuse.contents=NSColor.lightGray;result.roughness.contents=0.65
            guard let index,materials.indices.contains(index) else {return result}
            let source=materials[index],pbr=source["pbrMetallicRoughness"] as? [String:Any] ?? [:]
            if let rgba=pbr["baseColorFactor"] as? [Double],rgba.count==4 {result.diffuse.contents=NSColor(calibratedRed:rgba[0],green:rgba[1],blue:rgba[2],alpha:rgba[3])}
            result.metalness.contents=pbr["metallicFactor"] ?? 0;result.roughness.contents=pbr["roughnessFactor"] ?? 0.65;result.isDoubleSided=source["doubleSided"] as? Bool ?? false
            if let tex=pbr["baseColorTexture"] as? [String:Any],let ti=tex["index"] as? Int,textures.indices.contains(ti),let ii=textures[ti]["source"] as? Int,images.indices.contains(ii) {
                let image=images[ii]
                if let vi=image["bufferView"] as? Int,views.indices.contains(vi) {
                    let v=views[vi],start=v["byteOffset"] as? Int ?? 0,length=v["byteLength"] as? Int ?? 0
                    if start>=0,length>=0,start<=binary.count,length<=binary.count-start {result.diffuse.contents=NSImage(data:binary.subdata(in:start..<start+length)) ?? result.diffuse.contents}
                } else if let path=image["uri"] as? String,!path.contains(":"),!path.hasPrefix("/") {
                    let resolved=url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                    let parent=permittedRoot.path+"/"
                    if resolved.path.hasPrefix(parent),let size=try? resolved.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=32*1024*1024 {result.diffuse.contents=NSImage(contentsOf:resolved) ?? result.diffuse.contents}
                }
            }
            return result
        }
        for mesh in root["meshes"] as? [[String:Any]] ?? [] {
            let node=SCNNode();node.name=mesh["name"] as? String
            for primitive in mesh["primitives"] as? [[String:Any]] ?? [] {
                guard (primitive["mode"] as? Int ?? 4)==4,let attrs=primitive["attributes"] as? [String:Int],let position=attrs["POSITION"] else {continue}
                var sources=[try floatSource(position,3,.vertex)];vertexCount += sources[0].vectorCount
                if let index=attrs["NORMAL"] {sources.append(try floatSource(index,3,.normal))}
                if let index=attrs["TEXCOORD_0"] {sources.append(try floatSource(index,2,.texcoord))}
                let element:SCNGeometryElement
                if let index=primitive["indices"] as? Int {
                    let (b,count,type)=try bytes(index,1);guard let width=[5121:1,5123:2,5125:4][type],count%3==0 else {throw failure("Unsupported triangle indices.")}
                    for i in 0..<count {let value=(0..<width).reduce(0) {$0 | Int(b[i*width+$1]) << (8*$1)};guard value<sources[0].vectorCount else {throw failure("Triangle index is outside vertex data.")}}
                    element=SCNGeometryElement(data:b,primitiveType:.triangles,primitiveCount:count/3,bytesPerIndex:width);triangles += count/3
                } else {element=SCNGeometryElement(indices:Array(0..<Int32(sources[0].vectorCount)),primitiveType:.triangles);triangles += sources[0].vectorCount/3}
                let geometry=SCNGeometry(sources:sources,elements:[element]);geometry.materials=[material(primitive["material"] as? Int)];node.addChildNode(SCNNode(geometry:geometry))
            }
            meshNodes.append(node)
        }
        let nodes=root["nodes"] as? [[String:Any]] ?? []
        let created=nodes.map {_ in SCNNode()}
        for (i,item) in nodes.enumerated() {
            if let mesh=item["mesh"] as? Int,meshNodes.indices.contains(mesh) {created[i].addChildNode(meshNodes[mesh].clone())}
            if let t=item["translation"] as? [Double],t.count==3 {created[i].position=SCNVector3(t[0],t[1],t[2])}
            if let s=item["scale"] as? [Double],s.count==3 {created[i].scale=SCNVector3(s[0],s[1],s[2])}
            if let q=item["rotation"] as? [Double],q.count==4 {created[i].orientation=SCNQuaternion(q[0],q[1],q[2],q[3])}
            if let m=item["matrix"] as? [Double],m.count==16 {created[i].simdTransform=simd_float4x4(columns:(SIMD4<Float>(Float(m[0]),Float(m[1]),Float(m[2]),Float(m[3])),SIMD4<Float>(Float(m[4]),Float(m[5]),Float(m[6]),Float(m[7])),SIMD4<Float>(Float(m[8]),Float(m[9]),Float(m[10]),Float(m[11])),SIMD4<Float>(Float(m[12]),Float(m[13]),Float(m[14]),Float(m[15]))))}
        }
        var parented=Set<Int>()
        for (i,item) in nodes.enumerated() {for child in item["children"] as? [Int] ?? [] {guard created.indices.contains(child),child != i,!parented.contains(child) else {throw failure("Invalid node hierarchy.")};var ancestor:SCNNode?=created[i];while let a=ancestor {if a===created[child] {throw failure("Cyclic node hierarchy.")};ancestor=a.parent};created[i].addChildNode(created[child]);parented.insert(child)}}
        if nodes.isEmpty {meshNodes.forEach {scene.rootNode.addChildNode($0)}} else {for i in created.indices where !parented.contains(i) {scene.rootNode.addChildNode(created[i])}}
        guard vertexCount>0,triangles>0 else {throw failure("No supported triangle geometry in this file.")}
        return (scene,vertexCount,triangles)
    }
}
