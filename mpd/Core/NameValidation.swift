import Foundation

// Shared lexical identifier validation.
// Enforces allowed characters/shape only, not uniqueness or reserved-word policy.

extension Mpd.Core {
    /// Shared identifier rule for runtime/project names.
    /// Lowercase ASCII letters and digits, starting with a letter, min length 2.
    static func isValidIdentifier(_ name: String) -> Bool {
        name.wholeMatch(of: #/[a-z][a-z0-9]+/#) != nil
    }
}
