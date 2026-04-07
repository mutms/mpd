// mpd-desktop command hooks
// Desktop-only setup/start/stop/uninstall behavior (macOS host + Podman Desktop).

import Foundation

#if os(macOS)
extension Mpd.Environment.Action.Uninstall {
    static func execute(skipPrompt: Bool = false) throws {
        let fm = FileManager.default
        let status = Mpd.Core.State.readStatus()

        print("""

          This will:
            - Stop mpd runtime/services
            - Remove zsh completion
            - Delete ~/.mpd/ (state/cache only)
            - Keep ~/Developer/mpd/conf/ (CA, WG, service certs)
            - Print remaining manual cleanup steps

          Runtime data volume and VM/runtime machine are kept.

        """)

        guard skipPrompt || promptYesNo("Continue?") else {
            print("Aborted.")
            return
        }

        // Step 1 — Stop everything
        if status.activeMachine.isEmpty {
            ok("No active machine in ~/.mpd state. Continuing cleanup.")
        } else {
            step("Stopping mpd")
            do {
                try Mpd.Environment.Action.Stop.execute()
            } catch {
                errPrint("Warning: failed to stop mpd cleanly: \(error.localizedDescription)")
                print("Continuing uninstall cleanup.")
            }
        }

        // Step 2 — Remove zsh completion
        let completionFile = "\(Mpd.Environment.homeDir)/.zsh/completions/_mpd"
        if fm.fileExists(atPath: completionFile) {
            do {
                try fm.removeItem(atPath: completionFile)
                ok("Removed ~/.zsh/completions/_mpd")
            } catch {
                errPrint("Warning: failed to remove ~/.zsh/completions/_mpd: \(error.localizedDescription)")
            }
        } else {
            ok("~/.zsh/completions/_mpd already absent.")
        }

        // Step 3 — Report SSH known_hosts status for *.mpd.test
        step("SSH known_hosts status")
        checkKnownHosts(status: status)

        // Step 4 — Delete ~/.mpd/ (last — so earlier steps can still read state)
        if fm.fileExists(atPath: Mpd.Environment.dotMpdDir) {
            step("Removing ~/.mpd/")
            do {
                try fm.removeItem(atPath: Mpd.Environment.dotMpdDir)
                ok("~/.mpd/ removed.")
            } catch {
                errPrint("Warning: failed to remove ~/.mpd/: \(error.localizedDescription)")
            }
        } else {
            ok("~/.mpd/ already absent.")
        }

        // Step 5 — Ensure tracked placeholder directories (.gitkeep) in source checkout
        step("Repository placeholders")
        try Mpd.Environment.ensureTrackedPlaceholderDirectories()
        ok("Ensured ~/Developer/mpd/conf/.gitkeep")

        // Step 6 — Print environment-specific manual cleanup instructions
        let machineName = status.activeMachine.isEmpty ? "mpd-desktop" : status.activeMachine
        print(Mpd.Environment.Action.Uninstall.manualCleanupText(machineName: machineName))

        // Step 7 — Check manual cleanup status for resolver + root CA
        print(Mpd.Environment.Action.Uninstall.manualCleanupStatusText())

        print("\n\u{001B}[1;32m✓ mpd uninstall completed.\u{001B}[0m")
    }

    static func manualCleanupText(machineName: String) -> String {
        """

        Manual cleanup (requires sudo or manual action):
        After completing manual steps, rerun 'mpd --uninstall' to confirm status.

          # Remove DNS resolver
          sudo rm -f /etc/resolver/mpd.test

          # Remove CA cert from Keychain
          sudo security delete-certificate -c "mpd.test local development CA" \
            /Library/Keychains/System.keychain

          # Remove WireGuard tunnel
          Open the WireGuard app -> select 'mpd-desktop' tunnel -> delete

          # Open Podman Desktop and delete '\(machineName)' machine

          # Optional: remove persisted mpd cert/key material for a fully fresh next setup
          rm -rf ~/Developer/mpd/conf

          # Optional: clear SSH known_hosts entries for mpd domains
          ssh-keygen -R mpd.test
          # Repeat for runtime/project hosts if reported by uninstall status

          # Remove mpd source (optional)
          rm -rf ~/Developer/mpd
        """
    }

