import AppKit
import SwiftUI

/// The GX Works3 workspace: menu bar, toolbar, Navigation, editors,
/// Element Selection, docking windows, status bar and GX Simulator3.
struct MelsecWorkspaceView: View {
    let workspace: MelsecWorkspace

    var body: some View {
        VStack(spacing: 0) {
            MenuBarStrip(menus: MelsecCommandBars.menus(workspace), theme: workspace.theme)
            ToolStrip(items: MelsecCommandBars.toolItems(workspace), theme: workspace.theme)
            MelsecMainSplit(workspace: workspace)
            MelsecStatusBar(workspace: workspace)
        }
        .background(ShortcutLayer(shortcuts: MelsecCommandBars.shortcuts(workspace)))
        .overlay(alignment: .bottomTrailing) {
            // Over the docking windows, so the ladder's coil column stays visible.
            if workspace.isSimulatorPanelVisible, workspace.session != nil {
                MelsecSimulatorPanel(workspace: workspace)
                    .padding(.bottom, 40)
                    .padding(.trailing, 250)
            }
        }
        .sheet(item: sheetBinding) { sheet in
            MelsecSheetView(workspace: workspace, sheet: sheet)
        }
        .alert(workspace.alert?.title ?? "", isPresented: alertShown, presenting: workspace.alert) { alert in
            MelsecAlertButtons(workspace: workspace, alert: alert)
        } message: { alert in
            Text(alert.message)
        }
    }

    private var sheetBinding: Binding<MelsecSheet?> {
        Binding(get: { workspace.sheet }, set: { workspace.sheet = $0 })
    }

    private var alertShown: Binding<Bool> {
        // The buttons answer (and clear) the alert themselves, so a follow-up
        // alert they raise isn't dismissed with the first.
        Binding(get: { workspace.alert != nil }, set: { _ in })
    }
}

private struct MelsecAlertButtons: View {
    let workspace: MelsecWorkspace
    let alert: MelsecAlert

    var body: some View {
        if alert.action == .none {
            Button("OK") { workspace.answerAlert(alert, yes: false) }
        } else {
            Button("Yes") { workspace.answerAlert(alert, yes: true) }
            Button("No", role: .cancel) { workspace.answerAlert(alert, yes: false) }
        }
    }
}

/// Navigation | editors over docking windows | Element Selection.
private struct MelsecMainSplit: View {
    let workspace: MelsecWorkspace

    var body: some View {
        HSplitView {
            DockPanel(title: "Navigation", theme: workspace.theme) {
                MelsecNavigationView(workspace: workspace)
            }
            .frame(minWidth: 170, idealWidth: 230, maxWidth: 360)
            VSplitView {
                MelsecEditorArea(workspace: workspace)
                    .frame(minHeight: 200)
                MelsecDockArea(workspace: workspace)
                    .frame(minHeight: 110, idealHeight: 190)
            }
            .frame(minWidth: 420)
            DockPanel(title: "Element Selection", theme: workspace.theme) {
                MelsecElementSelectionView(workspace: workspace)
            }
            .frame(minWidth: 170, idealWidth: 220, maxWidth: 340)
        }
    }
}

/// The editor tabs and the selected editor.
private struct MelsecEditorArea: View {
    let workspace: MelsecWorkspace

    var body: some View {
        VStack(spacing: 0) {
            EditorTabStrip(tabs: tabs, selection: selection, theme: workspace.theme) { key in
                if let tab = MelsecEditorTabID(key: key) { workspace.close(tab) }
            }
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(workspace.theme.editorBackground)
        }
    }

    private var tabs: [EditorTab] {
        let unconverted = workspace.unconvertedPrograms
        return workspace.openTabs.map { tab in
            EditorTab(id: tab.key, title: workspace.title(for: tab), systemImage: icon(tab),
                      isModified: tab.programID.map { unconverted.contains($0) } ?? false)
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { workspace.selectedTab?.key }, set: { key in
            workspace.selectedTab = key.flatMap(MelsecEditorTabID.init(key:))
        })
    }

    private func icon(_ tab: MelsecEditorTabID) -> String {
        switch tab {
        case .program: return "list.bullet.indent"
        case .localLabels, .globalLabels: return "tag"
        case .deviceComments: return "text.bubble"
        case .deviceMemory: return "memorychip"
        case .cpuParameter: return "gearshape"
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch workspace.selectedTab {
        case let .program(id)?:
            if let program = workspace.program(id) {
                if program.language == .ladder {
                    MelsecLadderEditorView(workspace: workspace, programID: id)
                        .id(id)
                } else {
                    MelsecSTEditorView(workspace: workspace, programID: id)
                        .id(id)
                }
            }
        case let .localLabels(id)?:
            MelsecLabelEditorView(workspace: workspace, programID: id)
                .id(id)
        case .globalLabels?:
            MelsecLabelEditorView(workspace: workspace, programID: nil)
        case .deviceComments?:
            MelsecDeviceCommentView(workspace: workspace)
        case .deviceMemory?:
            MelsecBatchMonitorView(workspace: workspace)
        case .cpuParameter?:
            MelsecCPUParameterView(profile: workspace.project.profile)
        case nil:
            ContentUnavailableView("No editor open", systemImage: "doc.text",
                                   description: Text("Double-click a program, label or device item in the Navigation window."))
        }
    }
}

/// FX5U | Host Station | 14/70 Step | Overwrite | CAP | NUM.
private struct MelsecStatusBar: View {
    let workspace: MelsecWorkspace

    var body: some View {
        StatusStrip(segments: segments, theme: workspace.theme, leading: AnyView(leading))
    }

    private var segments: [String] {
        var result = [workspace.project.profile.series, workspace.session != nil ? "Simulation" : "Host Station"]
        if let id = workspace.selectedLadderID, let steps = workspace.stepStatus(programID: id) {
            result.append("\(steps.cursor)/\(steps.total) Step")
        }
        result.append(workspace.isInsertMode ? "Insert" : "Overwrite")
        result.append(NSEvent.modifierFlags.contains(.capsLock) ? "CAP" : "")
        result.append("NUM")
        return result.filter { !$0.isEmpty }
    }

    private var leading: some View {
        Text(workspace.statusMessage ?? "Hold fn for F-keys, or enable \"Use F1, F2, etc. keys as standard function keys\".")
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(workspace.statusMessage == nil ? Color.secondary : Color.orange)
    }
}
