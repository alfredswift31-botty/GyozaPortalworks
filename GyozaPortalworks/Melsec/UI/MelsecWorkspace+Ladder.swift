import CoreGraphics
import Foundation

/// Ladder editing: every key and menu command goes through `perform(_:)`.
extension MelsecWorkspace {
    /// The ladder program of the selected tab, if it is a ladder.
    var selectedLadderID: UUID? {
        guard let program = selectedProgram, program.language == .ladder else { return nil }
        return program.id
    }

    func cursor(for programID: UUID) -> MelsecCellRef {
        cursors[programID] ?? MelsecCellRef(row: 0, column: 0)
    }

    /// The element under the cursor of the selected ladder.
    var elementAtCursor: MelsecLadderElement {
        guard let id = selectedLadderID, let program = program(id) else { return .empty }
        return program.ladder[cursor(for: id)]
    }

    /// Runs a ladder command from a key, menu or toolbar button.
    func perform(_ command: MelsecLadderCommand) {
        statusMessage = nil
        switch command {
        case let .setMode(newMode):
            changeMode(to: newMode)
            return
        case .convert:
            convert(rebuildAll: false)
            return
        case .rebuildAll:
            convert(rebuildAll: true)
            return
        case .undo:
            undo()
            return
        case .redo:
            redo()
            return
        case .toggleBit:
            toggleBitAtCursor()
            return
        default:
            break
        }
        guard let id = selectedLadderID else { return }
        if command.edits, !mode.allowsEditing {
            statusMessage = "The ladder is read only in this mode: press F2 (Write Mode) to edit."
            return
        }
        switch command {
        case let .moveCursor(direction):
            var editor = MelsecLadderEditor(ladder: program(id)?.ladder ?? MelsecLadder(), cursor: cursor(for: id))
            editor.moveCursor(direction)
            cursors[id] = editor.cursor
        case let .ladderInput(symbol, text):
            sheet = .ladderInput(MelsecLadderInputState(symbol: defaultSymbol(symbol, text: text, id: id), text: text))
        case .editElement:
            let element = elementAtCursor
            let symbol: MelsecLadderSymbol = element.isOutput || cursor(for: id).column == MelsecLadder.coilColumn ? .coil : .openContact
            let text = element == .line ? "" : element.text
            sheet = .ladderInput(MelsecLadderInputState(symbol: symbol, text: text, isEditing: !element.isEmpty))
        case let .insertOperationResult(kind):
            edit(id) { try $0.insertOperationResult(kind) }
        case .drawHorizontalLine:
            edit(id) { try $0.drawHorizontalLine() }
        case .drawVerticalLine:
            edit(id) { try $0.drawVerticalLine() }
        case .deleteHorizontalLine:
            edit(id) { try $0.deleteHorizontalLine() }
        case .deleteVerticalLine:
            edit(id) { try $0.deleteVerticalLine() }
        case let .drawLine(direction):
            edit(id) { try $0.drawLine(direction) }
        case .insertRow:
            edit(id) { $0.insertRow() }
        case .deleteRow:
            edit(id) { try $0.deleteRow() }
        case .insertColumn:
            edit(id) { try $0.insertColumn() }
        case .deleteColumn:
            edit(id) { try $0.deleteColumn() }
        case .toggleInsertMode:
            setInsertMode(!isInsertMode)
        case .deleteElement:
            edit(id) { try $0.deleteElement() }
        case .setMode, .convert, .rebuildAll, .undo, .redo, .toggleBit:
            break
        }
    }

    /// Typing into the coil column starts a coil rather than a contact.
    private func defaultSymbol(_ symbol: MelsecLadderSymbol, text: String, id: UUID) -> MelsecLadderSymbol {
        guard symbol == .openContact, !text.isEmpty, cursor(for: id).column == MelsecLadder.coilColumn else { return symbol }
        return .coil
    }

