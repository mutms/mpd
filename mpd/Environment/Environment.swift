// mpd — compile-time environment context helpers
// Single source for path conventions used by the in-VM `mpd` binary.

import Foundation

extension Mpd {
    /// User's home directory
    static var homeDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Mpd source code directory (the in-VM checkout)
    static var mpdDir: String {
        "\(homeDir)/Developer/mpd"
    }

    /// Assets directory
    static var assetsDir: String {
        "\(mpdDir)/assets"
    }

    /// User's .mpd directory: ~/.mpd/ — runtime state + persistent identity.
    static var dotMpdDir: String {
        "\(homeDir)/.mpd"
    }

    /// Persistent local trust material: ~/.mpd/conf/
    /// Holds the CA + service cert + platform.env.
    static var confDir: String {
        "\(dotMpdDir)/conf"
    }

    /// Root CA directory
    static var confCARootDir: String {
        "\(confDir)/caroot"
    }

    /// Service TLS certificate directory
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

    /// Ensure the persistent identity directory `~/.mpd/conf/` exists.
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

    static var expectedExecutablePath: String {
        return "\(mpdDir)/bin/mpd"
    }

    static var pathExportHint: String {
        return "export PATH=\"$HOME/Developer/mpd/bin:$PATH\""
    }
}
