// mpd — handleStatus() command entry
// Delegates status rendering to Mpd.Action.Status.execute().

import Foundation

extension GlobalCommand {
    func handleStatus() throws {
        Mpd.Runtime.State.refreshCurrentStateCache()
        try Mpd.Action.Status.execute()
    }
}
