import AppKit
import SwiftUI

/// The Inspector window: Properties / Info / Diagnostics.
struct SiemensInspectorView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SiemensWorkspace.InspectorTab.allCases, id: \.self) { tab in
                    SiemensInspectorTabButton(title: tab.rawValue, isSelected: workspace.inspectorTab == tab) {
                        workspace.inspectorTab = tab
                    }
                }
                Spacer()
                if let result = workspace.compileResult {
                    Text("Errors: \(result.errorCount)  Warnings: \(result.warningCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(result.errorCount > 0 ? Color.red : Color.secondary)
                        .padding(.trailing, 8)
                }
            }
            .frame(height: 24)
            .background(SiemensColors.theme.paneHeader)
            switch workspace.inspectorTab {
            case .properties: SiemensPropertiesView(workspace: workspace)
            case .info: SiemensInfoView(workspace: workspace)
            case .diagnostics: SiemensInspectorDiagnostics(workspace: workspace)
            }
        }
        .background(SiemensColors.theme.paneBackground)
    }
}

private struct SiemensInspectorTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(isSelected ? SiemensColors.theme.paneBackground : Color.clear)
        }
        .buttonStyle(.plain)
        .foregroundStyle(SiemensColors.theme.paneHeaderText)
    }
}

// MARK: - Properties

private struct SiemensPropertiesView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let block = workspace.currentBlock {
                    SiemensBlockProperties(workspace: workspace, block: block)
                    if case let .network(id)? = workspace.selections[block.id],
                       let network = block.networks.first(where: { $0.id == id }) {
                        SiemensNetworkProperties(workspace: workspace, block: block, network: network)
                    }
                } else if case let .dataBlock(id)? = workspace.selectedTab,
                          let dataBlock = workspace.project.dataBlocks.first(where: { $0.id == id }) {
                    SiemensPropertyRow(title: "Name", value: dataBlock.name)
                    SiemensPropertyRow(title: "Number", value: "\(dataBlock.number)")
                    SiemensPropertyRow(title: "Type", value: dataBlock.kind.rawValue)
                    SiemensPropertyRow(title: "Block access", value: "Optimized")
                } else {
                    Text("Select a block to see its properties.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SiemensPropertyRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title + ":")
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
        }
        .font(.system(size: 11))
    }
}

/// General: Name, Type, Language, Number (Manual/Automatic), Title, Comment.
private struct SiemensBlockProperties: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("General").font(.system(size: 12, weight: .semibold))
            HStack {
                Text("Name:").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                SiemensCellField(text: block.name) { name in workspace.rename(.block(block.id), to: name) }
                    .frame(width: 200)
            }
            SiemensPropertyRow(title: "Type", value: block.kind.title)
            HStack {
                Text("Language:").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(get: { block.language }, set: { workspace.setLanguage($0, ofBlock: block.id) })) {
                    ForEach(SiemensLanguage.allCases, id: \.self) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .disabled(block.language == .scl)
            }
            HStack {
                Text("Number:").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                Stepper("\(block.number)", value: Binding(get: { block.number }, set: { value in
                    workspace.editBlock(block.id) { edited in
                        edited.number = max(1, value)
                        edited.isNumberAutomatic = false
                    }
                }))
                Toggle("Automatic", isOn: Binding(get: { block.isNumberAutomatic }, set: { value in
                    workspace.editBlock(block.id) { $0.isNumberAutomatic = value }
                }))
            }
            if block.kind == .organizationBlock {
                SiemensPropertyRow(title: "Event class", value: block.event.rawValue)
            }
            HStack {
                Text("Title:").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                SiemensCellField(text: block.title) { text in workspace.editBlock(block.id) { $0.title = text } }
            }
            HStack {
                Text("Comment:").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                SiemensCellField(text: block.comment) { text in workspace.editBlock(block.id) { $0.comment = text } }
            }
            SiemensPropertyRow(title: "Block access", value: "Optimized")
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }
}

