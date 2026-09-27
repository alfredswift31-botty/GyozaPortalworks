import AppKit
import SwiftUI

/// Column widths shared by the declaration tables.
nonisolated enum SiemensColumns {
    static let name: CGFloat = 170
    static let type: CGFloat = 150
    static let address: CGFloat = 90
    static let value: CGFloat = 110
    static let retain: CGFloat = 90
    static let monitor: CGFloat = 110
    static let section: CGFloat = 70
}

/// A header row of a TIA table.
struct SiemensTableHeader: View {
    let columns: [(String, CGFloat?)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                SiemensHeaderCell(title: column.0, width: column.1)
                Divider()
            }
        }
        .frame(height: 22)
        .background(SiemensColors.theme.paneHeader)
    }
}

// MARK: - Block interface

/// The block interface table: sections Input, Output, InOut, Static, Temp,
/// Constant (and Return for FCs), each with an "<Add new>" row.
struct SiemensInterfaceEditor: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        VStack(spacing: 0) {
            SiemensTableHeader(columns: [("Name", SiemensColumns.name + SiemensColumns.section), ("Data type", SiemensColumns.type),
                                         ("Default value", SiemensColumns.value), ("Retain", SiemensColumns.retain), ("Comment", nil)])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(SiemensInterface.sections(for: block.kind), id: \.self) { section in
                        SiemensInterfaceSection(workspace: workspace, block: block, section: section)
                    }
                }
            }
        }
        .background(SiemensColors.theme.editorBackground)
    }
}

private struct SiemensInterfaceSection: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock
    let section: VariableSection

    var body: some View {
        let owner = SiemensWorkspace.VariableOwner.interface(block: block.id, section: section)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                Text(section.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: 20)
            .background(Color.secondary.opacity(0.08))
            if section == .returnValue {
                SiemensReturnRow(workspace: workspace, block: block)
            } else {
                ForEach(block.interface.variables(in: section)) { variable in
                    SiemensVariableRow(workspace: workspace, owner: owner, variable: variable, indent: SiemensColumns.section,
                                       showsRetain: block.kind == .functionBlock && section != .temp && section != .constant,
                                       readOnly: block.kind == .organizationBlock && section == .input)
                }
                SiemensAddNewRow { workspace.addVariable(to: owner) }
            }
        }
    }
}

private struct SiemensReturnRow: View {
    let workspace: SiemensWorkspace
    let block: SiemensBlock

    var body: some View {
        HStack(spacing: 0) {
            Text(block.name)
                .font(.system(size: 11))
                .padding(.leading, SiemensColumns.section)
                .frame(width: SiemensColumns.name + SiemensColumns.section, alignment: .leading)
            Picker("", selection: Binding(get: { block.interface.returnType }, set: { workspace.setReturnType($0, ofBlock: block.id) })) {
                ForEach(["Void"] + PLCDataType.allCases.map(\.rawValue), id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: SiemensColumns.type)
            Spacer()
        }
        .frame(height: 22)
    }
}

/// One declaration row (interface, DB, PLC data type).
struct SiemensVariableRow: View {
    let workspace: SiemensWorkspace
    let owner: SiemensWorkspace.VariableOwner
    let variable: SiemensVariable
    var indent: CGFloat = 0
    var showsRetain = true
    var readOnly = false
    var monitorValue: String?

    var body: some View {
        HStack(spacing: 0) {
            SiemensCellField(text: variable.name) { text in update { $0.name = text } }
                .padding(.leading, indent)
                .frame(width: SiemensColumns.name + indent)
                .disabled(readOnly)
            Divider()
            SiemensCellField(text: variable.dataType, isError: typeProblem) { text in update { $0.dataType = text } }
                .frame(width: SiemensColumns.type)
                .disabled(readOnly)
            Divider()
            SiemensCellField(text: variable.startValue) { text in update { $0.startValue = text } }
                .frame(width: SiemensColumns.value)
                .disabled(readOnly)
            Divider()
            SiemensRetainPicker(variable: variable, visible: showsRetain) { retain in update { $0.retain = retain } }
                .frame(width: SiemensColumns.retain)
            Divider()
            if let monitorValue {
                Text(monitorValue)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: SiemensColumns.monitor, alignment: .leading)
                    .padding(.leading, 4)
                Divider()
            }
            SiemensCellField(text: variable.comment) { text in update { $0.comment = text } }
        }
        .frame(height: 22)
        .contextMenu {
            Button("Delete") { workspace.deleteVariable(variable.id, of: owner) }
                .disabled(readOnly)
        }
    }

