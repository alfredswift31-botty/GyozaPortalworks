import SwiftUI

/// Presents the workspace's current dialog.
struct MelsecSheetView: View {
    let workspace: MelsecWorkspace
    let sheet: MelsecSheet

    var body: some View {
        switch sheet {
        case let .ladderInput(state):
            MelsecLadderInputDialog(workspace: workspace, initial: state)
        case let .onlineDataOperation(operation):
            MelsecOnlineDataOperationDialog(workspace: workspace, operation: operation)
        case .programCheck:
            MelsecProgramCheckDialog(workspace: workspace)
        case let .modifyValue(device):
            MelsecModifyValueDialog(workspace: workspace, device: device)
        case .moduleDiagnostics:
            MelsecModuleDiagnosticsDialog(workspace: workspace)
        case .addProgram:
            MelsecAddProgramDialog(workspace: workspace)
        case let .rename(programID):
            MelsecRenameDialog(workspace: workspace, programID: programID)
        case let .dataType(labelID, programID):
            MelsecDataTypeDialog(workspace: workspace, labelID: labelID, programID: programID)
        case let .programProperties(programID):
            MelsecPropertiesDialog(workspace: workspace, programID: programID)
        }
    }
}

/// A dialog frame with a title and OK/Cancel-style buttons.
private struct MelsecDialogFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(minWidth: 380)
    }
}

// MARK: Ladder Input

extension MelsecLadderSymbol {
    /// The symbol dropdown of the Ladder Input dialog.
    static let dialogSymbols: [MelsecLadderSymbol] = [
        .openContact, .openBranch, .closeContact, .closeBranch, .risingPulse, .fallingPulse,
        .risingPulseBranch, .fallingPulseBranch, .coil, .instruction,
    ]

    var dialogTitle: String {
        switch self {
        case .openContact: return "┤├  Open Contact"
        case .openBranch: return "┤├  Open Branch"
        case .closeContact: return "┤/├  Close Contact"
        case .closeBranch: return "┤/├  Close Branch"
        case .risingPulse: return "┤↑├  Rising Pulse"
        case .fallingPulse: return "┤↓├  Falling Pulse"
        case .risingPulseBranch: return "┤↑├  Rising Pulse OR"
        case .fallingPulseBranch: return "┤↓├  Falling Pulse OR"
        case .coil: return "─( )─  Coil"
        case .instruction: return "[ ]  Application Instruction"
        }
    }
}

