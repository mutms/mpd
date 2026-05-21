// mpd-desktop command hooks
// Desktop-only setup/start/stop/uninstall behavior (macOS host + Podman Desktop).

import Foundation

#if os(macOS)
extension Mpd.Environment.Action.Setup {
    /// Derive the instance suffix from the adopted Podman machine name:
    /// `mpd-desktop` → "", `mpd-desktop-<X>` → "-<X>". Used to disambiguate
    /// runtime container hostnames across concurrent Podman machines.
    private static func derivedDesktopSuffix(machineName: String) -> String {
        let prefix = "mpd-desktop-"
        return machineName.hasPrefix(prefix)
            ? "-" + String(machineName.dropFirst(prefix.count))
            : ""
    }

    static func preflight() throws {
        let fm = FileManager.default
        let podmanDesktopApp = "/Applications/Podman Desktop.app"
        let podmanCLI = "/opt/podman/bin/podman"
        let wireGuardApp = "/Applications/WireGuard.app"

        var missing: [String] = []

        step("Check for Podman Desktop")
        if fm.fileExists(atPath: podmanDesktopApp) {
            ok("Found: \(podmanDesktopApp)")
        } else {
            missing.append("Podman Desktop for macOS: \(podmanDesktopApp)")
        }

        step("Check for Podman CLI")
        if fm.isExecutableFile(atPath: podmanCLI) {
            ok("Found: \(podmanCLI)")
        } else {
            missing.append("Podman CLI for macOS: \(podmanCLI)")
        }

        step("Check for WireGuard app")
        if fm.fileExists(atPath: wireGuardApp) {
            ok("Found: \(wireGuardApp)")
        } else {
            missing.append("WireGuard app: \(wireGuardApp)")
        }

        if !missing.isEmpty {
            let details = missing.map { "  - \($0)" }.joined(separator: "\n")
            throw RuntimeError("""
            Setup preflight failed. Required software is missing:
            \(details)

            Install Podman Desktop + CLI from:
              https://podman.io

            Install WireGuard from the Apple App Store:
              https://apps.apple.com/app/wireguard/id1451685025
            """)
        }

        try CommandPreflight.check(
            commandName: "mpd --setup",
            requiredNames: Mpd.Environment.HostExec.requiredBinaryNames())

    }

    static func execute() throws {
        let assetsDir = try Mpd.Core.Assets.path()
        ok("Execution environment: \(Mpd.Environment.label)")
        let fm = FileManager.default

        // Step — Environment preflight (read-only)
        try Mpd.Environment.Action.Setup.preflight()

        // Step — Ensure tracked placeholder directories (.gitkeep) in source checkout
        step("Repository placeholders")
        try Mpd.Environment.ensureTrackedPlaceholderDirectories()
        ok("Ensured ~/Developer/mpd/conf/.gitkeep")

        // Step — Platform identity (~/Developer/mpd/conf/platform.env)
        // Desktop knows everything statically; no prompt. Survives --uninstall.
        step("Platform identity")
        try Mpd.Core.Platform.ensureWritten(
            platform: .desktop, vmIP: "", instanceSuffix: "")
        ok("Platform identity at \(Mpd.Core.Platform.path)")

        // Step — Adopt the running mpd-desktop Podman machine. mpd doesn't
        // init machines; the dev creates and starts one in Podman Desktop
        // (named mpd-desktop or mpd-desktop-<suffix>) and `mpd --setup`
        // locks onto it.
        step("Podman machine")
        let machineName = try Mpd.Environment.PodmanMachine.adoptRunningMpdDesktop()

        // Refresh the instance suffix from the adopted machine name. Same
        // model as mpd-machine: `mpd-desktop` → "", `mpd-desktop-<X>` → "-<X>".
        let suffix = derivedDesktopSuffix(machineName: machineName)
        let currentSuffix = (try? Mpd.Core.Platform.load().instanceSuffix) ?? ""
        if suffix != currentSuffix {
            try Mpd.Core.Platform.updateInstanceSuffix(suffix)
        }

        // Step — Detect extuser/extuid (depends on machineDir from step 2)
        step("Configuration")
        var config = Mpd.Core.State.readConfig()
        let detectedIdentity = Mpd.Environment.detectUserAndUID()
        let user = detectedIdentity.user
        let uid = detectedIdentity.uid
        if !user.isEmpty { config.user = user }
        if !uid.isEmpty { config.uid = uid }
        Mpd.Core.State.writeConfig(config)
        ok("machine=\(machineName)  user=\(user)  uid=\(uid)")

        // Step — Root CA certificate
        step("Root CA certificate")

        let carootDir = Mpd.Environment.confCARootDir
        let serviceDir = Mpd.Environment.confServiceDir
        let wgDir = Mpd.Environment.confWireGuardDir
        let certOpsDir = Mpd.Environment.confTempDir
        let caRootPem = "\(carootDir)/rootCA.pem"
        let caKeyPem = "\(carootDir)/rootCA-key.pem"

        for dir in [carootDir, certOpsDir] {
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: dir, isDirectory: &isDirectory)

            if !exists {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } else if !isDirectory.boolValue {
                throw RuntimeError("Path exists but is not a directory: \(dir)")
            }

            // Validate directory creation and enforce secure permissions on every run.
            var createdIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &createdIsDirectory), createdIsDirectory.boolValue else {
                throw RuntimeError("Failed to ensure directory exists: \(dir)")
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        }