private struct SiemensNetworkProperties: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock
    let network: S7Network

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network").font(.system(size: 12, weight: .semibold))
            HStack {
                Text("Title:").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                SiemensCellField(text: network.title) { text in workspace.editNetwork(network.id, inBlock: block.id) { $0.title = text } }
            }
            HStack {
                Text("Comment:").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                SiemensCellField(text: network.comment) { text in workspace.editNetwork(network.id, inBlock: block.id) { $0.comment = text } }
            }
        }
        .font(.system(size: 11))
    }
}

// MARK: - Info

private struct SiemensInfoView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SiemensWorkspace.InfoTab.allCases, id: \.self) { tab in
                    SiemensInspectorTabButton(title: tab.rawValue, isSelected: workspace.infoTab == tab) {
                        workspace.infoTab = tab
                    }
                }
                Spacer()
            }
            .frame(height: 22)
            .background(SiemensColors.theme.paneBackground)
            Divider()
            switch workspace.infoTab {
            case .general:
                Text(workspace.lastMessage)
                    .font(.system(size: 11))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .compile:
                SiemensCompileList(workspace: workspace, messages: workspace.compileResult?.messages ?? [])
            case .syntax:
                SiemensCompileList(workspace: workspace, messages: syntaxMessages)
            }
        }
    }

    private var syntaxMessages: [SiemensCompileMessage] {
        guard let block = workspace.currentBlock else { return [] }
        return (workspace.compileResult?.messages ?? []).filter { $0.blockID == block.id && $0.severity != .information }
    }
}

/// Info › Compile: Path, Description, Go to, Errors, Warnings.
private struct SiemensCompileList: View {
    let workspace: SiemensWorkspace
    let messages: [SiemensCompileMessage]

    var body: some View {
        VStack(spacing: 0) {
            SiemensTableHeader(columns: [("!", 22), ("Path", 220), ("Description", nil), ("Go to", 44)])
            if messages.isEmpty {
                Text("Compile the program (Ctrl+B) to see results here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(messages) { message in
                        SiemensCompileRow(workspace: workspace, message: message)
                    }
                }
            }
        }
    }
}

private struct SiemensCompileRow: View {
    let workspace: SiemensWorkspace
    let message: SiemensCompileMessage

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 22)
            Text(message.path)
                .padding(.leading, CGFloat(message.level) * 10)
                .frame(width: 220, alignment: .leading)
                .lineLimit(1)
            Text(description)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
            if message.blockID != nil {
                Button {
                    workspace.goTo(message)
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.plain)
                .help("Go to")
                .accessibilityLabel("Go to")
                .frame(width: 44)
            } else {
                Color.clear.frame(width: 44)
            }
        }
        .font(.system(size: 11))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { workspace.goTo(message) }
    }

    private var description: String {
        var text = message.text
        if let network = message.network { text = "Network \(network): " + text }
        if let line = message.line { text = "Line \(line): " + text }
        return text
    }

    private var icon: String {
        switch message.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .information: return message.text.isEmpty ? "folder" : "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch message.severity {
        case .error: return .red
        case .warning: return .orange
        case .information: return message.text.isEmpty ? .secondary : .green
        }
    }
}

// MARK: - Diagnostics

private struct SiemensInspectorDiagnostics: View {
    let workspace: SiemensWorkspace

    var body: some View {
        let _ = workspace.session?.frame
        let cpu = workspace.cpu
        VStack(alignment: .leading, spacing: 4) {
            Text("Device information").font(.system(size: 12, weight: .semibold))
            SiemensPropertyRow(title: "Device", value: "PLC_1 [CPU 1214C DC/DC/DC]")
            SiemensPropertyRow(title: "Online status", value: workspace.isOnline ? "Online" : "Offline")
            SiemensPropertyRow(title: "Operating mode", value: cpu?.mode.rawValue ?? "—")
            SiemensPropertyRow(title: "ERROR LED", value: cpu?.isErrorLEDFlashing == true ? "Flashing" : "Off")
            SiemensPropertyRow(title: "MAINT LED", value: cpu?.isMaintenanceLEDOn == true ? "On (force jobs active)" : "Off")
            if let error = cpu?.diagnostics.last(where: \.isError) {
                SiemensPropertyRow(title: "Last error", value: error.message)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
