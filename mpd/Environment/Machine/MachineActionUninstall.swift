// mpd-machine command hooks
// Uninstall: stop and remove all mpd-managed containers/pods/network and ~/.mpd/
// state. Persistent material (~/Developer/mpd/conf, mpd data volume) is kept.
// System-level cleanup of CA trust is printed as a manual step. DNS plumbing
// is intentionally not torn down — the VM is a wipe-and-rebuild sandbox
// and `mpd --setup` re-converges DNS on every run, so leaving
// systemd-resolved configured costs nothing whether the user re-runs setup
// or deletes the VM outright.

import Foundation

#if os(Linux)
extension Mpd.Environment.Action.Uninstall {
    static func execute(skipPrompt: Bool = false) throws {
        let fm = FileManager.default

        print("""

          This will:
            - Stop and remove all mpd containers, pods, and the 'mpd-internal' network
            - Remove zsh completion
            - Delete ~/.mpd/ (state/cache only)
            - Keep ~/Developer/mpd/conf/ (CA, service certs)
            - Keep the 'mpd' data volume (projects, databases, personal area)
            - Print remaining manual cleanup steps

        """)

        guard skipPrompt || promptYesNo("Continue?") else {
            print("Aborted.")
            return
        }

        // Step 0 — Remove the user-level systemd shutdown unit before we
        // tear down everything else. Linger is left alone (user may have
        // enabled it for other reasons; orphan linger is harmless).
        step("Removing shutdown unit")
        Mpd.Environment.ShutdownUnit.uninstall()
        ok("~/.config/systemd/user/mpd.service removed.")

        // Step 1 — Force-remove all mpd-managed containers + pods.
        // We use rm -f (SIGKILL) — graceful shutdown isn't needed for teardown,
        // and `podman stop`'s 10s SIGTERM grace per container makes uninstall painful.
        step("Removing mpd containers and pods")
        var removed = 0
        var seen = Set<String>()
        let containerFilters = [
            "label=mpd.managed=true",                       // runtime containers
            "label=com.docker.compose.project=mpd-service", // service containers
            "label=com.docker.compose.project=mpd-dev",     // runtime pod members
            "label=mpd.type=db",                            // database containers
        ]
        for filter in containerFilters {
            for item in Mpd.Podman.ps(filter: filter) {
                guard let name = item.Names.first, !name.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)
                _ = Mpd.Podman.removeForcefully(name)
                removed += 1
            }
        }

        // Pods (runtime pods may persist after container removal).
        let (podCode, podOut) = Mpd.Environment.HostExec.capture(
            ["bash", "-c",
             "sudo -n podman pod ps --filter label=com.docker.compose.project=mpd-dev --format '{{.Name}}' 2>/dev/null"],
            suppressStderr: true)
        if podCode == 0 {
            for podName in podOut.split(separator: "\n").map(String.init) where !podName.isEmpty {
                _ = Mpd.Podman.podRemoveForcefully(podName)
                removed += 1
            }
        }

        if removed > 0 {
            ok("Removed \(removed) container(s)/pod(s).")
        } else {
            ok("No mpd containers or pods found.")
        }

        // Step 2 — Remove the 'mpd-internal' network.
        step("Removing 'mpd-internal' network")
        if Mpd.Podman.networkExists("mpd-internal") {
            if Mpd.Podman.networkRemove("mpd-internal") == 0 {
                ok("Network 'mpd-internal' removed.")
            } else {
                errPrint("Warning: failed to remove network 'mpd-internal'.")
            }
        } else {
            ok("Network 'mpd-internal' already absent.")
        }

        // Step 3 — Remove zsh completion.
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

        // Step 4 — Delete ~/.mpd/ (state/cache only).
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

        // Step 5 — Restore tracked placeholder dirs in source checkout.
        step("Repository placeholders")
        try Mpd.Environment.ensureTrackedPlaceholderDirectories()
        ok("Ensured ~/Developer/mpd/conf/.gitkeep")

        // Step 6 — Manual cleanup instructions + status.
        print(Mpd.Environment.Action.Uninstall.manualCleanupText())
        print(Mpd.Environment.Action.Uninstall.manualCleanupStatusText())

