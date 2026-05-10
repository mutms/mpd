// mpd — Mpd.Runtime sidecar machinery
//
// Sidecars are auxiliary containers attached to a runtime pod (sharing its
// network namespace). The Caddy frontdoor (Phase 8) is the first user; selenium,
// mailpit, and valkey will follow in Phase 9. Reconciliation is a single
// idempotent operation: given a desired set of sidecar roles, attach the
// missing ones and detach any that are no longer wanted.
//
// Pod members carry an `mpd.role=<role>-sidecar` label so we can list and diff
// without juggling separate state.

import Foundation

/// Description of a single sidecar container.
struct SidecarSpec {
    /// Stable role name (e.g. "frontdoor", "selenium"). Used to derive the
    /// container name and the `mpd.role` label.
    let role: String
    /// Image reference (`localhost/...` for mpd-built images,
    /// `docker.io/...` for upstream).
    let image: String
    /// Optional path under `assets/sidecars/<role>/` containing a Containerfile;
    /// when set and `image` is missing locally, mpd builds it before attaching.
    let buildContext: String?
    /// Extra `podman run` flags appended after the standard pod/label/volume
    /// flags. Volume mounts, env vars, labels, etc.
    let extraArgs: [String]

    init(role: String, image: String, buildContext: String? = nil, extraArgs: [String] = []) {
        self.role = role
        self.image = image
        self.buildContext = buildContext
        self.extraArgs = extraArgs
    }

    /// Container name for this sidecar in a given pod.
    /// e.g. role="frontdoor" + pod="mpd-runtime-php" → "mpd-runtime-php-frontdoor"
    func containerName(in podName: String) -> String {
        "\(podName)-\(role)"
    }
}

extension Mpd.Runtime {

    /// Roles of sidecars currently attached to a pod (label `mpd.role=*-sidecar`).
    static func attachedSidecarRoles(in podName: String) -> Set<String> {
        let containers = Mpd.Podman.ps(filter: "label=mpd.role").filter { item in
            (item.Labels?["mpd.pod"] ?? "") == podName
        }
        var roles = Set<String>()
        for item in containers {
            if let role = item.Labels?["mpd.role"], role.hasSuffix("-sidecar") {
                roles.insert(String(role.dropLast("-sidecar".count)))
            }
        }
        return roles
    }

    /// Build the sidecar image from its `assets/sidecars/<role>/Containerfile` if
    /// the image isn't present locally. No-op when already cached.
    private static func ensureSidecarImage(_ spec: SidecarSpec) throws {
        guard !Mpd.Podman.imageExists(spec.image) else { return }
        guard let context = spec.buildContext else {
            // Upstream image; pull instead.
            guard Mpd.Podman.pull(spec.image, quiet: true) == 0 else {
                throw RuntimeError("Failed to pull sidecar image '\(spec.image)'.")
            }
            return
        }
        let assetsDir = try Mpd.Core.Assets.path()
        let contextDir = "\(assetsDir)/\(context)"
        step("Building sidecar image '\(spec.image)'")
        guard Mpd.Podman.buildImage(tag: spec.image, contextDir: contextDir) == 0 else {
            throw RuntimeError("Failed to build sidecar image '\(spec.image)' from \(contextDir).")
        }
    }

    /// Attach a sidecar to a pod. Idempotent — if a container with the role's
    /// name already exists, leaves it alone. Builds the image first if missing.
    static func attachSidecar(_ spec: SidecarSpec, to podName: String) throws {
        try ensureSidecarImage(spec)

        let cName = spec.containerName(in: podName)
        if Mpd.Podman.exists(cName) {
            if !Mpd.Podman.running(cName) {
                _ = Mpd.Podman.startQuietly(cName)
            }
            return
        }

        var args: [String] = [
            "-d", "--name", cName, "--pod", podName,
            "--label", "mpd.managed=true",
            "--label", "mpd.role=\(spec.role)-sidecar",
            "--label", "mpd.pod=\(podName)",
            "--restart", "always",
        ]
        args += spec.extraArgs
        args.append(spec.image)
        guard Mpd.Podman.run(args) == 0 else {
            throw RuntimeError("Failed to attach \(spec.role) sidecar to '\(podName)'.")
        }
    }

