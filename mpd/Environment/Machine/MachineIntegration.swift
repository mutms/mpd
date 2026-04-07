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
    /// systemd-networkd). `provision-vm.sh` (netinst) and cloud-init
    /// (macos-utm) are both responsible for putting the host here. mpd
    /// just checks and bails with a hint if not.
    static func requireSystemdResolvedActive() throws {
        guard systemctlIsActive("systemd-resolved.service") else {
            throw RuntimeError("""
            systemd-resolved is not active. mpd-machine standardizes on
            systemd-resolved as the host DNS sink on every supported
            install profile.

            If you came in via provision-vm.sh and haven't rebooted yet:

                sudo reboot

            Then SSH back in and re-run mpd --setup.

            If you didn't run provision-vm.sh: run it now
            (~/Developer/mpd/mpd-machine/platforms/generic-vm/provision-vm.sh)
            and follow its instructions.
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

    /// Print per-OS laptop-client setup instructions (route + DNS + optional CA
    /// trust + verify) to the terminal at the end of `mpd --setup`. Bold ANSI
    /// header, setup commands, verify steps. The "uninstall" and "delete the
    /// VM" sections are intentionally omitted at setup time — the user is
    /// setting up, not tearing down. They can pull the full body any time via
    /// `mpd --setup-info`.
    ///
    /// Driven by `~/Developer/mpd/conf/platform.env` (Mpd.Core.Platform), which
    /// records the client OS and VM IP at provision time. No prompt here — if
    /// the user wants to change the recorded answer, they edit platform.env
    /// directly.
    static func printClientArtifacts(caPath: String, sshUser: String) {
        let dnsmasqIP = Mpd.Service.Dnsmasq.ip
        let subnet = Mpd.internalSubnet                       // e.g. "10.163.0.0/24"

        let identity: Mpd.Core.Platform.Identity
        do {
            identity = try Mpd.Core.Platform.load()
        } catch {
            print("\n  Warning: \(error.localizedDescription)")
            print("  Skipping laptop client recipe — re-run setup after platform.env is in place.")
            return
        }

        // VM IP from platform.env wins; primaryHostIP is a fallback for any
        // setup where the file was provisioned with an empty MPD_VM_IP (rare).
        let vmIP = identity.vmIP.isEmpty ? primaryHostIP : identity.vmIP
        let os = clientOSToRecipe(identity.clientOS)

        let setup = clientSetupBlock(for: os, vmIP: vmIP, dnsmasqIP: dnsmasqIP,
                                     subnet: subnet, caPath: caPath, sshUser: sshUser)
        let uninstall = clientUninstallBlock(for: os, subnet: subnet)
        print("\n\u{001B}[1m── Laptop client setup — \(os.label) ──\u{001B}[0m\n")
        print(setup)
        print("""

        ==> VERIFY

        ping mpd.test
        curl -sS https://mpd.test/        # add -k if you skipped the CA trust

        ==> UNINSTALL (run on your laptop — reverses SETUP)

        \(uninstall)
        """)
        print("\n  (full reference: mpd --setup-info)")
        print("  (recipe driven by \(Mpd.Core.Platform.path))")
    }

    /// Print the full plain-text setup info — same body as `setupTxtBody`,
    /// regenerated on demand from `conf/platform.env`. Used by
    /// `mpd --setup-info` and consumable directly via
    /// `ssh user@vm "mpd --setup-info" > SETUP.txt`. No ANSI, no interactive
    /// prompts; safe to redirect.
    static func printSetupInfo() throws {
        let identity = try Mpd.Core.Platform.load()
        let vmIP = identity.vmIP.isEmpty ? primaryHostIP : identity.vmIP
        let os = clientOSToRecipe(identity.clientOS)
        let caPath = "\(Mpd.Environment.confCARootDir)/rootCA.pem"
        let sshUser = Mpd.Environment.detectUserAndUID().user
        let body = setupTxtBody(
            for: os, vmIP: vmIP, dnsmasqIP: Mpd.Service.Dnsmasq.ip,
            subnet: Mpd.internalSubnet, caPath: caPath, sshUser: sshUser)
        print(body)
    }

    /// 1:1 mapping between the platform-identity ClientOS and the recipe enum.
    /// Both have the same four cases; the rawValues match by design so
    /// platform.env values can be diffed against the recipe set.
    private static func clientOSToRecipe(_ os: Mpd.Core.Platform.ClientOS) -> MachineClientOS {
        switch os {
        case .macos:   return .macOS
        case .debian:  return .debianUbuntu
        case .fedora:  return .fedoraRHEL
        case .windows: return .windows
        }
    }

    static func warnIfRemoteLoginEnabled() {
        // No-op on Linux — SSH daemon is expected to be running.
    }
}
#endif
