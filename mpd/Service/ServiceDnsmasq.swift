// mpd — Mpd.Service.Dnsmasq namespace
// dnsmasq DNS resolver: container lifecycle.
// Container: mpd-service-dnsmasq at 10.163.0.3
// Config file: assets/services/dnsmasq/dnsmasq.conf (bind-mounted read-only).
// Per-runtime overrides in ~/.mpd/machines/<m>/dnsmasq.d/ (bind-mounted read-only).
// Restart with `podman restart` after conf.d changes — SIGHUP does NOT reload conf-dir.

import Foundation

extension Mpd.Service.Dnsmasq {

    static let descriptor = Mpd.ServiceDescriptor(
        name: "dnsmasq",
        containerName: "mpd-service-dnsmasq",
        ip: "10.163.0.3",
        dns: "dnsmasq.service.mpd.test",
        accessHint: "DNS resolver (10.163.0.3:53)",
        dnsAliases: ["dnsmasq.service.mpd.test"],
        setup: nil,
        start: nil,
        stop: nil
    )

    static var containerName: String { descriptor.containerName }
    static var ip: String { descriptor.ip }

    /// Bump when container setup changes.
    static let revision = "9"

    /// Path to the host file dnsmasq watches for upstream nameservers.
    /// Bind-mounted into the dnsmasq container and referenced from
    /// dnsmasq.conf via `resolv-file=`. On a corporate VPN this is the
    /// corporate DNS, on a home LAN the router, etc. — no hardcoded
    /// public DNS, no MPD_DNS_UPSTREAM env var.
    ///
    /// Per-platform because the Podman machine VM (mpd-desktop) and the
    /// Trixie sandbox VM (mpd-machine) use different link managers:
    ///
    /// - **mpd-desktop**: Podman machine is FCOS with NetworkManager and
    ///   no systemd-resolved. `/etc/resolv.conf` is the real file written
    ///   by NM, pointing at gvproxy (`192.168.127.1`), which forwards to
    ///   the macOS host's upstream resolvers.
    /// - **mpd-machine**: provision-vm.sh installs systemd-resolved as a
    ///   hard prerequisite. `/etc/resolv.conf` is a stub symlink to
    ///   `127.0.0.53`; the real per-link upstreams live at
    ///   `/run/systemd/resolve/resolv.conf`.
    #if os(macOS)
    private static let hostResolvConfPath = "/etc/resolv.conf"
    #else
    private static let hostResolvConfPath = "/run/systemd/resolve/resolv.conf"
    #endif

    // Label keys
    private static let revisionLabel       = "mpd.service.revision"
    private static let caFingerprintLabel = "mpd.ca.fingerprint"

    // MARK: - Container lifecycle

    /// Create and configure the dnsmasq container. Idempotent.
    static func setup() throws {
        let fm = FileManager.default

        // Remove outdated container (version or CA fingerprint mismatch → rebuild)
        let caFP = Mpd.Environment.fileFingerprint("\(Mpd.Environment.confCARootDir)/rootCA.pem")

        Mpd.Podman.removeIfOutdated(containerName, labels: [
            revisionLabel: revision,
            caFingerprintLabel: caFP,
        ])

        step("Service: dnsmasq DNS resolver")
        
        let assetsDir = try Mpd.Core.Assets.path()
        let dnsmasqConf = "\(assetsDir)/services/dnsmasq/dnsmasq.conf"
        let dnsmasqDir = Mpd.Core.State.dnsmasqDir
        try fm.createDirectory(atPath: dnsmasqDir, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: dnsmasqConf) else {
            throw RuntimeError("dnsmasq.conf not found at \(dnsmasqConf)")
        }
        let serviceDNSChanged = try ensureServiceDNSRecords(in: dnsmasqDir)
        let databaseDNSChanged = try ensureDatabaseDNSRecords(in: dnsmasqDir)
        if serviceDNSChanged || databaseDNSChanged {
            // Sync the *.conf drop-ins into the data volume so the bind-mount
            // below sees them. Snapshot-at-attach is fine here — dnsmasq
            // restarts on conf-dir change anyway, re-attach picks up new
            // content.
            try Mpd.Core.State.syncBindMountFiles()
        }

        if !Mpd.Podman.exists(containerName) {
            print("Creating dnsmasq container")
            // Bind dnsmasq.d from the data volume (subpath) instead of from
            // the host directory. Routes around virtiofs cache lag on libkrun.
            // Source of truth lives at <dnsmasqDir> on the host;
            // syncBindMountFiles() mirrors it into the volume.
            guard Mpd.Podman.run([
                "-d", "--name", containerName,
                "--network", "mpd-internal:ip=\(ip)",
                "--restart", "always",
                "-v", "\(dnsmasqConf):/etc/dnsmasq.conf:ro",
                "--mount", "type=volume,source=\(Mpd.dataVolume),target=/etc/dnsmasq.d,subpath=state/dnsmasq.d,readonly",
                "-v", "\(hostResolvConfPath):/etc/dnsmasq-host-resolv.conf:ro",
                "--label", "com.docker.compose.project=mpd-service",
                "--label", "\(revisionLabel)=\(revision)",
                "--label", "\(caFingerprintLabel)=\(caFP)",
                "docker.io/4km3/dnsmasq:2.90-r3"]
            ) == 0 else { throw RuntimeError("Failed to start \(containerName).") }
            ok("dnsmasq running.")
        } else if !Mpd.Podman.running(containerName) {
            Mpd.Podman.startQuietly(containerName)
            ok("dnsmasq running.")
        } else {
            if serviceDNSChanged || databaseDNSChanged {
                _ = Mpd.Podman.restart(containerName)
                if databaseDNSChanged {
                    ok("dnsmasq reloaded service and database DNS records.")
                } else {
                    ok("dnsmasq reloaded service DNS records.")
                }
            } else {
                ok("Already running.")
            }
        }
    }