    /// Runs an editor operation on a ladder as one undo step. Errors are
    /// shown in the status bar; nothing changes then.
    @discardableResult
    func edit(_ id: UUID, _ operation: (inout MelsecLadderEditor) throws -> Void) -> String? {
        guard let index = programIndex(id) else { return "The program no longer exists." }
        var editor = MelsecLadderEditor(ladder: project.programs[index].ladder, cursor: cursor(for: id), isInsertMode: isInsertMode)
        do {
            try operation(&editor)
        } catch let error as MelsecEditError {
            statusMessage = error.message
            return error.message
        } catch {
            statusMessage = "The ladder can't be edited here."
            return statusMessage
        }
        let ladder = editor.ladder
        mutate { $0.programs[index].ladder = ladder }
        cursors[id] = editor.cursor
        return nil
    }

    /// OK in the Ladder Input dialog. Returns the error to show in the
    /// dialog, or nil when the element was placed (the dialog closes).
    @discardableResult
    func confirmLadderInput(_ state: MelsecLadderInputState) -> String? {
        guard let id = selectedLadderID else {
            sheet = nil
            return nil
        }
        let text = state.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            sheet = nil
            return nil
        }
        if let error = edit(id, { try $0.enterLadderInput(text, symbol: state.symbol) }) {
            var failed = state
            failed.error = error
            sheet = .ladderInput(failed)
            return error
        }
        sheet = nil
        return nil
    }

    /// Element Selection: double-click opens Ladder Input with the mnemonic.
    func insertFromPalette(_ mnemonic: String) {
        guard let input = MelsecPaletteNode.ladderInput(for: mnemonic) else { return }
        guard selectedLadderID != nil else {
            statusMessage = "Open a ladder program to insert \(mnemonic)."
            return
        }
        guard mode.allowsEditing else {
            statusMessage = "The ladder is read only in this mode: press F2 (Write Mode) to edit."
            return
        }
        sheet = .ladderInput(MelsecLadderInputState(symbol: input.symbol, text: input.text))
    }

    // MARK: Clipboard

    /// Edit › Copy: the element at the cursor as Ladder Input text.
    var copiedElementText: String? {
        let element = elementAtCursor
        return element.isEmpty ? nil : element.text
    }

    func cutElement() -> String? {
        let text = copiedElementText
        if text != nil { perform(.deleteElement) }
        return text
    }

    func pasteElement(_ text: String) {
        guard let id = selectedLadderID, mode.allowsEditing else { return }
        if text == "-" {
            edit(id) { try $0.drawHorizontalLine() }
        } else if let element = MelsecLadderElement(text: text), !element.isEmpty {
            edit(id) { try $0.enterLadderInput(element.text, symbol: .openContact) }
        }
    }

    // MARK: Mode

    /// F2 / Shift+F2 / F3 / Shift+F3 / Alt+F3.
    func changeMode(to newMode: MelsecEditorMode) {
        if newMode.isMonitoring {
            guard let cpu, session != nil else {
                alert = MelsecAlert(title: "Monitor", message: "There is no connection to a CPU. Start the simulation first (Debug › Simulation › Start Simulation).")
                return
            }
            cpu.isMonitoring = true
            if unconvertedPrograms.contains(where: { writtenConversions[$0] != nil }) {
                statusMessage = "The program in the CPU doesn't match the edited program. Convert and write to the PLC to monitor the changes."
            }
        } else {
            cpu?.isMonitoring = false
        }
        setEditorMode(newMode)
        session?.refresh()
    }

    // MARK: Shift+Enter

    /// The device or label the cursor element acts on: the contact's operand,
    /// or the first operand of a coil or instruction.
    var operandAtCursor: String? {
        switch elementAtCursor {
        case let .contact(_, operand): return operand
        case let .output(mnemonic, operands):
            if mnemonic == "MC" { return operands.count > 1 ? operands[1] : nil }
            return operands.first
        default: return nil
        }
    }

    /// Shift+Enter (monitor mode): inverts the bit at the cursor in the CPU.
    func toggleBitAtCursor() {
        guard mode.isMonitoring, let cpu, let session else {
            statusMessage = "Shift+Enter changes a bit while monitoring (F3)."
            return
        }
        guard let operand = operandAtCursor, operand != "?" else {
            statusMessage = "There is no bit device at the cursor."
            return
        }
        do {
            try cpu.toggleBit(operand)
        } catch let error as MelsecOperandError {
            statusMessage = error.message
        } catch {
            statusMessage = "'\(operand)' cannot be changed."
        }
        session.refresh()
    }
}

