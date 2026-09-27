import SwiftUI

/// Where the vendor workspaces plug into the app shell.
enum WorkspaceRegistry {
    static func makeWorkspace(for environment: PracticeEnvironment) -> (any PracticeWorkspace)? {
        switch environment {
        case .tiaPortal: return SiemensWorkspace()
        case .gxWorks3: return MelsecWorkspace()
        }
    }

    @ViewBuilder
    static func view(for environment: PracticeEnvironment, workspace: (any PracticeWorkspace)?) -> some View {
        if let workspace = workspace as? SiemensWorkspace {
            SiemensWorkspaceView(workspace: workspace)
        } else if let workspace = workspace as? MelsecWorkspace {
            MelsecWorkspaceView(workspace: workspace)
        } else {
            ContentUnavailableView(
                "\(environment.title) couldn't start",
                systemImage: "exclamationmark.triangle",
                description: Text("The \(environment.vendor) workspace isn't available.")
            )
        }
    }
}
