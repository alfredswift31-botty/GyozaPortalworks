import AppKit
import SwiftUI

/// The LAD/FBD program editor: toolbar, block interface, Favorites and networks.
struct SiemensLadderEditorView: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SiemensBlockToolbar(workspace: workspace, block: block)
            SiemensInterfacePane(workspace: workspace, block: block)
            SiemensFavoritesBar(workspace: workspace)
            SiemensMonitoringHint(workspace: workspace, block: block)
            ScrollView([.vertical, .horizontal]) {
                SiemensNetworkList(workspace: workspace, block: block)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(SiemensColors.theme.editorBackground)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handle(press) }
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let entry = S7InstructionCatalog.entry(id: id) else { return false }
                workspace.insert(entry)
                return true
            }
        }
        .onAppear { focused = true }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard workspace.editingOperand == nil else { return .ignored }
        guard let command = S7LadderEditing.command(for: press.key, modifiers: press.modifiers) else { return .ignored }
        // Shift+F-keys and Ctrl+R also come through the shortcut layer; handle only the editor's own keys here.
        switch command {
        case .moveLeft, .moveRight, .moveUp, .moveDown, .editOperand, .delete:
            workspace.perform(command, inBlock: block.id)
            return .handled
        default:
            return .ignored
        }
    }
}

/// The editor's toolbar above the interface.
struct SiemensBlockToolbar: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        HStack(spacing: 2) {
            toolButton("rectangle.stack.badge.plus", "Insert network (Ctrl+R)") { workspace.perform(.insertNetwork, inBlock: block.id) }
            toolButton("rectangle.stack.badge.minus", "Delete network") { deleteNetwork() }
            Divider().frame(height: 16).padding(.horizontal, 3)
            toolButton("chevron.down.2", "Open all networks") { openAll() }
            toolButton("chevron.up.2", "Close all networks") { closeAll() }
            toolButton(workspace.isInterfaceCollapsed(block) ? "tablecells.badge.ellipsis" : "tablecells",
                       workspace.isInterfaceCollapsed(block) ? "Show block interface" : "Hide block interface") {
                workspace.toggleInterface(block)
            }
            Divider().frame(height: 16).padding(.horizontal, 3)
            toolButton("eyeglasses", "Monitoring on/off (Ctrl+T)", active: workspace.isMonitoring(block.id)) {
                workspace.toggleMonitoring(block: block.id)
            }
            Spacer()
            Text(block.language.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(SiemensColors.theme.paneBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toolButton(_ image: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .foregroundStyle(active ? SiemensColors.online : Color.primary)
                .background(active ? SiemensColors.online.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func deleteNetwork() {
        guard let selection = workspace.selections[block.id] else { return }
        workspace.select(.network(selection.networkID), inBlock: block.id)
        workspace.perform(.delete, inBlock: block.id)
    }

    private func openAll() {
        for network in block.networks { workspace.collapsedNetworks.remove(network.id) }
    }

    private func closeAll() {
        for network in block.networks { workspace.collapsedNetworks.insert(network.id) }
    }
}

/// The Favorites bar: -| |-, -|/|-, -( ), ??, open and close branch.
struct SiemensFavoritesBar: View {
    let workspace: SiemensWorkspace

    var body: some View {
        HStack(spacing: 4) {
            Text("Favorites")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            favorite("-| |-", "Normally open contact (Shift+F2)", .insertContact(.normallyOpen))
            favorite("-|/|-", "Normally closed contact (Shift+F3)", .insertContact(.normallyClosed))
            favorite("-( )-", "Assignment (Shift+F7)", .insertCoil(.assign))
            favorite("??", "Empty box (Shift+F5)", .insertEmptyBox)
            favorite("↳", "Open branch (Shift+F8)", .openBranch)
            favorite("↲", "Close branch (Shift+F9)", .closeBranch)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(SiemensColors.theme.paneBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func favorite(_ title: String, _ help: String, _ command: S7EditorCommand) -> some View {
        Button(title) { workspace.perform(command) }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.system(size: 10, design: .monospaced))
            .help(help)
            .accessibilityLabel(help)
    }
}

/// TIA's hint when the block can't be monitored.
struct SiemensMonitoringHint: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        if workspace.isOnline, workspace.onlineStatus(ofBlock: block.id) != .identical {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("The online and offline versions of the block are different.")
                    .font(.system(size: 11))
                Spacer()
                Button("Download to device") { workspace.downloadToDevice() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.orange.opacity(0.15))
        }
    }
}

/// Block title and comment, then the networks.
struct SiemensNetworkList: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        let _ = workspace.session?.frame
        let monitor = workspace.monitor(ofBlock: block.id)
        VStack(alignment: .leading, spacing: 14) {
            SiemensBlockTitle(workspace: workspace, block: block)
            ForEach(Array(block.networks.enumerated()), id: \.element.id) { index, network in
                SiemensNetworkView(workspace: workspace, block: block, network: network, number: index + 1,
                                   context: S7LadderContext(workspace: workspace, blockID: block.id, networkID: network.id, monitor: monitor))
            }
        }
    }
}

private struct SiemensBlockTitle: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Block title:")
                    .font(.system(size: 11, weight: .semibold))
                SiemensCellField(text: block.title, placeholder: "Block title") { text in
                    workspace.editBlock(block.id) { $0.title = text }
                }
                .frame(maxWidth: 420)
            }
            SiemensCellField(text: block.comment, placeholder: "Comment") { text in
                workspace.editBlock(block.id) { $0.comment = text }
            }
            .frame(maxWidth: 520)
        }
    }
}

