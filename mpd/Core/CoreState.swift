import Foundation

// Core registry roots and machine pointers.
// Owns paths and read/write access for global status + per-machine config roots.
// Does not own live runtime/project lifecycle state (that lives in RuntimeState).

// MARK: - Mpd.Core.State

extension Mpd.Core.State {
    static var statusPath: String { "\(Mpd.Environment.dotMpdDir)/.status.json" }

    /// dnsmasq.d directory for the active machine. Source of truth on the
    /// host; mirrored into the data volume at `/srv/state/dnsmasq.d/` by
    /// `syncBindMountFiles()` so the dnsmasq container can bind-mount the
    /// volume subpath instead of a host path. Avoids virtiofs cache lag on
    /// libkrun-backed Podman machines.
    static var dnsmasqDir: String { "\(Mpd.Core.State.machineDir())/dnsmasq.d" }

    /// Persistent SSH host-key directory for the fileaccess service.
    /// Bind-mounted into the container so keys survive rebuilds.
    static var fileAccessHostKeysDir: String { "\(Mpd.Core.State.machineDir())/fileaccess/hostkeys" }

    /// Sync host-side bind-mount source files into the data volume so
    /// mpd-managed containers can bind-mount from the volume rather than
    /// from a host path. Source of truth stays on the host (fast reads,
    /// debuggable via `cat ~/.mpd/...`); the volume copy is a derived
    /// mirror refreshed on `--setup`, `--start`, and after host-side state
    /// changes (dnsmasq record updates).
    ///
    /// Why bother: macOS Podman machines using libkrun ship a virtiofs
    /// implementation with multi-second cache lag on host-bind-mounts of
    /// newly-created paths (filed at podman/libkrun upstreams; not mpd's
    /// problem to fix). Routing through the volume sidesteps virtiofs
    /// entirely — the volume lives natively inside the VM. AppleHV is
    /// unaffected, but routing both modes through the same code path
    /// avoids per-backend forking.
    ///
    /// Files synced:
    /// - `~/.mpd/mpd-user.env` → `/srv/personal/mpd-user.env`
    ///   (runtimes already mount `/srv` and read directly from there;
    ///   no separate bind-mount on the runtime pod.)
    /// - `~/.mpd/machines/<m>/dnsmasq.d/*.conf` → `/srv/state/dnsmasq.d/`
    ///   (dnsmasq container subpath-mounts that directory at /etc/dnsmasq.d.
    ///   Subpath= is snapshot-at-attach in current podman, but dnsmasq
    ///   already restarts on conf-dir changes — re-attach picks up the
    ///   latest content.)
    ///
    /// Requires fileaccess to be running. Safe to call repeatedly.
    static func syncBindMountFiles() throws {
        let fa = Mpd.Service.FileAccess.containerName
        let fm = FileManager.default

        // 1. mpd-user.env → /srv/personal/mpd-user.env
        let envHost = "\(Mpd.Environment.dotMpdDir)/mpd-user.env"
        if fm.fileExists(atPath: envHost) {
            let envVolDst = "\(fa):/srv/personal/mpd-user.env"
            guard Mpd.Podman.cp(from: envHost, to: envVolDst) == 0 else {
                throw RuntimeError("Failed to sync mpd-user.env into the data volume.")
            }
        }

        // 2. dnsmasq.d/*.conf → /srv/state/dnsmasq.d/
        //    Mirror, not just copy: any *.conf in the volume that's no longer
        //    on the host is removed so dnsmasq doesn't pick up stale records
        //    (e.g. after a runtime delete).
        let dnsmasqHostDir = Self.dnsmasqDir
        _ = Mpd.Podman.exec(fa, ["mkdir", "-p", "/srv/state/dnsmasq.d"])
        let hostConfNames = ((try? fm.contentsOfDirectory(atPath: dnsmasqHostDir)) ?? [])
            .filter { $0.hasSuffix(".conf") }
        let hostSet = Set(hostConfNames)

        let (rc, listed) = Mpd.Podman.execOutput(
            fa, ["ls", "/srv/state/dnsmasq.d"], suppressStderr: true)
        if rc == 0 {
            for line in listed.split(whereSeparator: \.isNewline) {
                let name = String(line)
                guard name.hasSuffix(".conf"), !hostSet.contains(name) else { continue }
                _ = Mpd.Podman.exec(fa, ["rm", "-f", "/srv/state/dnsmasq.d/\(name)"])
            }
        }

        for name in hostConfNames {
            let src = "\(dnsmasqHostDir)/\(name)"
            let dst = "\(fa):/srv/state/dnsmasq.d/\(name)"
            guard Mpd.Podman.cp(from: src, to: dst) == 0 else {
                throw RuntimeError("Failed to sync \(name) into the data volume.")
            }
        }
    }

    static func readStatus() -> CoreStatus {
        JSONStateStore.readJSON(statusPath, as: CoreStatus.self) ?? CoreStatus()
    }

    static func writeStatus(_ status: CoreStatus) {
        JSONStateStore.writeJSON(status, to: statusPath)
    }

    /// The active Podman machine name from .status.json.
    static func activeMachine() -> String {
        readStatus().activeMachine
    }

    /// Per-machine state directory: ~/.mpd/machines/<machine>/
    /// All per-machine files (config, projects, runtimes, dnsmasq.d, Assets) live here.
    static func machineDir(_ machine: String? = nil) -> String {
        let name = machine ?? activeMachine()
        return "\(Mpd.Environment.dotMpdDir)/machines/\(name)"
    }

    static var configPath: String { "\(machineDir())/config.json" }

    static func readConfig() -> CoreConfig {
        JSONStateStore.readJSON(configPath, as: CoreConfig.self) ?? CoreConfig()
    }

    static func writeConfig(_ config: CoreConfig) {
        JSONStateStore.writeJSON(config, to: configPath)
    }
}