    /// Start the dnsmasq container (for --start). Requires container to exist.
    static func start() throws {
        step("Service: dnsmasq")
        try ensureReadyForServiceResolution(verbose: true)
    }

    /// Ensure dnsmasq is running and service DNS records are up to date.
    /// Used by service start flows where dnsmasq output should stay quiet.
    static func ensureReadyForServiceResolution(verbose: Bool = false) throws {
        guard Mpd.Podman.exists(containerName) else {
            throw RuntimeError("\(containerName) not found. Run: mpd --setup")
        }

        let dnsmasqDir = Mpd.Core.State.dnsmasqDir
        try FileManager.default.createDirectory(atPath: dnsmasqDir, withIntermediateDirectories: true)
        let serviceDNSChanged = try ensureServiceDNSRecords(in: dnsmasqDir)
        let databaseDNSChanged = try ensureDatabaseDNSRecords(in: dnsmasqDir)
        if serviceDNSChanged || databaseDNSChanged {
            try Mpd.Core.State.syncBindMountFiles()
        }

        if !Mpd.Podman.running(containerName) {
            guard Mpd.Podman.startQuietly(containerName) == 0 else {
                throw RuntimeError("Failed to start \(containerName). Run: mpd --setup")
            }
            waitUntilReady()
            if verbose { ok("dnsmasq running.") }
        } else if serviceDNSChanged || databaseDNSChanged {
            _ = Mpd.Podman.restart(containerName)
            waitUntilReady()
            if verbose {
                if databaseDNSChanged {
                    ok("dnsmasq reloaded service and database DNS records.")
                } else {
                    ok("dnsmasq reloaded service DNS records.")
                }
            }
        } else if verbose {
            ok("Already running.")
        }
    }

    /// Block until dnsmasq is answering queries. Called after restart/start
    /// so callers (project create, runtime create, etc.) don't race against
    /// a half-up resolver. Probes a known internal record from inside the
    /// dnsmasq container (nslookup is in the image). Non-fatal: warns and
    /// returns on timeout, letting the caller surface its own error if DNS
    /// is genuinely broken.
    static func waitUntilReady(maxSeconds: Double = 5.0) {
        let probe = ["nslookup", "mpd.test", "127.0.0.1"]
        let interval: Double = 0.25
        let attempts = max(1, Int(maxSeconds / interval))
        for _ in 0..<attempts {
            if Mpd.Podman.execQuietly(containerName, probe) == 0 { return }
            Thread.sleep(forTimeInterval: interval)
        }
        print("Warning: dnsmasq did not become ready within \(Int(maxSeconds))s — DNS lookups may fail.")
    }

    private static func ensureServiceDNSRecords(in dnsmasqDir: String) throws -> Bool {
        let recordsPath = "\(dnsmasqDir)/services.conf"

        var lines: [String] = ["# mpd managed service DNS records"]
        for record in Mpd.serviceDNSRecords {
            // dnsmasq `address=/domain/ip` matches domain + subdomains.
            // Use host-record for apex-only mpd.test to avoid wildcard fallback.
            if record.host == "mpd.test" {
                lines.append("host-record=\(record.host),\(record.ip)")
            } else {
                lines.append("address=/\(record.host)/\(record.ip)")
            }
        }
        let content = lines.joined(separator: "\n") + "\n"

        let existing = (try? String(contentsOfFile: recordsPath, encoding: .utf8)) ?? ""
        guard existing != content else { return false }

        try content.write(toFile: recordsPath, atomically: true, encoding: .utf8)
        return true
    }

    private static func ensureDatabaseDNSRecords(in dnsmasqDir: String) throws -> Bool {
        let recordsPath = "\(dnsmasqDir)/databases.conf"

        var lines: [String] = ["# mpd managed database DNS records"]
        let dbState = Mpd.Runtime.State.loadDatabases().databases
        for db in dbState.sorted(by: { $0.databaseId < $1.databaseId }) {
            let containerName = db.containerName.isEmpty ? "mpd-db-\(db.databaseId)" : db.containerName
            let ip = Mpd.Podman.containerIP(containerName)
            guard !ip.isEmpty else { continue }
            lines.append("address=/\(db.databaseId).db.mpd.test/\(ip)")
        }
        let content = lines.joined(separator: "\n") + "\n"

        let existing = (try? String(contentsOfFile: recordsPath, encoding: .utf8)) ?? ""
        guard existing != content else { return false }

        try content.write(toFile: recordsPath, atomically: true, encoding: .utf8)
        return true
    }

}
