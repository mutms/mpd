// mpd — compile-time environment context helpers
// Single source for host/runtime path and tooling conventions.
// Owns static host paths and labels; does not perform setup/start/stop side effects.

import Foundation

extension Mpd.Environment {
    /// User's home directory
    static var homeDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Mpd source code directory
    static var mpdDir: String {
        "\(homeDir)/Developer/mpd"
    }

    /// Assets directory
    static var assetsDir: String {
        "\(mpdDir)/assets"
    }

    /// User's .mpd directory: ~/.mpd/
    static var dotMpdDir: String {
        "\(homeDir)/.mpd"
    }

    /// Persistent local trust/network material: ~/Developer/mpd/conf/
    /// Holds the CA, service cert, and (mpd-desktop only) WireGuard key material.
    static var confDir: String {
        "\(mpdDir)/conf"
    }

    /// Root CA directory (persisted, not removed by --uninstall)
    static var confCARootDir: String {
        "\(confDir)/caroot"
    }

    /// Platform-owned CA directory written by the mpd-machine macos
    /// bootstrap scripts (see setup/macos/lib/common.sh).
    /// Holds real files mirrored with `confCARootDir` on macOS hosts that
    /// have created an mpd-machine VM. `DesktopActionSetup` reads it when
    /// `confCARootDir` is missing so a Mac that runs both modes converges on
    /// a single CA. Bash scripts manage writes; Swift only ever reads.
    static var mpdMachineCARootDir: String {
        "\(homeDir)/.mpd-machine/ca"
    }

    /// WireGuard keys and client config directory (persisted, not removed by --uninstall).
    /// Used by mpd-desktop only — mpd-machine reaches containers via plain routing.
    static var confWireGuardDir: String {
        "\(confDir)/wireguard"
    }

    /// Service TLS certificate directory (persisted, not removed by --uninstall)
    static var confServiceDir: String {
        "\(confDir)/service"
    }

    /// Scratch area for short-lived cert artifacts
    static var confTempDir: String {
        "\(confDir)/temp"
    }

    /// CLI binary directory
    static var binDir: String {
        "\(mpdDir)/bin"
    }

    static var recommendedBuildCommand: String {
        return "cd ~/Developer/mpd && make install"
    }

    /// Ensure repository-tracked placeholder directories exist with .gitkeep files.
    /// Missing placeholders are recreated with repository-defined per-directory content.
    /// `bin/` is intentionally NOT in the list — `bin/machine/claude-install`
    /// is git-tracked, which keeps `bin/` alive without a placeholder.
    static func ensureTrackedPlaceholderDirectories() throws {
        let fm = FileManager.default
        let placeholders: [(directory: String, content: String)] = [
            (confDir, "Directory that holds mpd root CA + service cert material (and WireGuard config on mpd-desktop)\n"),
        ]

        for placeholder in placeholders {
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: placeholder.directory, isDirectory: &isDirectory)

            if !exists {
                try fm.createDirectory(atPath: placeholder.directory, withIntermediateDirectories: true)
            } else if !isDirectory.boolValue {
                throw RuntimeError("Path exists but is not a directory: \(placeholder.directory)")
            }

            let gitkeep = "\(placeholder.directory)/.gitkeep"
            var keepIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: gitkeep, isDirectory: &keepIsDirectory) {
                if keepIsDirectory.boolValue {
                    throw RuntimeError("Path exists but is not a file: \(gitkeep)")
                }
                continue
            }

            guard fm.createFile(atPath: gitkeep, contents: placeholder.content.data(using: .utf8)) else {
                throw RuntimeError("Failed to create placeholder file: \(gitkeep)")
            }
        }
    }

    static var expectedExecutablePath: String {
        return "\(mpdDir)/bin/mpd"
    }

    static var pathExportHint: String {
        return "export PATH=\"$HOME/Developer/mpd/bin:$PATH\""
    }
}
