// mpd — handleRestart() command entry
// Delegates to Mpd.Action.Restart.execute().

import Foundation

extension GlobalCommand {
    func handleRestart() throws {
        // No banner: --start and --stop print none, and the action itself
        // already announces "Rebooting VM". A header on one of three
        // sibling commands is just noise.
        try Mpd.Action.Restart.execute()
    }
}
