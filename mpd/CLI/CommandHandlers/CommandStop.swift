// mpd — handleStop() command entry
// Delegates to Mpd.Action.Stop.execute().

import Foundation

extension GlobalCommand {
    func handleStop() throws {
        try Mpd.Action.Stop.execute()
    }
}
