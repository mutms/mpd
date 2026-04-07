// mpd — Mpd.Service.Adminer namespace
// Adminer database management UI: container lifecycle.
// Container: mpd-service-adminer at 10.163.0.6
// UI backend :8080 (HTTPS exposed via portal reverse proxy). Always-on infra service.

import Foundation

extension Mpd.Service.Adminer {

    static let descriptor = Mpd.ServiceDescriptor(
        name: "adminer",
        ip: "10.163.0.6",
        accessHint: "https://adminer.service.mpd.test/",
        portalProxy: .init(upstreamPort: 8080),
        setup: setup,
        start: start,
        stop: stop
    )

    static var containerName: String { descriptor.containerName }
    static var ip: String { descriptor.ip }

    /// Bump when container setup changes.
    static let revision = "7"

    private static let revisionLabel = "mpd.service.revision"
    private static let imageTag = "localhost/mpd-adminer:latest"

    private static let commonLabels: [String] = [
        "--label", "mpd.managed=true",
        "--label", "mpd.type=service",
        "--label", "mpd.name=adminer",
        "--label", "com.docker.compose.project=mpd-service",
    ]

    /// Build the local adminer image if it isn't already present. We use a
    /// Debian-based build instead of `docker.io/library/adminer` (Alpine):
    /// libpq+musl on Alpine fails to resolve multi-label hostnames like
    /// `postgres-latest.db.mpd.test`, surfacing as
    /// `SQLSTATE[08006] could not translate host name ...`.
    private static func ensureImage() throws {
        guard !Mpd.Podman.imageExists(imageTag) else { return }
        let assetsDir = try Mpd.Core.Assets.path()
        let contextDir = "\(assetsDir)/services/adminer"
        step("Building adminer image")
        guard Mpd.Podman.buildImage(tag: imageTag, contextDir: contextDir) == 0 else {
            throw RuntimeError("Failed to build adminer image from \(contextDir).")
        }
    }

    // MARK: - Container lifecycle

    /// Create and start the adminer container. Called by --setup. Idempotent.
    static func setup() throws {
        step("Service: adminer")
        try ensureImage()
        Mpd.Podman.removeIfOutdated(containerName, labels: [revisionLabel: revision])

        if !Mpd.Podman.exists(containerName) {
            guard Mpd.Podman.run(
                ["-d", "--name", containerName,
                 "--network", "mpd-internal:ip=\(ip)",
                 "--restart", "always",
                 "--label", "\(revisionLabel)=\(revision)"]
                + commonLabels
                + [imageTag]
            ) == 0 else {
                throw RuntimeError("Failed to create service 'adminer'.")
            }
            ok("adminer running.")
        } else if !Mpd.Podman.running(containerName) {
            Mpd.Podman.startQuietly(containerName)
            ok("adminer running.")
        } else {
            ok("adminer already running.")
        }
    }

    /// Start adminer (called by --start). Creates the container first if missing.
    static func start() throws {
        step("Service: adminer")
        if !Mpd.Podman.exists(containerName) { try setup(); return }
        guard !Mpd.Podman.running(containerName) else {
            ok("adminer already running.")
            return
        }
        guard Mpd.Podman.startQuietly(containerName) == 0 else {
            throw RuntimeError("Failed to start '\(containerName)'.")
        }
        ok("adminer running.")
    }

    /// Stop the adminer container (called by --stop).
    static func stop() throws {
        guard Mpd.Podman.exists(containerName) else { return }
        guard Mpd.Podman.running(containerName) else { return }
        Mpd.Podman.stopQuietly(containerName)
    }
}
