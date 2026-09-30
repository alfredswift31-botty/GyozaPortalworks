import AppKit
import SwiftUI

/// A monitored value as TIA shows it in the grey box next to an operand.
nonisolated enum S7ValueText {
    static func text(_ value: PLCValue) -> String {
        switch value {
        case let .bool(flag): return flag ? "TRUE" : "FALSE"
        case let .int(number): return String(number)
        case let .real(number): return RealLiteral.format(number)
        case let .time(milliseconds): return TimeLiteral.format(milliseconds: milliseconds)
        }
    }
}

/// An operand above or below an element, or at a box pin. Red placeholder
/// when empty; double-click to type; a grey value box while monitoring.
struct S7OperandLabel: View {
    let target: S7OperandTarget
    let text: String
    let placeholderBool: Bool
    let context: S7LadderContext
    var value: PLCValue?
    var alignment: Alignment = .center
    /// An optional parameter left open shows "..." (not a red placeholder), as in TIA.
    var isOptional = false

    var body: some View {
        if context.workspace.editingOperand == target {
            S7OperandEditor(target: target, initial: text, context: context)
        } else {
            HStack(spacing: 3) {
                Text(shown)
                    .font(.system(size: 11))
                    .foregroundStyle(isMissing ? SiemensColors.placeholder : isPlaceholder ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.middle)
                if let value {
                    Text(S7ValueText.text(value))
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 3)
                        .background(Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 2))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                context.workspace.beginEditing(target, inBlock: context.blockID)
            }
            .help(isMissing ? "Double-click to enter an operand" : isPlaceholder ? "Optional parameter: double-click to enter an operand" : text)
            .accessibilityLabel(isMissing ? "Operand missing" : isPlaceholder ? "Optional parameter, not used" : text)
        }
    }

    private var isPlaceholder: Bool { S7Placeholder.isPlaceholder(text) }

    /// A placeholder that must be filled in before the block compiles.
    private var isMissing: Bool { isPlaceholder && !isOptional }

    private var shown: String {
        guard isPlaceholder else { return text }
        if isOptional { return S7Placeholder.optional }
        return placeholderBool ? S7Placeholder.bool : S7Placeholder.value
    }
}

/// Inline operand entry with a simple suggestion list from tags and locals.
struct S7OperandEditor: View {
    let target: S7OperandTarget
    let initial: String
    let context: S7LadderContext
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .frame(minWidth: 90)
            .focused($focused)
            .onAppear {
                draft = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { commit(draft) }
            .onExitCommand { context.workspace.cancelOperandEditing() }
            .overlay(alignment: .topLeading) {
                S7SuggestionList(suggestions: suggestions) { choice in commit(choice) }
                    .offset(y: 24)
            }
            .zIndex(10)
    }

    private var suggestions: [String] {
        guard let block = context.block, !draft.isEmpty, draft != initial else { return [] }
        return SiemensOperandEntry.suggestions(for: draft, block: block, project: context.workspace.project, limit: 6)
    }

    private func commit(_ text: String) {
        context.workspace.commitOperand(text, target: target, inBlock: context.blockID)
    }
}

private struct S7SuggestionList: View {
    let suggestions: [String]
    let choose: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Text(suggestion)
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { choose(suggestion) }
                }
            }
            .frame(width: 180)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5)))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// An instruction box with EN/ENO (or IN/Q) on the rung, its other pins and
/// the operands at them; the instance or bit operand sits above.
struct S7BoxView: View {
    let box: S7Box
    let context: S7LadderContext
    let showsRungWires: Bool

    var body: some View {
        let status = context.status(box.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 0) {
                S7BoxPinColumn(box: box, pins: box.inputs, isInput: true, context: context, status: status, showsRungWire: showsRungWires)
                S7BoxBody(box: box, context: context, status: status)
                S7BoxPinColumn(box: box, pins: box.outputs, isInput: false, context: context, status: status, showsRungWire: showsRungWires)
            }
            ForEach(branchPins, id: \.name) { pin in
                if case let .branch(path) = pin.source {
                    HStack(alignment: .top, spacing: 4) {
                        Text(pin.name + ":")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.top, S7LadderMetrics.lineY - 7)
                        S7PathView(path: path, context: context)
                    }
                    .padding(.leading, S7LadderMetrics.pinColumnWidth)
                }
            }
        }
        .modifier(S7ElementChrome(id: box.id, context: context, label: box.title + " box"))
        .contextMenu {
            S7BoxMenu(box: box, context: context)
        }
    }

    private var branchPins: [S7Pin] {
        (box.inputs + box.outputs).filter { if case .branch = $0.source { return true } else { return false } }
    }
}

