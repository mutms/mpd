// mpd — Mpd.Runtime.DB namespace
// shortName, containerName, parseTag, resolve, waitFor, ensure, create, drop.

import Foundation

// MARK: - Mpd.Runtime.DB

extension Mpd.Runtime.DB {

    // MARK: - Naming

    /// Reversible DB identifier used in DNS/container names.
    /// e.g. "postgres", "17" -> "postgres-17" ; "mariadb", "10.1.1" -> "mariadb-10-1-1"
    static func shortName(engine: String, version: String) -> String {
        "\(engine)-\(version.replacingOccurrences(of: ".", with: "-"))"
    }

    /// Full Podman container name for a DB container.
    /// e.g. "postgres", "17" -> "mpd-db-postgres-17"
    static func containerName(engine: String, version: String) -> String {
        "mpd-db-\(shortName(engine: engine, version: version))"
    }

    /// Data directory path inside the shared volume for a DB engine/version.
    /// e.g. "postgres", "17" -> "/srv/dbs/postgres-17"
    static func dataDir(engine: String, version: String) -> String {
        "/srv/dbs/\(shortName(engine: engine, version: version))"
    }

    /// Allocate the lowest free DB IP in the dedicated `.30–.99` range of
    /// this VM's /24 (`Mpd.Net.dbHostRange`).
    /// IPs are pinned at create time via Podman's `--network mpd-internal:ip=`,
    /// so once allocated they stay stable for the container's lifetime. Slots
    /// vacated by `--db-delete` are reusable.
    /// Throws when the 70-slot pool is full.
    static func allocateIP() throws -> String {
        let used = Set(Mpd.Podman.ps(filter: "label=mpd.type=db").compactMap { item -> Int? in
            // Prefer the explicit label (set on create); fall back to live IP
            // for any DB containers that pre-date this scheme.
            let ipString: String
            if let labelled = item.Labels?["mpd.ip"], !labelled.isEmpty {
                ipString = labelled
            } else if let name = item.Names.first {
                ipString = Mpd.Podman.containerIP(name)
            } else {
                return nil
            }
            // Only addresses inside *this* VM's /24 consume a slot — a
            // container left over from a different subnet must not.
            return Mpd.Net.hostOctet(of: ipString)
        })
        for host in Mpd.Net.dbHostRange where !used.contains(host) {
            return Mpd.Net.ip(host)
        }
        throw RuntimeError("DB IP pool exhausted (\(Mpd.Net.ip(Mpd.Net.dbHostRange.lowerBound))–"
            + "\(Mpd.Net.dbHostRange.upperBound)). Delete unused DB containers first.")
    }

    // MARK: - Tag parsing

    /// Sanitise and parse an MPD_DB tag.
    ///
    /// Accepts an opaque docker image reference with an engine whitelist:
    ///   - `postgres` (bare engine) → expanded to `postgres:latest`
    ///   - `postgres:17`, `postgres:17.2`, `postgres:17-bookworm` (digit-leading version)
    ///   - `postgres:latest` (explicit rolling tag — the only rolling tag allowed)
    ///
    /// Rejects unknown engines and non-`latest` word-only tags
    /// (e.g. `postgres:bookworm`, `postgres:alpine`).
    /// Returns `(engine, version)` where version is the substring after `:`
    /// (or `"latest"` for the bare-engine form).
    static func parseTag(_ raw: String) throws -> (engine: String, version: String) {
        let validEngines = ["postgres", "mariadb", "mysql"]
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let engine = parts[0]
        guard validEngines.contains(engine) else {
            throw RuntimeError("Unknown engine '\(engine)'. Valid values: \(validEngines.joined(separator: ", "))")
        }
        let version = parts.count == 2 ? parts[1] : "latest"
        guard isValidVersion(version) else {
            throw RuntimeError(
                "Invalid version '\(version)' for '\(engine)'. " +
                "Must be 'latest' or start with a digit (e.g. 17, 17.2, 17-bookworm).")
        }
        return (engine: engine, version: version)
    }