/// "Network n:" with title, comment and the rungs.
struct SiemensNetworkView: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock
    let network: S7Network
    let number: Int
    let context: S7LadderContext

    var body: some View {
        let collapsed = workspace.collapsedNetworks.contains(network.id)
        VStack(alignment: .leading, spacing: 4) {
            SiemensNetworkHeader(workspace: workspace, block: block, network: network, number: number, collapsed: collapsed)
            if !collapsed {
                SiemensCellField(text: network.comment, placeholder: "Comment") { text in
                    workspace.editNetwork(network.id, inBlock: block.id) { $0.comment = text }
                }
                .frame(maxWidth: 520)
                SiemensRungs(network: network, isFBD: block.language == .fbd, context: context)
            }
        }
        .padding(6)
        .background(workspace.selections[block.id] == .network(network.id) ? SiemensColors.theme.selection : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.25)))
    }
}

private struct SiemensNetworkHeader: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock
    let network: S7Network
    let number: Int
    let collapsed: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if collapsed { workspace.collapsedNetworks.remove(network.id) } else { workspace.collapsedNetworks.insert(network.id) }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Open network" : "Close network")
            .accessibilityLabel(collapsed ? "Open network" : "Close network")
            Text("Network \(number):")
                .font(.system(size: 11, weight: .bold))
                .onTapGesture { workspace.select(.network(network.id), inBlock: block.id) }
            SiemensCellField(text: network.title, placeholder: "Network title") { text in
                workspace.editNetwork(network.id, inBlock: block.id) { $0.title = text }
            }
            .frame(maxWidth: 360)
            Spacer()
        }
        .contextMenu {
            Button("Insert network    Ctrl+R") {
                workspace.select(.network(network.id), inBlock: block.id)
                workspace.perform(.insertNetwork, inBlock: block.id)
            }
            Button("Delete network") {
                workspace.select(.network(network.id), inBlock: block.id)
                workspace.perform(.delete, inBlock: block.id)
            }
        }
    }
}

