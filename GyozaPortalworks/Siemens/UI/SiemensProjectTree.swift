import AppKit
import SwiftUI

/// A "+ Add new…" entry of the project tree.
nonisolated enum SiemensTreeAction: Hashable, Sendable {
    case addNewBlock
    case addTagTable
    case addDataType
    case addWatchTable
}

nonisolated enum SiemensTreeTarget: Hashable, Sendable {
    case folder(String)
    case tab(SiemensEditorTab)
    case action(SiemensTreeAction)
}

/// One visible row of the project tree.
nonisolated struct SiemensTreeRow: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var systemImage: String
    var depth: Int
    var target: SiemensTreeTarget
    var isExpanded = true
    /// The comparison icon while online.
    var online: SiemensOnlineStatus?
}

extension SiemensWorkspace {
    /// The project tree as TIA shows it, folders expanded or collapsed.
    func treeRows() -> [SiemensTreeRow] {
        var rows: [SiemensTreeRow] = []
        func folder(_ title: String, _ image: String, depth: Int, key: String? = nil) -> Bool {
            let id = key ?? title
            let expanded = !collapsedFolders.contains(id)
            rows.append(SiemensTreeRow(id: "folder-" + id, title: title, systemImage: image, depth: depth, target: .folder(id), isExpanded: expanded))
            return expanded
        }
        func item(_ title: String, _ image: String, depth: Int, tab: SiemensEditorTab, online: SiemensOnlineStatus? = nil) {
            rows.append(SiemensTreeRow(id: tab.id, title: title, systemImage: image, depth: depth, target: .tab(tab), online: online))
        }
        func action(_ title: String, _ action: SiemensTreeAction, depth: Int) {
            rows.append(SiemensTreeRow(id: "action-\(action)", title: title, systemImage: "plus.square", depth: depth, target: .action(action)))
        }
        guard folder(project.name, "folder", depth: 0, key: "project") else { return rows }
        guard folder("\(project.device.name) [\(project.device.cpuType)]", "cpu", depth: 1, key: "plc") else { return rows }
        item("Device configuration", "rectangle.connected.to.line.below", depth: 2, tab: .deviceConfiguration)
        item("Online & diagnostics", "stethoscope", depth: 2, tab: .onlineDiagnostics)
        if folder("Program blocks", "folder", depth: 2) {
            action("Add new block", .addNewBlock, depth: 3)
            for block in sortedBlocks {
                item(block.displayName, Self.icon(for: block), depth: 3, tab: .block(block.id),
                     online: isOnline ? onlineStatus(ofBlock: block.id) : nil)
            }
            for dataBlock in project.dataBlocks.filter({ !$0.isProgramResource }).sorted(by: { $0.number < $1.number }) {
                item(dataBlock.displayName, "cylinder", depth: 3, tab: .dataBlock(dataBlock.id),
                     online: isOnline ? onlineStatus(ofDataBlock: dataBlock.id) : nil)
            }
            let resources = project.dataBlocks.filter(\.isProgramResource).sorted { $0.number < $1.number }
            if !resources.isEmpty, folder("System blocks", "folder", depth: 3), folder("Program resources", "folder", depth: 4) {
                for dataBlock in resources {
                    item(dataBlock.displayName, "cylinder", depth: 5, tab: .dataBlock(dataBlock.id),
                         online: isOnline ? onlineStatus(ofDataBlock: dataBlock.id) : nil)
                }
            }
        }
        if folder("PLC tags", "folder", depth: 2) {
            item("Show all tags", "list.bullet.rectangle", depth: 3, tab: .allTags)
            action("Add new tag table", .addTagTable, depth: 3)
            for table in project.tagTables {
                item("\(table.name) [\(table.tags.count)]", "tablecells", depth: 3, tab: .tagTable(table.id))
            }
        }
        if folder("PLC data types", "folder", depth: 2) {
            action("Add new data type", .addDataType, depth: 3)
            for type in project.dataTypes {
                item(type.name, "square.stack.3d.up", depth: 3, tab: .dataType(type.id))
            }
        }
        if folder("Watch and force tables", "folder", depth: 2) {
            action("Add new watch table", .addWatchTable, depth: 3)
            item("Force table", "exclamationmark.triangle", depth: 3, tab: .forceTable)
            for table in project.watchTables {
                item(table.name, "eyeglasses", depth: 3, tab: .watchTable(table.id))
            }
        }
        return rows
    }

