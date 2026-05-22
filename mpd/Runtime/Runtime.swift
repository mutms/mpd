// mpd — Mpd.Runtime namespace
//
// A runtime is a Podman *pod* hosting one main container (the "runtime
// container", `mpd-<vmid>-<n>-main`) plus N attached sidecars (Caddy
// frontdoor + on-demand mailpit / selenium / valkey — see Sidecars.swift).
// The pod is named `mpd-<vmid>-<n>` — same as the SSH alias the user
// types from the Mac (`ssh mpd-159-php`). All members share the pod's
// network namespace.
//
// Runtime names must match an `assets/runtimes/<name>/` directory:
// today `php`, `node`, `util`. Each directory ships a `build.sh`
// (phase-2 dev-user provisioning) plus optional `tools/` and
// `project_types/`. Phase-1 root bootstrap is shared across runtimes:
// `assets/runtime-base/bootstrap.sh` (the only root-context script —
// see AGENTS.md §"Mandatory privilege rule").
//
// Lifecycle:
//   create  → build base image if needed, podman pod create, podman run main,
//             phase-1 bootstrap.sh as root, phase-2 build.sh as dev user,
//             install CA, install SSH key, write dnsmasq entry, attach
//             sidecars, persist RuntimeStateEntry.
//   start   → start pod + reconcile sidecars (idempotent).
//   stop    → graceful stop of pod members.
//   delete  → stop, remove pod members + pod, clear dnsmasq entry, drop state.
//
// Created via `mpd --runtime-create=<n>` (host-side flag) or implicitly
// by `mpd create <project>` when the project's runtime doesn't exist yet.
//
// Verb/tool authoring guidance: ARCHITECTURE.md §7, AGENTS.md.

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func runtimeListSupportsAnsiColor() -> Bool {
    guard isatty(STDOUT_FILENO) == 1 else { return false }
    let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
    return !term.isEmpty && term != "dumb"
}

private func runtimeListColorStatusLabel(_ status: String, width: Int) -> String {
    let padded = status.count < width ? status.padding(toLength: width, withPad: " ", startingAt: 0) : status + "  "
    guard runtimeListSupportsAnsiColor() else { return padded }
    switch status {
    case "running":
        return "\u{001B}[32m\(padded)\u{001B}[0m"
    case "stopped":
        return "\u{001B}[33m\(padded)\u{001B}[0m"
    case "available":
        return padded
    default:
        return padded
    }
}

// MARK: - Mpd.Runtime

extension Mpd.Runtime {

    // MARK: - Container naming & discovery

    /// VM ID fragment used as the prefix for every pod/container/hostname.
    /// "100"–"254" for managed VMs, "000" for sandbox. Resolved from
    /// platform.env once per process. Empty if platform.env is missing —
    /// in that case container names will look obviously broken
    /// (`mpd--php`), which is the right signal.
    static let vmId: String = {
        (try? Mpd.Core.Platform.load().vmId) ?? ""
    }()

    /// Convert a runtime short name to its main container name.
    /// e.g. on VM "159" with runtime "php" → "mpd-159-php-main".
    static func containerName(_ name: String) -> String { "mpd-\(vmId)-\(name)-main" }

    /// Convert a runtime short name to its Podman pod name (also the pod's
    /// hostname, since pod members share the UTS namespace).
    /// e.g. on VM "159" with runtime "php" → "mpd-159-php".
    static func runtimePodName(_ name: String) -> String { "mpd-\(vmId)-\(name)" }

    /// Returns all runtime main containers (excludes DB, service).
    static func allContainers() -> [PsItem] {
        Mpd.Podman.ps(filter: "label=mpd.runtime")
    }

    /// All project entries for a given runtime, from projects.json.
    static func projectEntries(_ runtimeName: String) -> [RegisteredProjectRecord] {
        Mpd.Runtime.State.loadProjects().projects.filter { $0.runtimeName == runtimeName }
    }

