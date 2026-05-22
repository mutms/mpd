// In-VM host integration helpers
// Machine host integration for machine workflow (native Podman,
// Cert generation, CA trust, DNS guidance).

import Foundation

extension Mpd.Integration {

    /// Detect the VM's primary LAN IP. Falls back to 127.0.0.1 (local-only access).
    static var primaryHostIP: String {
        let (rc, out) = Mpd.HostExec.capture(
            ["bash", "-c", "ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[0-9.]+'"],
            suppressStderr: true)
        return (rc == 0 && !out.isEmpty) ? out : "127.0.0.1"
    }

    /// Verify the host is in the standardized network state mpd
    /// expects: systemd-resolved active, fed by some link manager (NM or
    /// systemd-networkd). The platform bootstrap scripts (macos/
    /// linux/windows; `sandbox/lib/provision.sh` for sandbox)
    /// are responsible for putting the host here. mpd just checks and
    /// bails with a hint if not.
    static func requireSystemdResolvedActive() throws {
        guard systemctlIsActive("systemd-resolved.service") else {
            throw RuntimeError("""
            systemd-resolved is not active. mpd VM standardizes on
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
            guard Mpd.HostExec.run(
                ["sudo", "systemctl", "reload", "systemd-resolved"]
            ) == 0 else {
                throw RuntimeError("systemctl reload systemd-resolved failed.")
            }
        }
        ok("DNS resolver configured (systemd-resolved → \(serviceIP) for mpd.test).")
    }

    private static func systemctlIsActive(_ unit: String) -> Bool {
        Mpd.HostExec.run(
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
        guard Mpd.HostExec.run(
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
            if Mpd.HostExec.capture(
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

        let (rc, out) = Mpd.HostExec.capture(
            ["bash", "-c", "getent hosts mpd.test 2>/dev/null | awk '{print $1}'"],
            suppressStderr: true)
        if rc == 0 && out == serviceIP {
            ok("DNS: mpd.test → \(serviceIP)")
        } else {
            print("DNS check: \(out.isEmpty ? "no result — system resolver not pointing at dnsmasq" : "got \(out), expected \(serviceIP)")")
            print("  Verify: resolvectl status; getent hosts mpd.test")
        }
    }

    static func warnIfRemoteLoginEnabled() {
        // No-op on Linux — SSH daemon is expected to be running.
    }
}
