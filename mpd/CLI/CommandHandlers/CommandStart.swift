// mpd — handleStart() command entry
// Delegates to Mpd.Action.Start.execute().

import Foundation

extension GlobalCommand {
    func handleStart() throws {
        try Mpd.Action.Start.execute()
    }
}
