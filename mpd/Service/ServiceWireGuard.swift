// mpd — Mpd.Service.WireGuard namespace
// WireGuard VPN gateway: key generation, container lifecycle, tunnel interface.
// Container: mpd-service-wireguard at 10.163.0.2
// gvproxy port binding 127.0.0.1:51820/udp on the macOS host.
// NO CA dependency — WireGuard never uses TLS. Only rebuilt on version bump or key rotation.
// mpd-desktop only — mpd-machine reaches containers via plain L3 routing from the laptop,
// no WireGuard tunnel and no WireGuard service container.

import Foundation

extension Mpd.Service.WireGuard {

    static let descriptor = Mpd.ServiceDescriptor(
        name: "wireguard",
        containerName: "mpd-service-wireguard",
        ip: "10.163.0.2",
        dns: "wireguard.service.mpd.test",
        accessHint: "WireGuard endpoint (10.163.0.2:51820/udp)",
        dnsAliases: ["wireguard.service.mpd.test"],
        setup: nil,
        start: nil,
        stop: nil
    )

    static var containerName: String { descriptor.containerName }
    static var ip: String { descriptor.ip }
    static let imageTag = "localhost/mpd-wireguard:latest"

    /// Bump when container setup changes — triggers rebuild on next --setup / --start.
    static let revision = "3"

    // WireGuard point-to-point tunnel addressing
    static let tunnelMac    = "10.164.0.1"    // Mac end of tunnel
    static let tunnelServer = "10.164.0.2"    // Container end of tunnel

    // Label keys
    private static let revisionLabel     = "mpd.service.revision"
    private static let wgFingerprintLabel = "mpd.wg.fingerprint"

    /// Build the WireGuard image if it isn't already present. Mirror of
    /// fileaccess's pattern: ship a Containerfile that pre-installs
    /// wireguard-tools so the runtime container has zero apt dependency
    /// at startup. Build runs with `--network=host` (see
    /// Mpd.Podman.buildImage), so apt resolves through the host's working
    /// resolver regardless of mpd-internal / dnsmasq state.
    private static func ensureImage() throws {
        guard !Mpd.Podman.imageExists(imageTag) else { return }
        let assetsDir = try Mpd.Core.Assets.path()
        let contextDir = "\(assetsDir)/services/wireguard"
        step("Building WireGuard image")
        guard Mpd.Podman.buildImage(tag: imageTag, contextDir: contextDir) == 0 else {
            throw RuntimeError("Failed to build WireGuard image from \(contextDir).")
        }
    }

    // MARK: - Key generation

    /// Generate 4 WireGuard key files in `wgDir` using a temporary container
    /// based on the prebuilt mpd-wireguard image (wireguard-tools already
    /// installed). Keys: server-privatekey, server-publickey,
    /// client-privatekey, client-publickey (0600 for private).
    static func generateKeys(wgDir: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: wgDir) {
            try fm.createDirectory(atPath: wgDir, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wgDir)
        try ensureImage()
        print("Generating WireGuard keypairs via temp container")
        // Containers run rootful on Linux (sudo podman), so files written into a host
        // bind-mount land owned by root. Chown back to the invoking user so the
        // user-mode mpd process can read them. No-op if MPD_UID is unset.
        let script = """
            set -e
            wg genkey | tee /wgkeys/server-privatekey | wg pubkey > /wgkeys/server-publickey
            wg genkey | tee /wgkeys/client-privatekey | wg pubkey > /wgkeys/client-publickey
            chmod 600 /wgkeys/server-privatekey /wgkeys/client-privatekey
            if [ -n "${MPD_UID:-}" ]; then chown "${MPD_UID}:${MPD_GID:-$MPD_UID}" /wgkeys/*; fi
            """
        let uid = String(geteuid())
        let gid = String(getegid())
        guard Mpd.Podman.run(["--rm",
                              "-v", "\(wgDir):/wgkeys",
                              "-e", "MPD_UID=\(uid)",
                              "-e", "MPD_GID=\(gid)",
                              imageTag, "bash", "-c", script]) == 0 else {
            throw RuntimeError("Failed to generate WireGuard keys.")
        }
        ok("WireGuard keypairs generated in \(wgDir)")
    }

