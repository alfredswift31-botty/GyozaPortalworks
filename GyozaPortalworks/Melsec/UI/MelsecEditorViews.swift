import AppKit
import SwiftUI

// MARK: ST editor

/// The ST editor: CodeEditor with GX Works3 colours and monitoring.
struct MelsecSTEditorView: View {
    let workspace: MelsecWorkspace
    let programID: UUID
    @State private var controller = CodeEditorController()

    var body: some View {
        let _ = workspace.session?.frame
        let trace = workspace.structuredTextTrace(programID: programID)
        CodeEditor(text: textBinding,
                   highlight: highlighter,
                   diagnostics: diagnostics,
                   monitor: trace.map(Self.monitorEntries),
                   executedLines: trace?.executedLines,
                   isEditable: workspace.mode.allowsEditing,
                   controller: controller)
            .onChange(of: workspace.pendingSourceJump) {
                guard let jump = workspace.pendingSourceJump else { return }
                controller.goTo(line: jump.line, column: jump.column)
                workspace.pendingSourceJump = nil
            }
    }

    private var textBinding: Binding<String> {
        Binding(get: { workspace.program(programID)?.structuredText ?? "" },
                set: { workspace.setStructuredText($0, programID: programID) })
    }

    private var diagnostics: [EditorDiagnostic] {
        workspace.structuredTextMarks(programID: programID).map {
            EditorDiagnostic(line: $0.line, column: $0.column, length: 0, message: $0.message, isError: $0.isError)
        }
    }

    private var highlighter: (String) -> [HighlightSpan] {
        let locals = Set((workspace.program(programID)?.localLabels ?? []).map { $0.name.lowercased() })
        let globals = Set(workspace.project.globalLabels.map { $0.name.lowercased() })
        return { source in MelsecSTColors.spans(source, locals: locals, globals: globals) }
    }

    private static func monitorEntries(_ trace: STTrace) -> [Int: [MonitorEntry]] {
        var result: [Int: [MonitorEntry]] = [:]
        for entry in trace.allEntries {
            var boolValue: Bool?
            if case let .bool(value) = entry.value { boolValue = value }
            result[entry.line, default: []].append(MonitorEntry(operand: entry.text, value: entry.display, boolValue: boolValue, style: .melsec))
        }
        return result
    }
}

/// GX Works3's ST colours: control keywords blue, global labels pink,
/// local labels sea-green, comments green.
enum MelsecSTColors {
    static func spans(_ source: String, locals: Set<String>, globals: Set<String>) -> [HighlightSpan] {
        let text = source as NSString
        return STSyntax.highlight(source, dialect: .melsec).compactMap { highlight in
            let color: NSColor
            switch highlight.kind {
            case .keyword:
                color = .systemBlue
            case .comment:
                color = .systemGreen
            case .string:
                color = .systemBrown
            case .invalid:
                color = .systemRed
            case .identifier, .localName, .globalName:
                guard NSMaxRange(highlight.range) <= text.length else { return nil }
                let name = text.substring(with: highlight.range).lowercased()
                if locals.contains(name) {
                    color = NSColor(red: 0.18, green: 0.55, blue: 0.47, alpha: 1)
                } else if globals.contains(name) {
                    color = .systemPink
                } else {
                    return nil
                }
            case .absoluteAddress:
                color = .systemIndigo
            case .number, .timeLiteral, .operator:
                return nil
            }
            return HighlightSpan(range: highlight.range, color: color)
        }
    }
}

// MARK: Label editor

