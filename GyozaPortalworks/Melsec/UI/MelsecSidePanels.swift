import SwiftUI

/// The Navigation window: the project tree.
struct MelsecNavigationView: View {
    let workspace: MelsecWorkspace
    @State private var selection: String?

    var body: some View {
        let nodes = MelsecNavigationNode.tree(for: workspace.project, unconverted: workspace.unconvertedPrograms)
        List(selection: $selection) {
            OutlineGroup(nodes, children: \.children) { node in
                MelsecNavigationRow(workspace: workspace, node: node)
                    .tag(node.id)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 20)
    }
}

private struct MelsecNavigationRow: View {
    let workspace: MelsecWorkspace
    let node: MelsecNavigationNode

    var body: some View {
        Label(node.title, systemImage: node.systemImage)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let tab = node.tab { workspace.open(tab) }
            }
            .contextMenu {
                Button("Add New Data…") { workspace.sheet = .addProgram }
                Button("Open") { if let tab = node.tab { workspace.open(tab) } }
                    .disabled(node.tab == nil)
                Divider()
                Button("Rename…") {
                    if let id = node.programID { workspace.sheet = .rename(programID: id) }
                }
                .disabled(!isProgramBlock)
                Button("Delete") {
                    if let id = node.programID, let problem = workspace.deleteProgram(id) {
                        workspace.alert = MelsecAlert(title: "Delete", message: problem)
                    }
                }
                .disabled(!isProgramBlock)
                Divider()
                Button("Properties…") {
                    if let id = node.programID { workspace.sheet = .programProperties(programID: id) }
                }
                .disabled(node.programID == nil)
            }
            .help(help)
    }

    private var isProgramBlock: Bool {
        node.id.hasPrefix("block:")
    }

    private var color: Color {
        switch node.state {
        case .normal: return .primary
        case .unconverted: return .red
        case .unused: return Color(red: 0.35, green: 0.65, blue: 0.95)
        }
    }

    private var help: String {
        switch node.state {
        case .normal: return node.tab == nil ? node.title : "Double-click to open \(node.title)"
        case .unconverted: return "\(node.title) has unconverted changes: Convert (F4)."
        case .unused: return "\(node.title) is not used by this simulator."
        }
    }
}

/// The Element Selection window: instructions by category, searchable.
struct MelsecElementSelectionView: View {
    let workspace: MelsecWorkspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            TextField("Search", text: $workspace.paletteSearch)
                .textFieldStyle(.roundedBorder)
                .padding(6)
            List(selection: $workspace.paletteSelection) {
                OutlineGroup(MelsecPaletteNode.tree(search: workspace.paletteSearch), children: \.children) { node in
                    MelsecPaletteRow(workspace: workspace, node: node)
                        .tag(node.id)
                }
            }
            .listStyle(.sidebar)
            helpFooter
        }
    }

    @ViewBuilder
    private var helpFooter: some View {
        if let help = selectedHelp {
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(workspace.theme.paneBackground)
        }
    }

    private var selectedHelp: String? {
        guard let id = workspace.paletteSelection, id.hasPrefix("item:") else { return nil }
        let mnemonic = String(id.dropFirst(5))
        guard let definition = MelsecInstructionSet.definition(mnemonic) else { return nil }
        return "\(definition.mnemonic): \(definition.help)"
    }
}

private struct MelsecPaletteRow: View {
    let workspace: MelsecWorkspace
    let node: MelsecPaletteNode

    var body: some View {
        HStack(spacing: 6) {
            if node.mnemonic != nil {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(node.title)
                .font(.system(size: 12, design: node.mnemonic == nil ? .default : .monospaced))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let mnemonic = node.mnemonic { workspace.insertFromPalette(mnemonic) }
        }
        .help(node.help.isEmpty ? node.title : node.help)
    }
}
