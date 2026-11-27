import Foundation

struct DumpInventory: Codable {
    struct Archive: Codable {
        let path: String
        let bytes: Int64
        let magic: String
        let headerHex: String
    }
    let root: String
    let fileCount: Int
    let totalBytes: Int64
    let sourceFileCount: Int
    let executablePresent: Bool
    let executableIsPE: Bool
    let archives: [Archive]
    let warnings: [String]
    let extractedAssetCount: Int
    let formatSupport: String
    static func scan(_ root: URL) throws -> DumpInventory {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw NSError(domain: "Sixm", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select the extracted Xbox dump folder."])
        }
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "Sixm", code: 2, userInfo: [NSLocalizedDescriptionKey: "This folder cannot be read."])
        }
        var count = 0, source = 0
        var bytes: Int64 = 0
        var archives: [Archive] = []
        var warnings: [String] = []
        var executable = false, pe = false
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { walk.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            count += 1
            guard count <= 200000 else { throw NSError(domain: "Sixm", code: 3, userInfo: [NSLocalizedDescriptionKey: "Folder exceeds the 200,000-file inspection limit."]) }
            let size = Int64(values.fileSize ?? 0)
            bytes += size
            if ["c","cpp","h","hpp","cs","sln"].contains(url.pathExtension.lowercased()) { source += 1 }
            if url.lastPathComponent == "game_scarlett_master.exe" {
                executable = true
                let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
                let header = try h.read(upToCount: 64) ?? Data()
                if header.count >= 64 && header[0] == 0x4d && header[1] == 0x5a {
                    let offset = (0..<4).reduce(UInt64(0)) { $0 | UInt64(header[60+$1]) << UInt64(8*$1) }
                    if offset < UInt64(max(size-4,0)) {
                        try h.seek(toOffset: offset)
                        pe = (try h.read(upToCount: 4)) == Data([0x50,0x45,0,0])
                    }
                }
            }
            if url.pathExtension.lowercased() == "rpf" {
                let h = try FileHandle(forReadingFrom: url)
                let header = try h.read(upToCount: 32) ?? Data(); try h.close()
                let raw = Array(header.prefix(4))
                let magic: String = raw == [0x39,0x46,0x50,0x52] ? "RPF9" : raw == [0x37,0x46,0x50,0x52] ? "RPF7" : "Unknown"
                let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                archives.append(Archive(path: relative, bytes: size, magic: magic, headerHex: header.map { String(format: "%02x", $0) }.joined()))
                if header.count < 32 { warnings.append("Truncated archive header: \(relative)") }
            }
        }
        if !executable { warnings.append("Xbox executable not found in this folder.") }
        if executable && !pe { warnings.append("Executable has no valid PE signature.") }
        if source == 0 { warnings.append("No C/C++/C# source files found within this folder; compiled systems are not recovered source.") }
        if !archives.isEmpty { warnings.append("Archive headers inventoried only. RPF9 directory decoding, extraction, and asset conversion are not implemented.") }
        return DumpInventory(root: root.path, fileCount: count, totalBytes: bytes, sourceFileCount: source,
                             executablePresent: executable, executableIsPE: pe, archives: archives.sorted { $0.path < $1.path }, warnings: warnings,
                             extractedAssetCount: 0, formatSupport: "Header inventory only")
    }
}
