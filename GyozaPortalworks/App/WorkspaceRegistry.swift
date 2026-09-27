import SwiftUI

/// Where the vendor workspaces plug into the app shell.
enum WorkspaceRegistry {
    static func makeWorkspace(for environment: PracticeEnvironment) -> (any PracticeWorkspace)? {
        switch environment {
        case .gxWorks3: return MelsecWorkspace()
        case .tiaPortal: return nil
        }
    }

    @ViewBuilder
    static func view(for environment: PracticeEnvironment, workspace: (any PracticeWorkspace)?) -> some View {
        if let workspace = workspace as? MelsecWorkspace {
            MelsecWorkspaceView(workspace: workspace)
        } else {
            ContentUnavailableView(
                "\(environment.title) is on its way",
                systemImage: "hammer",
                description: Text("The \(environment.vendor) workspace isn't part of this build yet.")
            )
        }
    }
}