// MARK: Drawing snapshot

extension MelsecWorkspace {
    /// What the ladder canvas draws for a program: elements, cursor, error
    /// and grey state, comments, and monitor values.
    func ladderDrawing(programID: UUID, isFocused: Bool, availableWidth: CGFloat = 0) -> MelsecLadderDrawing? {
        guard let program = program(programID) else { return nil }
        let ladder = program.ladder
        let profile = project.profile
        var comments: [String: String] = [:]
        var labels: Set<String> = []
        var values: [String: String] = [:]
        var coilValues: [MelsecCellRef: String] = [:]
        let monitoring = mode.isMonitoring && cpu != nil
        for (rowIndex, row) in ladder.rows.enumerated() {
            for (column, element) in row.cells.enumerated() {
                let operands = element.operands
                for operand in operands where operand != "?" {
                    switch try? MelsecOperandParser.parse(operand, profile: profile) {
                    case .label?:
                        labels.insert(operand)
                    case .constant?, .pointer?, .nesting?, nil:
                        break
                    default:
                        if let comment = project.comment(for: operand) {
                            comments[operand] = comment
                        }
                    }
                    if monitoring, values[operand] == nil, !isTimerOrCounter(operand, profile: profile) {
                        values[operand] = monitorValue(operand)
                    }
                }
                if monitoring, case let .output(mnemonic, outputOperands) = element,
                   ["OUT", "OUTH", "OUTHS"].contains(mnemonic), outputOperands.count == 2, let first = outputOperands.first {
                    coilValues[MelsecCellRef(row: rowIndex, column: column)] = monitorValue(first, isTimerCoil: true)
                }
            }
        }
        var energized: Set<MelsecCellRef> = []
        if monitoring, let cpu, let state = cpu.monitorState(program: program.name), let written = writtenConversions[programID] {
            for (cell, indices) in written.cellInstructions where indices.contains(where: { state.indices.contains($0) && state[$0] }) {
                energized.insert(cell)
            }
        }
        let conversion = conversions[programID]
        var blockSteps: [Int: Int] = [:]
        if let conversion, !ladder.hasUnconvertedRows {
            for block in conversion.blockSteps {
                blockSteps[block.rows.lowerBound] = block.step
            }
        }
        return MelsecLadderDrawing(
            ladder: ladder, layout: MelsecLadderLayout(ladder: ladder, availableWidth: availableWidth), cursor: cursor(for: programID), isFocused: isFocused,
            isMonitoring: monitoring, errorCells: Set((conversionErrors[programID] ?? []).map { MelsecCellRef(row: $0.row, column: $0.column) }),
            energized: energized, values: values, coilValues: coilValues, comments: comments, labels: labels,
            blockSteps: blockSteps, endStep: ladder.hasUnconvertedRows ? nil : conversion?.endStep)
    }

    private func isTimerOrCounter(_ operand: String, profile: MelsecCPUProfile) -> Bool {
        guard case let .device(device, _)? = try? MelsecOperandParser.parse(operand, profile: profile) else { return false }
        return device.kind.isTimerOrCounter && device.facet == .whole
    }

    /// The step at the cursor and the program size, for the status bar.
    func stepStatus(programID: UUID) -> (cursor: Int, total: Int)? {
        guard let conversion = conversions[programID], conversion.succeeded else { return nil }
        let total = conversion.endStep + 1
        let row = cursor(for: programID).row
        guard let program = program(programID), row < program.ladder.endRow else { return (conversion.endStep, total) }
        let step = conversion.blockSteps.last { $0.rows.lowerBound <= row }?.step ?? 0
        return (step, total)
    }
}
