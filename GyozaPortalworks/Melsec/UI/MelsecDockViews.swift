import SwiftUI

/// The bottom docking windows as tabs: Output, Conversion Result, Watch 1–4.
struct MelsecDockArea: View {
    let workspace: MelsecWorkspace

    private var tabs: [MelsecDockTab] {
        [.output, .conversionResult] + (0..<4).map { MelsecDockTab.watch($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(workspace.theme.paneBackground)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 1) {
            ForEach(tabs, id: \.self) { tab in
                MelsecDockTabButton(title: tab.title, isSelected: workspace.bottomTab == tab, theme: workspace.theme) {
                    workspace.bottomTab = tab
                }
            }
            Spacer()
        }
        .frame(height: 22)
        .background(workspace.theme.paneHeader)
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.bottomTab {
        case .output:
            MelsecOutputView(workspace: workspace)
        case .conversionResult:
            MelsecConversionResultView(workspace: workspace)
        case let .watch(index):
            MelsecWatchView(workspace: workspace, list: index)
        }
    }
}

private struct MelsecDockTabButton: View {
    let title: String
    let isSelected: Bool
    let theme: VendorTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .foregroundStyle(isSelected ? Color.primary : theme.paneHeaderText)
                .background(isSelected ? theme.paneBackground : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: Output

struct MelsecOutputView: View {
    let workspace: MelsecWorkspace
    @State private var selection: Int?

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            table
        }
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(MelsecOutputMessage.Result.allCases, id: \.self) { result in
                Toggle(isOn: filterBinding(result)) {
                    Label("\(result.rawValue) \(workspace.outputCount(result))", systemImage: icon(result))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show or hide \(result.rawValue.lowercased()) messages")
            }
            Spacer()
            Text("Double-click a message to jump to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(4)
    }

    private var table: some View {
        Table(workspace.visibleOutput, selection: $selection) {
            TableColumn("No.") { message in Text("\(message.id)") }
                .width(40)
            TableColumn("Result") { message in
                Label(message.result.rawValue, systemImage: icon(message.result))
                    .foregroundStyle(color(message.result))
            }
            .width(100)
            TableColumn("Data Name", value: \.dataName)
                .width(110)
            TableColumn("Category", value: \.category)
                .width(160)
            TableColumn("Content", value: \.content)
            TableColumn("Error Code", value: \.errorCode)
                .width(80)
        }
        .contextMenu(forSelectionType: Int.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            guard let id = ids.first, let message = workspace.outputMessages.first(where: { $0.id == id }) else { return }
            workspace.jump(to: message)
        }
    }

    private func filterBinding(_ result: MelsecOutputMessage.Result) -> Binding<Bool> {
        Binding(get: { workspace.outputFilter.contains(result) }, set: { isOn in
            if isOn { workspace.outputFilter.insert(result) } else { workspace.outputFilter.remove(result) }
        })
    }

    private func icon(_ result: MelsecOutputMessage.Result) -> String {
        switch result {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .information: return "info.circle.fill"
        }
    }

    private func color(_ result: MelsecOutputMessage.Result) -> Color {
        switch result {
        case .error: return .red
        case .warning: return .orange
        case .information: return .secondary
        }
    }
}

// MARK: Conversion Result

/// View › Docking Window › Conversion Result: Step | Code.
struct MelsecConversionResultView: View {
    let workspace: MelsecWorkspace

    var body: some View {
        let lines = workspace.conversionListing
        if lines.isEmpty {
            Text("Convert (F4) a ladder program to see its instruction list.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(lines.enumerated().map { MelsecListingRow(id: $0.offset, line: $0.element) }) {
                TableColumn("Step") { row in Text("\(row.line.step)").font(.system(.body, design: .monospaced)) }
                    .width(60)
                TableColumn("Code") { row in Text(row.line.code).font(.system(.body, design: .monospaced)) }
            }
        }
    }
}

private struct MelsecListingRow: Identifiable {
    var id: Int
    var line: MelsecListingLine
}

// MARK: Watch

private struct MelsecWatchRow: Identifiable {
    var id: Int
    var name: String
}

/// Watch 1–4: Name | Current Value | Display Format | Data Type | Comment.
struct MelsecWatchView: View {
    let workspace: MelsecWorkspace
    let list: Int
    @State private var newName = ""
    @State private var selection: Int?

    var body: some View {
        let _ = workspace.session?.frame
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            entryField
        }
        .onChange(of: selection) {
            workspace.watchSelection[list] = selection.flatMap { index in rows.first { $0.id == index }?.name }
        }
    }

    private var rows: [MelsecWatchRow] {
        guard workspace.project.watchLists.indices.contains(list) else { return [] }
        return workspace.project.watchLists[list].entries.enumerated().map { MelsecWatchRow(id: $0.offset, name: $0.element) }
    }

    private var isWatching: Bool {
        workspace.watching.indices.contains(list) && workspace.watching[list]
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button("ON") { workspace.watchSet(list: list, bit: true) }
            Button("OFF") { workspace.watchSet(list: list, bit: false) }
            Button("Switch ON/OFF") { workspace.watchSet(list: list, bit: nil) }
            Button("Update") { workspace.session?.refresh() }
            Divider().frame(height: 16)
            Button("Start Watching") { setWatching(true) }
                .disabled(workspace.cpu == nil || isWatching)
            Button("Stop Watching") { setWatching(false) }
                .disabled(!isWatching)
            Button {
                if let selection { workspace.removeWatchEntry(at: selection, list: list) }
                selection = nil
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete the selected row")
            .accessibilityLabel("Delete watch row")
            .disabled(selection == nil)
            Spacer()
            if workspace.cpu == nil {
                Text("Start the simulation to watch values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(4)
    }

    private func setWatching(_ value: Bool) {
        guard workspace.watching.indices.contains(list) else { return }
        workspace.watching[list] = value
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Current Value") { row in
                Text(live(row).value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(live(row).value == "TRUE" ? Color.blue : Color.primary)
            }
            TableColumn("Display Format") { row in
                MelsecFormatPicker(workspace: workspace, name: row.name)
            }
            .width(120)
            TableColumn("Data Type") { row in Text(live(row).type) }
            TableColumn("Comment") { row in Text(live(row).comment).foregroundStyle(.secondary) }
        }
    }

    private func live(_ row: MelsecWatchRow) -> (value: String, type: String, comment: String) {
        workspace.watchRow(row.name, format: workspace.watchFormats[row.name] ?? .decimal, list: list)
    }

    private var entryField: some View {
        HStack {
            TextField("Enter a device or label and press Enter", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    workspace.addWatchEntry(newName, list: list)
                    newName = ""
                }
        }
        .padding(4)
    }
}

private struct MelsecFormatPicker: View {
    let workspace: MelsecWorkspace
    let name: String

    var body: some View {
        Picker("Display Format", selection: Binding(get: { workspace.watchFormats[name] ?? .decimal },
                                                    set: { workspace.watchFormats[name] = $0 })) {
            ForEach(MelsecDisplayFormat.allCases, id: \.self) { format in
                Text(format.rawValue).tag(format)
            }
        }
        .labelsHidden()
    }
}
