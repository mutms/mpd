// mpd-machine — per-OS laptop client recipes (route + DNS + optional CA trust).
// Single source of truth for setup and uninstall command blocks: used by the
// interactive `mpd --setup` print, by `mpd --uninstall` cleanup output, and
// by `mpd --setup-info` (which emits the full plain-text body on demand).

#if !os(macOS)
import Foundation

enum MachineClientOS: String, CaseIterable {
    case macOS         = "macos"
    case debianUbuntu  = "debian"
    case fedoraRHEL    = "fedora"
    case windows       = "windows"

    var label: String {
        switch self {
        case .macOS:        return "macOS"
        case .debianUbuntu: return "Linux (Debian/Ubuntu)"
        case .fedoraRHEL:   return "Linux (Fedora/RHEL)"
        case .windows:      return "Windows"
        }
    }
}

extension Mpd.Environment.Integration {

    /// Per-OS UNINSTALL block. Reverse of the setup recipe — printed by
    /// `mpd --uninstall` and embedded in SETUP.txt.
    static func clientUninstallBlock(
        for os: MachineClientOS,
        subnet: String = Mpd.internalSubnet
    ) -> String {
        let subnetNet = subnet.components(separatedBy: "/").first ?? subnet
        switch os {
        case .macOS:
            return """
                sudo route -n delete -net \(subnet)
                sudo rm -f /etc/resolver/mpd.test
                sudo security delete-certificate -c "mpd.test local development CA" /Library/Keychains/System.keychain
                """
        case .debianUbuntu:
            return """
                sudo ip route del \(subnet)
                sudo rm -f /etc/systemd/resolved.conf.d/mpd.conf
                sudo systemctl restart systemd-resolved
                sudo rm -f /usr/local/share/ca-certificates/mpd-rootCA.pem
                sudo update-ca-certificates --fresh
                """
        case .fedoraRHEL:
            return """
                sudo ip route del \(subnet)
                sudo rm -f /etc/systemd/resolved.conf.d/mpd.conf
                sudo systemctl restart systemd-resolved
                sudo rm -f /etc/pki/ca-trust/source/anchors/mpd-rootCA.pem
                sudo update-ca-trust
                """
        case .windows:
            return """
                :: admin cmd:
                route delete \(subnetNet)

                # admin PowerShell:
                Get-DnsClientNrptRule | Where-Object Namespace -eq '.mpd.test' | Remove-DnsClientNrptRule
                Get-ChildItem Cert:\\LocalMachine\\Root | Where-Object Subject -like "*mpd.test local development CA*" | Remove-Item
                """
        }
    }