private struct MelsecLadderInputDialog: View {
    let workspace: MelsecWorkspace
    let initial: MelsecLadderInputState
    @State private var symbol: MelsecLadderSymbol = .openContact
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        MelsecDialogFrame(title: "Ladder Input") {
            HStack {
                Picker("Symbol", selection: $symbol) {
                    ForEach(MelsecLadderSymbol.dialogSymbols, id: \.self) { item in
                        Text(item.dialogTitle).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                TextField("e.g. X0, OUT T0 K50, MOV K10 D0, ;statement", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit(confirm)
                    .frame(minWidth: 260)
            }
            if let error = initial.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            HStack {
                Text("Missing operands become ?. \";text\" enters a statement, \"OUT Y0;note\" a note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { workspace.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            symbol = initial.symbol
            text = initial.text
            focused = true
        }
    }

    private func confirm() {
        var state = initial
        state.symbol = symbol
        state.text = text
        workspace.confirmLadderInput(state)
    }
}

// MARK: Online Data Operation

private struct MelsecOnlineDataOperationDialog: View {
    let workspace: MelsecWorkspace
    let operation: MelsecOnlineOperation

    private var verb: String { operation == .readFromPLC ? "Read" : "Write" }

    var body: some View {
        MelsecDialogFrame(title: operation.title) {
            Text(operation == .readFromPLC ? "Read from PLC" : "Write to PLC")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Module Name/Data Name").bold()
                    Text(verb).bold()
                }
                Divider()
                GridRow {
                    Text("Parameter (System/CPU Parameter)")
                    checkbox
                }
                GridRow {
                    Text("Global Label Setting")
                    checkbox
                }
                ForEach(workspace.project.programs) { program in
                    GridRow {
                        Text("Program: \(program.fileName) › \(program.name)")
                        checkbox
                    }
                }
            }
            HStack {
                Text("Target: FX5UCPU (Simulation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { workspace.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Execute") { workspace.executeOnlineOperation(operation) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var checkbox: some View {
        Image(systemName: "checkmark.square.fill")
            .foregroundStyle(workspace.theme.accent)
            .accessibilityLabel("\(verb): selected")
    }
}

// MARK: Program Check

private struct MelsecProgramCheckDialog: View {
    let workspace: MelsecWorkspace

    var body: some View {
        MelsecDialogFrame(title: "Program Check") {
            Text("Check Contents")
                .font(.subheadline)
            ForEach(MelsecCheckFinding.Category.allCases, id: \.self) { category in
                Toggle(category.rawValue, isOn: binding(category))
            }
            HStack {
                Text("Target: all programs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { workspace.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Execute") {
                    workspace.sheet = nil
                    workspace.runProgramCheck()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func binding(_ category: MelsecCheckFinding.Category) -> Binding<Bool> {
        Binding(get: { workspace.programCheckOptions.categories.contains(category) }, set: { isOn in
            if isOn {
                workspace.programCheckOptions.categories.insert(category)
            } else {
                workspace.programCheckOptions.categories.remove(category)
            }
        })
    }
}

// MARK: Modify Value

private struct MelsecModifyValueDialog: View {
    let workspace: MelsecWorkspace
    let device: String
    @State private var name = ""
    @State private var type: MelsecModifyType = .bit
    @State private var value = ""
    @State private var message: String?

    var body: some View {
        MelsecDialogFrame(title: "Modify Value") {
            Form {
                TextField("Device/Label", text: $name)
                Picker("Data Type", selection: $type) {
                    ForEach(MelsecModifyType.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                if type == .bit {
                    HStack {
                        Button("ON") { set("TRUE") }
                        Button("OFF") { set("FALSE") }
                        Button("Switch ON/OFF") { toggle() }
                    }
                } else {
                    TextField("Value", text: $value)
                        .onSubmit { set(value) }
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == "Set." ? Color.secondary : Color.red)
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { workspace.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { set(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(type == .bit)
            }
        }
        .onAppear {
            name = device
        }
    }

    private func set(_ text: String) {
        message = workspace.modifyValue(device: name, type: type, value: text) ?? "Set."
    }

    private func toggle() {
        guard let cpu = workspace.cpu else {
            message = "There is no connection to a CPU."
            return
        }
        do {
            try cpu.toggleBit(name)
            workspace.session?.refresh()
            message = "Set."
        } catch let error as MelsecOperandError {
            message = error.message
        } catch {
            message = "'\(name)' cannot be changed."
        }
    }
}

// MARK: Module Diagnostics

private struct MelsecModuleDiagnosticsDialog: View {
    let workspace: MelsecWorkspace

    var body: some View {
        let _ = workspace.session?.frame
        MelsecDialogFrame(title: "Module Diagnostics (CPU Diagnostics)") {
            LabeledContent("Module", value: "FX5UCPU (Simulation)")
            LabeledContent("Operating Status", value: status)
            GroupBox("Current Error") {
                Text(workspace.cpu?.errorMessage ?? "No error.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(workspace.cpu?.hasError == true ? Color.red : Color.primary)
            }
            GroupBox("Error History") {
                MelsecErrorHistory(events: workspace.cpu?.diagnostics ?? [])
                    .frame(height: 140)
            }
            Text("Error Code: not shown (the simulator reports the cause as text). Clear the error with RESET in GX Simulator3.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { workspace.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 520)
    }

    private var status: String {
        guard let cpu = workspace.cpu else { return "Not connected" }
        if cpu.hasError { return "STOP (ERROR)" }
        return cpu.mode.rawValue
    }
}

private struct MelsecErrorHistory: View {
    let events: [DiagnosticEvent]

    var body: some View {
        List(events.reversed()) { event in
            HStack(alignment: .top) {
                Text(String(format: "%.1f s", Double(event.time) / 1000))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 70, alignment: .leading)
                Text(event.message)
                    .font(.caption)
                    .foregroundStyle(event.isError ? Color.red : Color.primary)
            }
        }
    }
}

// MARK: Programs

private struct MelsecAddProgramDialog: View {
    let workspace: MelsecWorkspace
    @State private var name = "ProgPou2"
    @State private var language: MelsecProgramLanguage = .ladder
    @State private var problem: String?

    var body: some View {
        MelsecDialogFrame(title: "New Data") {
            Form {
                LabeledContent("Data Type", value: "Program Block")
                TextField("Data Name", text: $name)
                Picker("Program Language", selection: $language) {
                    Text("Ladder").tag(MelsecProgramLanguage.ladder)
                    Text("ST").tag(MelsecProgramLanguage.structuredText)
                }
                LabeledContent("Program File", value: workspace.project.programs.first?.fileName ?? "MAIN")
                LabeledContent("Execution Type", value: "Scan")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    problem = workspace.addProgram(name: name, language: language)
                    if problem == nil { workspace.sheet = nil }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct MelsecRenameDialog: View {
    let workspace: MelsecWorkspace
    let programID: UUID
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        MelsecDialogFrame(title: "Rename") {
            TextField("Data Name", text: $name)
                .textFieldStyle(.roundedBorder)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    problem = workspace.renameProgram(programID, to: name)
                    if problem == nil { workspace.sheet = nil }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            name = workspace.program(programID)?.name ?? ""
        }
    }
}

private struct MelsecPropertiesDialog: View {
    let workspace: MelsecWorkspace
    let programID: UUID

    var body: some View {
        MelsecDialogFrame(title: "Properties") {
            if let program = workspace.program(programID) {
                LabeledContent("Data Name", value: program.name)
                LabeledContent("Data Type", value: "Program Block")
                LabeledContent("Program File", value: program.fileName)
                LabeledContent("Language", value: program.language == .ladder ? "Ladder" : "ST")
                LabeledContent("Execution Type", value: program.executionType.rawValue)
                LabeledContent("Local Labels", value: "\(program.localLabels.count)")
                if let steps = workspace.conversions[programID].map({ $0.endStep + 1 }) {
                    LabeledContent("Program Size", value: "\(steps) Step")
                }
            }
            HStack {
                Spacer()
                Button("Close") { workspace.sheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: Data type selection

private struct MelsecDataTypeDialog: View {
    let workspace: MelsecWorkspace
    let labelID: UUID
    let programID: UUID?
    @State private var element: MelsecLabelElementType = .bit
    @State private var isArray = false
    @State private var lower = 0
    @State private var upper = 9

    var body: some View {
        MelsecDialogFrame(title: "Data Type Selection") {
            Form {
                Picker("Data Type", selection: $element) {
                    ForEach(MelsecLabelElementType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                Toggle("Array", isOn: $isArray)
                if isArray {
                    Stepper("Lower bound: \(lower)", value: $lower, in: -32768...upper)
                    Stepper("Upper bound: \(upper)", value: $upper, in: lower...(lower + 32766))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    let type = MelsecLabelDataType(element, arrayBounds: isArray ? lower...upper : nil)
                    workspace.updateLabel(labelID, programID: programID, field: "type") { $0.dataType = type }
                    workspace.sheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard let label = workspace.labels(programID: programID).first(where: { $0.id == labelID }) else { return }
            element = label.dataType.element
            if let bounds = label.dataType.arrayBounds {
                isArray = true
                lower = bounds.lowerBound
                upper = bounds.upperBound
            }
        }
    }
}
