// mpd — handleStop() command entry
// Delegates to environment-specific stop action.

import Foundation

extension GlobalCommand {
    func handleStop() throws {
        try Mpd.Environment.Action.Stop.execute()
    }
}