    private var typeProblem: Bool {
        (try? SiemensTypeParser.parse(variable.dataType)) == nil
    }

    private func update(_ change: @escaping (inout SiemensVariable) -> Void) {
        workspace.updateVariable(variable.id, of: owner, change)
    }
}

private struct SiemensRetainPicker: View {
    let variable: SiemensVariable
    let visible: Bool
    let set: (SiemensRetain) -> Void

    var body: some View {
        if visible {
            Picker("", selection: Binding(get: { variable.retain }, set: set)) {
                ForEach(SiemensRetain.allCases, id: \.self) { retain in
                    Text(retain.rawValue).tag(retain)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
        } else {
            Color.clear
        }
    }
}

/// The grey "<Add new>" row at the end of a table.
struct SiemensAddNewRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("<Add new>")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, SiemensColumns.section)
        }
        .buttonStyle(.plain)
        .frame(height: 20)
        .help("Add a new row")
    }
}

// MARK: - PLC tag table

/// A PLC tag table (or "Show all tags"): PLC tags / User constants / System constants.
struct SiemensTagTableView: View {
    let workspace: SiemensWorkspace
    /// nil = all tag tables.
    let tableID: UUID?
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("PLC tags").tag(0)
                Text("User constants").tag(1)
                Text("System constants").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(6)
            switch tab {
            case 0: SiemensTagRows(workspace: workspace, tableID: tableID)
            case 1: SiemensConstantRows(workspace: workspace, tableID: tableID)
            default: SiemensSystemConstants()
            }
        }
        .background(SiemensColors.theme.editorBackground)
    }
}

private struct SiemensTagRows: View {
    let workspace: SiemensWorkspace
    let tableID: UUID?

    var body: some View {
        let _ = workspace.session?.frame
        let issues = workspace.project.tagIssues
        let tables = workspace.project.tagTables.filter { tableID == nil || $0.id == tableID }
        VStack(spacing: 0) {
            SiemensTableHeader(columns: headerColumns)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tables) { table in
                        ForEach(table.tags) { tag in
                            SiemensTagRow(workspace: workspace, tag: tag, tableName: tableID == nil ? table.name : nil,
                                          issues: issues.filter { $0.rowID == tag.id })
                        }
                    }
                    if let tableID {
                        SiemensAddNewRow { workspace.addTag(toTable: tableID) }
                    }
                }
            }
        }
    }

    private var headerColumns: [(String, CGFloat?)] {
        var columns: [(String, CGFloat?)] = [("Name", SiemensColumns.name)]
        if tableID == nil { columns.append(("Tag table", SiemensColumns.value)) }
        columns.append(("Data type", SiemensColumns.type))
        columns.append(("Address", SiemensColumns.address))
        columns.append(("Retain", SiemensColumns.section))
        if workspace.isOnline { columns.append(("Monitor value", SiemensColumns.monitor)) }
        columns.append(("Comment", nil))
        return columns
    }
}

private struct SiemensTagRow: View {
    let workspace: SiemensWorkspace
    let tag: SiemensTag
    let tableName: String?
    let issues: [SiemensTagIssue]