    /// Write conf file (WireGuard client tunnel config) from saved key files.
    /// Conf is kept minimal: macOS WireGuard.app has a strict parser and inline
    /// comments in [Interface] can break it. Explanatory notes (split DNS,
    /// optional `DNS = ...`) are surfaced in `mpd --setup` output only.
    static func writeClientConf(wgDir: String, wgConf: String) throws {
        let serverPubKey  = try String(contentsOfFile: "\(wgDir)/server-publickey",  encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientPrivKey = try String(contentsOfFile: "\(wgDir)/client-privatekey", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientConf = """
            [Interface]
            PrivateKey = \(clientPrivKey)
            Address = \(tunnelMac)/32

            [Peer]
            PublicKey = \(serverPubKey)
            Endpoint = 127.0.0.1:51820
            AllowedIPs = \(Mpd.internalSubnet)
            """
        try clientConf.write(toFile: wgConf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wgConf)
    }

    // MARK: - Container lifecycle

    /// Create and configure the WireGuard container. Idempotent.
    /// Returns `true` if freshly created (caller should prompt for tunnel import).
    @discardableResult
    static func setup() throws -> Bool {
        let fm     = FileManager.default
        let wgDir  = Mpd.Environment.confWireGuardDir

        // Remove outdated container (version or WG fingerprint mismatch → rebuild)
        let wgFP = Mpd.Environment.fileFingerprint("\(wgDir)/server-publickey")
        Mpd.Podman.removeIfOutdated(containerName, labels: [
            revisionLabel: revision,
            wgFingerprintLabel: wgFP,
        ])

        step("Service: WireGuard gateway")

        if !Mpd.Podman.exists(containerName) {
            try ensureImage()

            // Ensure keys exist
            let serverPrivKeyPath = "\(wgDir)/server-privatekey"
            let clientPubKeyPath  = "\(wgDir)/client-publickey"
            if !fm.fileExists(atPath: serverPrivKeyPath) || !fm.fileExists(atPath: clientPubKeyPath) {
                try generateKeys(wgDir: wgDir)
            }

            // Read keys from disk
            let serverPrivKey = try String(contentsOfFile: serverPrivKeyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clientPubKey  = try String(contentsOfFile: clientPubKeyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard Mpd.Podman.run([
                "-d", "--name", containerName,
                "--network", "mpd-internal:ip=\(ip)",
                "--sysctl", "net.ipv4.ip_forward=1",
                "-p", "127.0.0.1:51820:51820/udp",
                "--cap-add", "NET_ADMIN",
                "--label", "com.docker.compose.project=mpd-service",
                "--label", "\(revisionLabel)=\(revision)",
                "--label", "\(wgFingerprintLabel)=\(wgFP)",
                 imageTag, "sleep", "infinity"]
            ) == 0 else { throw RuntimeError("Failed to create WireGuard container.") }

            // Write wg0.conf using keys read from disk
            let containerConf = """
                [Interface]
                PrivateKey = \(serverPrivKey)
                Address    = \(tunnelServer)/32
                ListenPort = 51820

                [Peer]
                PublicKey  = \(clientPubKey)
                AllowedIPs = \(tunnelMac)/32
                """
            let tmpConf = NSTemporaryDirectory() + "mpd-wg0.conf"
            try containerConf.write(toFile: tmpConf, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(atPath: tmpConf) }
            Mpd.Podman.execQuietly(containerName, ["mkdir", "-p", "/etc/wireguard"])
            guard Mpd.Podman.cp(from: tmpConf, to: "\(containerName):/etc/wireguard/wg0.conf") == 0
            else { throw RuntimeError("Failed to copy WireGuard config into container.") }
            Mpd.Podman.execQuietly(containerName, ["chmod", "600", "/etc/wireguard/wg0.conf"])

            try bringUp()
            ok("WireGuard gateway ready.")
            return true
        } else {
            // Container already exists. Start it if needed, then ping first.
            if !Mpd.Podman.running(containerName) {
                Mpd.Podman.startQuietly(containerName)
            }

            // Fast path for --setup idempotency: if gateway already responds, do not flap wg0.
            if Mpd.Environment.HostExec.capture(["ping", "-c", "1", "-W", "1", ip], suppressStderr: true).0 == 0 {
                ok("WireGuard gateway ready.")
                return false
            }

            // Gateway not reachable — repair interface.
            do {
                try bringUp()
            } catch {
                // bringUp failed against an existing container — rebuild from
                // scratch (covers config drift, missing kernel module after
                // VM reboot, broken wg0 state, etc.).
                print("WireGuard broken — removing and recreating...")
                Mpd.Podman.stopQuietly(containerName)
                Mpd.Podman.removeQuietly(containerName)
                return try setup()
            }
            ok("WireGuard gateway ready.")
            return false
        }
    }

    /// Start the WireGuard container (for --start). Requires container to exist.
    static func start() throws {
        step("Service: WireGuard")
        guard Mpd.Podman.exists(containerName) else {
            throw RuntimeError("\(containerName) not found. Run: mpd --setup")
        }
        if !Mpd.Podman.running(containerName) {
            guard Mpd.Podman.startQuietly(containerName) == 0 else {
                throw RuntimeError("Failed to start \(containerName). Run: mpd --setup")
            }
            ok("WireGuard running.")
            // WireGuard interface is lost on container stop — bring it back up
            try bringUp()
        } else {
            // Quick ping — if tunnel responds, nothing to do
            if Mpd.Environment.HostExec.capture(["ping", "-c", "1", "-W", "1", ip], suppressStderr: true).0 == 0 {
                ok("Already running.")
            } else {
                // Container running but interface down — restart it
                ok("Running, restarting interface.")
                try bringUp()
            }
        }
    }

    /// Bring up WireGuard interface and set iptables forwarding rules.
    static func bringUp() throws {
        Mpd.Podman.execQuietly(containerName, ["wg-quick", "down", "wg0"])
        guard Mpd.Podman.execQuietly(containerName, ["wg-quick", "up", "wg0"]) == 0
        else { throw RuntimeError("Failed to bring up WireGuard (wg-quick up wg0).") }

        Mpd.Podman.execQuietly(containerName,
            ["iptables", "-A", "FORWARD", "-i", "wg0", "-o", "eth0", "-j", "ACCEPT"])
        Mpd.Podman.execQuietly(containerName,
            ["iptables", "-A", "FORWARD", "-i", "eth0", "-o", "wg0",
             "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"])
        Mpd.Podman.execQuietly(containerName,
            ["iptables", "-t", "nat", "-A", "POSTROUTING",
             "-s", "\(tunnelMac)/32", "-o", "eth0", "-j", "MASQUERADE"])
    }
}
