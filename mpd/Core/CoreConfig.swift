import Foundation

// Per-machine operator config persisted in config.json.
// This is configuration input, not runtime status output.

// MARK: - Core config (per-machine)

struct CoreConfig: Codable {
    var user: String
    var uid: String

    init() {
        user = ""
        uid = ""
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        uid  = try c.decodeIfPresent(String.self, forKey: .uid) ?? ""
    }
}
