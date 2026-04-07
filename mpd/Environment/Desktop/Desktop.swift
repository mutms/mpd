// mpd — compile-time environment context helpers
// Single source for host/runtime path and tooling conventions.

#if os(macOS)
import Foundation

extension Mpd.Environment {
    static var label: String {
        return "mpd desktop (macOS host with Podman Desktop)"
    }

    static func fileFingerprint(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        let (code, out) = Mpd.Environment.HostExec.capture(["shasum", "-a", "256", path], suppressStderr: true)
        guard code == 0, let hex = out.split(separator: " ").first, !hex.isEmpty else { return "" }
        return String(hex.prefix(16))
    }
    
    static func detectUserAndUID() -> (user: String, uid: String) {
        let user = Mpd.Environment.HostExec.capture(["whoami"], suppressStderr: true)
            .1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = Mpd.Environment.HostExec.capture(["id", "-u"], suppressStderr: true)
            .1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (user, uid)
    }

    /// Public keys to authorize for SSH into any mpd-managed container. On macOS the
    /// host is the developer's primary machine; private keys live in `~/.ssh/*.pub`.
    static func authorizedPublicKeys(home: String) -> [String] {
        let sshDir = "\(home)/.ssh"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sshDir) else { return [] }
        var lines: [String] = []
        var seen = Set<String>()
        for file in files.sorted() where file.hasSuffix(".pub") {
            guard let content = try? String(contentsOfFile: "\(sshDir)/\(file)", encoding: .utf8) else { continue }
            for line in content.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !trimmed.hasPrefix("#"), seen.insert(trimmed).inserted {
                    lines.append(trimmed)
                }
            }
        }
        return lines
    }
}
#endif
