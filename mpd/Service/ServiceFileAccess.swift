// mpd — Mpd.Service.FileAccess namespace
// File access service: long-running container with the data volume mounted.
// Container: mpd-service-fileaccess at 10.163.0.5
//
// Two access paths:
//
//   1. `podman exec` — used by Mpd.Podman.volumeTool* for volume operations
//      (the latency-saving primary use). Auth-free at the podman level,
//      bypasses sshd entirely.
//
//   2. ssh / scp / sftp — for ad-hoc file access from the dev's laptop.
//      Pubkey-only, single user (`$EXTUSER`), no sudo. Listens only on the
//      internal podman network (no -p mapping), so the SSH endpoint is
//      reachable solely via the
//      laptop→VM tunnel.
//
// Mounts the data volume at `/srv` (no host overlay on either mode). Backup
// artifacts written by runtime verbs land at `/srv/backups/` on the volume;
// devs pull them off via this service's SSH/scp endpoint before wiping the
// volume. See ARCHITECTURE.md §10 for the single-transit-point contract.
//
// Authorized keys are sourced from `$HOME/.ssh/authorized_keys` on machine
// (cloud-init populated it with the dev's laptop pubkey). Bind-mounted
// read-only into the container so a laptop ssh works out of the box.

import Foundation

extension Mpd.Service.FileAccess {

    static let descriptor = Mpd.ServiceDescriptor(
        name: "fileaccess",
        ip: "10.163.0.5",
        accessHint: "ssh / scp at fileaccess.service.mpd.test (pubkey-only, internal)",
        setup: setup,
        start: start,
        stop: stop
    )

    static var containerName: String { descriptor.containerName }
    static var ip: String { descriptor.ip }
    static let imageTag = "localhost/mpd-fileaccess:latest"

    /// Bump when container setup changes (image, mounts, command, env).
    static let revision = "9"

    private static let revisionLabel = "mpd.service.revision"

    private static let commonLabels: [String] = [
        "--label", "mpd.managed=true",
        "--label", "mpd.type=service",
        "--label", "mpd.name=fileaccess",
        "--label", "com.docker.compose.project=mpd-service",
    ]

    /// Mount args. The data volume is always at /srv (so `/srv/backups/` is a
    /// volume subdirectory). The VM user's `authorized_keys` is bind-mounted
    /// read-only so SSH into fileaccess works on first boot.
    private static func mountArgs(extuser: String, hostHome: String) -> [String] {
        var args: [String] = [
            "-v", "\(Mpd.dataVolume):/srv",
            "-v", "\(Mpd.Core.State.fileAccessHostKeysDir):/etc/ssh/keys",
        ]
        if !extuser.isEmpty, !hostHome.isEmpty {
            args += [
                "-v",
                "\(hostHome)/.ssh/authorized_keys:/home/\(extuser)/.ssh/authorized_keys:ro",
            ]
        }
        return args
    }

    /// Build the local fileaccess image if it isn't already present.
    private static func ensureImage() throws {
        guard !Mpd.Podman.imageExists(imageTag) else { return }
        let assetsDir = try Mpd.Core.Assets.path()
        let contextDir = "\(assetsDir)/services/fileaccess"
        step("Building fileaccess image")
        guard Mpd.Podman.buildImage(tag: imageTag, contextDir: contextDir) == 0 else {
            throw RuntimeError("Failed to build fileaccess image from \(contextDir).")
        }
    }

    // MARK: - Container lifecycle

    /// Create and start the fileaccess container. Called by --setup. Idempotent.
    /// Must come up BEFORE any other code path uses `Mpd.Podman.volumeTool*`,
    /// since those calls now exec into this container.
    static func setup() throws {
        try ensureImage()

        // Persistent host-keys directory — survives container rebuilds, so
        // SSH fingerprints are stable.
        let hostKeysDir = Mpd.Core.State.fileAccessHostKeysDir
        try FileManager.default.createDirectory(
            atPath: hostKeysDir, withIntermediateDirectories: true)

        Mpd.Podman.removeIfOutdated(containerName, labels: [revisionLabel: revision])

        let identity = Mpd.detectUserAndUID()
        let hostHome = ProcessInfo.processInfo.environment["HOME"] ?? ""

        if !Mpd.Podman.exists(containerName) {
            guard Mpd.Podman.run(
                ["-d", "--name", containerName,
                 "--network", "mpd-internal:ip=\(ip)",
                 "--restart", "always",
                 "-e", "EXTUSER=\(identity.user)",
                 "-e", "EXTUID=\(identity.uid)",
                 "--label", "\(revisionLabel)=\(revision)"]
                + commonLabels
                + mountArgs(extuser: identity.user, hostHome: hostHome)
                + [imageTag]
            ) == 0 else {
                throw RuntimeError("Failed to create service 'fileaccess'.")
            }
            ok("fileaccess running.")
        } else if !Mpd.Podman.running(containerName) {
            Mpd.Podman.startQuietly(containerName)
            ok("fileaccess running.")
        } else {
            ok("fileaccess already running.")
        }

        // Race-free guarantee: entry.sh inside the container also ensures
        // /srv/<dir> exists user-owned, but it runs asynchronously after
        // `podman run -d` returns. Subsequent --setup steps (e.g.
        // PersonalArea.provision) call volumeTool* immediately and would
        // otherwise race ahead of entry.sh on a fresh container. This
        // explicit root-mode exec runs through podman's normal "wait for
        // container ready" semantics and is idempotent with entry.sh.
        ensureDataVolumeDirectories(uid: identity.uid)
    }

    /// Ensure the top-level data-volume directories exist and are owned by
    /// $EXTUID. Idempotent. Runs as root inside the container so it can
    /// chown out from under whatever pre-existing ownership might be there.
    /// Mirrors the same list in entry.sh; kept in sync.
    private static func ensureDataVolumeDirectories(uid: String) {
        guard !uid.isEmpty else { return }
        let dirs = ["/srv/projects", "/srv/data", "/srv/meta", "/srv/dbs", "/srv/personal", "/srv/backups"]
        let cmd = ["install", "-d", "-o", uid, "-g", uid, "-m", "0775"] + dirs
        _ = Mpd.Podman.exec(containerName, options: ["--user", "0:0"], cmd)
    }

    /// Start fileaccess (called by --start). Creates the container first if missing.
    static func start() throws {
        step("Service: fileaccess")
        if !Mpd.Podman.exists(containerName) { try setup(); return }
        guard !Mpd.Podman.running(containerName) else {
            ok("fileaccess already running.")
            return
        }
        guard Mpd.Podman.startQuietly(containerName) == 0 else {
            throw RuntimeError("Failed to start '\(containerName)'.")
        }
        ok("fileaccess running.")
    }

    /// Stop the fileaccess container (not used).
    static func stop() throws {
        guard Mpd.Podman.exists(containerName) else { return }
        guard Mpd.Podman.running(containerName) else { return }
        Mpd.Podman.stopQuietly(containerName)
    }
}
