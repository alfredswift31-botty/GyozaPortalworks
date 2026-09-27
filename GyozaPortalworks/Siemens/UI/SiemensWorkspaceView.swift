import AppKit
import SwiftUI

/// The TIA Portal project view: menu bar, toolbar, project tree, work area
/// with the editor bar, task cards, Inspector window and status bar.
struct SiemensWorkspaceView: View {
    @Bindable var workspace: SiemensWorkspace

    var body: some View {
        VStack(spacing: 0) {
            MenuBarStrip(menus: SiemensMenus(workspace: workspace).menus, theme: SiemensColors.theme)
                .modifier(SiemensAddBlockSheet(workspace: workspace))
            SiemensToolStrip(workspace: workspace)
            SiemensMainArea(workspace: workspace)
                .modifier(SiemensCallOptionsSheet(workspace: workspace))
            SiemensEditorBar(workspace: workspace)
            SiemensStatusBar(workspace: workspace)
                .modifier(SiemensLoadSheet(workspace: workspace))
        }
        .background(SiemensColors.theme.chrome)
        .background(ShortcutLayer(shortcuts: SiemensKeyboard(workspace: workspace).shortcuts))
        .overlay(alignment: .topTrailing) {
            if workspace.isPLCSIMVisible {
                SiemensPLCSIMWindow(workspace: workspace)
                    .padding(.top, 70)
                    .padding(.trailing, 40)
            }
        }
        .modifier(SiemensAlerts(workspace: workspace))
    }
}

/// Project tree | work area over the Inspector | task cards.
private struct SiemensMainArea: View {
    let workspace: SiemensWorkspace

    var body: some View {
        HSplitView {
            if workspace.showsProjectTree {
                SiemensProjectTreeView(workspace: workspace)
                    .frame(minWidth: 180, idealWidth: 250, maxWidth: 420)
            }
            VSplitView {
                SiemensWorkArea(workspace: workspace)
                    .frame(minHeight: 200)
                if workspace.showsInspector {
                    SiemensInspectorView(workspace: workspace)
                        .frame(minHeight: 110, idealHeight: 190)
                }
            }
            .frame(minWidth: 420)
            if workspace.showsTaskCards {
                SiemensTaskCardsView(workspace: workspace)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 380)
            }
        }
    }
}

/// The editor in the selected tab, under a title bar that turns orange online.
private struct SiemensWorkArea: View {
    let workspace: SiemensWorkspace

    var body: some View {
        VStack(spacing: 0) {
            SiemensEditorTitle(workspace: workspace)
            SiemensEditorContent(workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SiemensColors.theme.editorBackground)
    }
}

private struct SiemensEditorTitle: View {
    let workspace: SiemensWorkspace

