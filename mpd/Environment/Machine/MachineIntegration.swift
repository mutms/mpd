// mpd-machine host integration implementation
// Machine host integration for machine workflow (native Podman,
// Cert generation, CA trust, DNS guidance).

#if !os(macOS)
import Foundation

extension Mpd.Environment.Integration {

    /// Detect the VM's primary LAN IP. Falls back to 127.0.0.1 (local-only access).
    static var primaryHostIP: String {
        let (rc, out) = Mpd.Environment.HostExec.capture(
            ["bash", "-c", "ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[0-9.]+'"],
            suppressStderr: true)
        return (rc == 0 && !out.isEmpty) ? out : "127.0.0.1"
    }

    /// Verify the host is in the standardized network state mpd-machine
    /// expects: systemd-resolved active, fed by some link manager (NM or
    /// systemd-networkd). The platform bootstrap scripts (cloud-init for
    /// macos-utm/ubuntu-kvm/windows-hyperv; `sandbox/lib/provision.sh` for
    /// sandbox) are responsible for putting the host here. mpd just
    /// checks and bails with a hint if not.
    static func requireSystemdResolvedActive() throws {
        guard systemctlIsActive("systemd-resolved.service") else {
            throw RuntimeError("""
            systemd-resolved is not active. mpd-machine standardizes on
            systemd-resolved as the host DNS sink on every supported
            install profile.

            If your VM was just rebooted-in-place mid-provision, finish the
            reboot first:

                sudo reboot

            Then SSH back in and re-run mpd --setup.

            Otherwise, see the README of your platform under
            ~/Developer/mpd/setup/ for the expected network stack.
            """)
        }
        ok("systemd-resolved is active.")
    }

    /// Add the `*.mpd.test` rule to systemd-resolved. Single drop-in,
    /// idempotent. `reload` (not `restart`) so per-link DNS state resolved
    /// is already serving doesn't drop during the reconfigure.
    static func configureDNSResolver() throws {
        let serviceIP = Mpd.Service.Dnsmasq.ip
        let confPath = "/etc/systemd/resolved.conf.d/mpd.conf"
        let content = "[Resolve]\nDNS=\(serviceIP)\nDomains=~mpd.test\n"

        let alreadyMatches = (try? String(contentsOfFile: confPath, encoding: .utf8)) == content
        try writeRootOwnedFile(path: confPath, content: content)
        if !alreadyMatches {
            guard Mpd.Environment.HostExec.run(
                ["sudo", "systemctl", "reload", "systemd-resolved"]
            ) == 0 else {
                throw RuntimeError("systemctl reload systemd-resolved failed.")
            }
        }
        ok("DNS resolver configured (systemd-resolved → \(serviceIP) for mpd.test).")
    }

    private static func systemctlIsActive(_ unit: String) -> Bool {
        Mpd.Environment.HostExec.run(
            ["systemctl", "is-active", "--quiet", unit]) == 0
    }

    /// Write `content` to `path` via sudo + install (creates parent dirs,
    /// mode 644). Idempotent: if the file already has identical content,
    /// returns without invoking sudo.
    private static func writeRootOwnedFile(path: String, content: String) throws {
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           existing == content {
            return
        }
        let tmp = NSTemporaryDirectory() + "mpd-conf-\(getpid())-\(UUID().uuidString).tmp"
        try content.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard Mpd.Environment.HostExec.run(
            ["sudo", "install", "-D", "-m", "644", tmp, path]
        ) == 0 else {
            throw RuntimeError("Failed to install \(path).")
        }
    }


    static func verifyDNS() {
        let serviceIP = Mpd.Service.Portal.ip
        let dnsmasqIP = Mpd.Service.Dnsmasq.ip

        // Poll dnsmasq's TCP/53 — gives the netavark bridge and dnsmasq itself a few
        // seconds to come up after Service.Dnsmasq.setup(). TCP (not UDP) because UDP
        // is connectionless — opening a UDP fd succeeds even when nothing is listening.
        let probeScript = "exec 3<>/dev/tcp/\(dnsmasqIP)/53"
        let deadline = Date().addingTimeInterval(8)
        var dnsmasqReady = false
        while Date() < deadline {
            if Mpd.Environment.HostExec.capture(
                ["bash", "-c", "timeout 1 bash -c '\(probeScript)' 2>/dev/null"],
                suppressStderr: true).0 == 0 {
                dnsmasqReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !dnsmasqReady {
            print("DNS check: dnsmasq at \(dnsmasqIP):53 not reachable within 8s.")
            print("  Inspect with: sudo podman logs \(Mpd.Service.Dnsmasq.containerName)")
            return
        }

        let (rc, out) = Mpd.Environment.HostExec.capture(
            ["bash", "-c", "getent hosts mpd.test 2>/dev/null | awk '{print $1}'"],
            suppressStderr: true)
        if rc == 0 && out == serviceIP {
            ok("DNS: mpd.test → \(serviceIP)")
        } else {
            print("DNS check: \(out.isEmpty ? "no result — system resolver not pointing at dnsmasq" : "got \(out), expected \(serviceIP)")")
            print("  Verify: resolvectl status; getent hosts mpd.test")
        }
    }

    /// One-line "setup is done" footer printed at the end of `mpd --setup`.
    /// The host-side trust + route + resolver setup is owned entirely by
    /// the platform bootstrap script (cloud-init platforms apply it on the
    /// host before `mpd --setup` runs in the VM; sandbox has no separate
    /// host side at all). All this layer prints is a pointer back to the
    /// platform README for any host-side detail the user may want to look
    /// up after the fact.
    static func printClientArtifacts(caPath _: String, sshUser _: String) {
        let identity: Mpd.Core.Platform.Identity
        do {
            identity = try Mpd.Core.Platform.load()
        } catch {
            // Setup hasn't reached the platform.env write step yet — bail
            // silently. (`mpd --setup` would never reach this footer in
            // that state, but stay resilient if a caller ever reorders.)
            return
        }
        switch identity.platform {
        case .sandbox:
            print("\n  Sandbox: mpd lives inside this VM. Open Firefox to https://mpd.test/")
        case .desktop:
            // Desktop's footer is owned by DesktopIntegration.
            return
        case .macosUTM, .macosPRL, .ubuntuKVM, .windowsHyperV:
            let readme = "setup/\(identity.platform.rawValue)/README.md"
            print("\n  Host-side setup is owned by your platform's bootstrap script — see")
            print("  \(readme) for details and post-setup operations.")
        }
    }

    /// `mpd --setup-info` body for mpd-machine. After Phase 4 there is no
    /// laptop-side recipe to regenerate (cloud-init platforms apply trust
    /// host-side via their own bootstrap scripts; sandbox has no host
    /// side). Prints platform identity + a pointer to the platform README.
    static func printSetupInfo() throws {
        let identity = try Mpd.Core.Platform.load()
        let readme = "setup/\(identity.platform.rawValue)/README.md"
        print("""
        mpd-machine — \(identity.platform.rawValue)

        Host-side trust / route / resolver configuration is owned by the
        platform bootstrap script, not by `mpd --setup`. See

            \(readme)

        for the full setup story and any post-setup operations.
        """)
    }

    static func warnIfRemoteLoginEnabled() {
        // No-op on Linux — SSH daemon is expected to be running.
    }
}
#endif