/// Global / local label editor: Label Name, Data Type, Class, Assign,
/// Initial Value, Constant, Comment.
struct MelsecLabelEditorView: View {
    let workspace: MelsecWorkspace
    /// nil = global labels.
    let programID: UUID?
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            MelsecLabelTable(workspace: workspace, programID: programID, selection: $selection)
            problems
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                workspace.addLabel(programID: programID)
            } label: {
                Label("Add Label", systemImage: "plus")
            }
            .help("Add a label row")
            Button {
                if let selection { workspace.deleteLabel(selection, programID: programID) }
            } label: {
                Label("Delete Row", systemImage: "minus")
            }
            .disabled(selection == nil)
            .help("Delete the selected label")
            Spacer()
            Text(programID == nil ? "Global label: usable by all programs" : "Local label: usable in this program only")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(6)
    }

    @ViewBuilder
    private var problems: some View {
        let list = workspace.labelProblems(programID: programID)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct MelsecLabelTable: View {
    let workspace: MelsecWorkspace
    let programID: UUID?
    @Binding var selection: UUID?

    var body: some View {
        Table(workspace.labels(programID: programID), selection: $selection) {
            TableColumn("Label Name") { label in
                field(label, "name", \.name)
            }
            TableColumn("Data Type") { label in
                MelsecDataTypeCell(workspace: workspace, label: label, programID: programID)
            }
            .width(min: 150)
            TableColumn("Class") { label in
                MelsecClassCell(workspace: workspace, label: label, programID: programID)
            }
            .width(min: 120)
            TableColumn("Assign (Device/Label)") { label in
                field(label, "device", \.device)
                    .disabled(programID != nil || label.labelClass.isConstant)
            }
            TableColumn("Initial Value") { label in
                field(label, "initial", \.initialValue)
                    .disabled(label.labelClass.isConstant)
            }
            TableColumn("Constant") { label in
                field(label, "initial", \.initialValue)
                    .disabled(!label.labelClass.isConstant)
            }
            TableColumn("Comment") { label in
                field(label, "comment", \.comment)
            }
        }
    }

    private func field(_ label: MelsecLabel, _ name: String, _ keyPath: WritableKeyPath<MelsecLabel, String>) -> some View {
        TextField(name, text: Binding(get: { label[keyPath: keyPath] }, set: { value in
            workspace.updateLabel(label.id, programID: programID, field: name) { $0[keyPath: keyPath] = value }
        }))
        .textFieldStyle(.plain)
        .labelsHidden()
    }
}

private struct MelsecDataTypeCell: View {
    let workspace: MelsecWorkspace
    let label: MelsecLabel
    let programID: UUID?

    var body: some View {
        HStack(spacing: 4) {
            Text(label.dataType.text)
                .lineLimit(1)
            Spacer(minLength: 2)
            Button("…") {
                workspace.sheet = .dataType(labelID: label.id, programID: programID)
            }
            .buttonStyle(.borderless)
            .help("Data Type Selection")
            .accessibilityLabel("Choose data type")
        }
    }
}

private struct MelsecClassCell: View {
    let workspace: MelsecWorkspace
    let label: MelsecLabel
    let programID: UUID?

    var body: some View {
        Picker("Class", selection: Binding(get: { label.labelClass }, set: { value in
            workspace.updateLabel(label.id, programID: programID, field: "class") { $0.labelClass = value }
        })) {
            ForEach(classes, id: \.self) { labelClass in
                Text(labelClass.rawValue).tag(labelClass)
            }
        }
        .labelsHidden()
    }

    private var classes: [MelsecLabelClass] {
        programID == nil ? [.global, .globalConstant] : [.local, .localConstant]
    }
}

// MARK: Device comment editor

/// Device Comment: a device name selector and Device | Comment rows.
struct MelsecDeviceCommentView: View {
    let workspace: MelsecWorkspace
    @State private var start = "X0"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Device Name")
                TextField("X0", text: $start)
                    .frame(width: 100)
                    .textFieldStyle(.roundedBorder)
                Text("Enter a device such as X0, Y0, M0 or D0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(6)
            Divider()
            List(devices, id: \.self) { device in
                MelsecCommentRow(workspace: workspace, device: device)
            }
            .listStyle(.plain)
        }
    }

    private var devices: [String] {
        let profile = workspace.project.profile
        guard case let .device(device, nil)? = try? MelsecOperandParser.parse(start, profile: profile) else { return [] }
        return (0..<64).compactMap { offset in
            let next = device.advanced(by: offset)
            return profile.contains(next.kind, next.number) ? next.text(profile) : nil
        }
    }
}

private struct MelsecCommentRow: View {
    let workspace: MelsecWorkspace
    let device: String

    var body: some View {
        HStack {
            Text(device)
                .font(.system(.body, design: .monospaced))
                .frame(width: 80, alignment: .leading)
            TextField("Comment", text: Binding(get: { workspace.project.comment(for: device) ?? "" },
                                               set: { workspace.setDeviceComment($0, device: device) }))
                .textFieldStyle(.plain)
        }
    }
}

// MARK: Device/Buffer Memory Batch Monitor

