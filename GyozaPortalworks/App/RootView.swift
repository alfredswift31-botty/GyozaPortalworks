import SwiftUI

/// The main window: the chosen tool's workspace, with the tool switcher in
/// the toolbar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        WorkspaceRegistry.view(for: model.environment, workspace: model.activeWorkspace)
            .id(model.environment)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Tool", selection: $model.environment) {
                        ForEach(PracticeEnvironment.allCases) { environment in
                            Text(environment.title).tag(environment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .help("Switch between TIA Portal and GX Works3 (⌘1 / ⌘2). Each keeps its own project.")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        openWindow(id: WindowID.exercises)
                    } label: {
                        Label("Exercises", systemImage: "graduationcap")
                    }
                    .help("Practice tasks with automatic checking (⇧⌘E)")
                    Button {
                        openWindow(id: WindowID.trainer)
                    } label: {
                        Label("I/O Trainer", systemImage: "switch.2")
                    }
                    .help("Switches, push buttons and lamps wired to the simulated CPU (⇧⌘T)")
                }
            }
            .navigationTitle("GyozaPortalworks")
            .navigationSubtitle("\(model.environment.title) · \(model.environment.controller)")
            .onChange(of: sessionIdentity) {
                model.applyRestInputs()
            }
    }

    private var sessionIdentity: ObjectIdentifier? {
        model.activeSession.map(ObjectIdentifier.init)
    }
}