/// Operands to the left (inputs) or right (outputs) of a box, row by row.
private struct S7BoxPinColumn: View {
    let box: S7Box
    let pins: [S7Pin]
    let isInput: Bool
    let context: S7LadderContext
    let status: S7ElementStatus?
    let showsRungWire: Bool

    var body: some View {
        VStack(alignment: isInput ? .trailing : .leading, spacing: 0) {
            if showsRungWire && hasRungPin {
                S7Wire(signal: isInput ? status?.input : status?.output)
                    .frame(height: S7LadderMetrics.boxHeaderHeight + S7LadderMetrics.boxTitleHeight, alignment: .top)
            } else {
                Color.clear.frame(height: S7LadderMetrics.boxHeaderHeight + S7LadderMetrics.boxTitleHeight)
            }
            if box.typeLabel != nil || box.instruction == .calculate {
                Color.clear.frame(height: S7LadderMetrics.boxTypeHeight)
            }
            ForEach(pins, id: \.name) { pin in
                S7OperandLabel(target: context.target(box.id, .pin(pin.name)), text: label(pin), placeholderBool: isBool(pin),
                               context: context, value: status?.values[pin.name], alignment: isInput ? .trailing : .leading,
                               isOptional: isOptional(pin))
                    .frame(height: S7LadderMetrics.pinRowHeight)
            }
        }
        .frame(width: S7LadderMetrics.pinColumnWidth)
    }

    private var hasRungPin: Bool {
        isInput || !box.instruction.spec.powerOutput.isEmpty || box.instruction == .inRange || box.instruction == .outOfRange
    }

    private func label(_ pin: S7Pin) -> String {
        switch pin.source {
        case let .operand(text): return text
        case .branch: return isInput ? "⟵ branch" : "branch ⟶"
        }
    }

    private func isBool(_ pin: S7Pin) -> Bool {
        pinSpec(pin)?.type == .bool
    }

    /// Pins the instruction doesn't require (TON's ET, a counter's CV).
    private func isOptional(_ pin: S7Pin) -> Bool {
        pinSpec(pin).map { !$0.isRequired } ?? false
    }

    private func pinSpec(_ pin: S7Pin) -> S7PinSpec? {
        let spec = box.instruction.spec
        return (spec.inputs + spec.outputs).first { $0.name.caseInsensitiveCompare(pin.name) == .orderedSame }
    }
}

/// The box outline: title, type, pin names and the yellow star.
private struct S7BoxBody: View {
    let box: S7Box
    let context: S7LadderContext
    let status: S7ElementStatus?

    var body: some View {
        VStack(spacing: 0) {
            S7BoxHeader(box: box, context: context)
                .frame(height: S7LadderMetrics.boxHeaderHeight)
            VStack(spacing: 0) {
                S7BoxTitleRow(box: box)
                    .frame(height: S7LadderMetrics.boxTitleHeight)
                if box.instruction == .calculate {
                    SiemensCellField(text: box.expression, placeholder: "OUT := <???>") { text in
                        context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                            _ = network.setExpression(text, of: box.id)
                        }
                    }
                    .frame(height: S7LadderMetrics.boxTypeHeight)
                } else if let typeLabel = box.typeLabel {
                    S7BoxTypeLabel(box: box, typeLabel: typeLabel, context: context)
                        .frame(height: S7LadderMetrics.boxTypeHeight)
                }
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack {
                        Text(row < box.inputs.count ? box.inputs[row].name : "")
                        Spacer(minLength: 2)
                        Text(row < box.outputs.count ? box.outputs[row].name : "")
                    }
                    .font(.system(size: 10))
                    .padding(.horizontal, 4)
                    .frame(height: S7LadderMetrics.pinRowHeight)
                }
                if box.instruction.spec.expandableInputs || box.instruction.spec.expandableOutputs {
                    Button {
                        context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                            _ = network.addBoxInput(to: box.id)
                        }
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    .buttonStyle(.plain)
                    .help("Insert input")
                    .accessibilityLabel("Insert input")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.bottom, 2)
                }
            }
            .frame(width: S7LadderMetrics.boxWidth)
            .overlay(Rectangle().stroke(outline, lineWidth: 1.2))
        }
    }

    private var rowCount: Int { max(box.inputs.count, box.outputs.count) }

    private var outline: Color {
        box.instruction == .empty ? SiemensColors.placeholder : (status?.state == .satisfied ? SiemensColors.satisfied : Color.primary)
    }
}