    /// Detach a sidecar by role from a pod. No-op when nothing matches.
    static func detachSidecar(role: String, from podName: String) {
        // Multiple roles could in theory map to the same pod; remove every
        // container we find with the matching label.
        let matching = Mpd.Podman.ps(filter: "label=mpd.role=\(role)-sidecar").filter {
            ($0.Labels?["mpd.pod"] ?? "") == podName
        }
        for item in matching {
            guard let name = item.Names.first else { continue }
            _ = Mpd.Podman.removeForcefully(name)
        }
    }

    /// Reconcile the set of attached sidecars on a runtime's pod against a
    /// desired set. Adds missing, removes extras. Idempotent.
    static func reconcileSidecars(runtime: String, desired: [SidecarSpec]) throws {
        let podName = runtimePodName(runtime)
        guard Mpd.Podman.podExists(podName) else { return }

        let desiredRoles = Set(desired.map(\.role))
        let attached = attachedSidecarRoles(in: podName)

        for spec in desired where !attached.contains(spec.role) {
            try attachSidecar(spec, to: podName)
        }
        for role in attached.subtracting(desiredRoles) {
            detachSidecar(role: role, from: podName)
        }

        reconcileMailpitRuntimeMeta(runtime: runtime,
                                    mailpitAttached: desiredRoles.contains("mailpit"))
    }

    /// Manage the runtime-level mailpit URL — `mail.<runtime>.mpd.test/` —
    /// that the mailpit sidecar exposes. Stored under a pseudo-project named
    /// `_runtime-<runtime>` so it flows through the existing per-project
    /// meta plumbing (Caddy globs `/srv/meta/*/urls.json`, reads cert at
    /// `/srv/meta/<project>/cert.pem`, dnsmasq writes a `<project>.conf`).
    /// The leading underscore guarantees no collision with a real project
    /// (project names must start with a lowercase letter).
    ///
    /// Per-project mail URLs (`mail.<project>.mpd.test/`) are 302 shortcuts
    /// to this canonical URL with `?q=<project>.mpd.test` applied — see
    /// `assets/runtimes/php/project_types/moodle/scripts/configure.sh`.
    private static func reconcileMailpitRuntimeMeta(runtime: String, mailpitAttached: Bool) {
        let pseudoProject = "_runtime-\(runtime)"
        let host = "mail.\(runtime).mpd.test"

        if mailpitAttached {
            let urls = [ProjectURL(
                label: "mail",
                kind: "mail",
                url: "https://\(host)/",
                backend: ProjectURLBackend(type: "reverse-proxy",
                                           upstream: "http://127.0.0.1:8025")
            )]

            // Write urls.json into /srv/meta/_runtime-<rt>/.
            let payload = (try? JSONEncoder().encode(urls)) ?? Data()
            let writeScript = """
                mkdir -p /srv/meta/\(pseudoProject) && \
                cat > /srv/meta/\(pseudoProject)/urls.json
                """
            _ = Mpd.Podman.volumeToolRunWithInput(
                command: ["bash", "-c", writeScript],
                input: payload
            )

            // Cert covers `mail.<runtime>.mpd.test`.
            try? Mpd.Project.ensureProjectCert(project: pseudoProject, urls: urls)

            // dnsmasq record so the host resolves to the runtime IP.
            if let ip = try? ProjectType.runtimeIP(for: runtime) {
                Mpd.Project.writeDnsmasqRecord(project: pseudoProject, urls: urls, runtimeIP: ip)
            }
        } else {
            _ = Mpd.Podman.volumeToolRun(command: ["rm", "-rf", "/srv/meta/\(pseudoProject)"])
            Mpd.Project.removeDnsmasqRecord(project: pseudoProject)
        }
    }
}

// MARK: - Built-in sidecar specs

extension Mpd.Runtime {

    /// Caddy frontdoor sidecar — terminates TLS, routes by `urls.json`.
    /// Opt-in via `defaultSidecars: ["frontdoor"]` in a runtime's
    /// configuration.json. PHP and node declare it (they serve project
    /// URLs at `*.mpd.test`). util doesn't, since cftunnel and similar
    /// utility project types don't expose `.mpd.test` URLs.
    static func frontdoorSidecarSpec() -> SidecarSpec {
        SidecarSpec(
            role: "frontdoor",
            image: "localhost/mpd-caddy-sidecar:latest",
            buildContext: "sidecars/caddy",
            extraArgs: [
                // Read-only access to /srv (urls.json + per-project certs).
                "-v", "\(Mpd.dataVolume):/srv:ro",
            ]
        )
    }

