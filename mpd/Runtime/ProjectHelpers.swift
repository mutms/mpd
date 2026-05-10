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

    /// Determine which runtime to use for git clone based on create args.
    static func resolveRuntimeForClone(args: [String]) -> String {
        // Check if user specified a type — use its default runtime
        for arg in args {
            if arg.hasPrefix("--type=") {
                let typeName = String(arg.dropFirst(7))
                let rt = ProjectType(typeName).defaultRuntimeName
                if !rt.isEmpty { return rt }
            }
        }
        return "php" // default
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
        Mpd.Environment.detectUserAndUID().user
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
        let confPath = "\(Mpd.Core.State.dnsmasqDir)/\(project).conf"
        if hosts.isEmpty {
            try? FileManager.default.removeItem(atPath: confPath)
        } else {
            let content = hosts.map { "address=/\($0)/\(runtimeIP)" }.joined(separator: "\n") + "\n"
            try? content.write(toFile: confPath, atomically: true, encoding: .utf8)
        }
        try? Mpd.Core.State.syncBindMountFiles()
        Mpd.Podman.restart(Mpd.Service.Dnsmasq.containerName)
        Mpd.Service.Dnsmasq.waitUntilReady()
    }

    /// Remove dnsmasq conf for a project.
    static func removeDnsmasqRecord(project: String) {
        let confPath = "\(Mpd.Core.State.dnsmasqDir)/\(project).conf"
        try? FileManager.default.removeItem(atPath: confPath)
        try? Mpd.Core.State.syncBindMountFiles()
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

        // Check if cert already exists
        let (rc, _) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            command: ["test", "-f", "/srv/meta/\(project)/cert.pem"],
            suppressStderr: true
        )
        if rc == 0 { return }

        let certsDir = Mpd.Environment.confTempDir
        let caKey = "\(Mpd.Environment.confCARootDir)/rootCA-key.pem"
        let caCert = "\(Mpd.Environment.confCARootDir)/rootCA.pem"
        let tmpDir = Mpd.Environment.confTempDir
        let certPath = "\(tmpDir)/mpd-\(project)-cert.pem"
        let keyPath = "\(tmpDir)/mpd-\(project)-key.pem"
        defer {
            try? FileManager.default.removeItem(atPath: certPath)
            try? FileManager.default.removeItem(atPath: keyPath)
        }

        step("Generating TLS certificate for \(sans.joined(separator: ", "))")
        try Mpd.Environment.Certificate.generateCert(
            sans: sans,
            certPath: certPath,
            keyPath: keyPath,
            caKeyPath: caKey,
            caCertPath: caCert,
            certsDir: certsDir)

        // Write into /srv/meta/<project>/ via accessor container
        let certWriteScript = """
            mkdir -p /srv/meta/\(project) && \
            cat > /srv/meta/\(project)/cert.pem
            """
        let certData = try Data(contentsOf: URL(fileURLWithPath: certPath))
        let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))

        _ = Mpd.Podman.volumeToolRunWithInput(
            command: ["bash", "-c", certWriteScript],
            input: certData
        )

        let keyWriteScript = """
            cat > /srv/meta/\(project)/key.pem && \
            chmod 0600 /srv/meta/\(project)/key.pem
            """
        _ = Mpd.Podman.volumeToolRunWithInput(
            command: ["bash", "-c", keyWriteScript],
            input: keyData
        )
    }
}