    /// Short names of all runtimes — used by completion closures.
    static func namesForCompletion() -> [String] {
        var result = allContainers()
            .compactMap { $0.Labels?["mpd.name"] }
            .filter { !$0.isEmpty }
            .sorted()
        result.append(" ")
        return result
    }

    // MARK: - Runtime listing

    static func list() {
        Mpd.Runtime.State.refreshCurrentStateCache()
        let created = allContainers()
        let createdByName = Dictionary(uniqueKeysWithValues: created.compactMap { item -> (String, PsItem)? in
            let name = item.Labels?["mpd.name"] ?? item.Names.first ?? ""
            return name.isEmpty ? nil : (name, item)
        })

        let available = Set(ProjectType.allRuntimeNames())
        let names = Set(createdByName.keys).union(available).sorted()
        guard !names.isEmpty else { print("No runtimes found."); return }

        func col(_ s: String, _ w: Int) -> String {
            s.count < w ? s.padding(toLength: w, withPad: " ", startingAt: 0) : s + "  "
        }
        print(col("NAME", 18) + col("REQUESTED", 12) + col("CURRENT", 10) +
              col("IP", 16) + col("DNS", 28) + "PROJECTS")
        print(String(repeating: "─", count: 100))

        for name in names {
            let item = createdByName[name]
            let ip: String
            let dns: String
            let requestedStr: String
            let currentStr: String

            if let item {
                ip = item.Labels?["mpd.ip"] ?? Mpd.Podman.containerIP(item.Names.first ?? "")
                dns = "\(name).runtime.mpd.test"
                // Persisted intent (requested) drives reconciliation; live
                // observation (current) drives display of what is.
                requestedStr = Mpd.Runtime.State.loadRuntimeStateEntry(name)?.requested ?? "-"
                currentStr = item.State == "running" ? "running" : "stopped"
            } else {
                ip = "—"
                dns = "—"
                requestedStr = "-"
                currentStr = "available"
            }

            let count = projectEntries(name).count
            let pLabel = "\(count) project\(count == 1 ? "" : "s")"
            print(col(name, 18) + runtimeListColorStatusLabel(requestedStr, width: 12) +
                  runtimeListColorStatusLabel(currentStr, width: 10) +
                  col(ip, 16) + col(dns, 28) + pLabel)
        }
    }

    // MARK: - Runtime show

    static func show(_ name: String) throws {
        let cName = containerName(name)
        guard Mpd.Podman.exists(cName) else {
            throw RuntimeError("Runtime '\(name)' does not exist.")
        }
        let ip       = Mpd.Podman.label(cName, "mpd.ip")
        let projects = projectEntries(name)
        let requestedStr = Mpd.Runtime.State.loadRuntimeStateEntry(name)?.requested ?? "-"
        let currentStr = Mpd.Runtime.current(name).rawValue

        print("Name:       \(name)")
        print("IP:         \(ip.isEmpty ? "(unknown)" : ip)")
        print("SSH:        ssh \(name).runtime.mpd.test")
        print("URL:        https://\(name).runtime.mpd.test")
        print("Requested:  \(requestedStr)")
        print("Current:    \(currentStr)")
        if projects.isEmpty {
            print("Projects:   (none)")
        } else {
            for (i, entry) in projects.enumerated() {
                let prefix = i == 0 ? "Projects:   " : "            "
                let url = entry.requested == .running ? "  → https://\(entry.name).mpd.test/" : ""
                var info = "\(entry.name)  \(entry.requested)  \(entry.type)"
                if !entry.databaseEngine.isEmpty { info += "  [\(entry.databaseEngine):\(entry.databaseVersion)]" }
                print("\(prefix)\(info)\(url)")
            }
        }
    }

    // MARK: - Runtime create