    /// Mailpit sidecar — SMTP catcher on `localhost:1025`, web UI on
    /// `localhost:8025`. Per-runtime (each pod gets its own); attached when a
    /// runtime declares `defaultSidecars: ["mailpit"]` in its configuration.json
    /// or a project type requests it.
    static func mailpitSidecarSpec() -> SidecarSpec {
        SidecarSpec(
            role: "mailpit",
            image: "docker.io/axllent/mailpit:latest",
            extraArgs: []
        )
    }

    /// Selenium standalone-chromium sidecar. Reachable on `localhost:4444`
    /// (Selenium WebDriver JSON wire protocol) inside the runtime pod.
    /// Attached on demand when any project on the runtime has a `kind: behat`
    /// URL (Phase 9.2 trigger source). Image is ~1.5 GB so we only pull/pin it
    /// when actually needed.
    static func seleniumSidecarSpec() -> SidecarSpec {
        SidecarSpec(
            role: "selenium",
            image: "docker.io/selenium/standalone-chromium:latest",
            extraArgs: []
        )
    }

    /// Valkey (Redis-compatible) cache sidecar on `localhost:6379`. Attached
    /// when a project type's configuration.json declares `sidecars: ["valkey"]`.
    static func valkeySidecarSpec() -> SidecarSpec {
        SidecarSpec(
            role: "valkey",
            image: "docker.io/valkey/valkey:8",
            extraArgs: []
        )
    }

    /// Resolve a sidecar role name to its spec. Returns nil for unknown roles.
    /// Central place to extend when adding new sidecars.
    static func sidecarSpec(forRole role: String) -> SidecarSpec? {
        switch role {
        case "frontdoor": return frontdoorSidecarSpec()
        case "mailpit":   return mailpitSidecarSpec()
        case "selenium":  return seleniumSidecarSpec()
        case "valkey":    return valkeySidecarSpec()
        default:          return nil
        }
    }

    /// Compute the desired sidecar set for a runtime. Combines three signals:
    ///   1. Runtime-declared defaults: `assets/runtimes/<n>/configuration.json`
    ///      `defaultSidecars` field. PHP/node list `frontdoor` (and PHP also
    ///      lists `mailpit`); util declares none.
    ///   2. Project-type-required: each project's
    ///      `assets/runtimes/<rt>/project_types/<t>/configuration.json` `sidecars`
    ///      field (e.g. valkey when a project type declares it as a sidecar).
    ///   3. URL-kind-derived: any project with a `kind: behat` URL pulls in the
    ///      selenium sidecar.
    static func desiredSidecars(forRuntime name: String) -> [SidecarSpec] {
        var roles: [String] = []
        roles.append(contentsOf: ProjectType.runtimeDefaultSidecars(for: name))

        let projects = Mpd.Runtime.State.loadProjects().projects.filter { $0.runtimeName == name }

        // (3) project-type-required sidecars
        for proj in projects {
            if let cfg = try? ProjectType(proj.type).loadConfiguration() {
                roles.append(contentsOf: cfg.sidecars)
            }
        }

        // (4) URL-kind-derived: kind:behat → selenium
        if projects.contains(where: { $0.urls.contains(where: { $0.kind == "behat" }) }) {
            roles.append("selenium")
        }

        // Dedupe preserving order; skip unknown roles.
        var seen = Set<String>()
        var specs: [SidecarSpec] = []
        for role in roles where seen.insert(role).inserted {
            if let spec = sidecarSpec(forRole: role) { specs.append(spec) }
        }
        return specs
    }

    /// Convenience wrapper — computes the desired set and reconciles in one
    /// call. Use this from project lifecycle handlers (configure, start, stop,
    /// delete) so URL-derived sidecars track project changes automatically.
    static func reconcileSidecars(forRuntime name: String) throws {
        try reconcileSidecars(runtime: name, desired: desiredSidecars(forRuntime: name))
    }
}
