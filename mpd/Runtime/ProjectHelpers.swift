// mpd — Mpd.Project helpers shared by lifecycle + operations.
//
// **`projectExec(_:_:)`** is the standard way to run a command inside
// a runtime container as the **dev user** (`--user <EXTUSER>`). All
// project-type orchestrator scripts (project-create.sh,
// project-setup.sh, project-delete.sh, scripts/configure.sh) run via
// this helper, which means they execute UNPRIVILEGED. Sudo INSIDE
// those scripts is the right pattern for the few operations that
// need root. See `docs/ARCHITECTURE.md` §7 "Privilege model" and
// `AGENTS.md` for the contract.
//
// **`detectProjectType`** sniffs the source tree to identify the
// project type (moodle / astro / bare / …) when the user didn't pass
// `--type` explicitly at create time.
//
// Other helpers here read project URLs and effective.json values that
// the project-type configure.sh wrote.

import Foundation

extension Mpd.Project {

    /// Determine which runtime to use for the create flow.
    /// Routes to the resolved project type's default runtime — works
    /// equally for explicit `--type=X` and for suffix-autodetected
    /// types (e.g. `mpd create foo-cftunnel` → cftunnel → util).
    /// Falls back to `php` only when the type has no defaultRuntime
    /// configured (or for an unknown type).
    static func resolveRuntimeForClone(typeHint: String) -> String {
        let rt = ProjectType(typeHint).defaultRuntimeName
        return rt.isEmpty ? "php" : rt
    }

    static func ensureRuntime(name: String) throws {
        let cName = Mpd.Runtime.containerName(name)
        if !Mpd.Podman.exists(cName) {
            print("No runtime '\(name)' — creating...")
            try Mpd.Runtime.create(name: name)
        } else if !Mpd.Podman.running(cName) {
            try Mpd.Runtime.start(name)
        }
    }

    /// Effective project user inside runtime containers.
    static func projectExecUser() -> String {
        Mpd.VM.detectUserAndUID().user
    }

    static func projectExecOptions() -> [String] {
        ["--user", projectExecUser()]
    }

    @discardableResult
    static func projectExec(_ container: String, _ args: [String]) -> Int32 {
        Mpd.Podman.exec(container, options: projectExecOptions(), args)
    }

    @discardableResult
    static func projectExecInteractive(_ container: String, _ args: [String]) -> Int32 {
        Mpd.Podman.execInteractive(container, options: projectExecOptions(), args)
    }