    /// Allow `latest` or digit-leading `[a-z0-9.-]+`.
    /// Blocks word-only tags (e.g. `bookworm`, `alpine`) so rolling tags other
    /// than `latest` can't sneak in via mpd.env.
    private static func isValidVersion(_ v: String) -> Bool {
        if v == "latest" { return true }
        guard let first = v.first, first.isASCII, first.isNumber else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        return v.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Container resolution

    /// Resolve engine:version (or databaseId) from argument.
    static func resolve(_ input: String) throws -> (engine: String, version: String, container: String) {
        let knownEngines = ["postgres", "mariadb", "mysql"]

        if input.contains(":") {
            let parts = input.split(separator: ":", maxSplits: 1).map(String.init)
            let engine = parts[0]
            guard knownEngines.contains(engine) else {
                throw RuntimeError(
                    "Unknown engine '\(engine)'. Valid values: \(knownEngines.joined(separator: ", "))")
            }
            return (engine: engine, version: parts[1],
                    container: containerName(engine: engine, version: parts[1]))
        }

        if let engine = knownEngines.first(where: { input == $0 }) {
            // Bare engine name expands to :latest (matches Docker convention
            // and parseTag's expansion).
            let version = "latest"
            return (engine: engine, version: version,
                    container: containerName(engine: engine, version: version))
        }

        // databaseId form: <engine>-<version with dots replaced by dashes>
        if let engine = knownEngines.first(where: { input.hasPrefix("\($0)-") }) {
            let versionPart = String(input.dropFirst(engine.count + 1))
            guard !versionPart.isEmpty else {
                throw RuntimeError("Invalid database id '\(input)'.")
            }
            let version = versionPart.replacingOccurrences(of: "-", with: ".")
            return (engine: engine, version: version,
                    container: containerName(engine: engine, version: version))
        }

        let cName = "mpd-db-\(input)"
        guard Mpd.Podman.exists(cName) else {
            throw RuntimeError("DB container 'mpd-db-\(input)' not found. Use engine:version or databaseId format.")
        }
        let engine  = Mpd.Podman.label(cName, "mpd.db.engine")
        let version = Mpd.Podman.label(cName, "mpd.db.version")
        guard !engine.isEmpty else {
            throw RuntimeError("Could not read engine label from container 'mpd-db-\(input)'.")
        }
        return (engine: engine, version: version, container: cName)
    }

    // MARK: - Wait for readiness

    /// Block until the DB container is accepting connections (up to 60 s).
    /// Engine-specific ping: MariaDB 12.x dropped the `mysqladmin` symlink
    /// in favour of `mariadb-admin`, so the two MySQL-family engines no
    /// longer share a ping binary.
    static func waitFor(engine: String, container: String) throws {
        print("Waiting for \(container) to be ready...")
        let interval: Double = engine == "postgres" ? 1 : 2
        let maxAttempts = 30
        for _ in 0..<maxAttempts {
            Thread.sleep(forTimeInterval: interval)
            let ready: Bool
            switch engine {
            case "postgres":
                ready = Mpd.Podman.execOutput(container, ["pg_isready", "-U", "postgres"]).0 == 0
            case "mariadb":
                ready = Mpd.Podman.execOutput(container,
                            ["mariadb-admin", "-u", "root", "-proot", "ping", "--silent"]).0 == 0
            default: // mysql
                ready = Mpd.Podman.execOutput(container,
                            ["mysqladmin", "-u", "root", "-proot", "ping", "--silent"]).0 == 0
            }
            if ready { return }
        }
        throw RuntimeError(
            "DB container '\(container)' did not become ready within \(Int(Double(maxAttempts) * interval))s.")
    }

    // MARK: - Ensure / create / drop

    /// Ensure a DB container exists and is running; creates it if needed.
    /// Data is stored in the shared data volume at /srv/dbs/<engine><ver>/.
    static func ensure(engine: String, version: String) throws {
        let name      = containerName(engine: engine, version: version)
        let imageBase = engine == "postgres" ? "postgres" : engine
        let image = "docker.io/library/\(imageBase):\(version)"
        let srvPath   = dataDir(engine: engine, version: version)

        // Ensure shared DB parent directory exists in the volume.
        _ = Mpd.Podman.volumeToolRun(command: ["mkdir", "-p", "/srv/dbs"])

        if !Mpd.Podman.exists(name) {
            // Explicit pre-pull so layer-download progress is visible to the
            // user. `podman run -d` would otherwise pull silently and only
            // print the container ID at the end. Cached pulls return in <1s.
            print("Pulling \(image)...")
            guard Mpd.Podman.pull(image) == 0 else {
                throw RuntimeError("Failed to pull image '\(image)'.")
            }

            let ip = try allocateIP()
            print("\(name): creating DB container at \(ip)...")
            var runArgs: [String] = Mpd.VM.optMountRO + [
                "-d", "--name", name,
                "--network", "mpd-internal:ip=\(ip)",
                "-v", "\(Mpd.dataVolume):/srv",
                "--label", "mpd.managed=true",
                "--label", "mpd.name=\(shortName(engine: engine, version: version))",
                "--label", "mpd.ip=\(ip)",
                "--label", "mpd.type=db",
                "--label", "mpd.db.engine=\(engine)",
                "--label", "mpd.db.version=\(version)",
                "--label", "com.docker.compose.project=mpd-db",
                "--network-alias", shortName(engine: engine, version: version),
            ]
            switch engine {
            case "postgres":
                runArgs += [
                    "-e", "POSTGRES_USER=postgres",
                    "-e", "POSTGRES_PASSWORD=postgres",
                    "-e", "PGDATA=\(srvPath)",
                    image,
                    // synchronous_commit=off only risks losing the last
                    // fraction of a second of commits on a crash — bounded,
                    // no corruption. full_page_writes=off is deliberately NOT
                    // set: it turns an unclean shutdown into a torn page
                    // postgres cannot repair, and unclean shutdowns are a
                    // routine event here (OOM, VM reset), not a rare one.
                    "postgres", "-c", "synchronous_commit=off",
                ]
            case "mariadb":
                runArgs += [
                    "-e", "MARIADB_ROOT_PASSWORD=root",
                    image,
                    "--character-set-server=utf8mb4", "--collation-server=utf8mb4_bin",
                    "--datadir=\(srvPath)",
                    "--innodb_file_per_table=On", "--wait-timeout=28800", "--skip-log-bin",
                ]
            case "mysql":
                runArgs += [
                    "-e", "MYSQL_ROOT_PASSWORD=root",
                    image,
                    "--character-set-server=utf8mb4", "--collation-server=utf8mb4_bin",
                    "--datadir=\(srvPath)",
                    "--skip-log-bin",
                ]
            default:
                throw RuntimeError("Unknown engine '\(engine)'")
            }
            guard Mpd.Podman.run(runArgs) == 0 else {
                throw RuntimeError("Failed to create DB container '\(name)'.")
            }
            try waitFor(engine: engine, container: name)

            ok("\(name) is ready.")
        } else if !Mpd.Podman.running(name) {
            print("\(name): starting...")
            guard Mpd.Podman.start(name) == 0 else {
                throw RuntimeError("Failed to start DB container '\(name)'.")
            }
            try waitFor(engine: engine, container: name)
            ok("\(name) is running.")
        }
    }

    /// Create a per-project user and database in a running DB container.
    /// User, password, and database name all match the project name.
    static func create(engine: String, container: String, named dbName: String) throws {
        print("Creating user and database '\(dbName)' in \(container)...")
        let rc: Int32
        switch engine {
        case "postgres":
            // Idempotent role ensure.
            let rcRole = Mpd.Podman.exec(container,
                        ["psql", "-U", "postgres", "-c",
                         "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '\(dbName)') THEN CREATE ROLE \"\(dbName)\" LOGIN PASSWORD '\(dbName)'; ELSE ALTER ROLE \"\(dbName)\" WITH LOGIN PASSWORD '\(dbName)'; END IF; END $$;"])
            guard rcRole == 0 else { throw RuntimeError("Failed to ensure PostgreSQL role '\(dbName)'.") }

            // CREATE DATABASE cannot run inside a DO/transaction block,
            // so probe first and only create when missing.
            let (existsRc, existsOut) = Mpd.Podman.execOutput(container,
                        ["psql", "-U", "postgres", "-tAc",
                         "SELECT 1 FROM pg_database WHERE datname='\(dbName)';"])
            guard existsRc == 0 else {
                throw RuntimeError("Failed to check PostgreSQL database '\(dbName)'.")
            }
            if existsOut.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                rc = 0
            } else {
                rc = Mpd.Podman.exec(container,
                            ["psql", "-U", "postgres", "-c",
                             "CREATE DATABASE \"\(dbName)\" OWNER \"\(dbName)\";"])
            }
        case "mariadb", "mysql":
            let sql = """
                CREATE DATABASE IF NOT EXISTS `\(dbName)` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
                CREATE USER IF NOT EXISTS '\(dbName)'@'%' IDENTIFIED BY '\(dbName)';
                GRANT ALL PRIVILEGES ON `\(dbName)`.* TO '\(dbName)'@'%';
                FLUSH PRIVILEGES;
                """
            // MariaDB 12.x dropped the `mysql` CLI symlink — use engine binary.
            let cli = engine == "mariadb" ? "mariadb" : "mysql"
            rc = Mpd.Podman.exec(container,
                        [cli, "-u", "root", "-proot", "-e", sql])
        default:
            throw RuntimeError("Unknown engine '\(engine)'")
        }
        guard rc == 0 else { throw RuntimeError("Failed to create database '\(dbName)'.") }
    }