    private static func checkKnownHosts(status: CoreStatus) {
        let fm = FileManager.default

        var candidateHosts = Set<String>()
        candidateHosts.insert("mpd.test")

        let projects = Mpd.Runtime.State.loadProjects().projects
        for p in projects where !p.name.isEmpty {
            candidateHosts.insert("\(p.name).mpd.test")
            candidateHosts.insert("behat.\(p.name).mpd.test")
            if !p.runtimeName.isEmpty {
                candidateHosts.insert("\(p.runtimeName).runtime.mpd.test")
            }
        }

        let runtimes = Mpd.Runtime.State.listRuntimeStateEntries()
        for rt in runtimes where !rt.name.isEmpty {
            candidateHosts.insert("\(rt.name).runtime.mpd.test")
        }

        if !status.activeMachine.isEmpty {
            candidateHosts.insert("\(status.activeMachine).runtime.mpd.test")
        }

        let knownHostsPaths = [
            "\(Mpd.Environment.homeDir)/.ssh/known_hosts",
            "\(Mpd.Environment.homeDir)/.ssh/known_hosts2",
        ]

        let existingKnownHosts = knownHostsPaths.filter { fm.fileExists(atPath: $0) }
        guard !existingKnownHosts.isEmpty else {
            ok("No known_hosts files found under ~/.ssh/.")
            return
        }

        var detectedHosts = Set<String>()
        for path in existingKnownHosts {
            detectedHosts.formUnion(discoverMpdHosts(inKnownHostsFile: path))
        }
        candidateHosts.formUnion(detectedHosts)

        var remainingHosts = Set<String>()
        for path in existingKnownHosts {
            for host in candidateHosts {
                let (code, _) = Mpd.Environment.HostExec.capture([
                    "ssh-keygen", "-F", host, "-f", path,
                ], suppressStderr: true)
                if code == 0 {
                    remainingHosts.insert(host)
                }
            }
        }

        if remainingHosts.isEmpty {
            ok("No detected *.mpd.test entries remain in ~/.ssh/known_hosts files.")
        } else {
            print("  Remaining known_hosts entries for mpd domains:")
            for host in remainingHosts.sorted() {
                print("    - \(host)")
            }
            print("  Manual cleanup:")
            for host in remainingHosts.sorted() {
                print("    ssh-keygen -R \(host)")
            }
            print("  Note: hashed known_hosts entries are not discoverable by suffix scan.")
        }
    }

    private static func discoverMpdHosts(inKnownHostsFile path: String) -> Set<String> {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var found = Set<String>()

        for rawLine in content.split(separator: "\n") {
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("#") { continue }

            guard let hostField = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
                continue
            }

            for rawHost in hostField.split(separator: ",") {
                let host = String(rawHost)
                if host.hasPrefix("|") { continue } // hashed host entry

                // Handle [host]:port format and plain hostnames.
                var normalized = host
                if normalized.hasPrefix("[") {
                    if let end = normalized.firstIndex(of: "]") {
                        normalized = String(normalized[normalized.index(after: normalized.startIndex)..<end])
                    }
                } else if let colon = normalized.firstIndex(of: ":") {
                    normalized = String(normalized[..<colon])
                }

                if normalized == "mpd.test" || normalized.hasSuffix(".mpd.test") {
                    found.insert(normalized)
                }
            }
        }

        return found
    }

    static func manualCleanupStatusText() -> String {
        let resolverPath = "/etc/resolver/mpd.test"
        let resolverRemoved = !FileManager.default.fileExists(atPath: resolverPath)

        let (certCode, _) = Mpd.Environment.HostExec.capture(
            [
                "security",
                "find-certificate",
                "-c", "mpd.test local development CA",
                "/Library/Keychains/System.keychain",
            ],
            suppressStderr: true)
        let certRemoved = certCode != 0

        let persistedCAPath = "\(Mpd.Environment.confCARootDir)/rootCA.pem"
        let persistedCAExists = FileManager.default.fileExists(atPath: persistedCAPath)

        return """

        Manual cleanup status:

          \(resolverRemoved ? "✓" : "•") DNS resolver /etc/resolver/mpd.test \(resolverRemoved ? "removed" : "still present")
          \(certRemoved ? "✓" : "•") Root CA 'mpd.test local development CA' \(certRemoved ? "removed" : "still present in System keychain")
          \(persistedCAExists ? "•" : "✓") Persisted CA material in ~/Developer/mpd/conf \(persistedCAExists ? "present (next setup reuses existing cert material)" : "absent (next setup generates fresh cert material)")
        """
    }
}
#endif
