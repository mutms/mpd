// mpd — handleSetupInfo() command entry
// Prints the full laptop-side setup recipe (plain text) for the active mode.
// Driven by ~/Developer/mpd/conf/platform.env; emits a fix-it message and
// exits non-zero when the file is missing.

import Foundation

extension GlobalCommand {
    func handleSetupInfo() throws {
        do {
            try Mpd.Environment.Integration.printSetupInfo()
        } catch {
            // Mpd.Core.Platform.load() already includes a fix-it message
            // pointing at the right bootstrap path; just reframe the lead-in.
            throw RuntimeError("Cannot print setup info — \(error.localizedDescription)")
        }
    }
}
