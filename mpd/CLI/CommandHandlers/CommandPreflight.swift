// mpd — command-owned binary preflight helper.
// Ensures required pinned binaries are present/executable before operational commands run.

import Foundation

enum CommandPreflight {
    static func check(commandName: String, requiredNames: [String]) throws {
        var missing: [(name: String, path: String?)] = []

        for name in requiredNames {
            if !Mpd.Environment.HostExec.isExecutable(name) {
                missing.append((name, Mpd.Environment.HostExec.binaryPath(for: name)))
            }
        }

        guard missing.isEmpty else {
            let expected = missing.map { "  - \($0.name): \($0.path ?? "path not known")" }.joined(separator: "\n")
            throw RuntimeError("""
            Binary preflight failed for \(commandName).
            Missing or non-executable pinned binaries:
            \(expected)
            """)
        }
    }
}
