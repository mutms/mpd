// mpd — handleCheckHooks() command entry
// Cross-references hook directories under assets/ against the Swift
// Event catalogue and prints warnings for orphans + revision bumps.
// Same engine that runs at the end of `mpd --setup`; this flag exposes
// it on demand.

import Foundation

extension GlobalCommand {
    func handleCheckHooks() throws {
        Mpd.Hooks.diagnose()
    }
}