/// Online › Monitor › Device/Buffer Memory Batch Monitor.
struct MelsecBatchMonitorView: View {
    let workspace: MelsecWorkspace

    var body: some View {
        let _ = workspace.session?.frame
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.vertical, .horizontal]) {
                MelsecBatchGrid(workspace: workspace, rows: rows)
                    .padding(6)
            }
        }
    }

    private var header: some View {
        @Bindable var workspace = workspace
        return HStack(spacing: 8) {
            Text("Device Name")
            TextField("D0", text: $workspace.batchDevice)
                .frame(width: 100)
                .textFieldStyle(.roundedBorder)
            Button {
                workspace.isBatchMonitoring.toggle()
            } label: {
                Label(workspace.isBatchMonitoring ? "Monitoring" : "Start Monitoring", systemImage: "eye")
            }
            .tint(workspace.isBatchMonitoring ? .green : nil)
            .buttonStyle(.borderedProminent)
            .disabled(workspace.cpu == nil)
            .help(workspace.cpu == nil ? "Start the simulation to monitor device memory." : "Start or stop monitoring")
            if workspace.cpu == nil {
                Text("Not connected: start the simulation first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(6)
    }

    private var rows: [MelsecBatchRow] {
        let memory = workspace.isBatchMonitoring ? (workspace.cpu?.memory ?? workspace.typeProbe.memory) : workspace.typeProbe.memory
        return MelsecBatchRow.rows(start: workspace.batchDevice, memory: memory) { workspace.project.comment(for: $0) } ?? []
    }
}

private struct MelsecBatchGrid: View {
    let workspace: MelsecWorkspace
    let rows: [MelsecBatchRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
            GridRow {
                Text("Device").bold()
                ForEach(0..<16, id: \.self) { index in
                    Text(String(15 - index, radix: 16, uppercase: true)).bold().frame(width: 16)
                }
                Text("Current Value").bold()
                Text("String").bold()
                Text("Comment").bold()
            }
            ForEach(rows) { row in
                GridRow {
                    Text(row.device).font(.system(.body, design: .monospaced))
                    ForEach(0..<16, id: \.self) { index in
                        MelsecBitCell(isOn: row.bits[index]) {
                            toggle(row.bitDevices[index])
                        }
                    }
                    Text(String(row.value)).font(.system(.body, design: .monospaced))
                    Text(row.string).font(.system(.body, design: .monospaced))
                    Text(row.comment).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 11))
    }

    private func toggle(_ device: String) {
        guard !device.isEmpty, let cpu = workspace.cpu else { return }
        try? cpu.toggleBit(device)
        workspace.session?.refresh()
    }
}

private struct MelsecBitCell: View {
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Text(isOn ? "1" : "0")
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 16, height: 16)
            .background(isOn ? Color.blue.opacity(0.35) : Color.clear)
            .onTapGesture(count: 2, perform: toggle)
            .accessibilityLabel(isOn ? "Bit on" : "Bit off")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: CPU Parameter

/// A read-only summary of the FX5U CPU parameters the simulator uses.
struct MelsecCPUParameterView: View {
    let profile: MelsecCPUProfile

    var body: some View {
        Form {
            Section("Name Setting") {
                LabeledContent("CPU Type", value: "\(profile.series)CPU")
                LabeledContent("Model", value: profile.modelName)
            }
            Section("Operation Related Setting") {
                LabeledContent("Scan Time", value: "10 ms (simulated)")
                LabeledContent("Output Mode at STOP to RUN", value: "Output the output (Y) status before STOP")
                LabeledContent("Built-in Analog", value: "AI CH1 SD6020, AI CH2 SD6060, AO CH1 SD6180 (0 to 4000)")
            }
            Section("Device/Label Memory Area Setting") {
                ForEach(MelsecDeviceKind.allCases, id: \.self) { kind in
                    LabeledContent("\(kind.displayName) (\(kind.rawValue))", value: detail(kind))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func detail(_ kind: MelsecDeviceKind) -> String {
        var text = "\(profile.count(kind)) points, \(profile.rangeText(kind))"
        switch profile.numbering(for: kind) {
        case .octal: text += ", octal"
        case .hexadecimal: text += ", hexadecimal"
        case .decimal: break
        }
        if let latched = profile.latchedRanges[kind], !latched.isEmpty {
            text += ", latch (1): all"
        }
        return text
    }
}
