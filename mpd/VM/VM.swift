// mpd — Mpd.VM top-level (paths + identity)
//
// Paths are absolute and VM-wide (not derived from $HOME). The mpd VM is
// a single-purpose appliance: code, assets, and state live in FHS-standard
// system locations; the dev user just owns them via chown at bootstrap.
//
// Other VM/*.swift files extend Mpd.VM with operations (exec, identity,
// DNS, shutdown unit, certificate, etc.) and the sub-namespaces (Assets,
// DataVolume, Platform, Config).

import Foundation

extension Mpd.VM {

    // MARK: - Label

    static var label: String { "mpd VM (Debian Trixie)" }

    // MARK: - Filesystem paths

    /// Dev user's home directory. Used only for genuinely per-user
    /// concerns (e.g. systemd user units must live under $HOME). Nothing
    /// mpd-owned should live here — mpd state is in /var/lib/mpd.
    static var homeDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Mpd source-checkout + assets + built binary. Owned by the dev user
    /// (bootstrap chowns the tree); /opt is the FHS slot for add-on packages.
    static var mpdDir: String { "/opt/mpd" }

    /// Assets directory
    static var assetsDir: String { "\(mpdDir)/assets" }

    /// CLI binary directory
    static var binDir: String { "\(mpdDir)/bin" }

    /// Persistent VM state root. FHS `/var/lib/<pkg>/` slot.
    /// Owned by the dev user (bootstrap chowns).
    static var varLibDir: String { "/var/lib/mpd" }

    /// Persistent local trust material: /var/lib/mpd/conf/
    /// Holds the CA + service cert + platform.env.
    /// PRIVATE — never bind-mounted into containers.
    static var confDir: String { "\(varLibDir)/conf" }

    /// User-editable env overrides: /var/lib/mpd/env/
    /// Holds `mpd-vm.env` — VM-wide MPD_* overrides the developer edits
    /// by hand. Bind-mounted RO into runtime containers at the same path
    /// (directory mount, so vim/nano atomic-rename writes propagate).
    static var envDir: String { "\(varLibDir)/env" }

    /// Operational state: /var/lib/mpd/state/
    /// Holds projects.json, databases.json, runtimes/, current-state.json,
    /// dnsmasq.d/, fileaccess/hostkeys/, portal/, hooks-state.json. Safe
    /// to bind-mount RO into containers that need to observe mpd state
    /// (the portal mounts this whole tree at /mpd-state). Wipe to reset.
    static var stateDir: String { "\(varLibDir)/state" }

    /// Root CA directory
    static var confCARootDir: String { "\(confDir)/caroot" }

    /// Service TLS certificate directory
    static var confServiceDir: String { "\(confDir)/service" }

    /// Scratch area for short-lived cert artifacts
    static var confTempDir: String { "\(confDir)/temp" }

    /// dnsmasq.d directory. Source of truth on the host; bind-mounted RO
    /// into the dnsmasq container at /etc/dnsmasq.d/. Directory mount so
    /// per-runtime .conf adds/removes are visible inside the container
    /// immediately — dnsmasq restarts on conf-dir changes.
    static var dnsmasqDir: String { "\(stateDir)/dnsmasq.d" }

    /// Persistent SSH host-key directory for the fileaccess service.
    /// Bind-mounted into the container so keys survive rebuilds.
    static var fileAccessHostKeysDir: String { "\(stateDir)/fileaccess/hostkeys" }

    // MARK: - Container mount args

    /// Standard read-only mount of the mpd checkout into every container.
    /// `/opt/mpd/` means the same thing inside containers as on the VM —
    /// runtimes, services, sidecars all see the same tree at the same
    /// path. Splat into the args list of every container create.
    static let optMountRO: [String] = ["-v", "/opt/mpd:/opt/mpd:ro"]

    /// Read-only mount of /var/lib/mpd/env/ into runtime containers.
    /// Lets `source-mpd-env.sh` read mpd-vm.env at the same absolute path
    /// as on the VM. Directory mount (not file mount) so editor atomic-
    /// rename writes propagate without breaking the mount.
    static let envMountRO: [String] = ["-v", "/var/lib/mpd/env:/var/lib/mpd/env:ro"]

    /// Read-only mount of /var/lib/mpd/skel/ into runtime containers.
    /// Read at runtime-create time by `assets/runtime-base/bootstrap.sh`
    /// to overlay the VM-host's user-managed dotfile defaults on top of
    /// the shipped `assets/runtime-base/skel/`. The directory is empty
    /// by default — `mpd --setup` creates it so the bind-mount source
    /// always exists, and bootstrap.sh skips the overlay when the
    /// directory is empty.
    static let skelMountRO: [String] = ["-v", "/var/lib/mpd/skel:/var/lib/mpd/skel:ro"]

    // MARK: - Developer-facing hints

    static var recommendedBuildCommand: String { "cd /opt/mpd && make install" }
    static var expectedExecutablePath: String { "\(binDir)/mpd" }
    static var pathExportHint: String { "export PATH=\"/opt/mpd/bin:$PATH\"" }

    // MARK: - Path resolution with existence check

    /// Resolve the assets directory in the source checkout, throwing if the
    /// checkout looks incomplete. Useful when callers want a hard fail-fast
    /// rather than silently using a missing path.
    static func assetsPath() throws -> String {
        let p = assetsDir
        guard FileManager.default.fileExists(atPath: "\(p)/runtime-base") else {
            throw RuntimeError("Assets not found at \(p) — clone mpd to /opt/mpd.")
        }
        return p
    }

    // MARK: - Directory creation helpers

    /// Ensure the persistent identity directory `/var/lib/mpd/conf/` exists.
    /// The CA + service certs land inside it; sub-callers create their own
    /// subdirs as needed.
    static func ensureConfDirectory() throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: confDir, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw RuntimeError("Path exists but is not a directory: \(confDir)")
            }
            return
        }
        try fm.createDirectory(atPath: confDir, withIntermediateDirectories: true)
    }
}
