// mpd — Mpd.VM.Platform namespace
// Reads/writes /var/lib/mpd/conf/platform.env — the in-VM identity file that
// records which kind of mpd setup this is:
//   MPD_PLATFORM=managed | sandbox
//   MPD_VM_IP=<ip>           (empty for sandbox; for managed it's the
//                              VM's static IP, e.g. 10.211.55.159)
//   MPD_VM_ID=<NNN>          3-digit VM identifier used everywhere:
//                              "100"-"254" for managed VMs (static-IP octet),
//                              "000" for the sandbox VM (DHCP — no fixed IP).
//                              Pod/container/hostname all build from this:
//                              `mpd-<NNN>` is the VM, `mpd-<NNN>-<runtime>`
//                              is each runtime inside it.
//
// Writers:
//   - managed VM via the host-side `mpd-virt` orchestrator (separate repo):
//     writes the file over SSH before `mpd --setup` runs in the VM.
//   - sandbox via setup/sandbox/lib/provision.sh: writes the file with
//     MPD_PLATFORM=sandbox / MPD_VM_ID=sandbox before `mpd --setup` runs.
//
// Reader: mpd's setup actions and helpers that need to know the platform
// or the VM ID at run-time. Lives under /var/lib/mpd/conf/ (persistent identity).

import Foundation

extension Mpd.VM.Platform {

    enum PlatformKind: String {
        case managed = "managed"
        case sandbox = "sandbox"
    }

    struct Identity {
        let platform: PlatformKind
        let vmIP: String
        let vmId: String   // 3-digit: "100"-"254" for managed, "000" for sandbox
    }

    /// Path to /var/lib/mpd/conf/platform.env.
    static var path: String {
        "\(Mpd.VM.confDir)/platform.env"
    }

    /// Load the identity file; throws with a fix-it message if missing.
    static func load() throws -> Identity {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw RuntimeError(
                "Missing \(path).\n" +
                "Run the matching bootstrap first:\n" +
                "  • sandbox VM:  setup/sandbox/take-over-sandbox-vm.sh\n" +
                "  • managed VM:  the host-side `mpd-virt` orchestrator")
        }

        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let kv = parseKV(raw)

        guard let platformRaw = kv["MPD_PLATFORM"], let platform = PlatformKind(rawValue: platformRaw) else {
            throw RuntimeError("\(path): MPD_PLATFORM missing or invalid (expected: managed, sandbox).")
        }
        let vmIP = kv["MPD_VM_IP"] ?? ""
        let vmId = kv["MPD_VM_ID"] ?? ""

        return Identity(platform: platform, vmIP: vmIP, vmId: vmId)
    }

    /// Keys this writer manages. Other `MPD_*` keys (e.g. `MPD_NETWORK_*` set
    /// by a bootstrap script) are preserved verbatim by `write` so the
    /// bootstrap scripts and Platform can share the same file without
    /// clobbering each other.
    private static let managedKeys: Set<String> = [
        "MPD_PLATFORM", "MPD_VM_IP", "MPD_VM_ID",
    ]

    /// Write the identity file. Idempotent — overwrites the managed keys
    /// with the supplied values; preserves any other keys (e.g.
    /// `MPD_NETWORK_*`) that bootstrap scripts may have written.
    static func write(platform: PlatformKind, vmIP: String, vmId: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Mpd.VM.confDir, withIntermediateDirectories: true)

        // Collect non-managed keys from the existing file, in original order.
        var preserved: [(key: String, value: String)] = []
        if fm.fileExists(atPath: path) {
            let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            for rawLine in raw.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                if managedKeys.contains(key) { continue }
                let value = String(line[line.index(after: eq)...])
                preserved.append((key, value))
            }
        }

        var body = """
            # mpd platform identity — written by setup, read at runtime.
            # Lives under /var/lib/mpd/conf/.
            MPD_PLATFORM=\(platform.rawValue)
            MPD_VM_IP=\(vmIP)
            # 3-digit VM identifier used in pod/container/hostname names.
            # Auto-derived from the VM hostname (mpd-<NNN>) at --setup; edit
            # to override. Runtime containers are named mpd-<NNN>-<runtime>.
            MPD_VM_ID=\(vmId)

            """
        if !preserved.isEmpty {
            body += "# Other keys preserved verbatim (set by bootstrap scripts):\n"
            for kv in preserved {
                body += "\(kv.key)=\(kv.value)\n"
            }
        }
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Bootstrap helper: write the file if absent; leave any existing file
    /// untouched.
    static func ensureWritten(platform: PlatformKind, vmIP: String,
                              vmId: String) throws {
        if FileManager.default.fileExists(atPath: path) { return }
        try write(platform: platform, vmIP: vmIP, vmId: vmId)
    }

    /// Update only the VM ID in an existing platform.env. Used by
    /// `mpd --setup` to refresh the ID on every run (auto-derived from the
    /// VM hostname; the user can override by hand-editing the file).
    static func updateVmId(_ vmId: String) throws {
        let identity = try load()
        try write(platform: identity.platform, vmIP: identity.vmIP, vmId: vmId)
    }

    private static func parseKV(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var value = String(line[line.index(after: eq)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
