import Foundation

// Shared lexical identifier validation.
// Enforces allowed characters/shape only, not uniqueness or reserved-word policy.

extension Mpd.Core {
    /// Strict identifier rule. Lowercase ASCII letters and digits,
    /// starting with a letter, min length 2. Used for runtime names
    /// (which appear in container/pod name patterns like
    /// `mpd-runtime-<n>-main`, where dashes would break parsing).
    static func isValidIdentifier(_ name: String) -> Bool {
        name.wholeMatch(of: #/[a-z][a-z0-9]+/#) != nil
    }

    /// Project identifier rule. Same as `isValidIdentifier` but allows
    /// internal dashes (no leading/trailing/consecutive) — needed for
    /// the `<target>-cftunnel` naming convention and any future
    /// suffix/prefix-style project type conventions. Project names
    /// don't appear in mpd-internal name parsing the way runtime
    /// names do.
    static func isValidProjectIdentifier(_ name: String) -> Bool {
        name.wholeMatch(of: #/[a-z][a-z0-9]*(-[a-z0-9]+)*/#) != nil
            && name.count >= 2
    }
}
