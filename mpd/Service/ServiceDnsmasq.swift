// mpd — Mpd.Service.Dnsmasq namespace
// dnsmasq DNS resolver: container lifecycle.
// Container: mpd-service-dnsmasq at Mpd.Net.ip(.dnsmasq) — .3 of the VM's /24
// Config file: assets/services/dnsmasq/dnsmasq.conf (bind-mounted read-only).
// Per-runtime overrides in /var/lib/mpd/state/dnsmasq.d/ (bind-mounted read-only).
// Restart with `podman restart` after conf.d changes — SIGHUP does NOT reload conf-dir.

import Foundation

extension Mpd.Service.Dnsmasq {

    static let descriptor = Mpd.ServiceDescriptor(
        name: "dnsmasq",
        containerName: "mpd-service-dnsmasq",
        ip: Mpd.Net.ip(Mpd.Net.Host.dnsmasq),
        dns: Mpd.Net.service("dnsmasq"),
        accessHint: "DNS resolver (\(Mpd.Net.ip(Mpd.Net.Host.dnsmasq)):53)",
        dnsAliases: [Mpd.Net.service("dnsmasq")],
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
    /// - **In-VM**: setup expects the host to deliver
    ///   systemd-resolved active. `/etc/resolv.conf` is a stub symlink to
    ///   `127.0.0.53`; the real per-link upstreams live at
    ///   `/run/systemd/resolve/resolv.conf`.
    private static let hostResolvConfPath = "/run/systemd/resolve/resolv.conf"

    // Label keys
    private static let revisionLabel       = "mpd.service.revision"
    private static let caFingerprintLabel = "mpd.ca.fingerprint"

    // MARK: - Container lifecycle

    /// Create and configure the dnsmasq container. Idempotent.
    static func setup() throws {
        let fm = FileManager.default

        // Remove outdated container (version or CA fingerprint mismatch → rebuild)
        let caFP = Mpd.VM.fileFingerprint("\(Mpd.VM.confCARootDir)/rootCA.pem")

        Mpd.Podman.removeIfOutdated(containerName, labels: [
            revisionLabel: revision,
            caFingerprintLabel: caFP,
        ])

        step("Service: dnsmasq DNS resolver")

        let assetsDir = try Mpd.VM.assetsPath()
        let dnsmasqConf = "\(assetsDir)/services/dnsmasq/dnsmasq.conf"
        let dnsmasqDir = Mpd.VM.dnsmasqDir
        try fm.createDirectory(atPath: dnsmasqDir, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: dnsmasqConf) else {
            throw RuntimeError("dnsmasq.conf not found at \(dnsmasqConf)")
        }
        let staleRemoved = pruneOutOfZoneRecords(in: dnsmasqDir)
        let serviceDNSChanged = try ensureServiceDNSRecords(in: dnsmasqDir)
        let databaseDNSChanged = try ensureDatabaseDNSRecords(in: dnsmasqDir)

        if !Mpd.Podman.exists(containerName) {
            print("Creating dnsmasq container")
            // Bind dnsmasq.d directly from the host. Directory mount, so
            // *.conf adds/removes are visible inside immediately. dnsmasq
            // restarts on conf-dir change.
            guard Mpd.Podman.run(Mpd.VM.optMountRO + [
                "-d", "--name", containerName,
                "--network", "mpd-internal:ip=\(ip)",
                "--restart", "always",
                "-v", "\(dnsmasqConf):/etc/dnsmasq.conf:ro",
                "-v", "\(dnsmasqDir):/etc/dnsmasq.d:ro",
                "-v", "\(hostResolvConfPath):/etc/dnsmasq-host-resolv.conf:ro",
                "--label", "com.docker.compose.project=mpd-service",
                "--label", "\(revisionLabel)=\(revision)",
                "--label", "\(caFingerprintLabel)=\(caFP)",
                "docker.io/4km3/dnsmasq:2.90-r3"]
            ) == 0 else { throw RuntimeError("Failed to start \(containerName).") }
            ok("dnsmasq running.")
        } else if !Mpd.Podman.running(containerName) {
            Mpd.Podman.startQuietly(containerName)
            waitUntilReady()
            ok("dnsmasq running.")
        } else {
            if serviceDNSChanged || databaseDNSChanged || staleRemoved {
                _ = Mpd.Podman.restart(containerName)
                waitUntilReady()
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

        let dnsmasqDir = Mpd.VM.dnsmasqDir
        try FileManager.default.createDirectory(atPath: dnsmasqDir, withIntermediateDirectories: true)
        let staleRemoved = pruneOutOfZoneRecords(in: dnsmasqDir)
        let serviceDNSChanged = try ensureServiceDNSRecords(in: dnsmasqDir)
        let databaseDNSChanged = try ensureDatabaseDNSRecords(in: dnsmasqDir)

        if !Mpd.Podman.running(containerName) {
            guard Mpd.Podman.startQuietly(containerName) == 0 else {
                throw RuntimeError("Failed to start \(containerName). Run: mpd --setup")
            }
            waitUntilReady()
            if verbose { ok("dnsmasq running.") }
        } else if serviceDNSChanged || databaseDNSChanged || staleRemoved {
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
    /// dnsmasq container (nslookup is in the image). Internal-only by
    /// design — external resolution depends on the host's upstream chain
    /// and is not dnsmasq's responsibility to wait on; callers that need
    /// to verify a specific external host should probe that host directly.
    /// Non-fatal: warns and returns on timeout.
    static func waitUntilReady(maxSeconds: Double = 5.0) {
        let probe = ["nslookup", Mpd.Net.zone, "127.0.0.1"]
        let interval: Double = 0.25
        let attempts = max(1, Int(maxSeconds / interval))
        for _ in 0..<attempts {
            if Mpd.Podman.execQuietly(containerName, probe) == 0 { return }
            Thread.sleep(forTimeInterval: interval)
        }
        print("Warning: dnsmasq did not become ready within \(Int(maxSeconds))s — DNS lookups may fail.")
    }

    /// Delete conf files that serve names outside this VM's zone.
    ///
    /// Per-runtime (`<rt>.conf`, `_runtime-<rt>.conf`) and per-project
    /// (`<project>.conf`) records are written at create time and never
    /// revisited, so after the VM's ID changes they keep answering for the
    /// old zone at addresses on the old subnet — names that resolve to
    /// somewhere nothing listens. The entities they describe have to be
    /// recreated to get correct records anyway, so the stale file has no
    /// value; leaving it only produces confusing half-working DNS.
    ///
    /// `services.conf` and `databases.conf` are excluded: mpd regenerates
    /// both from scratch immediately after this runs.
    ///
    /// Returns true when anything was removed (caller restarts dnsmasq —
    /// SIGHUP does not reload the conf dir).
    @discardableResult
    private static func pruneOutOfZoneRecords(in dnsmasqDir: String) -> Bool {
        let managed: Set<String> = ["services.conf", "databases.conf"]
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dnsmasqDir) else { return false }

        var removedAny = false
        for entry in entries where entry.hasSuffix(".conf") && !managed.contains(entry) {
            let path = "\(dnsmasqDir)/\(entry)"
            guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            // `address=/<host>/<ip>` — extract the host and test the zone.
            let hosts = body.components(separatedBy: .newlines).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("address=/") else { return nil }
                let parts = trimmed.dropFirst("address=/".count).split(separator: "/")
                return parts.first.map(String.init)
            }
            guard !hosts.isEmpty, hosts.contains(where: { !Mpd.Net.isInZone($0) }) else { continue }
            try? fm.removeItem(atPath: path)
            removedAny = true
            print("  Removed stale DNS record file \(entry) (not in \(Mpd.Net.zone))")
        }
        return removedAny
    }

    private static func ensureServiceDNSRecords(in dnsmasqDir: String) throws -> Bool {
        let recordsPath = "\(dnsmasqDir)/services.conf"

        var lines: [String] = ["# mpd managed service DNS records"]
        for record in Mpd.serviceDNSRecords {
            // dnsmasq `address=/domain/ip` matches domain + subdomains.
            // Use host-record for the apex alone to avoid wildcard fallback.
            if record.host == Mpd.Net.zone {
                lines.append("host-record=\(record.host),\(record.ip)")
            } else {
                lines.append("address=/\(record.host)/\(record.ip)")
            }
        }

        // `vm.service.<zone>` → this VM's own IP (NOT a container IP).
        // Lets the host-side orchestrator (mpd-virt diag) verify it's
        // talking to THIS VM's dnsmasq by checking the answer matches
        // the expected MPD_VM_IP. Skipped on sandbox VMs (vmIP is empty).
        //
        // PHASE 2: retire this record. Once the zone itself carries the VM
        // ID, `<id>.mpd.test` resolving at all is the same proof.
        if let identity = try? Mpd.VM.Platform.load(), !identity.vmIP.isEmpty {
            lines.append("host-record=\(Mpd.Net.service("vm")),\(identity.vmIP)")
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
            lines.append("address=/\(Mpd.Net.db(db.databaseId))/\(ip)")
        }
        let content = lines.joined(separator: "\n") + "\n"

        let existing = (try? String(contentsOfFile: recordsPath, encoding: .utf8)) ?? ""
        guard existing != content else { return false }

        try content.write(toFile: recordsPath, atomically: true, encoding: .utf8)
        return true
    }

}
