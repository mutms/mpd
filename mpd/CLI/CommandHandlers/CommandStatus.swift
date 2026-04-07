// mpd — handleStatus() command entry
// Delegates status rendering to environment-specific implementation.

import Foundation

extension GlobalCommand {
    func handleStatus() throws {
        try Mpd.Environment.Action.Status.execute()
    }
}
