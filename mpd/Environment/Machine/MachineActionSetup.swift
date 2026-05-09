// mpd-machine command hooks
// Linux runtime / mpd-machine setup behavior.

import Foundation

#if os(Linux)
extension Mpd.Environment.Action.Setup {
    /// Packages mpd installs at setup time. Runtime essentials, podman + its
    /// DNS plugin (aardvark-dns — without it `--dns` flags on networks are
    /// silently dropped), and a generous diagnostics set (the VM is a
    /// sandbox you can wipe and rebuild, so size isn't a concern;
    /// DNS-class debugging routinely needs all of these).
    ///
    /// Notably absent: `systemd-resolved` and `network-manager`. The host's
    /// network stack (link manager + DNS sink) is standardized to
    /// systemd-networkd or NetworkManager + systemd-resolved by
    /// `provision-vm.sh` (or by cloud-init on the macos-utm path). By the
    /// time `mpd --setup` runs, systemd-resolved is already active. mpd
    /// touches it through a single drop-in for `*.mpd.test`; nothing else.
    private static let aptPackages: [String] = [
        // runtime
        // `catatonit` is a Recommends of podman (init binary used as the pause
        // process in pods); --no-install-recommends drops it, so pod creation
        // fails with "finding pause binary" without an explicit install.
        "podman", "catatonit", "aardvark-dns", "nftables", "sudo", "openssl",
        "bash", "coreutils", "git", "iputils-ping", "ca-certificates",
        "systemd", "iproute2", "jq",
        // diagnostics
        "dnsutils", "traceroute", "tcpdump", "lsof", "curl",
        "less", "vim-tiny", "psmisc",
    ]