    /// Drop a per-project database and user from a DB container.
    static func drop(engine: String, container: String, named dbName: String) throws {
        print("Dropping database and user '\(dbName)' from \(container)...")
        let rc: Int32
        switch engine {
        case "postgres":
            let rcDb = Mpd.Podman.exec(container,
                        ["psql", "-U", "postgres", "-c",
                         "DROP DATABASE IF EXISTS \"\(dbName)\";"])
            rc = Mpd.Podman.exec(container,
                        ["psql", "-U", "postgres", "-c",
                         "DROP ROLE IF EXISTS \"\(dbName)\";"])
            if rcDb != 0 { throw RuntimeError("Failed to drop database '\(dbName)'.") }
        case "mariadb", "mysql":
            let sql = """
                DROP DATABASE IF EXISTS `\(dbName)`;
                DROP USER IF EXISTS '\(dbName)'@'%';
                """
            let cli = engine == "mariadb" ? "mariadb" : "mysql"
            rc = Mpd.Podman.exec(container,
                        [cli, "-u", "root", "-proot", "-e", sql])
        default:
            throw RuntimeError("Unknown engine '\(engine)'")
        }
        guard rc == 0 else { throw RuntimeError("Failed to drop database '\(dbName)'.") }
    }

    // MARK: - State cache rebuild