    static func create(name: String) throws {
        let fm   = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        guard Mpd.Core.isValidIdentifier(name) else {
            throw RuntimeError(
                "'\(name)' is not a valid runtime name. " +
                "Use lowercase letters and digits only, starting with a letter, minimum 2 characters.")
        }
        guard ProjectType.isValidRuntimeName(name) else {
            let available = ProjectType.allRuntimeNames().joined(separator: ", ")
            throw RuntimeError(
                "No runtime definition found for '\(name)' in assets/runtimes/.\n" +
                "Available runtimes: \(available)\n" +
                "To add a new runtime, create assets/runtimes/\(name)/build.sh")
        }
        let cName = containerName(name)
        guard !Mpd.Podman.exists(cName) else {
            throw RuntimeError("Runtime '\(name)' already exists.")
        }

        let assets     = try Mpd.Core.Assets.path()
        let detectedIdentity = Mpd.detectUserAndUID()
        let user = detectedIdentity.user
        let uid = detectedIdentity.uid

        // IP is fixed per runtime name (one PHP runtime, one Node runtime, etc.) —
        // declared in assets/runtimes/<n>/configuration.json.
        let runtimeIP = try ProjectType.runtimeIP(for: name)

        // Build base image if needed
        let baseImage = "mpd-debian-trixie-systemd"
        if !Mpd.Podman.imageExists(baseImage) {
            step("Building base image '\(baseImage)'")
            let containerfileDir = "\(assets)/runtime-base"
            guard Mpd.Podman.buildImage(tag: baseImage, contextDir: containerfileDir) == 0 else {
                throw RuntimeError("Failed to build base image '\(baseImage)'.")
            }
            ok("Base image '\(baseImage)' built.")
        }

        step("Creating runtime '\(name)'")

        // Create runtime pod. DNS is configured at the network level — see
        // `Mpd.Podman.networkCreate` in ActionSetup,
        // where `--dns 10.163.0.3` (dnsmasq) is set on `mpd-internal`. All
        // containers attached to the network use that for resolution; no
        // per-pod or per-container `--dns` needed.
        // Pod hostname is `mpd-<NNN>-<runtime>` — same as the pod name and
        // the SSH alias the user types from the Mac (`ssh mpd-159-php`),
        // so bash's default `\h` prompt makes the VM unambiguous when
        // SSH'd in. Set on the pod (not the container) because pod members
        // share the UTS namespace. DNS (`<runtime>.runtime.mpd.test`) is
        // unaffected — it resolves by IP via dnsmasq.
        let runtimeHostname = runtimePodName(name)

        guard Mpd.Podman.podCreate([
            "--name", runtimePodName(name),
            "--hostname", runtimeHostname,
            "--network", "mpd-internal:ip=\(runtimeIP)",
            "--label", "com.docker.compose.project=mpd-dev",
        ]) == 0 else {
            throw RuntimeError("Failed to create runtime '\(name)'.")
        }

        // Create main container with data volume mount. `/srv/backups` is a
        // subdirectory of the data volume — backup tools write there, and the
        // dev exits via fileaccess SSH/scp before wiping the volume. No host
        // overlay; see ARCHITECTURE.md §10.
        // mpd-user.env is read by runtime tools at `/srv/personal/mpd-user.env`.
        // The file lives natively in the data volume (synced from the host
        // copy by `Mpd.Core.State.syncBindMountFiles()` on --setup/--start),
        // so the runtime sees it via the `/srv` volume mount below — no
        // separate single-file bind-mount needed.
        let runArgs: [String] = [
            "-d", "--name", cName, "--pod", runtimePodName(name),
            "--systemd", "always",
            "-v", "\(assets):/mnt/assets:ro",
            "-v", "\(Mpd.dataVolume):/srv",
            "--label", "mpd.managed=true",
            "--label", "mpd.name=\(name)",
            "--label", "mpd.runtime=\(name)",
            "--label", "mpd.ip=\(runtimeIP)",
            "--label", "com.docker.compose.project=mpd-dev",
            baseImage, "/sbin/init",
        ]
        guard Mpd.Podman.run(runArgs) == 0 else {
            Mpd.Podman.podRemove(runtimePodName(name))
            throw RuntimeError("Failed to create main container.")
        }

        print("Waiting for systemd to initialise...")
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 1)
            let (_, st) = Mpd.Podman.execOutput(cName, ["systemctl", "is-system-running"])
            if st == "running" || st == "degraded" { break }
        }

        // Provisioning runs in two phases — see AGENTS.md §"Mandatory privilege rule".
        // Phase 1 (root, the one bootstrap exception): create the dev user and
        // lay out /srv. Phase 2 (dev user): build the specific runtime on top.
        step("Bootstrapping runtime base")
        guard Mpd.Podman.exec(cName, ["bash",
                     "/mnt/assets/runtime-base/bootstrap.sh",
                     name, user, uid]) == 0
        else { throw RuntimeError("Runtime '\(name)' base bootstrap failed.") }

        step("Building '\(name)' runtime")
        guard Mpd.Podman.exec(cName, options: ["-u", user], ["bash",
                     "/mnt/assets/runtimes/\(name)/build.sh",
                     name]) == 0
        else { throw RuntimeError("Runtime '\(name)' build failed.") }

        // Install CA cert into runtime trust store
        let caPath = "\(Mpd.confCARootDir)/rootCA.pem"
        if fm.fileExists(atPath: caPath) {
            let cpOk = Mpd.Podman.cp(from: caPath,
                                     to: "\(cName):/usr/local/share/ca-certificates/mpd-local.crt") == 0
                       && Mpd.Podman.exec(cName, ["update-ca-certificates"]) == 0
            if !cpOk { print("Warning: failed to install CA cert into runtime.") }
        }

        // SSH public key
        step("Installing SSH public key")
        try installSSHKey(cName: cName, home: home, user: user)

        // mpd-user.env is bind-mounted RO at runtime container creation (above);
        // no copy step needed. bootstrap.sh symlinks the bind-mount target
        // into the user's home for source-mpd-env.sh.

        // dnsmasq
        step("Writing dnsmasq conf.d entry")
        let confContent = "address=/\(name).runtime.mpd.test/\(runtimeIP)\n"
        try confContent.write(toFile: "\(Mpd.Core.State.dnsmasqDir)/\(name).conf",
                              atomically: true, encoding: .utf8)
        try? Mpd.Core.State.syncBindMountFiles()
        Mpd.Podman.restart(Mpd.Service.Dnsmasq.containerName)
        Mpd.Service.Dnsmasq.waitUntilReady()

        // Write runtime meta
        Mpd.Runtime.State.saveRuntimeStateEntry(RuntimeStateEntry(
            name: name, runtime: name, ip: runtimeIP, requested: "running"))

        // Attach sidecars: frontdoor (always-on) + runtime defaults + URL-kind
        // derived (e.g. selenium when any project has `kind: behat`). At create
        // time no projects exist yet, so the URL-derived signals don't fire here;
        // project lifecycle handlers re-call reconcileSidecars when URLs land.
        step("Attaching runtime sidecars")
        try reconcileSidecars(forRuntime: name)

        // Restore projects with runtimeName=name and status=running
        restoreRunningProjects(name: name, cName: cName)

        // Wait for sshd inside the runtime to bind. The container reports
        // "running" once systemd is up, but services boot async — sshd usually
        // lands a few seconds later. Without this wait, an immediate
        // `ssh user@<rt>.runtime.mpd.test` hits "Connection refused" and
        // looks like a setup failure to the user. Silent on the fast path;
        // prints a one-liner if it actually has to wait noticeably.
        try waitForRuntimeSSHD(ip: runtimeIP)

        print("")
        ok("Runtime '\(name)' is ready.")
        print("""
          IP:   \(runtimeIP)
          SSH:  ssh \(name).runtime.mpd.test
        """)
    }

    /// Block until sshd on the runtime is fully ready to negotiate, up to 30s.
    /// A plain TCP-accept probe isn't enough — there's a window where sshd has
    /// called listen() but isn't ready to send its banner yet, and `ssh` from
    /// the caller hangs in that window. So we open the socket AND read the
    /// banner: sshd sends "SSH-2.0-…" as soon as it can actually negotiate.
    /// First probe runs silently so a fast-booting runtime stays quiet; we
    /// only print the "waiting…" line if the first probe fails.
    private static func waitForRuntimeSSHD(ip: String) throws {
        // bash builtin /dev/tcp opens the socket; `read -t 2` waits up to 2s
        // for sshd to send its banner; the banner check rejects garbage.
        let probeScript = "exec 3<>/dev/tcp/\(ip)/22 2>/dev/null && IFS= read -t 2 -u 3 banner && [[ \"$banner\" == SSH-* ]]"
        let probe: () -> Bool = {
            Mpd.HostExec.capture(
                ["bash", "-c", probeScript],
                suppressStderr: true
            ).0 == 0
        }
        if probe() { return }

        print("  Waiting for sshd to bind on \(ip):22…")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if probe() { return }
        }
        throw RuntimeError("sshd at \(ip):22 didn't accept SSH protocol within 30s. Inspect with: sudo podman logs <runtime-container>")
    }

    // MARK: - Runtime start / stop / delete

    static func start(_ name: String) throws {
        let cName = containerName(name)
        guard Mpd.Podman.exists(cName) else {
            throw RuntimeError("Runtime '\(name)' does not exist.")
        }
        guard Mpd.Podman.podStart(runtimePodName(name)) == 0 else {
            throw RuntimeError("Failed to start runtime '\(name)'.")
        }
        let runtimeIP: String
        if let entry = Mpd.Runtime.State.loadRuntimeStateEntry(name) {
            var updated = entry
            updated.requested = "running"
            Mpd.Runtime.State.saveRuntimeStateEntry(updated)
            runtimeIP = entry.ip
        } else {
            let ip = Mpd.Podman.label(cName, "mpd.ip")
            let runtime = Mpd.Podman.label(cName, "mpd.runtime")
            Mpd.Runtime.State.saveRuntimeStateEntry(RuntimeStateEntry(
                name: name,
                runtime: runtime.isEmpty ? name : runtime,
                ip: ip,
                requested: "running"
            ))
            runtimeIP = ip
        }
        // Same race as runtime-create: pod is up but systemd inside hasn't
        // started sshd yet. Wait so the caller can `ssh` immediately after.
        if !runtimeIP.isEmpty {
            try waitForRuntimeSSHD(ip: runtimeIP)
        }
        ok("Started runtime '\(name)'.")

        // Pre-warm every DB any project on this runtime might need —
        // running or stopped — so subsequent `mpd start <project>` calls
        // never have to wait for a cold-start. Daily dev machines have
        // ~3 DBs total; release-test environments (separate VM, by
        // convention) carry many DB versions. See docs/HOOKS.md
        // §"Resource lifecycle model".
        ensureProjectDatabases(runtimeName: name)

        restoreRunningProjects(name: name, cName: cName)
    }

    /// Ensure every distinct DB (engine,version) used by any project on
    /// `runtimeName` is up. Idempotent; failures log a warning but don't
    /// throw — a single broken DB shouldn't block runtime start, and the
    /// per-project `mpd start <project>` path still ensures its own DB.
    static func ensureProjectDatabases(runtimeName: String) {
        let projects = Mpd.Runtime.State.loadProjects().projects
            .filter { $0.runtimeName == runtimeName && !$0.databaseEngine.isEmpty }
        var seen = Set<String>()
        for proj in projects {
            let key = "\(proj.databaseEngine):\(proj.databaseVersion)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            do {
                try Mpd.Runtime.DB.ensure(engine: proj.databaseEngine, version: proj.databaseVersion)
            } catch {
                errPrint("Warning: failed to ensure DB '\(key)' for runtime '\(runtimeName)': \(error.localizedDescription)")
            }
        }
    }

    static func stop(_ name: String) throws {
        let cName = containerName(name)
        guard Mpd.Podman.exists(cName) else {
            throw RuntimeError("Runtime '\(name)' does not exist.")
        }
        guard Mpd.Podman.podStop(runtimePodName(name)) == 0 else {
            throw RuntimeError("Failed to stop runtime '\(name)'.")
        }
        if let entry = Mpd.Runtime.State.loadRuntimeStateEntry(name) {
            var updated = entry
            updated.requested = "stopped"
            Mpd.Runtime.State.saveRuntimeStateEntry(updated)
        } else {
            let ip = Mpd.Podman.label(cName, "mpd.ip")
            let runtime = Mpd.Podman.label(cName, "mpd.runtime")
            Mpd.Runtime.State.saveRuntimeStateEntry(RuntimeStateEntry(
                name: name,
                runtime: runtime.isEmpty ? name : runtime,
                ip: ip,
                requested: "stopped"
            ))
        }

        // Drop dnsmasq records for projects on this runtime — URLs stop
        // resolving immediately so users don't get confused responses.
        // Project `requested` is preserved (the user didn't ask to stop
        // these projects) — see docs/HOOKS.md §"Resource lifecycle model".
        // When the runtime is started again, restoreRunningProjects
        // re-creates the dnsmasq records.
        let projects = Mpd.Runtime.State.loadProjects().projects
            .filter { $0.runtimeName == name && $0.requested == .running }
        for proj in projects {
            Mpd.Project.removeDnsmasqRecord(project: proj.name)
        }

        ok("Stopped runtime '\(name)'.")
    }

    static func delete(_ name: String, skipPrompt: Bool) throws {
        let fm   = FileManager.default
        let cName = containerName(name)
        guard Mpd.Podman.exists(cName) else {
            throw RuntimeError("Runtime '\(name)' does not exist.")
        }

        let projects = projectEntries(name)
        if !projects.isEmpty {
            let projectList = projects.map { $0.name }.joined(separator: ", ")
            print("Runtime '\(name)' has projects: \(projectList)")
        }
        let user = Mpd.detectUserAndUID().user
        print("Warning: /home/\(user)/ contents inside the runtime will be lost.")
        print("(IDE settings, shell history, manually installed CLIs in ~/.local/bin)")
        print("Preserved (via /srv/personal/): known_hosts, mpd-user.env")

        guard skipPrompt || promptYesNo("Remove runtime '\(name)' and all its containers?") else {
            print("Aborted."); return
        }
        Mpd.Podman.podStop(runtimePodName(name))
        guard Mpd.Podman.podRemove(runtimePodName(name)) == 0 else {
            throw RuntimeError("Failed to remove runtime '\(name)'.")
        }
        // Clean up runtime-level dnsmasq + meta (sidecar-published URLs).
        // Pseudo-project `_runtime-<name>` holds mailpit's canonical URL meta.
        let confPath = "\(Mpd.Core.State.dnsmasqDir)/\(name).conf"
        if fm.fileExists(atPath: confPath) {
            try? fm.removeItem(atPath: confPath)
        }
        let pseudoConf = "\(Mpd.Core.State.dnsmasqDir)/_runtime-\(name).conf"
        if fm.fileExists(atPath: pseudoConf) {
            try? fm.removeItem(atPath: pseudoConf)
        }
        _ = Mpd.Podman.volumeToolRun(command: ["rm", "-rf", "/srv/meta/_runtime-\(name)"])
        try? Mpd.Core.State.syncBindMountFiles()
        Mpd.Podman.restart(Mpd.Service.Dnsmasq.containerName)
        Mpd.Service.Dnsmasq.waitUntilReady()
        Mpd.Runtime.State.deleteRuntimeStateEntry(name)

        // Drop dnsmasq records for orphaned projects — their URLs would
        // otherwise resolve to a now-deleted runtime. Project `requested`
        // is preserved; the user can `mpd <project> delete` explicitly
        // (or wait for `mpd --gc` to reclaim) to clean up the entries.
        let orphaned = Mpd.Runtime.State.loadProjects().projects
            .filter { $0.runtimeName == name && $0.requested == .running }
        for proj in orphaned {
            Mpd.Project.removeDnsmasqRecord(project: proj.name)
        }

        ok("Runtime '\(name)' removed.")
    }

    // MARK: - Project restore (called after runtime create or start)

    static func restoreRunningProjects(name: String, cName: String) {
        let projects = Mpd.Runtime.State.loadProjects().projects
            .filter { $0.runtimeName == name && $0.requested == .running }
        guard !projects.isEmpty else { return }

        let runtimeIP = Mpd.Podman.label(cName, "mpd.ip")

        step("Restoring \(projects.count) project(s) in '\(name)'")
        for proj in projects {
            print("  Restoring '\(proj.name)'...")

            // Ensure per-project TLS cert exists
            try? Mpd.Project.ensureProjectCert(project: proj.name, urls: proj.urls)

            // Run project-setup.sh from the project type's assets directory
            let pType = ProjectType(proj.type)
            if let config = try? pType.loadConfiguration() {
                let args = ["bash", "/mnt/assets/runtimes/\(config.assetsRuntime)/project_types/\(config.assetsType)/project-setup.sh", proj.name]
                Mpd.Project.projectExec(cName, args)
            }

            // Write dnsmasq record for this project
            if !runtimeIP.isEmpty {
                Mpd.Project.writeDnsmasqRecord(project: proj.name, urls: proj.urls,
                                                runtimeIP: runtimeIP)
            }
        }
    }

    // MARK: - Garbage collect unused runtimes

    static func garbageCollect() throws {
        let projects = Mpd.Runtime.State.loadProjects().projects
        let runningRuntimes = Set(projects.filter { $0.requested == .running }.map { $0.runtimeName })
        let containers = allContainers()
        var stopped = 0
        for item in containers {
            let n = item.Labels?["mpd.name"] ?? ""; guard !n.isEmpty else { continue }
            if item.State == "running" && !runningRuntimes.contains(n) {
                print("Stopping unused runtime '\(n)'...")
                try stop(n)
                stopped += 1
            }
        }
        if stopped == 0 { print("No unused runtimes to stop.") }
        else { ok("Stopped \(stopped) unused runtime(s).") }
    }

    // MARK: - Cert reconciliation (called by --setup when CA changes)

    /// Reconcile per-project certs and per-runtime CA trust stores to the
    /// current CA. Per-runtime TLS certs went away with Apache (Phase 8) — the
    /// Caddy frontdoor sidecar serves project certs directly from
    /// `/srv/meta/<project>/{cert,key}.pem`, no copying into runtime needed.
    static func reconcileCertificates() {
        // Renew project certs — delete existing, ensureProjectCert regenerates
        let projects = Mpd.Runtime.State.loadProjects().projects
        for proj in projects where !proj.name.isEmpty {
            print("  Renewing cert for \(proj.name).mpd.test")
            _ = Mpd.Podman.volumeToolOutput(
                command: ["rm", "-f", "/srv/meta/\(proj.name)/cert.pem", "/srv/meta/\(proj.name)/key.pem"],
                suppressStderr: true
            )
            try? Mpd.Project.ensureProjectCert(project: proj.name, urls: proj.urls)
        }

        // Reinstall CA into running runtime trust stores so `curl https://*.mpd.test`
        // from inside containers continues to validate cleanly.
        let caPath = "\(Mpd.confCARootDir)/rootCA.pem"
        let runtimes = allContainers().compactMap { $0.Labels?["mpd.name"] }.filter { !$0.isEmpty }
        for name in runtimes {
            let cName = containerName(name)
            guard Mpd.Podman.running(cName) else { continue }
            if Mpd.Podman.cp(from: caPath, to: "\(cName):/usr/local/share/ca-certificates/mpd-local.crt") == 0 {
                Mpd.Podman.exec(cName, ["update-ca-certificates"])
            }
        }

        ok("Certificate reconciliation completed.")
    }

    // MARK: - Private helpers

    private static func installSSHKey(cName: String, home: String, user: String) throws {
        let fm = FileManager.default

        let lines = Mpd.authorizedPublicKeys(home: home)
        guard !lines.isEmpty else {
            throw RuntimeError("No SSH public keys found for runtime authorization on \(Mpd.label).")
        }
        let keys = lines.joined(separator: "\n") + "\n"

        // Write concatenated keys into a temp file, copy into container
        let tmpFile = NSTemporaryDirectory() + "mpd-authorized-keys"
        try keys.write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: tmpFile) }

        let remoteSshDir = "/home/\(user)/.ssh"
        guard Mpd.Podman.exec(cName, ["mkdir", "-p", remoteSshDir]) == 0,
              Mpd.Podman.cp(from: tmpFile,
                            to: "\(cName):\(remoteSshDir)/authorized_keys") == 0,
              Mpd.Podman.exec(cName, ["chmod", "700", remoteSshDir]) == 0,
              Mpd.Podman.exec(cName, ["chmod", "600", "\(remoteSshDir)/authorized_keys"]) == 0,
              Mpd.Podman.exec(cName, ["chown", "-R", "\(user):\(user)", remoteSshDir]) == 0
        else { throw RuntimeError("Failed to install SSH keys.") }
    }

    // MARK: - State cache rebuild

    /// Walk live runtime containers, prune stale cache entries, and persist the
    /// current view. Counterpart to `Mpd.Runtime.DB.rebuildStateCache`.
    static func rebuildStateCache(quiet: Bool = false) {
        let containers = allContainers()

        let discoveredNames = Set(containers.compactMap { $0.Labels?["mpd.name"] }.filter { !$0.isEmpty })
        let cachedNames = Set(Mpd.Runtime.State.listRuntimeStateEntries().map { $0.name })
        for stale in cachedNames.subtracting(discoveredNames) {
            Mpd.Runtime.State.deleteRuntimeStateEntry(stale)
        }

        for item in containers {
            let n       = item.Labels?["mpd.name"]    ?? ""; guard !n.isEmpty else { continue }
            let runtime = item.Labels?["mpd.runtime"] ?? n
            let ip      = item.Labels?["mpd.ip"]      ?? Mpd.Podman.containerIP(item.Names.first ?? "")
            let status  = item.State == "running" ? "running" : "stopped"
            let meta    = RuntimeStateEntry(name: n, runtime: runtime, ip: ip, requested: status)
            Mpd.Runtime.State.saveRuntimeStateEntry(meta)
        }
        guard !quiet else { return }
        if containers.isEmpty {
            ok("No runtimes found.")
        } else {
            ok("Runtime cache rebuilt (\(containers.count) runtime(s) found).")
        }
    }

    /// Project directories present in the data volume but missing from the
    /// registered-projects cache. Reads `/srv/projects/` from inside the
    /// fileaccess service container; returns sorted names not in `knownNames`.
    static func unregisteredProjectDirectories(knownNames: Set<String>) -> [String] {
        let (_, dirsOut) = Mpd.Podman.volumeToolOutput(
            readOnly: true,
            command: ["bash", "-c", "ls -1 /srv/projects/ 2>/dev/null || true"],
            suppressStderr: true
        )
        return dirsOut.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && !knownNames.contains($0) }
            .sorted()
    }
}
