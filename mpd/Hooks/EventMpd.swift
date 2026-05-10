// mpd — mpd-level hook events
//
// Events fired around the mpd environment as a whole — `mpd --start` /
// `mpd --stop`. One fire per invocation, audience drawn from "all
// running containers of the audience kind" (see
// `Mpd.Hooks.runningContainers`).
//
// See docs/HOOKS.md for the v1 catalogue and design.

import Foundation

/// Fires once during `mpd --stop`, before any container teardown begins.
/// DB containers do graceful shutdown so the next `mpd --start` does
/// not trigger crash recovery (see docs/HOOKS.md §"Why this exists").
///
/// Audience: every running DB container.
/// Failure: `.continue` — a stop must always complete.
/// Timeout: 120 s — DB shutdown can take time when there's pending IO.
struct EventMpdPreStop: Mpd.Hooks.Event {
    static let audiences: [Mpd.Hooks.Audience] = [.database]
    static let onFailure: Mpd.Hooks.FailureMode = .continue
    static let timeout: TimeInterval = 120

    var env: [String: String] { [:] }
}
