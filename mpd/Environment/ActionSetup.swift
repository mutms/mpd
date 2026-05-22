// mpd-machine command hooks
// Linux runtime / mpd-machine setup behavior.

import Foundation

extension Mpd.Action.Setup {
    /// Packages mpd installs at setup time. Runtime essentials, podman + its
    /// DNS plugin (aardvark-dns — without it `--dns` flags on networks are
    /// silently dropped), and a generous diagnostics set (the VM is a
    /// sandbox you can wipe and rebuild, so size isn't a concern;
    /// DNS-class debugging routinely needs all of these).
    ///
    /// Notably absent: `systemd-resolved` and `network-manager`. The host's
    /// network stack (link manager + DNS sink) is standardized to
    /// systemd-networkd or NetworkManager + systemd-resolved by the
    /// platform bootstrap (cloud-init for macos/linux/windows;
    /// `sandbox/lib/provision.sh` for sandbox). By the time `mpd --setup`
    /// runs, systemd-resolved is already active. mpd touches it through a
    /// single drop-in for `*.mpd.test`; nothing else.
    private static let aptPackages: [String] = [
        // runtime
        // `catatonit` is a Recommends of podman (init binary used as the pause
        // process in pods); --no-install-recommends drops it, so pod creation
        // fails with "finding pause binary" without an explicit install.
        "podman", "catatonit", "aardvark-dns", "nftables", "sudo", "openssl",
        "bash", "coreutils", "git", "iputils-ping", "ca-certificates",
        "systemd", "iproute2", "jq",
        // diagnostics
        // bind9-dnsutils (dig/nslookup/host). `dnsutils` is a virtual
        // package on Trixie — dpkg-query against the virtual name always
        // reports not-installed, so we'd reinstall every setup. Use the
        // real package name to make the idempotent check work.
        "bind9-dnsutils", "traceroute", "tcpdump", "lsof", "curl",
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

    /// Hard gate: mpd-machine targets Debian Trixie across every
    /// platform — cloud-init (macos, linux, windows) and
    /// sandbox alike. Other distros / releases are unsupported (package
    /// names, Swift availability, systemd unit layout, NetworkManager
    /// defaults all vary).
    private static func requireSupportedHost() throws {
        guard let os = readOSRelease() else {
            throw RuntimeError("""
            Cannot read /etc/os-release. mpd-machine targets Debian Trixie.
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
        guard Mpd.HostExec.run(["sudo", "apt-get", "update"]) == 0 else {
            throw RuntimeError("apt-get update failed.")
        }
        guard Mpd.HostExec.run(
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
        guard Mpd.HostExec.run(
            ["sudo", "systemctl", "enable", "--now", "podman-restart.service"]
        ) == 0 else {
            throw RuntimeError("Failed to enable podman-restart.service.")
        }
        ok("podman-restart.service enabled (containers survive reboot).")
    }

    /// Derive the instance suffix from the VM's OS hostname. The mpd-machine
    /// bootstrap (create-vm.sh on the cloud-init platforms; the user's own
    /// rename on sandbox) sets the hostname to either `mpd-machine`
    /// (singleton), `mpd-machine-<X>` (concurrent variant on cloud-init
    /// platforms), or `mpd-machine-sandbox` (sandbox); the suffix here is
    /// `-<X>` / `-sandbox` (with the leading dash) or `""`. Used to
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

    /// Append a single conditional `PATH` line to the dev user's
    /// `~/.bashrc` so `bin/machine/` tools (demo, claude-install, …) are
    /// on PATH in every bash session. Same shape as Debian's stock
    /// `~/.profile` block for `~/.local/bin`.
    ///
    /// Single-user assumption: mpd-machine is a sandbox VM with one
    /// developer account, so user-scoped wiring is enough — no sudo, no
    /// /etc/profile.d (where ordering/file-existence-at-login bites IDE
    /// terminals that snapshot env before mpd --setup runs).
    ///
    /// Idempotent: the marker comment is the dedupe key. Re-runs no-op.
    /// Also strips the legacy provision.sh snippet that sourced
    /// /etc/profile.d/mpd-machine.sh, then `sudo rm`s the drop-in.
    private static func installMachineBinPath() throws {
        let bashrc = "\(NSHomeDirectory())/.bashrc"
        let marker = "# mpd-machine: bin/machine on PATH"
        let snippet = """

        \(marker)
        if [ -d "$HOME/Developer/mpd/bin/machine" ] ; then
            PATH="$HOME/Developer/mpd/bin/machine:$PATH"
        fi

        """

        var contents = (try? String(contentsOfFile: bashrc, encoding: .utf8)) ?? ""
        let original = contents
        contents = stripLegacyBashrcSnippet(contents)
        if !contents.contains(marker) {
            if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
            contents += snippet
        }
        if contents != original {
            do {
                try contents.write(toFile: bashrc, atomically: true, encoding: .utf8)
            } catch {
                throw RuntimeError("Failed to write \(bashrc): \(error.localizedDescription)")
            }
        }

        // Clean up the legacy /etc/profile.d drop-in for upgraders.
        // Best-effort (file may be absent or sudo may be unavailable).
        _ = Mpd.HostExec.run(
            ["sudo", "rm", "-f", "/etc/profile.d/mpd-machine.sh"])

        ok("~/.bashrc — adds bin/machine/ to PATH (run `source ~/.bashrc` to update the current shell).")
    }

    /// Strip the older provision.sh-installed bashrc snippet that sourced
    /// /etc/profile.d/mpd-machine.sh. Removes the marker comment plus the
    /// next line. No-op when absent.
    private static func stripLegacyBashrcSnippet(_ text: String) -> String {
        let legacy = "# mpd-machine: pick up /etc/profile.d/mpd-machine.sh for non-login shells"
        guard text.contains(legacy) else { return text }
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipNext = false
        for line in lines {
            if skipNext { skipNext = false; continue }
            if line == legacy { skipNext = true; continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Install assets/machine/motd as /etc/motd and disable Debian's
    /// dynamic update-motd scripts so the static banner survives every login.
    /// Idempotent. Single source for the banner across all platforms — the
    /// per-platform `create-vm.sh` scripts no longer touch /etc/motd.
    private static func installLoginBanner() throws {
        let source = "\(Mpd.assetsDir)/machine/motd"
        guard FileManager.default.fileExists(atPath: source) else {
            throw RuntimeError("motd asset missing: \(source)")
        }
        // Disable dynamic motd generation. Some Debian images ship
        // /etc/update-motd.d/* scripts that would otherwise compete with our
        // static /etc/motd. Best-effort — directory may not exist.
        _ = Mpd.HostExec.run(
            ["sudo", "bash", "-c", "chmod -x /etc/update-motd.d/* 2>/dev/null || true"]
        )
        guard Mpd.HostExec.run(
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
        let (rc, out) = Mpd.HostExec.capture(
            ["dpkg-query", "-W", "-f=${Status}", pkg],
            suppressStderr: true)
        return rc == 0 && out.contains("install ok installed")
    }

    /// Generate ~/.ssh/id_ed25519 if no id_*.pub already exists, then make
    /// sure ~/.ssh/authorized_keys exists (touched empty if missing) with
    /// the VM's own pubkey appended. Idempotent.
    ///
    /// Why authorized_keys matters even on a never-SSH'd sandbox VM:
    /// `Service.FileAccess` bind-mounts the host's authorized_keys into the
    /// fileaccess container (`statfs` fails the service start if the file
    /// doesn't exist). Cloud-init platforms get the file as a side-effect
    /// of injecting the laptop's pubkey via user-data, but sandbox has
    /// no laptop side and the file may genuinely be absent. Touching it
    /// (and adding the VM key so VM→fileaccess SSH works) covers both.
    ///
    /// No passphrase on the key — the VM is the trust boundary; the key
    /// only authenticates VM→runtime / VM→fileaccess hops.
    private static func ensureVMSSHKey() throws {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let sshDir = "\(home)/.ssh"

        try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sshDir)

        let entries = (try? fm.contentsOfDirectory(atPath: sshDir)) ?? []
        let hasIdPub = entries.contains { $0.hasPrefix("id_") && $0.hasSuffix(".pub") }
        let keyPath = "\(sshDir)/id_ed25519"
        let pubPath = "\(sshDir)/id_ed25519.pub"
        if hasIdPub {
            ok("VM-local key already present in ~/.ssh/.")
        } else {
            let host = ProcessInfo.processInfo.hostName
            let comment = "mpd-machine \(host)"
            guard Mpd.HostExec.run([
                "ssh-keygen", "-t", "ed25519", "-N", "", "-f", keyPath, "-C", comment, "-q",
            ]) == 0 else {
                throw RuntimeError("Failed to generate ~/.ssh/id_ed25519. Run `ssh-keygen -t ed25519` manually and re-run mpd --setup.")
            }
            ok("Generated VM-local key at ~/.ssh/id_ed25519 (no passphrase, used for VM→runtime / VM→fileaccess SSH).")
        }

        try ensureAuthorizedKeysHasVMKey(sshDir: sshDir, vmPubKeyPath: pubPath)
    }

    /// Make sure `~/.ssh/authorized_keys` exists (mode 600) and contains
    /// the VM's own pubkey. Required because Service.FileAccess
    /// bind-mounts the file into the container; a missing host file
    /// fails the service start with statfs ENOENT.
    private static func ensureAuthorizedKeysHasVMKey(sshDir: String, vmPubKeyPath: String) throws {
        let fm = FileManager.default
        let authPath = "\(sshDir)/authorized_keys"
        if !fm.fileExists(atPath: authPath) {
            fm.createFile(atPath: authPath, contents: Data(), attributes: [
                .posixPermissions: 0o600
            ])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
        }

        guard let pub = try? String(contentsOfFile: vmPubKeyPath, encoding: .utf8) else {
            return  // No VM pubkey (shouldn't happen after ssh-keygen); leave the empty file in place.
        }
        let pubLine = pub.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match on the base64 key blob (middle field), so a re-keyed VM
        // with a different comment doesn't duplicate the line.
        let fields = pubLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count >= 2 else { return }
        let blob = fields[1]

        let existing = (try? String(contentsOfFile: authPath, encoding: .utf8)) ?? ""
        if existing.contains(blob) {
            ok("VM pubkey already in ~/.ssh/authorized_keys.")
            return
        }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += pubLine + "\n"
        try updated.write(toFile: authPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
        ok("Appended VM pubkey to ~/.ssh/authorized_keys.")
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
        guard Mpd.HostExec.binaryPath(for: "certutil") != nil,
              FileManager.default.fileExists(atPath: "/usr/bin/certutil") else {
            print("  certutil not found (apt: libnss3-tools). Skipping NSS-DB import.")
            return
        }

        // -A adds; nickname "mpd CA" is overwritten on re-run, so this is
        // idempotent. Trust flags "C,," = trusted CA for SSL only.
        guard Mpd.HostExec.run([
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

    // MARK: - WireGuard tunnel

    private static let wgInVMConfPath  = "\(Mpd.confDir)/wireguard/mpd0.conf"
    private static let wgSystemConfPath = "/etc/wireguard/mpd0.conf"
    private static let wgService        = "wg-quick@mpd0.service"

    /// Gated on `~/.mpd/conf/wireguard/mpd0.conf` (pushed in by mpd-virt at
    /// provisioning time). If absent — sandbox case, or an mpd-machine VM
    /// whose host hasn't pushed config yet — this step is a clean no-op.
    ///
    /// When present: apt-install `wireguard`, copy the conf to
    /// `/etc/wireguard/mpd0.conf` (root:root, 0600), persist
    /// `net.ipv4.ip_forward=1` via sysctl.d, and enable + start the
    /// `wg-quick@mpd0` systemd unit. Re-run safely; the service is only
    /// restarted when the conf file actually changed.
    private static func configureWireGuardIfPresent() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: wgInVMConfPath) else {
            ok("No \(wgInVMConfPath) present — skipping WireGuard setup.")
            return
        }

        try installPackages(["wireguard"], label: "wireguard")
        try ensureIPForwardEnabled()
        let changed = try installWireGuardConf()

        if changed {
            // First install OR conf was rewritten: enable + start (or restart).
            // `systemctl enable --now` is idempotent for the enable side; the
            // explicit restart picks up the new conf even if the service was
            // already running.
            guard Mpd.HostExec.run(
                ["sudo", "systemctl", "enable", wgService]
            ) == 0 else {
                throw RuntimeError("Failed to enable \(wgService).")
            }
            guard Mpd.HostExec.run(
                ["sudo", "systemctl", "restart", wgService]
            ) == 0 else {
                throw RuntimeError("Failed to (re)start \(wgService).")
            }
            ok("\(wgService) active (conf installed).")
        } else {
            // Conf unchanged — just make sure the service is up.
            guard Mpd.HostExec.run(
                ["sudo", "systemctl", "enable", "--now", wgService]
            ) == 0 else {
                throw RuntimeError("Failed to enable \(wgService).")
            }
            ok("\(wgService) already active (conf unchanged).")
        }
    }

    /// Install the in-VM conf at `/etc/wireguard/mpd0.conf` (root:root, 0600).
    /// Returns true if the destination changed (new file or content differs),
    /// false if already up to date.
    private static func installWireGuardConf() throws -> Bool {
        // `cmp -s` exits 0 if identical, non-zero on any difference (incl.
        // destination missing). Run via sudo because the destination is
        // root-owned 0600 and our process can't read it otherwise.
        let (cmpRC, _) = Mpd.HostExec.capture(
            ["sudo", "cmp", "-s", wgInVMConfPath, wgSystemConfPath],
            suppressStderr: true
        )
        if cmpRC == 0 { return false }
        guard Mpd.HostExec.run([
            "sudo", "install",
            "-m", "0600", "-o", "root", "-g", "root",
            wgInVMConfPath, wgSystemConfPath,
        ]) == 0 else {
            throw RuntimeError("Failed to install \(wgInVMConfPath) → \(wgSystemConfPath).")
        }
        return true
    }

    /// Persist `net.ipv4.ip_forward=1` via a sysctl.d drop-in. Required so
    /// the VM kernel routes packets arriving on `wg0` (from the Mac) into
    /// `podman1` and out to container IPs. Idempotent.
    private static func ensureIPForwardEnabled() throws {
        let dropInPath = "/etc/sysctl.d/99-mpd-wg.conf"
        let desired = "# Written by mpd --setup. Forwarding required for WireGuard → podman1.\nnet.ipv4.ip_forward=1\n"
        // Read what's there (sudo not needed for /etc/sysctl.d — world-readable).
        let current = (try? String(contentsOfFile: dropInPath, encoding: .utf8)) ?? ""
        if current != desired {
            guard Mpd.HostExec.run([
                "sudo", "bash", "-c",
                "cat > \(dropInPath) <<'EOF'\n\(desired)EOF",
            ]) == 0 else {
                throw RuntimeError("Failed to write \(dropInPath).")
            }
        }
        // Apply current settings. `sysctl --system` reloads every drop-in,
        // including our new one, and is idempotent.
        guard Mpd.HostExec.run(["sudo", "sysctl", "--system"]) == 0 else {
            throw RuntimeError("sysctl --system failed.")
        }
    }

    static func preflight() throws {
        // Distro gate — fail fast on unsupported hosts before any apt work.
        // Debian Trixie across every platform.
        try requireSupportedHost()

        // Verify the host's network stack is in the standardized state
        // (systemd-resolved active, fed by either NetworkManager or
        // systemd-networkd). cloud-init (macos/linux/windows)
        // and `sandbox/lib/provision.sh` (sandbox) are both responsible
        // for putting the system here; mpd --setup just verifies and
        // bails with a hint if not.
        try Mpd.Integration.requireSystemdResolvedActive()

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
        ok("Execution environment: \(Mpd.label)")
        let fm = FileManager.default

        try Mpd.Action.Setup.preflight()

        step("Conf directory")
        try Mpd.ensureConfDirectory()
        ok("Ensured ~/.mpd/conf/")

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
        ok("Platform: \(identity.platform.rawValue), VM IP: \(identity.vmIP.isEmpty ? "—" : identity.vmIP), suffix: \(derivedSuffix.isEmpty ? "—" : derivedSuffix)")

        // Step — VM-local SSH keypair. Without this, the VM has no private key
        // to offer when SSHing into runtimes from a local terminal (e.g. inside
        // GNOME desktop), so users would always need `ssh -A` from the laptop.
        // The pubkey is later picked up by Mpd.authorizedPublicKeys
        // and ends up in every runtime's authorized_keys.
        step("VM-local SSH key")
        try ensureVMSSHKey()

        let machineName = Mpd.Core.State.activeMachine()

        // Detect extuser/extuid
        step("Configuration")
        var config = Mpd.Core.State.readConfig()
        let detectedIdentity = Mpd.detectUserAndUID()
        let user = detectedIdentity.user
        let uid = detectedIdentity.uid
        if !user.isEmpty { config.user = user }
        if !uid.isEmpty { config.uid = uid }
        Mpd.Core.State.writeConfig(config)
        ok("machine=\(machineName)  user=\(user)  uid=\(uid)")

        // Root CA certificate
        step("Root CA certificate")

        let carootDir = Mpd.confCARootDir
        let serviceDir = Mpd.confServiceDir
        let certOpsDir = Mpd.confTempDir
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
            try Mpd.Certificate.generateCA(caKeyPath: caKeyPem, caCertPath: caRootPem, certsDir: certOpsDir)
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
        let currentCAFingerprint = Mpd.fileFingerprint(caRootPem)
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

            try Mpd.Certificate.generateCert(
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
        Mpd.Certificate.trustCA(caPath: caRootPem)

        step("Trust mpd CA in user's NSS DB (Chromium)")
        try ensureCAInUserNSSDB(caPath: caRootPem)

        step("Trust mpd CA in Firefox (enterprise policy)")
        Mpd.Certificate.installFirefoxPolicy(caPath: caRootPem)

        step("DNS resolver for mpd.test")
        try Mpd.Integration.configureDNSResolver()

        step("WireGuard tunnel")
        try configureWireGuardIfPresent()

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
        let mpdUserEnvPath = "\(Mpd.dotMpdDir)/mpd-user.env"
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
        Mpd.Integration.verifyDNS()

        step("Shell completion for mpd")
        Mpd.Core.Assets.installCompletion()

        step("Adding bin/machine/ to login PATH")
        try installMachineBinPath()

        step("Installing login banner (motd)")
        try installLoginBanner()

        step("Rescanning data volume")
        try? Mpd.Core.DataVolume.rescan()

        step("Probing existing runtime containers")
        Mpd.Runtime.rebuildStateCache()

        step("Probing existing database containers")
        Mpd.Runtime.DB.rebuildStateCache()
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

        // Install the user-level systemd unit that fires `mpd --stop`
        // on VM shutdown / reboot / suspend, so DBs get graceful
        // EventMpdPreStop hooks instead of being killed mid-flight.
        // See docs/HOOKS.md §"Systemd integration".
        step("Installing shutdown unit")
        try Mpd.ShutdownUnit.install()
        ok("~/.config/systemd/user/mpd.service installed and enabled.")

        // Hook diagnostics — orphans, audience drift, revision bumps.
        // Silent in the happy path; prints warnings only when something
        // is off. Stamps current event revisions for next-run comparison.
        Mpd.Hooks.diagnose()

        // Live-state snapshot for out-of-process consumers (portal etc.).
        Mpd.Runtime.State.refreshCurrentStateCache()

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
