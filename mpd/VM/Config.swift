// mpd — Mpd.VM.Config
// VM-wide operator config persisted at /var/lib/mpd/state/config.json.
// Holds dev user + uid (detected at `mpd --setup` time).

import Foundation

// MARK: - VMConfig persisted struct

struct VMConfig: Codable {
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

// MARK: - Mpd.VM.Config

extension Mpd.VM.Config {
    static var path: String { "\(Mpd.VM.stateDir)/config.json" }

    static func read() -> VMConfig {
        JSONStateStore.readJSON(path, as: VMConfig.self) ?? VMConfig()
    }

    static func write(_ config: VMConfig) {
        JSONStateStore.writeJSON(config, to: path)
    }
}