    var body: some View {
        HStack(spacing: 0) {
            SiemensCellField(text: tag.name, isError: has(.name)) { text in workspace.updateTag(tag.id) { $0.name = text } }
                .frame(width: SiemensColumns.name)
            Divider()
            if let tableName {
                Text(tableName).font(.system(size: 11)).frame(width: SiemensColumns.value, alignment: .leading).padding(.leading, 4)
                Divider()
            }
            Picker("", selection: Binding(get: { tag.dataType }, set: { type in workspace.updateTag(tag.id) { $0.dataType = type } })) {
                ForEach(PLCDataType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: SiemensColumns.type)
            Divider()
            SiemensCellField(text: tag.address, isError: addressError, isWarning: addressDuplicate) { text in
                workspace.updateTag(tag.id) { $0.address = text }
            }
            .frame(width: SiemensColumns.address)
            Divider()
            Toggle("", isOn: Binding(get: { workspace.project.isRetain(tag) }, set: { workspace.setRetain($0, forTag: tag.id) }))
                .labelsHidden()
                .controlSize(.mini)
                .disabled(tag.parsedAddress?.area != .memory)
                .frame(width: SiemensColumns.section)
            Divider()
            if workspace.isOnline {
                Text(workspace.monitorValue(ofOperand: "\"\(tag.name)\"") ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: SiemensColumns.monitor, alignment: .leading)
                    .padding(.leading, 4)
                Divider()
            }
            SiemensCellField(text: tag.comment) { text in workspace.updateTag(tag.id) { $0.comment = text } }
        }
        .frame(height: 22)
        .help(issues.map(\.message).joined(separator: "\n"))
        .contextMenu {
            Button("Delete") { workspace.deleteTagRow(tag.id) }
        }
    }

    private func has(_ column: SiemensTagIssue.Column) -> Bool {
        issues.contains { $0.column == column }
    }

    private var addressDuplicate: Bool {
        issues.contains { $0.column == .address && $0.message.hasPrefix("The address") && $0.message.contains("more than one") }
    }

    private var addressError: Bool {
        has(.address) && !addressDuplicate
    }
}

private struct SiemensConstantRows: View {
    let workspace: SiemensWorkspace
    let tableID: UUID?

    var body: some View {
        let issues = workspace.project.tagIssues
        let tables = workspace.project.tagTables.filter { tableID == nil || $0.id == tableID }
        VStack(spacing: 0) {
            SiemensTableHeader(columns: [("Name", SiemensColumns.name), ("Data type", SiemensColumns.type),
                                         ("Value", SiemensColumns.value), ("Comment", nil)])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tables) { table in
                        ForEach(table.constants) { constant in
                            SiemensConstantRow(workspace: workspace, constant: constant, issues: issues.filter { $0.rowID == constant.id })
                        }
                    }
                    if let tableID {
                        SiemensAddNewRow { workspace.addConstant(toTable: tableID) }
                    }
                }
            }
        }
    }
}

private struct SiemensConstantRow: View {
    let workspace: SiemensWorkspace
    let constant: SiemensUserConstant
    let issues: [SiemensTagIssue]

