// mpd — handleSetup() command entry
// Delegates to environment-specific setup action.

import Foundation

extension GlobalCommand {
    func handleSetup() throws {
        print("\n\u{001B}[1mmpd --setup\u{001B}[0m\n")
        try Mpd.Environment.Action.Setup.execute()
    }
}
