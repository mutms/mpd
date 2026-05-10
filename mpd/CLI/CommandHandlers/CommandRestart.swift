// mpd — handleRestart() command entry
// Delegates to environment-specific restart action.

import Foundation

extension GlobalCommand {
    func handleRestart() throws {
        print("\n\u{001B}[1mmpd --restart\u{001B}[0m\n")
        try Mpd.Environment.Action.Restart.execute()
    }
}