    var body: some View {
        HStack(spacing: 0) {
            SiemensCellField(text: constant.name, isError: issues.contains { $0.column == .name }) { text in
                workspace.updateConstant(constant.id) { $0.name = text }
            }
            .frame(width: SiemensColumns.name)
            Divider()
            Picker("", selection: Binding(get: { constant.dataType }, set: { type in workspace.updateConstant(constant.id) { $0.dataType = type } })) {
                ForEach(PLCDataType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: SiemensColumns.type)
            Divider()
            SiemensCellField(text: constant.value, isError: issues.contains { $0.column == .value }) { text in
                workspace.updateConstant(constant.id) { $0.value = text }
            }
            .frame(width: SiemensColumns.value)
            Divider()
            SiemensCellField(text: constant.comment) { text in workspace.updateConstant(constant.id) { $0.comment = text } }
        }
        .frame(height: 22)
        .contextMenu {
            Button("Delete") { workspace.deleteTagRow(constant.id) }
        }
    }
}

private struct SiemensSystemConstants: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("System constants are hardware identifiers that the device configuration assigns to modules and OBs.")
            Text("This simulator's CPU has no configurable modules, so there are none to show.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Data blocks and PLC data types

/// The DB editor: Name, Data type, Start value, Retain, Comment (+ Monitor value online).
struct SiemensDataBlockEditor: View {
    let workspace: SiemensWorkspace
    let dataBlock: SiemensDataBlock

    var body: some View {
        let _ = workspace.session?.frame
        VStack(spacing: 0) {
            HStack {
                Text(dataBlock.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(kindText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if dataBlock.kind != .global {
                    Toggle("Retain", isOn: Binding(get: { dataBlock.isRetain }, set: { value in
                        workspace.edit { project in
                            if let index = project.dataBlocks.firstIndex(where: { $0.id == dataBlock.id }) { project.dataBlocks[index].isRetain = value }
                        }
                    }))
                    .controlSize(.small)
                }
            }
            .padding(6)
            SiemensTableHeader(columns: headerColumns)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if dataBlock.kind == .global {
                        ForEach(dataBlock.members) { member in
                            SiemensVariableRow(workspace: workspace, owner: .dataBlock(dataBlock.id), variable: member,
                                               monitorValue: monitor(member.name))
                            SiemensStructMembers(variable: member, prefix: member.name, depth: 1, workspace: workspace, dataBlock: dataBlock)
                        }
                        SiemensAddNewRow { workspace.addVariable(to: .dataBlock(dataBlock.id)) }
                    } else {
                        ForEach(instanceRows) { row in
                            SiemensReadOnlyRow(name: row.path, type: row.type, value: monitor(row.path))
                        }
                    }
                }
            }
        }
        .background(SiemensColors.theme.editorBackground)
    }

    private var kindText: String {
        switch dataBlock.kind {
        case .global: return "Global DB, optimized block access"
        case .instance: return "Instance DB of \"\(dataBlock.instanceOf)\""
        case .systemInstance: return "Instance DB of \(dataBlock.instanceOf) (Program resources)"
        }
    }

    private var headerColumns: [(String, CGFloat?)] {
        var columns: [(String, CGFloat?)] = [("Name", SiemensColumns.name), ("Data type", SiemensColumns.type)]
        if dataBlock.kind == .global {
            columns += [("Start value", SiemensColumns.value), ("Retain", SiemensColumns.retain)]
        }
        if workspace.isOnline { columns.append(("Monitor value", SiemensColumns.monitor)) }
        columns.append(("Comment", nil))
        return columns
    }

    private var instanceRows: [SiemensLeafRow] {
        let environment = SiemensTypeEnvironment(dataTypes: workspace.project.dataTypes, blocks: workspace.project.blocks)
        guard let storage = try? SiemensProjectCompiler.storage(for: dataBlock, project: workspace.project, environment: environment) else {
            return []
        }
        return storage.1.leaves().map { leaf in
            SiemensLeafRow(path: leaf.path, type: leaf.node.elementaryType?.rawValue ?? "")
        }
    }

    private func monitor(_ path: String) -> String? {
        guard workspace.isOnline else { return nil }
        return workspace.monitorValue(ofOperand: "\"\(dataBlock.name)\".\(path)") ?? ""
    }
}

/// Struct members shown under their parent (edited in the parent's type).
private struct SiemensStructMembers: View {
    let variable: SiemensVariable
    let prefix: String
    let depth: Int
    let workspace: SiemensWorkspace
    let dataBlock: SiemensDataBlock

    var body: some View {
        ForEach(variable.members) { member in
            SiemensReadOnlyRow(name: String(repeating: "   ", count: depth) + member.name, type: member.dataType,
                               value: workspace.isOnline ? workspace.monitorValue(ofOperand: "\"\(dataBlock.name)\".\(prefix).\(member.name)") : nil)
        }
    }
}

private struct SiemensReadOnlyRow: View {
    let name: String
    let type: String
    var value: String?

    var body: some View {
        HStack(spacing: 0) {
            Text(name).frame(width: SiemensColumns.name, alignment: .leading).padding(.leading, 4)
            Divider()
            Text(type).frame(width: SiemensColumns.type, alignment: .leading).padding(.leading, 4)
            Divider()
            if let value {
                Text(value).font(.system(size: 11, design: .monospaced)).frame(width: SiemensColumns.monitor, alignment: .leading)
                    .padding(.leading, 4)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .frame(height: 20)
    }
}

/// A PLC data type (UDT) editor.
struct SiemensDataTypeEditor: View {
    let workspace: SiemensWorkspace
    let dataType: SiemensDataType

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(dataType.name).font(.system(size: 12, weight: .semibold))
                Text("PLC data type").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(6)
            SiemensTableHeader(columns: [("Name", SiemensColumns.name), ("Data type", SiemensColumns.type),
                                         ("Default value", SiemensColumns.value), ("Retain", SiemensColumns.retain), ("Comment", nil)])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(dataType.members) { member in
                        SiemensVariableRow(workspace: workspace, owner: .dataType(dataType.id), variable: member, showsRetain: false)
                    }
                    SiemensAddNewRow { workspace.addVariable(to: .dataType(dataType.id)) }
                }
            }
        }
        .background(SiemensColors.theme.editorBackground)
    }
}

/// One elementary value of an instance DB.
nonisolated struct SiemensLeafRow: Identifiable, Hashable, Sendable {
    var path: String
    var type: String
    var id: String { path }
}
