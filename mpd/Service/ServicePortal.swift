// mpd — Mpd.Service.Portal namespace
// Portal status dashboard: container lifecycle.
// Container: mpd-service-portal at 10.163.0.4
// Serves https://mpd.test/ and dynamic HTTPS reverse proxy vhosts for selected services.
// debian:trixie with apache2 + php installed inline (apachectl -D FOREGROUND).
// SECURITY: strictly read-only — never executes commands or accepts user input.

import Foundation

extension Mpd.Service.Portal {

    static let descriptor = Mpd.ServiceDescriptor(
        name: "portal",
        containerName: "mpd-service-portal",
        ip: "10.163.0.4",
        dns: "mpd.test",
        accessHint: "https://mpd.test/",
        dnsAliases: ["mpd.test", "portal.service.mpd.test"],
        setup: nil,
        start: nil,
        stop: nil
    )

    static var containerName: String { descriptor.containerName }
    static var ip: String { descriptor.ip }

    /// Bump when container setup/mount behavior changes.
    static let revision = "10"

    // Label keys
    private static let revisionLabel = "mpd.service.revision"
    private static let caFingerprintLabel = "mpd.ca.fingerprint"
    private static let machineLabel = "mpd.machine.name"

    // MARK: - Container lifecycle

    /// Create and configure the portal container. Idempotent.
    static func setup() throws {
        let fm = FileManager.default

        step("Service: portal at https://mpd.test")

        // Remove outdated container (version, CA fingerprint, or machine mismatch → rebuild)
        let caFP = Mpd.fileFingerprint("\(Mpd.confCARootDir)/rootCA.pem")
        let machineName = Mpd.Core.State.activeMachine()
        Mpd.Podman.removeIfOutdated(containerName, labels: [
            revisionLabel: revision,
            caFingerprintLabel: caFP,
            machineLabel: machineName,
        ])

        let assetsDir = try Mpd.Core.Assets.path()
        let machineDir = Mpd.Core.State.machineDir()
        let serviceCert = "\(Mpd.confServiceDir)/cert.pem"
        let serviceKey = "\(Mpd.confServiceDir)/key.pem"

        let portalDir = "\(assetsDir)/services/portal"
        let portalWWW = "\(portalDir)/www"
        let portalPhp = "\(portalWWW)/index.php"
        let apacheConf = "\(portalDir)/apache.conf"
        let portalPhpIni = "\(portalDir)/php.ini"
        let vhostTemplate = "\(portalDir)/templates/service-vhost.conf.tpl"
        let runtimesAssetsDir = "\(assetsDir)/runtimes"

        guard fm.fileExists(atPath: portalPhp) else {
            throw RuntimeError("portal/www/index.php not found at \(portalPhp)")
        }
        guard fm.fileExists(atPath: apacheConf) else {
            throw RuntimeError("portal/apache.conf not found at \(apacheConf)")
        }
        guard fm.fileExists(atPath: vhostTemplate) else {
            throw RuntimeError("portal/templates/service-vhost.conf.tpl not found at \(vhostTemplate)")
        }
        guard fm.fileExists(atPath: portalPhpIni) else {
            throw RuntimeError("portal/php.ini not found at \(portalPhpIni)")
        }

        let portalStateDir = "\(machineDir)/portal"
        let portalVhostsDir = "\(portalStateDir)/vhosts"
        let portalCertsDir = "\(portalStateDir)/certs"
        let certOpsDir = "\(portalStateDir)/certops"

        try fm.createDirectory(atPath: portalVhostsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: portalCertsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: certOpsDir, withIntermediateDirectories: true)

        // Display name for the portal's H1 / title. The portal already mounts
        // machineDir at /mpd-state read-only, so the file is reachable inside
        // the container without a new bind mount. PHP reads it on every
        // request — refreshes pick up changes immediately.
        //   • mpd-machine: VM hostname (cloud-init set this to mpd-machine-NN
        //     on the cloud-init platforms; sandbox uses mpd-machine-sandbox).
        let displayName: String
        displayName = ProcessInfo.processInfo.hostName
        try? displayName.write(
            toFile: "\(portalStateDir)/display-name.txt",
            atomically: true,
            encoding: .utf8)

        // Dev user for IDE link URLs (vscode://, jetbrains-gateway://). The
        // runtime container's dev user matches the host UID/username; portal
        // PHP reads this to render correct Remote-SSH connection targets in
        // the per-project popover.
        try? NSUserName().write(
            toFile: "\(portalStateDir)/dev-user.txt",
            atomically: true,
            encoding: .utf8)

        let proxyArtifactsChanged = try ensurePortalProxyArtifacts(
            vhostTemplatePath: vhostTemplate,
            portalStateDir: portalStateDir,
            vhostsDir: portalVhostsDir,
            certsDir: portalCertsDir,
            certOpsDir: certOpsDir,
            currentCAFingerprint: caFP
        )

        if !Mpd.Podman.exists(containerName) {
            print("Creating portal")
            let portalMounts = [
                "-v", "\(portalWWW):/var/www/html:ro",
                "-v", "\(Mpd.dataVolume):/srv:ro",
                "-v", "\(machineDir):/mpd-state:ro",
                "-v", "\(apacheConf):/etc/apache2/sites-available/mpd-portal.conf:ro",
                "-v", "\(portalPhpIni):/tmp/mpd-portal.ini:ro",
                "-v", "\(runtimesAssetsDir):/mnt/assets/runtimes:ro",
                "-v", "\(serviceCert):/etc/mpd/cert.pem:ro",
                "-v", "\(serviceKey):/etc/mpd/key.pem:ro",
                "-v", "\(portalVhostsDir):/etc/apache2/mpd-vhosts:ro",
                "-v", "\(portalCertsDir):/etc/mpd/certs:ro",
            ]
            let aptCmd = "apt-get update -qq && apt-get install -y --no-install-recommends " +
                         "apache2 php libapache2-mod-php && " +
                         "for d in /etc/php/*/apache2/conf.d; do " +
                         "[ -d \"$d\" ] || continue; " +
                         "cp /tmp/mpd-portal.ini \"$d/99-mpd-portal.ini\"; " +
                         "done && " +
                         "a2enmod ssl proxy proxy_http && a2dissite 000-default && a2ensite mpd-portal && " +
                         "apachectl -D FOREGROUND"
            guard Mpd.Podman.run(
                ["-d", "--name", containerName,
                 "--network", "mpd-internal:ip=\(ip)",
                 "--restart", "always"]
                + portalMounts
                + ["--label", "com.docker.compose.project=mpd-service",
                   "--label", "\(revisionLabel)=\(revision)",
                   "--label", "\(caFingerprintLabel)=\(caFP)",
                   "--label", "\(machineLabel)=\(machineName)",
                   "docker.io/library/debian:trixie",
                   "bash", "-c", aptCmd]
            ) == 0 else { throw RuntimeError("Failed to start \(containerName).") }
            ok("Portal running.")
            return
        }

        if !Mpd.Podman.running(containerName) {
            guard Mpd.Podman.startQuietly(containerName) == 0 else {
                throw RuntimeError("Failed to start \(containerName).")
            }
            ok("Portal running.")
            return
        }

        if proxyArtifactsChanged {
            guard Mpd.Podman.restart(containerName) == 0 else {
                throw RuntimeError("Failed to reload \(containerName) after portal config update.")
            }
            ok("Portal reloaded dynamic service vhosts.")
        } else {
            ok("Already running.")
        }
    }

