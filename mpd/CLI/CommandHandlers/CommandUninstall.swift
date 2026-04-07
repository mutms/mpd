// mpd — handleUninstall() command entry
// Delegates to environment-specific uninstall action.

import Foundation

extension GlobalCommand {
    func handleUninstall() throws {
        try Mpd.Environment.Action.Uninstall.execute(skipPrompt: yes)
    }
}
