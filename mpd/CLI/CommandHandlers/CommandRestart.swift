// mpd — handleRestart() command entry
// Delegates to Mpd.Action.Restart.execute().

import Foundation

extension GlobalCommand {
    func handleRestart() throws {
        print("\n\u{001B}[1mmpd --restart\u{001B}[0m\n")
        try Mpd.Action.Restart.execute()
    }
}