        print("\n\u{001B}[1;32m✓ mpd uninstall completed.\u{001B}[0m")
    }

    /// One-line "where to look for laptop-side cleanup" pointer. After the
    /// PLAN.md Phase 4 cleanup, mpd no longer carries per-OS uninstall
    /// recipes — host-side cleanup is documented in each platform's
    /// `uninstall.*` script (or, for sandbox, is just "revert the
    /// snapshot").
    private static func clientUninstallPointer() -> String {
        guard let identity = try? Mpd.Core.Platform.load() else {
            return "  See your platform's README under setup/."
        }
        switch identity.platform {
        case .sandbox:
            return "  (sandbox platform — no laptop-side cleanup; mpd lived entirely inside this VM)"
        case .desktop:
            return "  (desktop — see docs/desktop/USAGE.md for laptop-side teardown)"
        case .macosUTM, .macosPRL, .ubuntuKVM, .windowsHyperV:
            let dir = "setup/\(identity.platform.rawValue)"
            return "  See \(dir)/uninstall.* (or its README) for the host-side teardown."
        }
    }

    static func manualCleanupText() -> String {
        """

        Manual cleanup on the VM (requires sudo, optional):

          # Untrust the mpd CA
          sudo rm -f /usr/local/share/ca-certificates/mpd-local.crt
          sudo update-ca-certificates --fresh

          # Remove the Firefox enterprise policy (paths vary by Firefox flavor)
          sudo rm -f /usr/lib/firefox-esr/distribution/policies.json   # Debian firefox-esr
          sudo rm -f /etc/firefox/policies/policies.json               # Ubuntu / snap-Firefox / Mozilla deb
          sudo rm -f /etc/firefox/policies/mpd-rootCA.crt              # (CA copy alongside the policy)

          # Optional: remove persisted CA / service cert material for a clean next setup
          rm -rf ~/Developer/mpd/conf

          # Optional: remove the mpd data volume (wipes ALL projects, dbs, personal area)
          sudo podman volume rm mpd-data-volume

          # Remove mpd source (optional)
          rm -rf ~/Developer/mpd

        Host-side / laptop-side cleanup:

        \(clientUninstallPointer())

          Optional: clear SSH known_hosts entries for mpd domains
            ssh-keygen -R mpd.test
        """
    }

    static func manualCleanupStatusText() -> String {
        let fm = FileManager.default
        let trustPath = "/usr/local/share/ca-certificates/mpd-local.crt"
        let trustRemoved = !fm.fileExists(atPath: trustPath)

        // Firefox policy lives in one of two places depending on the
        // installed flavor (firefox-esr vs Mozilla/snap). Report whichever
        // is currently present, or "removed" if neither exists.
        let firefoxEsrPolicy = "/usr/lib/firefox-esr/distribution/policies.json"
        let mozillaPolicy = "/etc/firefox/policies/policies.json"
        let mozillaCert = "/etc/firefox/policies/mpd-rootCA.crt"
        let presentFirefoxPaths = [firefoxEsrPolicy, mozillaPolicy, mozillaCert]
            .filter { fm.fileExists(atPath: $0) }
        let firefoxPolicyRemoved = presentFirefoxPaths.isEmpty
        let firefoxStatusDetail = firefoxPolicyRemoved
            ? "Firefox enterprise policy removed"
            : "Firefox enterprise policy still present at: \(presentFirefoxPaths.joined(separator: ", "))"

        let persistedCAPath = "\(Mpd.Environment.confCARootDir)/rootCA.pem"
        let persistedCAExists = fm.fileExists(atPath: persistedCAPath)

        let volumeExists = Mpd.Podman.volumeExists(Mpd.dataVolume)

        return """

        Manual cleanup status:

          \(trustRemoved ? "✓" : "•") Root CA \(trustPath) \(trustRemoved ? "removed" : "still present in system trust store")
          \(firefoxPolicyRemoved ? "✓" : "•") \(firefoxStatusDetail)
          \(persistedCAExists ? "•" : "✓") Persisted CA / service material in ~/Developer/mpd/conf \(persistedCAExists ? "present (next setup reuses existing material)" : "absent (next setup generates fresh material)")
          \(volumeExists ? "•" : "✓") Data volume '\(Mpd.dataVolume)' \(volumeExists ? "present (projects, dbs, personal area kept)" : "absent (next setup creates a fresh volume)")
        """
    }
}
#endif