    /// Per-OS SETUP block. Plain commands, no ANSI/color — printed to the
    /// terminal by `printClientArtifacts` and embedded in setupTxtBody for
    /// `mpd --setup-info`.
    static func clientSetupBlock(
        for os: MachineClientOS,
        vmIP: String,
        dnsmasqIP: String,
        subnet: String,
        caPath: String,
        sshUser: String
    ) -> String {
        let subnetNet = subnet.components(separatedBy: "/").first ?? subnet
        let subnetMask = "255.255.255.0"
        switch os {
        case .macOS:
            return """
                # Route to mpd containers (re-add after reboot — macOS doesn't persist routes)
                sudo route -n add -net \(subnet) \(vmIP)

                # DNS resolver (split DNS for *.mpd.test — picked up automatically)
                echo "nameserver \(dnsmasqIP)" | sudo tee /etc/resolver/mpd.test >/dev/null

                # Optional: trust the mpd CA system-wide for clean HTTPS
                scp \(sshUser)@\(vmIP):\(caPath) mpd-rootCA.pem
                sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain mpd-rootCA.pem
                """
        case .debianUbuntu:
            return """
                # Route to mpd containers
                sudo ip route add \(subnet) via \(vmIP)
                # Persist via NetworkManager:
                # nmcli connection modify <conn> +ipv4.routes "\(subnet) \(vmIP)"

                # DNS resolver (split DNS for *.mpd.test)
                sudo install -D -m 644 /dev/stdin /etc/systemd/resolved.conf.d/mpd.conf <<'EOF'
                [Resolve]
                DNS=\(dnsmasqIP)
                Domains=~mpd.test
                EOF
                sudo systemctl restart systemd-resolved

                # Optional: trust the mpd CA system-wide for clean HTTPS
                scp \(sshUser)@\(vmIP):\(caPath) mpd-rootCA.pem
                sudo cp mpd-rootCA.pem /usr/local/share/ca-certificates/
                sudo update-ca-certificates
                # Firefox/Chromium use NSS — trust separately if HTTPS warnings persist:
                # certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n mpd -i mpd-rootCA.pem
                """
        case .fedoraRHEL:
            return """
                # Route to mpd containers
                sudo ip route add \(subnet) via \(vmIP)
                # Persist via NetworkManager:
                # nmcli connection modify <conn> +ipv4.routes "\(subnet) \(vmIP)"

                # DNS resolver (split DNS for *.mpd.test)
                sudo install -D -m 644 /dev/stdin /etc/systemd/resolved.conf.d/mpd.conf <<'EOF'
                [Resolve]
                DNS=\(dnsmasqIP)
                Domains=~mpd.test
                EOF
                sudo systemctl restart systemd-resolved

                # Optional: trust the mpd CA system-wide for clean HTTPS
                scp \(sshUser)@\(vmIP):\(caPath) mpd-rootCA.pem
                sudo cp mpd-rootCA.pem /etc/pki/ca-trust/source/anchors/
                sudo update-ca-trust
                # Firefox/Chromium use NSS — trust separately if HTTPS warnings persist:
                # certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n mpd -i mpd-rootCA.pem
                """
        case .windows:
            return """
                :: Route to mpd containers (admin cmd; -p persists across reboots)
                route add \(subnetNet) mask \(subnetMask) \(vmIP) -p

                # DNS resolver — split DNS for *.mpd.test (admin PowerShell)
                Add-DnsClientNrptRule -Namespace ".mpd.test" -NameServers "\(dnsmasqIP)"

                # Optional: trust the mpd CA system-wide for clean HTTPS.
                # Copy mpd-rootCA.pem from VM (WinSCP, scp, or shared folder), then in admin PowerShell:
                Import-Certificate -FilePath mpd-rootCA.pem -CertStoreLocation Cert:\\LocalMachine\\Root
                """
        }
    }

    /// Full plain-text body for the chosen OS: setup + verify + uninstall.
    /// Emitted by `mpd --setup-info` so users have a complete reference and
    /// a clear "back out anytime" exit.
    static func setupTxtBody(
        for os: MachineClientOS,
        vmIP: String,
        dnsmasqIP: String,
        subnet: String,
        caPath: String,
        sshUser: String
    ) -> String {
        let setup = clientSetupBlock(for: os, vmIP: vmIP, dnsmasqIP: dnsmasqIP,
                                     subnet: subnet, caPath: caPath, sshUser: sshUser)
        let uninstall = clientUninstallBlock(for: os, subnet: subnet)
        return """
        mpd-machine — laptop client setup (\(os.label))

        VM IP:   \(vmIP)
        DNS:     \(dnsmasqIP) (resolves *.mpd.test)
        Subnet:  \(subnet) (route this to the VM)
        CA cert: rootCA.pem (public; safe to distribute)

        ==> SETUP (run on your laptop)

        \(setup)

        ==> VERIFY

        ping mpd.test
        curl -sS https://mpd.test/        # add -k if you skipped the CA trust

        ==> UNINSTALL (run on your laptop — reverses SETUP)

        \(uninstall)
        """
    }

    /// All-OS uninstall block, used by `mpd --uninstall` (which doesn't know
    /// which OS the laptop runs). Returns the four blocks indented under labels.
    static func allClientUninstallBlocks(subnet: String = Mpd.internalSubnet) -> String {
        MachineClientOS.allCases.map { os in
            let body = clientUninstallBlock(for: os, subnet: subnet)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    \($0)" }
                .joined(separator: "\n")
            return "  \(os.label):\n\(body)"
        }.joined(separator: "\n\n")
    }
}
#endif
