// mpd — handleStart() command entry
// Delegates to environment-specific start action.

import Foundation

extension GlobalCommand {
    func handleStart() throws {
        try Mpd.Action.Start.execute()
    }
}