    var body: some View {
        HStack(spacing: 4) {
            Text(path)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if workspace.isOnline {
                Text("Online")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(workspace.isOnline ? Color.white : SiemensColors.theme.paneHeaderText)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(workspace.isOnline ? SiemensColors.online : SiemensColors.theme.paneHeader)
    }

    private var path: String {
        let root = "\(workspace.project.name) › \(workspace.project.device.name) [\(workspace.project.device.cpuType)]"
        guard let tab = workspace.selectedTab else { return root }
        switch tab {
        case .block, .dataBlock: return root + " › Program blocks › " + workspace.title(of: tab)
        case .tagTable, .allTags: return root + " › PLC tags › " + workspace.title(of: tab)
        case .dataType: return root + " › PLC data types › " + workspace.title(of: tab)
        case .watchTable, .forceTable: return root + " › Watch and force tables › " + workspace.title(of: tab)
        case .deviceConfiguration, .onlineDiagnostics: return root + " › " + workspace.title(of: tab)
        }
    }
}

private struct SiemensEditorContent: View {
    let workspace: SiemensWorkspace

    var body: some View {
        switch workspace.selectedTab {
        case let .block(id)?:
            if let block = workspace.block(id) {
                if block.language == .scl {
                    SiemensSCLEditorView(workspace: workspace, block: block)
                } else {
                    SiemensLadderEditorView(workspace: workspace, block: block)
                }
            }
        case let .dataBlock(id)?:
            if let dataBlock = workspace.project.dataBlocks.first(where: { $0.id == id }) {
                SiemensDataBlockEditor(workspace: workspace, dataBlock: dataBlock)
            }
        case let .dataType(id)?:
            if let dataType = workspace.project.dataTypes.first(where: { $0.id == id }) {
                SiemensDataTypeEditor(workspace: workspace, dataType: dataType)
            }
        case let .tagTable(id)?:
            SiemensTagTableView(workspace: workspace, tableID: id)
        case .allTags?:
            SiemensTagTableView(workspace: workspace, tableID: nil)
        case let .watchTable(id)?:
            if let table = workspace.project.watchTables.first(where: { $0.id == id }) {
                SiemensWatchTableView(workspace: workspace, table: table)
            }
        case .forceTable?:
            SiemensForceTableView(workspace: workspace)
        case .deviceConfiguration?:
            SiemensDeviceConfigurationView(workspace: workspace)
        case .onlineDiagnostics?:
            SiemensOnlineDiagnosticsView(workspace: workspace)
        case nil:
            ContentUnavailableView("No editor open", systemImage: "square.dashed",
                                   description: Text("Double-click an object in the project tree to open it."))
        }
    }
}

/// TIA's editor bar at the bottom of the window.
private struct SiemensEditorBar: View {
    let workspace: SiemensWorkspace

    var body: some View {
        EditorTabStrip(tabs: tabs, selection: selection, theme: SiemensColors.theme) { id in
            if let tab = workspace.openTabs.first(where: { $0.id == id }) { workspace.close(tab) }
        }
    }

    private var tabs: [EditorTab] {
        workspace.openTabs.map { tab in
            EditorTab(id: tab.id, title: workspace.title(of: tab), systemImage: icon(tab))
        }
    }

    private var selection: Binding<String?> {
        Binding(get: { workspace.selectedTab?.id }, set: { id in
            if let tab = workspace.openTabs.first(where: { $0.id == id }) { workspace.open(tab) }
        })
    }

    private func icon(_ tab: SiemensEditorTab) -> String {
        switch tab {
        case let .block(id): return workspace.block(id).map(SiemensWorkspace.icon(for:)) ?? "square"
        case .dataBlock: return "cylinder"
        case .dataType: return "square.stack.3d.up"
        case .tagTable, .allTags: return "tablecells"
        case .watchTable: return "eyeglasses"
        case .forceTable: return "exclamationmark.triangle"
        case .deviceConfiguration: return "rectangle.connected.to.line.below"
        case .onlineDiagnostics: return "stethoscope"
        }
    }
}

/// The status bar: Portal view, last message, the online bar and the F-key hint.
private struct SiemensStatusBar: View {
    let workspace: SiemensWorkspace

    var body: some View {
        StatusStrip(segments: segments, theme: SiemensColors.theme, leading: AnyView(SiemensStatusLeading(workspace: workspace)))
    }

    private var segments: [String] {
        var result = [workspace.lastMessage]
        if workspace.session != nil { result.append(workspace.isOnline ? "Online: PLC_1" : "PLCSIM running") }
        result.append("Hold fn for F-keys, or enable 'Use F1, F2, etc. keys as standard function keys'")
        return result
    }
}

private struct SiemensStatusLeading: View {
    let workspace: SiemensWorkspace
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Text("◂ Portal view")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("The Portal view isn't part of this simulator; everything happens in the project view.")
            if workspace.isOnline {
                Capsule()
                    .fill(SiemensColors.online)
                    .frame(width: 60, height: 6)
                    .opacity(pulse ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .accessibilityLabel("Online")
            }
        }
    }
}

// MARK: - Sheets and alerts

private struct SiemensAddBlockSheet: ViewModifier {
    let workspace: SiemensWorkspace

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { workspace.newBlockRequest != nil },
                                           set: { if !$0 { workspace.newBlockRequest = nil } })) {
            if let request = workspace.newBlockRequest {
                SiemensAddNewBlockDialog(workspace: workspace, request: request)
            }
        }
    }
}

private struct SiemensCallOptionsSheet: ViewModifier {
    let workspace: SiemensWorkspace

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { workspace.callOptions != nil },
                                           set: { if !$0 { workspace.callOptions = nil } })) {
            if let options = workspace.callOptions {
                SiemensCallOptionsDialog(workspace: workspace, options: options)
            }
        }
    }
}

private struct SiemensLoadSheet: ViewModifier {
    let workspace: SiemensWorkspace

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { workspace.loadStep != nil },
                                           set: { if !$0, workspace.loadStep != nil { workspace.cancelLoad() } })) {
            if let step = workspace.loadStep {
                SiemensLoadDialog(workspace: workspace, step: step)
            }
        }
    }
}

private struct SiemensAlerts: ViewModifier {
    @Bindable var workspace: SiemensWorkspace

    func body(content: Content) -> some View {
        content
            .alert(workspace.confirmation?.title ?? "", isPresented: Binding(get: { workspace.confirmation != nil },
                                                                           set: { if !$0 { workspace.confirmation = nil } }),
                   presenting: workspace.confirmation) { confirmation in
                Button(confirmation.confirmTitle, role: confirmation == .forceAll ? .destructive : nil) {
                    workspace.confirm(confirmation)
                }
                Button("Cancel", role: .cancel) { workspace.confirmation = nil }
            } message: { confirmation in
                Text(confirmation.message)
            }
            .alert("TIA Portal", isPresented: Binding(get: { workspace.alertMessage != nil },
                                                      set: { if !$0 { workspace.alertMessage = nil } })) {
                Button("OK") { workspace.alertMessage = nil }
            } message: {
                Text(workspace.alertMessage ?? "")
            }
            .alert("Project couldn't be opened", isPresented: Binding(get: { workspace.startupAlert != nil },
                                                                      set: { if !$0 { workspace.startupAlert = nil } })) {
                Button("OK") { workspace.startupAlert = nil }
            } message: {
                Text(workspace.startupAlert ?? "")
            }
    }
}
