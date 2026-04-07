import Foundation

// Global control-plane status shared by all commands.
// Keeps only top-level selection such as active machine.

// MARK: - Core status (global)

struct CoreStatus: Codable {
    var activeMachine: String

    init() {
        activeMachine = ""
    }
}