    /// OBs, then FBs, then FCs, each by number.
    var sortedBlocks: [SiemensBlock] {
        let order: [SiemensBlockKind] = [.organizationBlock, .functionBlock, .function]
        return project.blocks.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.kind) ?? 0
            let right = order.firstIndex(of: rhs.kind) ?? 0
            return left != right ? left < right : lhs.number < rhs.number
        }
    }

    static func icon(for block: SiemensBlock) -> String {
        switch block.kind {
        case .organizationBlock: return "square.grid.2x2"
        case .functionBlock: return "square.on.square"
        case .function: return "function"
        }
    }

    /// Double-click / Return on a tree row.
    func activate(_ row: SiemensTreeRow) {
        switch row.target {
        case let .folder(id):
            if collapsedFolders.contains(id) { collapsedFolders.remove(id) } else { collapsedFolders.insert(id) }
        case let .tab(tab):
            open(tab)
        case let .action(action):
            switch action {
            case .addNewBlock: beginAddNewBlock()
            case .addTagTable: addTagTable()
            case .addDataType: addDataType()
            case .addWatchTable: addWatchTable()
            }
        }
    }
}

/// The "Project tree" pane.
struct SiemensProjectTreeView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        DockPanel(title: "Project tree", theme: SiemensColors.theme) {
            VStack(spacing: 0) {
                HStack {
                    Text("Devices")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 6)
                .frame(height: 20)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(workspace.treeRows()) { row in
                            SiemensTreeRowView(workspace: workspace, row: row)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct SiemensTreeRowView: View {
    let workspace: SiemensWorkspace
    let row: SiemensTreeRow

    var body: some View {
        HStack(spacing: 4) {
            if case .folder = row.target {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
            } else {
                Color.clear.frame(width: 10)
            }
            Image(systemName: row.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 16)
            if let online = row.online {
                SiemensComparisonIcon(status: online)
            }
            if case let .tab(tab) = row.target, workspace.renamingTab == tab {
                SiemensRenameField(initial: row.title.components(separatedBy: " [").first ?? row.title) { name in
                    workspace.renamingTab = nil
                    workspace.rename(tab, to: name)
                }
            } else {
                Text(row.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 12 + 4)
        .frame(height: 20)
        .background(isSelected ? SiemensColors.theme.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.activate(row) }
        .onTapGesture { select() }
        .contextMenu { SiemensTreeMenu(workspace: workspace, row: row) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var isSelected: Bool {
        if case let .tab(tab) = row.target { return workspace.treeSelection == tab }
        return false
    }

    private var iconColor: Color {
        if case .action = row.target { return SiemensColors.theme.accent }
        return .secondary
    }

    private func select() {
        switch row.target {
        case let .tab(tab): workspace.treeSelection = tab
        case .folder: workspace.activate(row)
        case .action: workspace.activate(row)
        }
    }
}

/// Green (identical) or orange (different) comparison dot.
struct SiemensComparisonIcon: View {
    let status: SiemensOnlineStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .help(help)
            .accessibilityLabel(help)
    }

    private var symbol: String {
        switch status {
        case .identical: return "circle.fill"
        case .different: return "circle.lefthalf.filled"
        case .offlineOnly: return "circle"
        }
    }

    private var color: Color {
        switch status {
        case .identical: return .green
        case .different: return .orange
        case .offlineOnly: return .orange
        }
    }

    private var help: String {
        switch status {
        case .identical: return "Online and offline are identical"
        case .different: return "Online and offline are different"
        case .offlineOnly: return "Exists only offline"
        }
    }
}

private struct SiemensRenameField: View {
    let initial: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .focused($focused)
            .onAppear {
                draft = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { commit(draft) }
            .onExitCommand { commit(initial) }
    }
}

private struct SiemensTreeMenu: View {
    let workspace: SiemensWorkspace
    let row: SiemensTreeRow

    var body: some View {
        if case let .tab(tab) = row.target {
            Button("Open") { workspace.open(tab) }
            if isRenamable(tab) {
                Button("Rename    F2") { workspace.renamingTab = tab }
                Button("Delete    Del") { workspace.delete(tab) }
            }
            Divider()
            Menu("Compile") {
                Button("Software (only changes)    Ctrl+B") { workspace.compile() }
            }
            Button("Properties") {
                workspace.open(tab)
                workspace.inspectorTab = .properties
            }
        } else if case .folder("Program blocks") = row.target {
            Button("Add new block") { workspace.beginAddNewBlock() }
            Menu("Compile") {
                Button("Software (only changes)    Ctrl+B") { workspace.compile() }
            }
        } else {
            Button("Open") { workspace.activate(row) }
        }
    }

    private func isRenamable(_ tab: SiemensEditorTab) -> Bool {
        switch tab {
        case .block, .dataBlock, .dataType, .tagTable, .watchTable: return true
        default: return false
        }
    }
}

// MARK: - Task cards

/// The task cards on the right: Instructions, Testing, Libraries.
struct SiemensTaskCardsView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        HStack(spacing: 0) {
            DockPanel(title: workspace.taskCard.rawValue, theme: SiemensColors.theme) {
                switch workspace.taskCard {
                case .instructions: SiemensInstructionsCard(workspace: workspace)
                case .testing:
                    ScrollView { SiemensOperatorPanel(workspace: workspace) }
                case .libraries:
                    Text("Libraries aren't available in this simulator.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            VStack(spacing: 2) {
                ForEach(SiemensWorkspace.TaskCard.allCases, id: \.self) { card in
                    SiemensVerticalTab(title: card.rawValue, isSelected: workspace.taskCard == card) {
                        workspace.taskCard = card
                    }
                }
                Spacer()
            }
            .frame(width: 22)
            .background(SiemensColors.theme.chrome)
        }
    }
}

private struct SiemensVerticalTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: 20, height: CGFloat(title.count) * 6 + 16)
                .background(isSelected ? SiemensColors.theme.selection : Color.clear)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Instructions: search, Favorites, Basic instructions.
private struct SiemensInstructionsCard: View {
    let workspace: SiemensWorkspace
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(6)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if search.isEmpty {
                        SiemensCatalogSection(title: "Favorites", entries: S7InstructionCatalog.favorites, workspace: workspace, expanded: true)
                        Text("Basic instructions")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.top, 6)
                        ForEach(S7InstructionCatalog.basicInstructions) { folder in
                            SiemensCatalogSection(title: folder.title, entries: folder.entries, workspace: workspace, expanded: false)
                        }
                        Text("Extended instructions")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.top, 6)
                        Text("Not available in this simulator.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(S7InstructionCatalog.search(search)) { entry in
                            SiemensCatalogEntryRow(entry: entry, workspace: workspace)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

private struct SiemensCatalogSection: View {
    let title: String
    let entries: [S7CatalogEntry]
    let workspace: SiemensWorkspace
    @State var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(entries) { entry in
                SiemensCatalogEntryRow(entry: entry, workspace: workspace)
            }
        } label: {
            Text(title).font(.system(size: 11))
        }
    }
}

private struct SiemensCatalogEntryRow: View {
    let entry: S7CatalogEntry
    let workspace: SiemensWorkspace

    var body: some View {
        Text(entry.title)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { workspace.insert(entry) }
            .help("Double-click to insert at the selection")
            .draggable(entry.id)
    }
}
