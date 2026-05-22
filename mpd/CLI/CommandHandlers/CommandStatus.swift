// mpd — handleStatus() command entry
// Delegates status rendering to environment-specific implementation.

import Foundation

extension GlobalCommand {
    func handleStatus() throws {
        Mpd.Runtime.State.refreshCurrentStateCache()
        try Mpd.Action.Status.execute()
    }
}
