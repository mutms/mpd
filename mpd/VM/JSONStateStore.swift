import Foundation

// Minimal JSON file persistence helper.
// Owns read/write/ensureDir primitives only; no schema migration or versioning logic.

enum JSONStateStore {
    static func ensureDir(_ path: String) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
    }

    static func readJSON<T: Decodable>(_ path: String, as type: T.Type) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) {
        ensureDir(path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            _ = FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