/// The instance or bit operand above a box.
private struct S7BoxHeader: View {
    let box: S7Box
    let context: S7LadderContext

    var body: some View {
        if box.instruction.needsInstance || (box.instruction == .call && context.workspace.project.block(named: box.calledBlock)?.kind == .functionBlock) {
            S7OperandLabel(target: context.target(box.id, .slot(.instance)), text: box.instance, placeholderBool: false, context: context)
        } else if box.instruction.needsBitOperand {
            S7OperandLabel(target: context.target(box.id, .slot(.operand)), text: box.operand, placeholderBool: true, context: context)
        } else {
            Color.clear
        }
    }
}

private struct S7BoxTitleRow: View {
    let box: S7Box

    var body: some View {
        HStack(spacing: 2) {
            Text(box.instruction.spec.powerInput)
                .font(.system(size: 10))
            Spacer(minLength: 2)
            Text(box.instruction == .empty ? "??" : box.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(box.instruction == .empty ? SiemensColors.placeholder : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            Text(box.instruction.spec.powerOutput)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 4)
    }
}

/// "Int", "Auto (???)", "Int to Real": click to pick.
private struct S7BoxTypeLabel: View {
    let box: S7Box
    let typeLabel: String
    let context: S7LadderContext

    var body: some View {
        Menu {
            switch box.instruction.typing {
            case let .single(types):
                S7TypeMenu(title: "Data type", types: types, element: box.id, context: context)
            case let .pair(first, second):
                S7TypeMenu(title: "Input type", types: first, element: box.id, context: context)
                S7TypeMenu(title: "Output type", types: second, element: box.id, context: context, second: true)
            case .none:
                EmptyView()
            }
        } label: {
            Text(typeLabel)
                .font(.system(size: 10))
                .foregroundStyle(typeLabel.contains("???") ? SiemensColors.placeholder : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select the data type")
    }
}

/// The box's context menu: pick the instruction, types, add inputs, branches.
private struct S7BoxMenu: View {
    let box: S7Box
    let context: S7LadderContext

    var body: some View {
        Menu("Instruction") {
            ForEach(S7InstructionCatalog.basicInstructions) { folder in
                Menu(folder.title) {
                    ForEach(folder.entries.filter(\.isBox)) { entry in
                        Button(entry.title) { pick(entry) }
                    }
                }
            }
            let callable = context.workspace.project.blocks.filter { $0.kind != .organizationBlock && $0.id != context.blockID }
            if !callable.isEmpty {
                Menu("Program blocks") {
                    ForEach(callable) { block in
                        Button(block.displayName) {
                            context.workspace.setCall(block, box: box.id, network: context.networkID, inBlock: context.blockID)
                        }
                    }
                }
            }
        }
        if box.instruction.spec.expandableInputs || box.instruction.spec.expandableOutputs {
            Button("Insert input") {
                context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                    _ = network.addBoxInput(to: box.id)
                }
            }
        }
        let boolInputs = box.inputs.filter { pin in
            box.instruction.spec.inputs.contains { $0.name == pin.name && $0.type == .bool }
        }
        if !boolInputs.isEmpty {
            Menu("Connect input to a branch") {
                ForEach(boolInputs, id: \.name) { pin in
                    Button(pin.name) {
                        context.workspace.editNetwork(context.networkID, inBlock: context.blockID) { network in
                            _ = network.connectPinToBranch(pin.name, of: box.id)
                        }
                    }
                }
            }
        }
        S7CommonElementMenu(id: box.id, context: context)
    }

    private func pick(_ entry: S7CatalogEntry) {
        guard case let .box(instruction) = entry.kind else { return }
        context.workspace.setInstruction(instruction, box: box.id, network: context.networkID, inBlock: context.blockID)
    }
}

nonisolated extension S7CatalogEntry {
    var isBox: Bool {
        if case .box = kind { return true }
        return false
    }
}