    static func detectProjectType(project: String) -> String {
        // Run a quick accessor container to probe the source tree
        let script = """
            if [ -f /srv/projects/\(project)/version.php ] && [ -f /srv/projects/\(project)/lib/moodlelib.php ]; then
                echo moodle
            elif [ -f /srv/projects/\(project)/astro.config.mjs ]; then
                echo astro
            else
                echo ""
            fi
            """
        let (_, out) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            command: ["bash", "-c", script],
            suppressStderr: true
        )
        return out
    }

    /// Read project-type-specific resolved settings from
    /// `/srv/meta/<project>/effective.json`. Returns nil when the file is
    /// missing or unparseable. Keys are project-type-defined (e.g.
    /// `phpVersion` for moodle, `port` for astro). Swift doesn't interpret
    /// them — only displays them in `mpd show <project>`.
    static func readProjectEffectiveDisplay(project: String) -> [String: Any]? {
        let path = "/srv/meta/\(project)/effective.json"
        let (rc, out) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            command: ["bash", "-c", "test -f \(path) && cat \(path) || true"],
            suppressStderr: true)
        guard rc == 0,
              let data = out.data(using: .utf8),
              !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Read the list of project URLs that the project type's `configure.sh` wrote
    /// to `/srv/meta/<project>/urls.json` on the data volume. Returns `[]` when the
    /// file is missing or unparseable — "no URLs" is a valid project state.
    static func readProjectURLs(project: String) -> [ProjectURL] {
        let path = "/srv/meta/\(project)/urls.json"
        let (rc, out) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            command: ["bash", "-c", "test -f \(path) && cat \(path) || true"],
            suppressStderr: true)
        guard rc == 0,
              let data = out.data(using: .utf8),
              !data.isEmpty,
              let urls = try? JSONDecoder().decode([ProjectURL].self, from: data)
        else { return [] }
        return urls
    }

    static func writeProjectMeta(project: String, entry: RegisteredProjectRecord) {
        var meta: [String: Any] = [
            "name": project,
            "runtime": entry.runtimeName,
            "type": entry.type,
        ]

        if !entry.databaseEngine.isEmpty {
            meta["databaseEngine"] = entry.databaseEngine
            meta["databaseVersion"] = entry.databaseVersion
            meta["databaseId"] = entry.databaseId
        }
        meta["webRoot"] = "/srv/projects/\(project)"
        // Always emit `urls` (possibly empty) so consumers don't need to handle
        // "key absent vs present-but-empty" — they're the same thing. The
        // `backend` field is sidecar-internal routing — emitted only when the
        // project type populates it (currently nobody does until Phase 8).
        meta["urls"] = entry.urls.map { url -> [String: Any] in
            var dict: [String: Any] = [
                "label": url.label,
                "kind":  url.kind,
                "url":   url.url,
            ]
            if let backend = url.backend {
                var b: [String: Any] = ["type": backend.type]
                if let fastcgi  = backend.fastcgi  { b["fastcgi"]  = fastcgi }
                if let upstream = backend.upstream { b["upstream"] = upstream }
                if let root     = backend.root     { b["root"]     = root }
                if let tryFiles = backend.tryFiles { b["tryFiles"] = tryFiles }
                if let target   = backend.target   { b["target"]   = target }
                dict["backend"] = b
            }
            return dict
        }
        let json = (try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let script = """
            mkdir -p /srv/meta/\(project) && cat > /srv/meta/\(project)/project.json
            """
        _ = Mpd.Podman.volumeToolRunWithInput(
            command: ["bash", "-c", script],
            input: json
        )
    }

    /// The "main" URL for a running project — first entry whose `kind == "web"`
    /// or `label == "main"`, else the first URL. Empty when the project isn't
    /// running or has no URLs.
    static func projectURL(entry: RegisteredProjectRecord) -> String {
        guard !entry.runtimeName.isEmpty, entry.requested == .running else { return "" }
        if let main = entry.urls.first(where: { $0.kind == "web" || $0.label == "main" }) {
            return main.url
        }
        return entry.urls.first?.url ?? ""
    }

    /// Format project configuration for `mpd <project>` detail view.
    /// e.g. "postgres:17" — empty string if nothing to show. Project-type-specific
    /// runtime details (PHP version, dev-server port, etc.) are not surfaced
    /// here; they live in `/srv/projects/<project>/mpd.env` and are resolved by
    /// `configure.sh`.
    static func configurationDisplay(_ entry: RegisteredProjectRecord) -> String {
        var parts: [String] = []
        if !entry.databaseEngine.isEmpty { parts.append("\(entry.databaseEngine):\(entry.databaseVersion)") }
        return parts.joined(separator: ", ")
    }

    static func parseDB(_ input: String) -> (engine: String, version: String) {
        let parts = input.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (parts[0], "latest")
    }

    // MARK: - dnsmasq per-project records

    /// Extract unique `*.mpd.test` hostnames from a project's URL list, sorted.
    /// Used for both cert SAN generation and dnsmasq record writing — single
    /// source of truth so the two sets can never drift.
    private static func mpdHosts(from urls: [ProjectURL]) -> [String] {
        var seen = Set<String>()
        for u in urls {
            guard let parsed = URL(string: u.url),
                  let host = parsed.host,
                  host == "mpd.test" || host.hasSuffix(".mpd.test")
            else { continue }
            seen.insert(host)
        }
        return seen.sorted()
    }

    /// Write dnsmasq conf for a project: one `address=` line per unique
    /// `*.mpd.test` host in the project's URL list, all pointing at the
    /// runtime IP. Removes the conf if the URL list yields no hosts.
    static func writeDnsmasqRecord(project: String, urls: [ProjectURL], runtimeIP: String) {
        let hosts = mpdHosts(from: urls)
        let confPath = "\(Mpd.VM.dnsmasqDir)/\(project).conf"
        if hosts.isEmpty {
            try? FileManager.default.removeItem(atPath: confPath)
        } else {
            let content = hosts.map { "address=/\($0)/\(runtimeIP)" }.joined(separator: "\n") + "\n"
            try? content.write(toFile: confPath, atomically: true, encoding: .utf8)
        }
        Mpd.Podman.restart(Mpd.Service.Dnsmasq.containerName)
        Mpd.Service.Dnsmasq.waitUntilReady()
    }

    /// Remove dnsmasq conf for a project.
    static func removeDnsmasqRecord(project: String) {
        let confPath = "\(Mpd.VM.dnsmasqDir)/\(project).conf"
        try? FileManager.default.removeItem(atPath: confPath)
        Mpd.Podman.restart(Mpd.Service.Dnsmasq.containerName)
        Mpd.Service.Dnsmasq.waitUntilReady()
    }

    // MARK: - Per-project TLS cert

    /// Generate a per-project TLS cert covering every `*.mpd.test` host in the
    /// project's URL list. No-op when the URL list yields no hosts (project
    /// has no HTTPS surface, e.g. a bare/util project).
    static func ensureProjectCert(project: String, urls: [ProjectURL]) throws {
        let sans = mpdHosts(from: urls)
        guard !sans.isEmpty else { return }

        // Reuse the existing cert only when it already covers exactly the
        // current SAN set. We record the SAN signature alongside the cert
        // (`cert.sans`) at generation time and compare it here — a bare
        // `test -f cert.pem` would keep a stale cert forever, so enabling
        // behat (or any host-adding change) on an existing project would
        // never widen the cert and its `behat.<project>.mpd.test` SNI would
        // fail the TLS handshake. Missing signature (pre-upgrade certs)
        // counts as a mismatch, forcing a one-time regeneration.
        let sansSignature = sans.joined(separator: "\n")
        let (rc, existingSig) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            command: [
                "bash", "-c",
                "test -f /srv/meta/\(project)/cert.pem && cat /srv/meta/\(project)/cert.sans",
            ],
            suppressStderr: true
        )
        if rc == 0
            && existingSig.trimmingCharacters(in: .whitespacesAndNewlines) == sansSignature {
            return
        }

        let certsDir = Mpd.VM.confTempDir
        let caKey = "\(Mpd.VM.confCARootDir)/rootCA-key.pem"
        let caCert = "\(Mpd.VM.confCARootDir)/rootCA.pem"
        let tmpDir = Mpd.VM.confTempDir
        let certPath = "\(tmpDir)/mpd-\(project)-cert.pem"
        let keyPath = "\(tmpDir)/mpd-\(project)-key.pem"
        defer {
            try? FileManager.default.removeItem(atPath: certPath)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        step("Generating TLS certificate for \(sans.joined(separator: ", "))")
        try Mpd.VM.Certificate.generateCert(
            sans: sans,
            certPath: certPath,
            keyPath: keyPath,
            caKeyPath: caKey,
            caCertPath: caCert,
            certsDir: certsDir)

        // Write into /srv/meta/<project>/ via accessor container. Each file
        // is written to a temp path and renamed into place: the Caddy
        // frontdoor watches this directory and re-validates on every change,
        // so a half-written cert.pem would fail `caddy validate` and get the
        // reload skipped — leaving Caddy serving the pre-widening cert until
        // a manual restart. An atomic rename means the watcher only ever
        // observes a complete file.
        let certWriteScript = """
            mkdir -p /srv/meta/\(project) && \
            cat > /srv/meta/\(project)/cert.pem.tmp && \
            mv -f /srv/meta/\(project)/cert.pem.tmp /srv/meta/\(project)/cert.pem
            """
        let certData = try Data(contentsOf: URL(fileURLWithPath: certPath))
        let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))

        _ = Mpd.Podman.volumeToolRunWithInput(
            command: ["bash", "-c", certWriteScript],
            input: certData
        )

        let keyWriteScript = """
            cat > /srv/meta/\(project)/key.pem.tmp && \
            chmod 0600 /srv/meta/\(project)/key.pem.tmp && \
            mv -f /srv/meta/\(project)/key.pem.tmp /srv/meta/\(project)/key.pem
            """
        _ = Mpd.Podman.volumeToolRunWithInput(
            command: ["bash", "-c", keyWriteScript],
            input: keyData
        )

        // Record the SAN signature so a later ensureProjectCert can tell
        // whether the cert still covers the project's current host set.
        _ = Mpd.Podman.volumeToolRunWithInput(
            command: ["bash", "-c", "cat > /srv/meta/\(project)/cert.sans"],
            input: Data(sansSignature.utf8)
        )

        // The Caddy frontdoor loads project certs from file and caches them in
        // memory; it does NOT evict a superseded cert on config reload (a
        // `caddy reload` keeps serving the old cert for the same SNI). Only a
        // full process restart clears the cache. So a running frontdoor would
        // keep presenting the pre-regeneration cert — e.g. after enabling
        // behat, the widened `behat.<project>.mpd.test` SAN would be on disk
        // but never served. Restart the frontdoor now that the new cert is in
        // place. Skipped when it isn't running (initial create/start, or
        // runtimes without a frontdoor): it reads the current cert on start.
        if let runtime = Mpd.Runtime.State.loadProjects().projects
            .first(where: { $0.name == project })?.runtimeName, !runtime.isEmpty {
            let frontdoor = Mpd.Runtime.frontdoorSidecarSpec()
                .containerName(in: Mpd.Runtime.runtimePodName(runtime))
            if Mpd.Podman.running(frontdoor) {
                _ = Mpd.Podman.restart(frontdoor)
            }
        }
    }
}
