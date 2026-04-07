// mpd-desktop host integration implementation
// Desktop host integration for desktop workflow (cert generation,
// CA trust, DNS resolver configuration, DNS verification).

#if os(macOS)
import Foundation

extension Mpd.Environment.Integration {
    static func configureDNSResolver() {
        let resolverPath = "/etc/resolver/mpd.test"
        let serviceIP = Mpd.Service.Dnsmasq.ip
        if let content = try? String(contentsOfFile: resolverPath, encoding: .utf8),
           content.contains(serviceIP) {
            ok("DNS resolver already configured in \(resolverPath)")
            return
        }
        let action = FileManager.default.fileExists(atPath: resolverPath) ? "Recreate" : "Create"
        let commands = "sudo mkdir -p /etc/resolver && printf \"nameserver \(serviceIP)\\n\" | sudo tee /etc/resolver/mpd.test"
        print("""

          ACTION REQUIRED — \(action) the macOS DNS resolver (requires sudo):

            \(commands)

        """)

        let dnsCheck = {
            if let content = try? String(contentsOfFile: resolverPath, encoding: .utf8),
               content.contains(serviceIP) { return true }
            return false
        }

        // Raw terminal mode for instant keypress + background check
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var rawTermios = oldTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios) }

        while true {
            if dnsCheck() { return }

            print("")
            print("  DNS resolver not configured yet.")
            print("    1. Retry  [Enter]")
            print("    2. Copy commands to clipboard")
            print("  Choice: ", terminator: "")
            fflush(stdout)

            var key: String? = nil
            while key == nil {
                var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 2000) > 0 {
                    var buf = [UInt8](repeating: 0, count: 1)
                    if read(STDIN_FILENO, &buf, 1) == 1 {
                        key = String(UnicodeScalar(buf[0]))
                    }
                } else {
                    if dnsCheck() {
                        print("\n")
                        ok("DNS resolver configured!")
                        return
                    }
                }
            }

            print(key!)
            switch key! {
            case "2":
                let rc = Mpd.Environment.HostExec.run(["pbcopy"], input: Data(commands.utf8))
                if rc == 0 {
                    print("  Commands copied to clipboard. Paste into Terminal.")
                } else {
                    print("  Clipboard copy failed. Copy manually:")
                    print(commands)
                }
            default:
                break
            }
        }
    }

    static func verifyDNS() {
        let serviceIP = Mpd.Service.Portal.ip
        let (_, dnsOut) = Mpd.Environment.HostExec.capture(["dscacheutil", "-q", "host", "-a", "name", "mpd.test"],
            suppressStderr: true)
        if dnsOut.contains("ip_address: \(serviceIP)") {
            ok("DNS: mpd.test → \(serviceIP)")
        } else {
            print("DNS check: \(dnsOut.isEmpty ? "no result yet — tunnel may not be active" : dnsOut)")
            print("Activate the WireGuard tunnel in the WireGuard app, then retry:")
            print("  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder")
            return
        }
        // Informational: verify containers can resolve external DNS (via dnsmasq forwarding)
        let (rc, _) = Mpd.Podman.execOutput(
            Mpd.Service.Portal.containerName,
            ["getent", "hosts", "deb.debian.org"],
            suppressStderr: true)
        if rc == 0 {
            ok("External DNS forwarding works.")
        } else {
            print("  ⚠ External DNS not resolving from containers (apt-get may fail).")
            print("    Check: podman logs mpd-service-dnsmasq")
        }
    }

    /// Check if the WireGuard tunnel interface is active (utun with 10.164.0.1 in ifconfig).
    private static func tunnelInterfaceExists() -> Bool {
        let (_, out) = Mpd.Environment.HostExec.capture(["ifconfig"], suppressStderr: true)
        return out.contains("inet \(Mpd.Service.WireGuard.tunnelMac) ")
    }

    static func importWireGuardConfig(confPath: String) {
        guard FileManager.default.fileExists(atPath: confPath) else { return }

        // Step 1 — check if the tunnel interface is up (utun with 10.164.0.1)
        let interfaceUp = tunnelInterfaceExists()

        if interfaceUp {
            // Interface is up — wait for handshake to complete
            print("  Waiting for WireGuard handshake (or reconnect manually)...", terminator: "")
            fflush(stdout)
            for _ in 1...30 {
                if Mpd.Environment.HostExec.capture(["ping", "-c", "1", "-W", "1000", Mpd.Service.WireGuard.ip], suppressStderr: true).0 == 0 {
                    print("")
                    return
                }
                if !tunnelInterfaceExists() { print(""); break }
                print(".", terminator: "")
                fflush(stdout)
            }
            print("")
            // Fall through — handshake didn't complete (keys likely changed, or tunnel deactivated)
        } else {
            // Interface not up — quick ping just in case, then show prompt
            if Mpd.Environment.HostExec.capture(["ping", "-c", "1", "-W", "1000", Mpd.Service.WireGuard.ip], suppressStderr: true).0 == 0 { return }
        }

        if tunnelInterfaceExists() {
            // Interface exists but handshake failed — keys likely changed
            print("""

              ACTION REQUIRED — WireGuard tunnel not responding.

              Keys may have changed. Update the tunnel config in the WireGuard app:
                1. Select the 'mpd-desktop' tunnel → Edit
                2. Replace the config with the contents of:
                   \(confPath)
                3. Save and re-enable the tunnel

            """)
        } else {
            // Tunnel not configured at all — first-time import
            print("""

              ACTION REQUIRED — Activate the WireGuard tunnel.

              Enable the 'mpd-desktop' tunnel in the WireGuard app,
              or import it if not yet configured:
                File → Import Tunnel(s) from File…
                Config: \(confPath)
              Tip: enable On Demand for auto-connect on boot.

            """)
        }

        // Raw terminal mode for instant keypress + background ping
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var rawTermios = oldTermios
        rawTermios.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &rawTermios)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios) }

        while true {
            // Always ping first before showing menu
            if Mpd.Environment.HostExec.capture(["ping", "-c", "1", "-W", "1000", Mpd.Service.WireGuard.ip], suppressStderr: true).0 == 0 { return }

            print("")
            print("  WireGuard tunnel is not active yet.")
            print("    1. Retry  [Enter]")
            print("    2. Copy config to clipboard")
            print("    3. Open folder with config")
            print("  Choice: ", terminator: "")
            fflush(stdout)

            // Poll stdin with 2-second timeout; ping on each timeout
            var key: String? = nil
            while key == nil {
                var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 2000) > 0 {
                    var buf = [UInt8](repeating: 0, count: 1)
                    if read(STDIN_FILENO, &buf, 1) == 1 {
                        key = String(UnicodeScalar(buf[0]))
                    }
                } else {
                    // Timeout — background ping check
                    if Mpd.Environment.HostExec.capture(["ping", "-c", "1", "-W", "1000", Mpd.Service.WireGuard.ip], suppressStderr: true).0 == 0 {
                        print("\n  Tunnel detected!")
                        return
                    }
                }
            }

            print(key!)
            switch key! {
            case "2":
                if let content = try? String(contentsOfFile: confPath, encoding: .utf8) {
                    let rc = Mpd.Environment.HostExec.run(["pbcopy"], input: Data(content.utf8))
                    if rc == 0 {
                        print("  Config copied to clipboard. Paste into WireGuard → new tunnel from scratch.")
                    } else {
                        print("  Clipboard copy failed. Config content:")
                        print(content)
                    }
                }
            case "3":
                let dir = URL(fileURLWithPath: confPath).deletingLastPathComponent().path
                Mpd.Environment.HostExec.run(["open", dir])
            default:
                break // "1" or Enter — loop back, ping at top
            }
        }
    }

    /// Print the full plain-text setup info for mpd-desktop. Used by
    /// `mpd --setup-info`. No ANSI, no interactive prompts — safe to redirect
    /// to a file. Reads `conf/platform.env` purely as a presence check; the
    /// recipe content itself is fixed for the desktop platform.
    static func printSetupInfo() throws {
        _ = try Mpd.Core.Platform.load()  // throw with fix-it if platform.env is missing
        let dnsmasqIP = Mpd.Service.Dnsmasq.ip
        let wgConf = "\(Mpd.Environment.confWireGuardDir)/mpd-desktop.conf"
        let caPath = "\(Mpd.Environment.confCARootDir)/rootCA.pem"
        let resolverPath = "/etc/resolver/mpd.test"

        print("""
        mpd-desktop — laptop client setup (macOS)

        WireGuard config: \(wgConf)
        DNS resolver:     \(resolverPath) (nameserver \(dnsmasqIP))
        CA cert:          \(caPath) (trust into macOS Keychain)

        ==> SETUP

        # 1. Import the WireGuard tunnel into the WireGuard.app:
        #      File → Import Tunnel(s) from File…
        #      Config: \(wgConf)
        #    Enable "On Demand" for auto-connect on boot.

        # 2. DNS resolver — already configured by `mpd --setup`. Manual command
        #    if you ever need to recreate it:
        sudo mkdir -p /etc/resolver && printf "nameserver \(dnsmasqIP)\\n" | sudo tee \(resolverPath) >/dev/null

        # 3. Trust the mpd CA — already added by `mpd --setup`. Manual command
        #    if you ever need to re-add it:
        sudo security add-trusted-cert -d -r trustRoot \\
          -k /Library/Keychains/System.keychain \\
          \(caPath)

        ==> VERIFY

        ping mpd.test
        curl -sS https://mpd.test/        # add -k if you skipped the CA trust

        ==> UNINSTALL (back out anytime)

        # Open WireGuard.app → select 'mpd-desktop' tunnel → Delete
        sudo rm -f \(resolverPath)
        sudo security delete-certificate -c "mpd.test local development CA" /Library/Keychains/System.keychain

        Run `mpd --uninstall` to additionally remove ~/.mpd/ state and stop
        the mpd containers; conf/ (CA, WireGuard keys, service certs) is
        preserved by design.
        """)
    }

    /// Read a single keypress without requiring Enter.
    private static func readKey() -> String {
        var old = termios()
        tcgetattr(STDIN_FILENO, &old)
        var raw = old
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &old) }

        var buf = [UInt8](repeating: 0, count: 1)
        return read(STDIN_FILENO, &buf, 1) == 1 ? String(UnicodeScalar(buf[0])) : ""
    }

}
#endif