        if fm.fileExists(atPath: caRootPem) {
            ok("CA already exists in \(caRootPem)")
        } else {
            // Adopt the mpd-machine platform CA when present so a Mac running
            // both modes shares one CA (the macos bash scripts do the
            // symmetric thing — they reuse caroot/ when it exists).
            let machineCAPem = "\(Mpd.Environment.mpdMachineCARootDir)/rootCA.pem"
            let machineCAKey = "\(Mpd.Environment.mpdMachineCARootDir)/rootCA-key.pem"
            if fm.fileExists(atPath: machineCAPem) && fm.fileExists(atPath: machineCAKey) {
                try fm.copyItem(atPath: machineCAPem, toPath: caRootPem)
                try fm.copyItem(atPath: machineCAKey, toPath: caKeyPem)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: caRootPem)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKeyPem)
                ok("CA adopted from \(Mpd.Environment.mpdMachineCARootDir) into \(caRootPem)")
            } else {
                try Mpd.Environment.Certificate.generateCA(caKeyPath: caKeyPem, caCertPath: caRootPem, certsDir: certOpsDir)
                ok("CA certificate generated in \(caRootPem)")
            }
        }

        var caCertIsDir: ObjCBool = false
        guard fm.fileExists(atPath: caRootPem, isDirectory: &caCertIsDir), !caCertIsDir.boolValue else {
            throw RuntimeError("Root CA certificate missing or invalid: \(caRootPem)")
        }
        var caKeyIsDir: ObjCBool = false
        guard fm.fileExists(atPath: caKeyPem, isDirectory: &caKeyIsDir), !caKeyIsDir.boolValue else {
            throw RuntimeError("Root CA key missing or invalid: \(caKeyPem)")
        }

        // Step — WireGuard keys (generated once; survive --uninstall)
        step("WireGuard keys and configuration")
        var wgIsDirectory: ObjCBool = false
        let wgExists = fm.fileExists(atPath: wgDir, isDirectory: &wgIsDirectory)
        if !wgExists {
            try fm.createDirectory(atPath: wgDir, withIntermediateDirectories: true)
        } else if !wgIsDirectory.boolValue {
            throw RuntimeError("Path exists but is not a directory: \(wgDir)")
        }

        var validatedWGDirectory: ObjCBool = false
        guard fm.fileExists(atPath: wgDir, isDirectory: &validatedWGDirectory), validatedWGDirectory.boolValue else {
            throw RuntimeError("Failed to ensure directory exists: \(wgDir)")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wgDir)

        let serverPrivKeyPath = "\(wgDir)/server-privatekey"
        let wgConf = "\(wgDir)/mpd-desktop.conf"
        if !fm.fileExists(atPath: serverPrivKeyPath) {
            try Mpd.Service.WireGuard.generateKeys(wgDir: wgDir)
        } else {
            ok("WireGuard keys already exist in \(wgDir)")
        }
        try Mpd.Service.WireGuard.writeClientConf(wgDir: wgDir, wgConf: wgConf)
        ok("WG client configuration in \(wgConf)")

        // Step — Generate service cert when missing or CA fingerprint changed
        step("Services certificate")
        let serviceCert = "\(serviceDir)/cert.pem"
        let serviceKey = "\(serviceDir)/key.pem"
        let serviceFingerprint = "\(serviceDir)/rootCA.fingerprint"
        let currentCAFingerprint = Mpd.Environment.fileFingerprint(caRootPem)
        let storedServiceFingerprint: String
        if fm.fileExists(atPath: serviceFingerprint) {
            storedServiceFingerprint = try String(contentsOfFile: serviceFingerprint, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            storedServiceFingerprint = ""
        }

        let caFingerprintChanged = storedServiceFingerprint != currentCAFingerprint
        let shouldGenerateServiceCert =
            !fm.fileExists(atPath: serviceCert) ||
            !fm.fileExists(atPath: serviceKey) ||
            caFingerprintChanged

        if shouldGenerateServiceCert {
            var serviceIsDirectory: ObjCBool = false
            let serviceExists = fm.fileExists(atPath: serviceDir, isDirectory: &serviceIsDirectory)
            if !serviceExists {
                try fm.createDirectory(atPath: serviceDir, withIntermediateDirectories: true)
            } else if !serviceIsDirectory.boolValue {
                throw RuntimeError("Path exists but is not a directory: \(serviceDir)")
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: serviceDir)

            try Mpd.Environment.Certificate.generateCert(
                sans: ["mpd.test"],
                certPath: serviceCert,
                keyPath: serviceKey,
                caKeyPath: caKeyPem,
                caCertPath: caRootPem,
                certsDir: certOpsDir)
            try currentCAFingerprint.write(toFile: serviceFingerprint, atomically: true, encoding: .utf8)
            ok("Services certificate generated in \(serviceDir)")
        } else {
            ok("Services cert already exists in \(serviceDir)")
        }

        // Step — Trust CA
        step("Root Certificate Authority for mpd.test in system trust store")
        Mpd.Environment.Certificate.trustCA(caPath: caRootPem)

        // Step — DNS resolver
        step("DNS resolver for mpd.test")
        Mpd.Environment.Integration.configureDNSResolver()

        // Step — Podman network
        step("Podman network")
        if Mpd.Podman.networkExists("mpd-internal") {
            ok("Network 'mpd-internal' already exists (\(Mpd.internalSubnet)).")
        } else {
            guard Mpd.Podman.networkCreate(
                "mpd-internal",
                subnet: Mpd.internalSubnet,
                dnsServers: [Mpd.Service.Dnsmasq.ip]) == 0 else {
                throw RuntimeError("Failed to create Podman network 'mpd-internal'.")
            }
            ok("Network 'mpd-internal' created (\(Mpd.internalSubnet)).")
        }

        // Step — Data volume
        step("Data volume")
        if Mpd.Podman.volumeExists(Mpd.dataVolume) {
            ok("Volume '\(Mpd.dataVolume)' already exists.")
        } else {
            guard Mpd.Podman.volumeCreate(Mpd.dataVolume) == 0 else {
                throw RuntimeError("Failed to create data volume '\(Mpd.dataVolume)'.")
            }
            ok("Volume '\(Mpd.dataVolume)' created.")
        }

        // Step — File access service (must come up before any volumeTool* call,
        // since those exec into this container.)
        step("File access service")
        try Mpd.Service.FileAccess.setup()

        step("Personal area in data volume")
        try Mpd.Core.PersonalArea.provision()

        // Step — Prepare per-machine subdirs and cache files
        step("mpd data directories")

        try fm.createDirectory(atPath: Mpd.Runtime.State.runtimesDir, withIntermediateDirectories: true)
        let projectsPath = Mpd.Runtime.State.projectsPath
        if !fm.fileExists(atPath: projectsPath) {
            try "{\"projects\":[]}".write(toFile: projectsPath, atomically: true, encoding: .utf8)
        }
        let databasesPath = Mpd.Runtime.State.databasesPath
        if !fm.fileExists(atPath: databasesPath) {
            try "{\"databases\":[]}".write(toFile: databasesPath, atomically: true, encoding: .utf8)
        }
        ok("~/.mpd/machines/\(machineName)/ ready.")

        // Step — mpd-user.env defaults (created once from template, never
        // overwritten). Comes BEFORE service setup so the first sync has
        // a file to mirror into the volume.
        step("mpd-user.env defaults")
        let mpdUserEnvPath = "\(Mpd.Environment.dotMpdDir)/mpd-user.env"
        if fm.fileExists(atPath: mpdUserEnvPath) {
            ok("\(mpdUserEnvPath) already exists — edit to set your defaults.")
        } else {
            let src = "\(assetsDir)/templates/mpd-user.env"
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: mpdUserEnvPath)
                ok("\(mpdUserEnvPath) created — edit to set your defaults.")
            } else {
                print("  Warning: template not found at \(src)")
            }
        }

        // Step — Sync host-side bind-mount sources into the data volume.
        // Runtimes read mpd-user.env from /srv/personal/mpd-user.env; the
        // dnsmasq container subpath-binds /srv/state/dnsmasq.d. Routes
        // around virtiofs cache lag on libkrun.
        step("Syncing bind-mount sources into data volume")
        try Mpd.Core.State.syncBindMountFiles()
        ok("Bind-mount sources synced.")

        // Step 14 — Services (WireGuard → dnsmasq → portal)
        try Mpd.Service.WireGuard.setup()
        try Mpd.Service.Dnsmasq.setup()
        try Mpd.Service.Portal.setup()

        // Step — WireGuard tunnel: ensure active (interactive menu if needed)
        step("WireGuard tunnel")
        Mpd.Environment.Integration.importWireGuardConfig(confPath: wgConf)
        ok("WireGuard tunnel active.")

        // Step — Verify DNS
        step("DNS resolution")
        Mpd.Environment.Integration.verifyDNS()

        // Step — zsh completion
        step("Shell completion for mpd")
        Mpd.Core.Assets.installCompletion()

        // Step — Rescan data volume
        step("Rescanning data volume")
        try? Mpd.Core.DataVolume.rescan()

        // Step — Probe existing containers and rebuild runtimes/meta.json
        step("Probing existing runtime containers")
        Mpd.Environment.PodmanMachine.rebuildRuntimeStateEntryCache()

        // Step — Probe existing database containers and rebuild databases.json
        step("Probing existing database containers")
        Mpd.Environment.PodmanMachine.rebuildDatabaseStateCache()
        try Mpd.Service.Dnsmasq.ensureReadyForServiceResolution()

        // Step — Reconcile runtime/project certificates only when CA changed.
        if caFingerprintChanged {
            step("Reconciling TLS certificates")
            Mpd.Runtime.reconcileCertificates()
        }


        // Always-on infra services beyond dnsmasq/portal. Add new ones here as
        // they ship; per-runtime sidecars (mailpit/selenium/valkey) are NOT
        // here — they attach to runtime pods, not the global service network.
        try? Mpd.Service.Adminer.setup()

        // Silent pre-fetch default database image (best effort).
        _ = Mpd.Podman.pull("docker.io/library/postgres:17", quiet: true)

        // Hook diagnostics — orphans, audience drift, revision bumps.
        // Silent in the happy path; prints warnings only when something
        // is off. Stamps current event revisions for next-run comparison.
        Mpd.Hooks.diagnose()

        // Live-state snapshot for out-of-process consumers (portal etc.).
        Mpd.Runtime.State.refreshCurrentStateCache()

        print("""

        \u{001B}[1;32m✓ mpd --setup complete.\u{001B}[0m

          https://mpd.test/

        Tip: enable On Demand in WireGuard so the tunnel auto-connects on boot.

        Next steps — create, configure, start a Moodle project:
          mpd create moodle52 --git-repo=https://github.com/moodle/moodle.git --git-branch=MOODLE_502_STABLE
          mpd configure moodle52 MPD_DB=postgres:18
          mpd start moodle52
          open https://moodle52.mpd.test/
        """)
    }
}
#endif
