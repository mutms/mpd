// mpd — Mpd.Core.Platform namespace
// Reads/writes ~/Developer/mpd/conf/platform.env — the host-side identity file
// that records *which* kind of mpd setup this is and where it lives:
//   MPD_PLATFORM=desktop | macos-utm | macos-prl | ubuntu-kvm | windows-hyperv | sandbox
//   MPD_VM_IP=<ip>           (empty for desktop and sandbox)
//   MPD_INSTANCE_SUFFIX=<-suffix>   (e.g. "-161"; empty for the unsuffixed
//                                    instance — used for hostname disambiguation
//                                    when running concurrent VMs / machines)
//
// Writers:
//   - mpd-desktop: Mpd.Core.Platform.ensureWritten(...) at the start of setup,
//     bootstraps the file on first run with platform=desktop, vm_ip="".
//   - mpd-machine via macos-utm/create-vm.sh: writes the file via SSH before
//     `mpd --setup` runs in the VM.
//   - mpd-machine via macos-prl/create-vm.sh: same, via SSH (Parallels template).
//   - mpd-machine via ubuntu-kvm/lib/create-vm.sh: same, via SSH.
//   - mpd-machine via windows-hyperv: same, via WinRM.
//   - mpd-machine via sandbox/lib/provision.sh: writes the file with
//     platform=sandbox before `mpd --setup` runs inside the Debian VM.
//
// Reader: mpd's setup actions and helpers that need to know the platform
// or the VM IP at run-time. Lives under conf/ so it survives
// `mpd --uninstall` (which wipes ~/.mpd/ but leaves ~/Developer/mpd/conf/
// alone).

import Foundation

extension Mpd.Core.Platform {

    enum PlatformKind: String {
        case desktop        = "desktop"
        case macosUTM       = "macos-utm"
        case macosPRL       = "macos-prl"
        case ubuntuKVM      = "ubuntu-kvm"
        case windowsHyperV  = "windows-hyperv"
        case sandbox        = "sandbox"
    }

    struct Identity {
        let platform: PlatformKind
        let vmIP: String          // empty for desktop and sandbox
        let instanceSuffix: String  // e.g. "-161", or "" — leading dash included
    }

    /// Path to ~/Developer/mpd/conf/platform.env.
    static var path: String {
        "\(Mpd.Environment.confDir)/platform.env"
    }

    /// Load the identity file; throws with a fix-it message if missing.
    static func load() throws -> Identity {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw RuntimeError(
                "Missing \(path).\n" +
                "Run the matching bootstrap script first:\n" +
                "  • sandbox VM:      setup/sandbox/take-over-sandbox-vm.sh\n" +
                "  • macOS+UTM:       setup/macos-utm/setup.command\n" +
                "  • macOS+Parallels: setup/macos-prl/setup.command\n" +
                "  • Ubuntu+KVM:      setup/ubuntu-kvm/setup.sh\n" +
                "  • Windows Hyper-V: setup/windows-hyperv/setup.cmd\n" +
                "  • desktop:         re-run `mpd --setup` (will write the file).")
        }

        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let kv = parseKV(raw)

        guard let platformRaw = kv["MPD_PLATFORM"], let platform = PlatformKind(rawValue: platformRaw) else {
            throw RuntimeError("\(path): MPD_PLATFORM missing or invalid (expected: desktop, macos-utm, macos-prl, ubuntu-kvm, windows-hyperv, sandbox).")
        }
        let vmIP = kv["MPD_VM_IP"] ?? ""
        let instanceSuffix = kv["MPD_INSTANCE_SUFFIX"] ?? ""

        return Identity(platform: platform, vmIP: vmIP, instanceSuffix: instanceSuffix)
    }

    /// Keys this writer manages. Other `MPD_*` keys (e.g. `MPD_NETWORK_*` set
    /// by a bootstrap script) are preserved verbatim by `write` so the
    /// bootstrap scripts and Platform can share the same file without
    /// clobbering each other.
    private static let managedKeys: Set<String> = [
        "MPD_PLATFORM", "MPD_VM_IP", "MPD_INSTANCE_SUFFIX",
    ]

    /// Write the identity file. Used by mpd-desktop's setup bootstrap and by
    /// `updateInstanceSuffix`. Idempotent — overwrites the managed keys with
    /// the supplied values; preserves any other keys (e.g. `MPD_NETWORK_*`)
    /// that bootstrap scripts may have written.
    static func write(platform: PlatformKind, vmIP: String, instanceSuffix: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Mpd.Environment.confDir, withIntermediateDirectories: true)

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
            # Lives under conf/ so it survives `mpd --uninstall`.
            MPD_PLATFORM=\(platform.rawValue)
            MPD_VM_IP=\(vmIP)
            # Disambiguates concurrent VMs/machines. Auto-derived from the
            # host name (mpd-machine-<X> or mpd-desktop-<X>) at --setup; edit
            # to override. Used as the hostname suffix on runtime containers,
            # e.g. mpd-runtime-php\(instanceSuffix.isEmpty ? "" : "<suffix>").
            MPD_INSTANCE_SUFFIX=\(instanceSuffix)

            """
        if !preserved.isEmpty {
            body += "# Other keys preserved verbatim (set by bootstrap scripts):\n"
            for kv in preserved {
                body += "\(kv.key)=\(kv.value)\n"
            }
        }
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Bootstrap helper for mpd-desktop's setup: write the file with the known
    /// desktop values if absent, leave any existing file untouched.
    static func ensureWritten(platform: PlatformKind, vmIP: String,
                              instanceSuffix: String) throws {
        if FileManager.default.fileExists(atPath: path) { return }
        try write(platform: platform, vmIP: vmIP, instanceSuffix: instanceSuffix)
    }

    /// Update only the instance suffix in an existing platform.env. Used by
    /// `mpd --setup` to refresh the suffix on every run (auto-derived from
    /// the host name at setup time, but the user can override by hand-editing).
    static func updateInstanceSuffix(_ suffix: String) throws {
        let identity = try load()
        try write(platform: identity.platform, vmIP: identity.vmIP, instanceSuffix: suffix)
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
