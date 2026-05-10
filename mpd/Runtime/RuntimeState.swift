import Foundation

// Runtime/project registry persisted under ~/.mpd/machines/<machine>/.
// Owns "known/registered" records (projects, runtimes, selected databaseId, status intent).
// Does not query or represent live container truth directly (Podman is authoritative for live state).

// MARK: - Mpd.Runtime.State

extension Mpd.Runtime.State {
    /// Runtimes metadata directory for the active machine.
    static var runtimesDir: String { "\(Mpd.Core.State.machineDir())/runtimes" }

    static var projectsPath: String { "\(Mpd.Core.State.machineDir())/projects.json" }
    static var databasesPath: String { "\(Mpd.Core.State.machineDir())/databases.json" }

    static func loadProjects() -> RegisteredProjects {
        JSONStateStore.readJSON(projectsPath, as: RegisteredProjects.self) ?? RegisteredProjects()
    }

    static func saveProjects(_ state: RegisteredProjects) {
        JSONStateStore.writeJSON(state, to: projectsPath)
        refreshCurrentStateCache()
    }

    static func upsertProject(_ project: RegisteredProjectRecord) {
        var state = loadProjects()
        if let idx = state.projects.firstIndex(where: { $0.name == project.name }) {
            state.projects[idx] = project
        } else {
            state.projects.append(project)
        }
        saveProjects(state)
    }

    static func deleteProject(_ name: String) {
        var state = loadProjects()
        state.projects.removeAll { $0.name == name }
        saveProjects(state)
    }

    static func getProject(_ name: String) -> RegisteredProjectRecord? {
        loadProjects().projects.first { $0.name == name }
    }

    static func runtimeStatePath(_ name: String) -> String {
        "\(runtimesDir)/\(name)/meta.json"
    }

    static func loadRuntimeStateEntry(_ name: String) -> RuntimeStateEntry? {
        JSONStateStore.readJSON(runtimeStatePath(name), as: RuntimeStateEntry.self)
    }

    static func saveRuntimeStateEntry(_ entry: RuntimeStateEntry) {
        JSONStateStore.writeJSON(entry, to: runtimeStatePath(entry.name))
        refreshCurrentStateCache()
    }

    static func deleteRuntimeStateEntry(_ name: String) {
        let dir = "\(runtimesDir)/\(name)"
        try? FileManager.default.removeItem(atPath: dir)
        refreshCurrentStateCache()
    }

    static func listRuntimeStateEntries() -> [RuntimeStateEntry] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: runtimesDir)
        else { return [] }
        return entries.compactMap { loadRuntimeStateEntry($0) }
    }

    static func loadDatabases() -> RegisteredDatabases {
        JSONStateStore.readJSON(databasesPath, as: RegisteredDatabases.self) ?? RegisteredDatabases()
    }

    static func saveDatabases(_ state: RegisteredDatabases) {
        JSONStateStore.writeJSON(state, to: databasesPath)
    }
}

// MARK: - Registered projects

enum ProjectLifecycleStatus: String, Codable {
    case notConfigured = "not-configured"
    case stopped
    case running
}

/// Sidecar-internal routing info for a `ProjectURL`. The frontdoor sidecar
/// (Phase 8 — Caddy) reads this to generate its routing config. Portal/TUI/CLI
/// ignore it entirely; it's user-invisible.
///
/// Two backend types are supported:
/// - `php-fpm`: `fastcgi` is the FPM listen address (TCP `host:port` or
///   `unix//path/to/sock`); `root` is the document root inside the runtime
///   container; `tryFiles` is the Caddy try_files chain (e.g.
///   `["{path}", "{path}/index.php", "/r.php"]` for Moodle 5.0).
/// - `reverse-proxy`: `upstream` is the full URL the sidecar proxies to
///   (e.g. `http://127.0.0.1:4321` for Astro). Other fields ignored.
struct ProjectURLBackend: Codable {
    var type: String
    var fastcgi: String?
    var upstream: String?
    var root: String?
    var tryFiles: [String]?
    /// `redirect` backend: the absolute URL Caddy 302-redirects to.
    /// Used by per-project mail URLs that shortcut to a runtime-level
    /// canonical mailpit URL with a search filter applied.
    var target: String?