    /// Walk live DB containers and rewrite the registered-databases state file.
    /// Called whenever DB containers come/go so `<db>.db.<zone>` resolution
    /// and other consumers see a current view.
    static func rebuildStateCache(quiet: Bool = false) {
        let containers = Mpd.Podman.ps(filter: "label=mpd.type=db")
        let entries: [DatabaseStateEntry] = containers.compactMap { item in
            let databaseId = item.Labels?["mpd.name"] ?? ""
            let engine = item.Labels?["mpd.db.engine"] ?? ""
            let version = item.Labels?["mpd.db.version"] ?? ""
            guard !databaseId.isEmpty, !engine.isEmpty, !version.isEmpty else { return nil }
            let containerName = item.Names.first ?? "mpd-db-\(databaseId)"
            let status = item.State == "running" ? "running" : "stopped"
            return DatabaseStateEntry(
                databaseId: databaseId,
                engine: engine,
                version: version,
                containerName: containerName,
                status: status
            )
        }
        let sorted = entries.sorted { $0.databaseId < $1.databaseId }
        Mpd.Runtime.State.saveDatabases(RegisteredDatabases(databases: sorted))
        guard !quiet else { return }
        if sorted.isEmpty {
            ok("No databases found.")
        } else {
            ok("Database cache rebuilt (\(sorted.count) database(s) found).")
        }
    }
}
