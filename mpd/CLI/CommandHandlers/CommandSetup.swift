// mpd — handleSetup() command entry
// Delegates to Mpd.Action.Setup.execute().

import Foundation

extension GlobalCommand {
    func handleSetup() throws {
        print("\n\u{001B}[1mmpd --setup\u{001B}[0m\n")
        try Mpd.Action.Setup.execute()
    }
}