    /// Parse /etc/os-release. Returns (id, codename), or nil if the file is
    /// unreadable / malformed. Bash-key=value format with optional quotes.
    private static func readOSRelease() -> (id: String, codename: String)? {
        guard let body = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
            return nil
        }
        var values: [String: String] = [:]
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            var val = String(line[line.index(after: eq)...])
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            values[key] = val
        }
        guard let id = values["ID"], let codename = values["VERSION_CODENAME"] else {
            return nil
        }
        return (id, codename)
    }

    /// Hard gate: mpd-machine targets Debian Trixie only. Different install
    /// methods (cloud-init, netinst, manual) all converge on the same OS;
    /// other distros / Debian releases are unsupported (package names, Swift
    /// availability, systemd unit layout, NetworkManager defaults all vary).
    private static func requireDebianTrixie() throws {
        guard let os = readOSRelease() else {
            throw RuntimeError("""
            Cannot read /etc/os-release. mpd-machine targets Debian Trixie.
            Use a Debian Trixie VM and re-run mpd --setup.
            """)
        }
        guard os.id == "debian" else {
            throw RuntimeError("""
            mpd-machine targets Debian (got ID=\(os.id)).
            Use a Debian Trixie VM and re-run mpd --setup.
            """)
        }
        guard os.codename == "trixie" else {
            throw RuntimeError("""
            mpd-machine targets Debian Trixie (got VERSION_CODENAME=\(os.codename)).
            Package names, Swift toolchain, and systemd-resolved/NetworkManager
            defaults vary between releases — pin to Trixie or accept that
            you're off the supported path.
            """)
        }
    }

    /// Install (or re-assert) the given apt package set. Idempotent:
    /// apt-get install on already-satisfied packages is a fast no-op. We do
    /// `apt-get update` only when at least one package is actually missing,
    /// so the common "re-run mpd --setup on a healthy VM" path stays quick.
    ///
    /// No prompt: passwordless sudo is a hard provisioning gate, and prompting
    /// on every re-run is friction without payoff.
    private static func installPackages(_ packages: [String], label: String) throws {
        let missing = packages.filter { !dpkgPackageInstalled($0) }
        if missing.isEmpty {
            ok("\(label) already installed.")
            return
        }
        print("Installing \(label): \(missing.joined(separator: ", "))")
        guard Mpd.Environment.HostExec.run(["sudo", "apt-get", "update"]) == 0 else {
            throw RuntimeError("apt-get update failed.")
        }
        guard Mpd.Environment.HostExec.run(
            ["sudo", "apt-get", "install", "-y", "--no-install-recommends"] + packages
        ) == 0 else {
            throw RuntimeError("Failed to install \(label).")
        }
        ok("\(label) installed.")
    }

    /// Enable podman-restart.service so `--restart=always` containers get
    /// started back up at boot. Without this unit, the restart policy holds
    /// for crash recovery only — a host reboot stops every container and
    /// nothing brings them back. `systemctl enable --now` is idempotent.
    private static func enablePodmanRestart() throws {
        guard Mpd.Environment.HostExec.run(
            ["sudo", "systemctl", "enable", "--now", "podman-restart.service"]
        ) == 0 else {
            throw RuntimeError("Failed to enable podman-restart.service.")
        }
        ok("podman-restart.service enabled (containers survive reboot).")
    }

    /// Derive the instance suffix from the VM's OS hostname. The mpd-machine
    /// bootstrap (provision-vm.sh / create-vm.sh) sets the hostname to either
    /// `mpd-machine` (singleton) or `mpd-machine-<X>` (concurrent variant);
    /// the suffix here is `-<X>` (with the leading dash) or `""`. Used to
    /// disambiguate runtime container hostnames so a developer SSH'd into
    /// `php.runtime.mpd.test` sees `mpd-runtime-php-<X>` in their prompt.
    private static func deriveInstanceSuffix() -> String {
        // Read /etc/hostname directly — `hostname` isn't on the HostExec
        // whitelist and the file is always present on Debian.
        let raw = (try? String(contentsOfFile: "/etc/hostname", encoding: .utf8)) ?? ""
        // Take the short name (first dot strips any FQDN form just in case).
        let h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").first.map(String.init) ?? ""
        let prefix = "mpd-machine-"
        return h.hasPrefix(prefix) ? "-" + String(h.dropFirst(prefix.count)) : ""
    }

    /// Drop /etc/profile.d/mpd-machine.sh that prepends the repo's
    /// `bin/machine/` directory to PATH for every login shell on the
    /// mpd-machine VM. Idempotent — re-run rewrites the file. Uses
    /// literal `$HOME` so the snippet works for any account that might
    /// log into the VM (single-user expected, but no reason to hardcode).
    private static func installMachineBinPath() throws {
        let snippet = "export PATH=\"$HOME/Developer/mpd/bin/machine:$PATH\"\n"
        let tmp = "/tmp/mpd-machine-path.sh"
        try snippet.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard Mpd.Environment.HostExec.run(
            ["sudo", "install", "-D", "-m", "644", tmp, "/etc/profile.d/mpd-machine.sh"]
        ) == 0 else {
            throw RuntimeError("Failed to install /etc/profile.d/mpd-machine.sh.")
        }
        ok("/etc/profile.d/mpd-machine.sh — adds bin/machine/ to PATH.")
    }

    /// Install assets/machine/motd as /etc/motd and disable Ubuntu/Debian's
    /// dynamic update-motd scripts so the static banner survives every login.
    /// Idempotent. Single source for the banner across all platforms — the
    /// per-platform `create-vm.sh` scripts no longer touch /etc/motd.
    private static func installLoginBanner() throws {
        let source = "\(Mpd.Environment.assetsDir)/machine/motd"
        guard FileManager.default.fileExists(atPath: source) else {
            throw RuntimeError("motd asset missing: \(source)")
        }
        // Disable dynamic motd generation. Ubuntu cloud images ship a few
        // /etc/update-motd.d/* scripts that would otherwise compete with our
        // static /etc/motd. Best-effort — directory may not exist on Debian.
        _ = Mpd.Environment.HostExec.run(
            ["sudo", "bash", "-c", "chmod -x /etc/update-motd.d/* 2>/dev/null || true"]
        )
        guard Mpd.Environment.HostExec.run(
            ["sudo", "install", "-m", "644", source, "/etc/motd"]
        ) == 0 else {
            throw RuntimeError("Failed to install /etc/motd from \(source).")
        }
        ok("/etc/motd installed from assets/machine/motd")
    }

    /// Ask dpkg whether a package is in 'install ok installed' state. Cheap
    /// (local DB lookup, no network) and accurate enough to gate apt-get
    /// invocation.
    private static func dpkgPackageInstalled(_ pkg: String) -> Bool {
        let (rc, out) = Mpd.Environment.HostExec.capture(
            ["dpkg-query", "-W", "-f=${Status}", pkg],
            suppressStderr: true)
        return rc == 0 && out.contains("install ok installed")
    }

    /// Generate ~/.ssh/id_ed25519 if no id_*.pub already exists. No passphrase
    /// (the VM is the trust boundary; key only authenticates VM→runtime hops).
    /// Idempotent — once a key is present we leave it alone, even if the user
    /// later swaps in their own.
    private static func ensureVMSSHKey() throws {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let sshDir = "\(home)/.ssh"

        try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir)

        let entries = (try? fm.contentsOfDirectory(atPath: sshDir)) ?? []
        let hasIdPub = entries.contains { $0.hasPrefix("id_") && $0.hasSuffix(".pub") }
        if hasIdPub {
            ok("VM-local key already present in ~/.ssh/.")
            return
        }

        let keyPath = "\(sshDir)/id_ed25519"
        let host = ProcessInfo.processInfo.hostName
        let comment = "mpd-machine \(host)"
        guard Mpd.Environment.HostExec.run([
            "ssh-keygen", "-t", "ed25519", "-N", "", "-f", keyPath, "-C", comment, "-q",
        ]) == 0 else {
            throw RuntimeError("Failed to generate ~/.ssh/id_ed25519. Run `ssh-keygen -t ed25519` manually and re-run mpd --setup.")
        }
        ok("Generated VM-local key at ~/.ssh/id_ed25519 (no passphrase, used for VM→runtime SSH).")
    }

    /// Import the mpd CA into the dev user's NSS DB at ~/.pki/nssdb/.
    /// Chromium (and Chrome, Edge, etc.) read this DB on Linux for SSL trust;
    /// without this step, https://mpd.test/ shows a security warning even
    /// though the CA is in the OS trust store, because Linux browsers don't
    /// read /etc/ssl/certs/ directly. Idempotent: certutil -A overwrites if
    /// the nickname already exists. Requires libnss3-tools (provides certutil).
    private static func ensureCAInUserNSSDB(caPath: String) throws {
        let fm = FileManager.default
        let nssDir = "\(NSHomeDirectory())/.pki/nssdb"
        try fm.createDirectory(atPath: nssDir, withIntermediateDirectories: true)

        // certutil from libnss3-tools. If missing, log and skip — this isn't
        // worth failing setup for; the user can browse with -k or accept the
        // warning manually until they install it.
        guard Mpd.Environment.HostExec.binaryPath(for: "certutil") != nil,
              FileManager.default.fileExists(atPath: "/usr/bin/certutil") else {
            print("  certutil not found (apt: libnss3-tools). Skipping NSS-DB import.")
            return
        }

        // -A adds; nickname "mpd CA" is overwritten on re-run, so this is
        // idempotent. Trust flags "C,," = trusted CA for SSL only.
        guard Mpd.Environment.HostExec.run([
            "certutil", "-A",
            "-n", "mpd CA",
            "-t", "C,,",
            "-i", caPath,
            "-d", "sql:\(nssDir)",
        ]) == 0 else {
            throw RuntimeError("certutil failed to import \(caPath) into \(nssDir).")
        }
        ok("mpd CA imported into ~/.pki/nssdb/ (restart Chromium-family browsers to apply).")
    }

    static func preflight() throws {
        // Distro gate — fail fast on non-Trixie before any apt work.
        try requireDebianTrixie()

        // Verify the host's network stack is in the standardized state
        // (systemd-resolved active, fed by either NetworkManager or
        // systemd-networkd). `provision-vm.sh` and cloud-init are both
        // responsible for putting the system here; mpd --setup just
        // verifies and bails with a hint if not.
        try Mpd.Environment.Integration.requireSystemdResolvedActive()

        // Single apt phase: runtime essentials + diagnostics + aardvark-dns.
        try installPackages(aptPackages, label: "mpd packages")

        // podman-restart.service is what drives `--restart=always` containers
        // back up after a host reboot — without it the policy is silently
        // ineffective. `enable --now` is idempotent.
        try enablePodmanRestart()

        // The VM itself is the machine; pin the state name accordingly.
        var status = Mpd.Core.State.readStatus()
        if status.activeMachine != "mpd-machine" {
            status.activeMachine = "mpd-machine"
            Mpd.Core.State.writeStatus(status)
        }
        ok("Podman runs natively — no machine needed.")
    }

    static func execute() throws {
        let assetsDir = try Mpd.Core.Assets.path()
        ok("Execution environment: \(Mpd.Environment.label)")
        let fm = FileManager.default

        try Mpd.Environment.Action.Setup.preflight()

        step("Repository placeholders")
        try Mpd.Environment.ensureTrackedPlaceholderDirectories()
        ok("Ensured ~/Developer/mpd/conf/.gitkeep")

        // Step — Platform identity (must be written by the bootstrap script
        // before this point). Tells mpd which client OS the laptop runs and
        // what the VM IP is, so we print correct laptop-side recipes.
        step("Platform identity")
        let identity = try Mpd.Core.Platform.load()
        // Auto-refresh the instance suffix from the VM's OS hostname on every
        // setup run. User can hand-edit MPD_INSTANCE_SUFFIX in platform.env
        // afterwards if they want a different label; the next --setup will
        // overwrite it back to the auto-derived value.
        let derivedSuffix = deriveInstanceSuffix()
        if derivedSuffix != identity.instanceSuffix {
            try Mpd.Core.Platform.updateInstanceSuffix(derivedSuffix)
        }
        ok("Platform: \(identity.platform.rawValue), client: \(identity.clientOS.rawValue), VM IP: \(identity.vmIP.isEmpty ? "—" : identity.vmIP), suffix: \(derivedSuffix.isEmpty ? "—" : derivedSuffix)")

        // Step — VM-local SSH keypair. Without this, the VM has no private key
        // to offer when SSHing into runtimes from a local terminal (e.g. inside
        // GNOME desktop), so users would always need `ssh -A` from the laptop.
        // The pubkey is later picked up by Mpd.Environment.authorizedPublicKeys
        // and ends up in every runtime's authorized_keys.
        step("VM-local SSH key")
        try ensureVMSSHKey()

        let machineName = Mpd.Core.State.activeMachine()

        // Detect extuser/extuid
        step("Configuration")
        var config = Mpd.Core.State.readConfig()
        let detectedIdentity = Mpd.Environment.detectUserAndUID()
        let user = detectedIdentity.user
        let uid = detectedIdentity.uid
        if !user.isEmpty { config.user = user }
        if !uid.isEmpty { config.uid = uid }
        Mpd.Core.State.writeConfig(config)
        ok("machine=\(machineName)  user=\(user)  uid=\(uid)")

        // Root CA certificate
        step("Root CA certificate")

        let carootDir = Mpd.Environment.confCARootDir
        let serviceDir = Mpd.Environment.confServiceDir
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

            var createdIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &createdIsDirectory), createdIsDirectory.boolValue else {
                throw RuntimeError("Failed to ensure directory exists: \(dir)")
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        }

        if !fm.fileExists(atPath: caRootPem) {
            try Mpd.Environment.Certificate.generateCA(caKeyPath: caKeyPem, caCertPath: caRootPem, certsDir: certOpsDir)
            ok("CA certificate generated in \(caRootPem)")
        } else {
            ok("CA already exists in \(caRootPem)")
        }

        var caCertIsDir: ObjCBool = false
        guard fm.fileExists(atPath: caRootPem, isDirectory: &caCertIsDir), !caCertIsDir.boolValue else {
            throw RuntimeError("Root CA certificate missing or invalid: \(caRootPem)")
        }
        var caKeyIsDir: ObjCBool = false
        guard fm.fileExists(atPath: caKeyPem, isDirectory: &caKeyIsDir), !caKeyIsDir.boolValue else {
            throw RuntimeError("Root CA key missing or invalid: \(caKeyPem)")
        }

        // Services certificate
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

        step("Root Certificate Authority for mpd.test in system trust store")
        Mpd.Environment.Certificate.trustCA(caPath: caRootPem)

        step("Trust mpd CA in user's NSS DB (Chromium)")
        try ensureCAInUserNSSDB(caPath: caRootPem)

        step("Trust mpd CA in Firefox (enterprise policy)")
        Mpd.Environment.Certificate.installFirefoxPolicy(caPath: caRootPem)

        step("DNS resolver for mpd.test")
        try Mpd.Environment.Integration.configureDNSResolver()

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

        step("Data volume")
        if Mpd.Podman.volumeExists(Mpd.dataVolume) {
            ok("Volume '\(Mpd.dataVolume)' already exists.")
        } else {
            guard Mpd.Podman.volumeCreate(Mpd.dataVolume) == 0 else {
                throw RuntimeError("Failed to create data volume '\(Mpd.dataVolume)'.")
            }
            ok("Volume '\(Mpd.dataVolume)' created.")
        }

        step("File access service")
        try Mpd.Service.FileAccess.setup()

        step("Personal area in data volume")
        try Mpd.Core.PersonalArea.provision()

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

        // mpd-user.env defaults (created once from template, never overwritten).
        // Comes BEFORE service setup so the first sync has a file to mirror.
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

        step("Syncing bind-mount sources into data volume")
        try Mpd.Core.State.syncBindMountFiles()
        ok("Bind-mount sources synced.")

        try Mpd.Service.Dnsmasq.setup()
        try Mpd.Service.Portal.setup()

        step("DNS resolution")
        Mpd.Environment.Integration.verifyDNS()

        step("Shell completion for mpd")
        Mpd.Core.Assets.installCompletion()

        step("Adding bin/machine/ to login PATH")
        try installMachineBinPath()

        step("Installing login banner (motd)")
        try installLoginBanner()

        step("Rescanning data volume")
        try? Mpd.Core.DataVolume.rescan()

        step("Probing existing runtime containers")
        Mpd.Environment.PodmanMachine.rebuildRuntimeStateEntryCache()

        step("Probing existing database containers")
        Mpd.Environment.PodmanMachine.rebuildDatabaseStateCache()
        try Mpd.Service.Dnsmasq.ensureReadyForServiceResolution()

        if caFingerprintChanged {
            step("Reconciling TLS certificates")
            Mpd.Runtime.reconcileCertificates()
        }

        // Always-on infra services beyond dnsmasq/portal. Add new ones here as
        // they ship; per-runtime sidecars (mailpit/selenium/valkey) are NOT
        // here — they attach to runtime pods, not the global service network.
        try? Mpd.Service.Adminer.setup()

        _ = Mpd.Podman.pull("docker.io/library/postgres:17", quiet: true)

        Mpd.Environment.Integration.printClientArtifacts(
            caPath: caRootPem, sshUser: user)

        print("""

        \u{001B}[1;32m✓ mpd --setup complete.\u{001B}[0m

          https://mpd.test/

        Next steps — create, configure, start a Moodle project:
          mpd create moodle52 --git-repo=https://github.com/moodle/moodle.git --git-branch=MOODLE_502_STABLE
          mpd configure moodle52 MPD_DB=postgres:18
          mpd start moodle52

        Then browse to: https://moodle52.mpd.test/
        """)
    }
}
#endif