    /// Start the portal container (for --start). Requires container to exist.
    static func start() throws {
        step("Service: Portal")
        guard Mpd.Podman.exists(containerName) else {
            throw RuntimeError("\(containerName) not found. Run: mpd --setup")
        }
        if !Mpd.Podman.running(containerName) {
            guard Mpd.Podman.startQuietly(containerName) == 0 else {
                throw RuntimeError("Failed to start \(containerName). Run: mpd --setup")
            }
            ok("Portal running.")
        } else {
            ok("Already running.")
        }
    }

    // MARK: - Dynamic proxy config generation

    private static func ensurePortalProxyArtifacts(
        vhostTemplatePath: String,
        portalStateDir: String,
        vhostsDir: String,
        certsDir: String,
        certOpsDir: String,
        currentCAFingerprint: String
    ) throws -> Bool {
        let fm = FileManager.default
        let template = try String(contentsOfFile: vhostTemplatePath, encoding: .utf8)
        let proxiedServices = Mpd.services.filter { $0.portalProxy != nil }

        var changed = false

        let expectedVhostFiles = Set(proxiedServices.map { "\($0.name).conf" })
        let expectedCertDirs = Set(proxiedServices.map { $0.name })

        // Remove stale vhost files
        let existingVhostFiles = (try? fm.contentsOfDirectory(atPath: vhostsDir)) ?? []
        for file in existingVhostFiles where !expectedVhostFiles.contains(file) {
            try fm.removeItem(atPath: "\(vhostsDir)/\(file)")
            changed = true
        }

        // Remove stale cert directories
        let existingCertDirs = (try? fm.contentsOfDirectory(atPath: certsDir)) ?? []
        for dir in existingCertDirs where !expectedCertDirs.contains(dir) {
            try fm.removeItem(atPath: "\(certsDir)/\(dir)")
            changed = true
        }

        let fingerprintPath = "\(portalStateDir)/ca.fingerprint"
        let storedFingerprint = ((try? String(contentsOfFile: fingerprintPath, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mustRegenerateAllCerts = storedFingerprint != currentCAFingerprint

        for service in proxiedServices {
            guard let proxy = service.portalProxy else { continue }

            let certDir = "\(certsDir)/\(service.name)"
            try fm.createDirectory(atPath: certDir, withIntermediateDirectories: true)

            let certPath = "\(certDir)/cert.pem"
            let keyPath = "\(certDir)/key.pem"

            if mustRegenerateAllCerts || !fm.fileExists(atPath: certPath) || !fm.fileExists(atPath: keyPath) {
                try Mpd.Certificate.generateCert(
                    sans: [service.dns],
                    certPath: certPath,
                    keyPath: keyPath,
                    caKeyPath: "\(Mpd.confCARootDir)/rootCA-key.pem",
                    caCertPath: "\(Mpd.confCARootDir)/rootCA.pem",
                    certsDir: certOpsDir
                )
                changed = true
            }

            let certPathInContainer = "/etc/mpd/certs/\(service.name)/cert.pem"
            let keyPathInContainer = "/etc/mpd/certs/\(service.name)/key.pem"
            let upstreamURL = "\(proxy.upstreamScheme)://\(service.ip):\(proxy.upstreamPort)"

            let rendered = template
                .replacingOccurrences(of: "{{SERVER_NAME}}", with: service.dns)
                .replacingOccurrences(of: "{{CERT_FILE}}", with: certPathInContainer)
                .replacingOccurrences(of: "{{KEY_FILE}}", with: keyPathInContainer)
                .replacingOccurrences(of: "{{UPSTREAM_URL}}", with: upstreamURL)

            let vhostPath = "\(vhostsDir)/\(service.name).conf"
            if try writeIfChanged(content: rendered, path: vhostPath) {
                changed = true
            }
        }

        if mustRegenerateAllCerts || storedFingerprint.isEmpty {
            try currentCAFingerprint.write(toFile: fingerprintPath, atomically: true, encoding: .utf8)
        }

        return changed
    }

    private static func writeIfChanged(content: String, path: String) throws -> Bool {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard existing != content else { return false }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }
}
