import Foundation

/// Why the exercise checker couldn't load the user's program.
nonisolated struct CheckSetupError: Error, Hashable, Sendable {
    var message: String
    var details: [String] = []
}

/// What the app shell needs from each environment's workspace. Workspaces
/// are @Observable classes, so views reading these properties update.
@MainActor protocol PracticeWorkspace: AnyObject {
    var environment: PracticeEnvironment { get }
    /// The running simulation (PLCSIM / GX Simulator3), if the user started one.
    var session: SimulationSession? { get }
    /// Compiles the current project into a fresh CPU, already in RUN, for the
    /// exercise checker. Nothing on screen changes.
    func makeCheckCPU() -> Result<any SimulatedCPU, CheckSetupError>
    /// Writes unsaved project changes to disk.
    func save()
}