    init(type: String, fastcgi: String? = nil, upstream: String? = nil,
         root: String? = nil, tryFiles: [String]? = nil, target: String? = nil) {
        self.type = type
        self.fastcgi = fastcgi
        self.upstream = upstream
        self.root = root
        self.tryFiles = tryFiles
        self.target = target
    }
}

/// A user-facing URL for a project. Populated by the project type's `configure.sh`
/// (which writes `/srv/meta/<project>/urls.json`) and read by the portal, TUI,
/// cert generation (SAN extraction), and dnsmasq record writer.
struct ProjectURL: Codable {
    /// Visible chip text on the portal/TUI (e.g. "main", "behat", "wrangler").
    var label: String
    /// Discriminator for portal styling — "web", "behat", "devport", …
    var kind: String
    /// Full URL string as displayed and clicked.
    var url: String
    /// Sidecar routing info (Phase 8). Optional — when nil, the URL is
    /// informational only (no sidecar route is generated for it).
    var backend: ProjectURLBackend?

    init(label: String, kind: String, url: String, backend: ProjectURLBackend? = nil) {
        self.label = label
        self.kind = kind
        self.url = url
        self.backend = backend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label   = try c.decode(String.self, forKey: .label)
        kind    = try c.decode(String.self, forKey: .kind)
        url     = try c.decode(String.self, forKey: .url)
        backend = try c.decodeIfPresent(ProjectURLBackend.self, forKey: .backend)
    }
}

struct RegisteredProjectRecord: Codable {
    var name: String
    var type: String
    var databaseId: String
    var databaseEngine: String
    var databaseVersion: String
    var runtimeName: String
    /// Persisted intent: what the user has asked the project's state to be.
    /// Mutated only by explicit verbs (`mpd <p> create/start/stop/delete`).
    /// `current` (live observation) lives in `Mpd.Project.current(_:)`.
    var requested: ProjectLifecycleStatus
    var urls: [ProjectURL]

    init(
        name: String,
        type: String = "",
        databaseId: String = "",
        databaseEngine: String = "",
        databaseVersion: String = "",
        runtimeName: String = "",
        requested: ProjectLifecycleStatus = .notConfigured,
        urls: [ProjectURL] = []
    ) {
        self.name = name
        self.type = type
        self.databaseId = databaseId
        self.databaseEngine = databaseEngine
        self.databaseVersion = databaseVersion
        self.runtimeName = runtimeName
        self.requested = requested
        self.urls = urls
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name            = try c.decode(String.self, forKey: .name)
        type            = try c.decode(String.self, forKey: .type)
        databaseId      = try c.decode(String.self, forKey: .databaseId)
        databaseEngine  = try c.decode(String.self, forKey: .databaseEngine)
        databaseVersion = try c.decode(String.self, forKey: .databaseVersion)
        runtimeName     = try c.decode(String.self, forKey: .runtimeName)
        requested       = try c.decode(ProjectLifecycleStatus.self, forKey: .requested)
        urls            = try c.decodeIfPresent([ProjectURL].self, forKey: .urls) ?? []
    }
}

struct RegisteredProjects: Codable {
    var projects: [RegisteredProjectRecord]

    init() {
        projects = []
    }
}

// MARK: - Runtime state entry

struct RuntimeStateEntry: Codable {
    var name: String
    var runtime: String
    var ip: String
    /// Persisted intent: "running" or "stopped". Mutated only by explicit
    /// runtime verbs (`mpd --runtime-create/start/stop/delete`). The live
    /// observation lives in `Mpd.Runtime.current(_:)`.
    var requested: String?

    init(name: String, runtime: String, ip: String, requested: String? = nil) {
        self.name = name
        self.runtime = runtime
        self.ip = ip
        self.requested = requested
    }
}

struct DatabaseStateEntry: Codable {
    var databaseId: String
    var engine: String
    var version: String
    var containerName: String
    var status: String
}

struct RegisteredDatabases: Codable {
    var databases: [DatabaseStateEntry]

    init() {
        databases = []
    }

    init(databases: [DatabaseStateEntry]) {
        self.databases = databases
    }
}