/// The rungs of a network: LAD from the left power rail, or FBD.
private struct SiemensRungs: View {
    let network: S7Network
    let isFBD: Bool
    let context: S7LadderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(network.rungs) { rung in
                if isFBD {
                    S7FBDPathView(path: rung, context: context)
                } else {
                    S7PathView(path: rung, context: context, incoming: context.monitor == nil ? nil : .satisfied)
                }
            }
        }
        .padding(.leading, isFBD ? 0 : 4)
        .overlay(alignment: .leading) {
            if !isFBD {
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 3)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The SCL editor: interface on top, source below with TIA-style monitoring.
struct SiemensSCLEditorView: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock
    @State private var controller = CodeEditorController()

    var body: some View {
        let _ = workspace.session?.frame
        VStack(spacing: 0) {
            SiemensBlockToolbar(workspace: workspace, block: block)
            SiemensInterfacePane(workspace: workspace, block: block)
            SiemensMonitoringHint(workspace: workspace, block: block)
            CodeEditor(text: source, highlight: SiemensSCLStyle.highlight, diagnostics: diagnostics,
                       monitor: monitorEntries, executedLines: workspace.trace(ofBlock: block.id)?.executedLines,
                       controller: controller)
        }
        .onAppear { jumpIfNeeded() }
        .onChange(of: workspace.pendingGoTo?.line) { _, _ in jumpIfNeeded() }
    }

    private var source: Binding<String> {
        Binding(get: { block.source }, set: { newValue in
            workspace.editBlock(block.id) { $0.source = newValue }
        })
    }

    private var diagnostics: [EditorDiagnostic] {
        workspace.diagnostics(ofBlock: block.name).compactMap { diagnostic in
            guard let line = diagnostic.line else { return nil }
            return EditorDiagnostic(line: line, column: diagnostic.column ?? 1, length: 0, message: diagnostic.message,
                                    isError: diagnostic.severity == .error)
        }
    }

    private var monitorEntries: [Int: [MonitorEntry]]? {
        guard let trace = workspace.trace(ofBlock: block.id) else { return nil }
        var entries: [Int: [MonitorEntry]] = [:]
        for entry in trace.allEntries {
            let flag: Bool?
            if case let .bool(value) = entry.value { flag = value } else { flag = nil }
            entries[entry.line, default: []].append(MonitorEntry(operand: entry.text, value: entry.display, boolValue: flag, style: .siemens))
        }
        return entries
    }

    private func jumpIfNeeded() {
        guard let target = workspace.pendingGoTo, target.block == block.id else { return }
        workspace.pendingGoTo = nil
        DispatchQueue.main.async { controller.goTo(line: target.line, column: target.column) }
    }
}

/// SCL colours for the code editor.
nonisolated enum SiemensSCLStyle {
    static func highlight(_ source: String) -> [HighlightSpan] {
        STSyntax.highlight(source, dialect: .siemens).map { item in
            HighlightSpan(range: item.range, color: color(item.kind), isBold: item.kind == .keyword)
        }
    }

    static func color(_ kind: STHighlight.Kind) -> NSColor {
        switch kind {
        case .keyword: return .systemBlue
        case .comment: return .systemGreen
        case .number, .timeLiteral: return .systemTeal
        case .string: return .systemBrown
        case .localName: return .labelColor
        case .globalName: return .systemPurple
        case .absoluteAddress: return .systemOrange
        case .identifier: return .labelColor
        case .operator: return .secondaryLabelColor
        case .invalid: return .systemRed
        }
    }
}

/// The collapsible block interface pane: a one-line bar when collapsed,
/// otherwise the interface table with a draggable splitter below it.
struct SiemensInterfacePane: View {
    @Bindable var workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        if workspace.isInterfaceCollapsed(block) {
            Button {
                workspace.toggleInterface(block)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Block interface")
                        .font(.system(size: 11))
                    Text("(\(SiemensWorkspace.declaredRowCount(block)) declarations)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(SiemensColors.theme.paneBackground)
            .overlay(alignment: .bottom) { Divider() }
            .help("Show block interface")
            .accessibilityLabel("Show block interface")
        } else {
            SiemensInterfaceEditor(workspace: workspace, block: block)
                .frame(height: workspace.interfaceHeight)
            SiemensSplitter(height: $workspace.interfaceHeight, range: 70...520, growsUpward: false)
        }
    }
}

/// A horizontal splitter bar: drag it to resize the pane above (or below).
struct SiemensSplitter: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>
    /// True when the resized pane is below the bar (dragging up makes it taller).
    let growsUpward: Bool
    @State private var startHeight: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(height: 5)
            .overlay(Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 30, height: 2))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = startHeight ?? height
                    if startHeight == nil { startHeight = height }
                    let delta = growsUpward ? -value.translation.height : value.translation.height
                    height = min(max(start + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startHeight = nil })
            .help("Drag to resize")
            .accessibilityLabel("Resize")
    }
}
