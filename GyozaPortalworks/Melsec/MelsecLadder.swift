import Foundation

/// What one ladder cell holds.
nonisolated enum MelsecLadderElement: Hashable, Sendable {
    case empty
    /// A horizontal line (F9).
    case line
    case contact(MelsecContactKind, operand: String)
    /// A comparison contact: [= D0 K10], [D> D0 D2], [E< D0 E1.5].
    case comparison(ComparisonOperator, MelsecValueWidth, operands: [String])
    /// INV, MEP, MEF.
    case operationResult(MelsecOperationResultKind)
    /// A coil or application instruction, always in the coil column.
    case output(mnemonic: String, operands: [String])

    var isEmpty: Bool { self == .empty }

    var isOutput: Bool {
        if case .output = self { return true }
        return false
    }

    /// Contacts, comparisons and INV/MEP/MEF: elements current flows through.
    var isConnector: Bool {
        switch self {
        case .contact, .comparison, .operationResult: return true
        default: return false
        }
    }

    /// The operand texts, in order.
    var operands: [String] {
        switch self {
        case let .contact(_, operand): return [operand]
        case let .comparison(_, _, operands), let .output(_, operands): return operands
        default: return []
        }
    }

    /// Ladder Input text: "LD X0", "LDI X0", "LD>= D0 K10", "INV",
    /// "OUT T0 K50", "-" for a line and "" for an empty cell. Contacts and
    /// comparisons use their LD form.
    var text: String {
        switch self {
        case .empty:
            return ""
        case .line:
            return "-"
        case let .contact(kind, operand):
            return "\(kind.mnemonic(.load)) \(operand)"
        case let .comparison(op, width, operands):
            return (["LD" + width.prefix + op.rawValue] + operands).joined(separator: " ")
        case let .operationResult(kind):
            return kind.rawValue
        case let .output(mnemonic, operands):
            return ([mnemonic] + operands).joined(separator: " ")
        }
    }

    /// Reads `text` back (the inverse of `text`).
    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            self = .empty
            return
        }
        if trimmed == "-" {
            self = .line
            return
        }
        guard case let .element(element, _, _)? = try? MelsecLadderInput.parse(trimmed, symbol: .openContact) else {
            return nil
        }
        self = element
    }
}

/// One row of the ladder: 11 contact columns and the coil column.
nonisolated struct MelsecLadderRow: Hashable, Sendable, Codable {
    var cells: [MelsecLadderElement]
    /// `verticalLines[b]`: a vertical line from this row down to the next at
    /// the left edge of column b (b = 1…11; 0 would be the left bus).
    var verticalLines: [Bool]
    /// Line statement shown above the block ("; text").
    var statement: String
    /// Note shown next to the coil or instruction of this row.
    var note: String
    /// Pointer label (P0) in front of the block that starts at this row.
    var pointer: Int?
    /// Edited since the last conversion (drawn grey in GX Works3).
    var isUnconverted: Bool

    init() {
        cells = Array(repeating: .empty, count: MelsecLadder.columnCount)
        verticalLines = Array(repeating: false, count: MelsecLadder.columnCount)
        statement = ""
        note = ""
        pointer = nil
        isUnconverted = true
    }

    var isBlank: Bool {
        cells.allSatisfy(\.isEmpty) && !verticalLines.contains(true) && statement.isEmpty && pointer == nil
    }

    var hasVerticalLine: Bool { verticalLines.contains(true) }

    private enum CodingKeys: String, CodingKey {
        case cells, verticalLines, statement, note, pointer, isUnconverted
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let texts = try container.decodeIfPresent([String].self, forKey: .cells) ?? []
        for (index, text) in texts.prefix(MelsecLadder.columnCount).enumerated() {
            cells[index] = MelsecLadderElement(text: text) ?? .empty
        }
        let lines = try container.decodeIfPresent([Int].self, forKey: .verticalLines) ?? []
        for boundary in lines where (1..<MelsecLadder.columnCount).contains(boundary) {
            verticalLines[boundary] = true
        }
        statement = try container.decodeIfPresent(String.self, forKey: .statement) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        pointer = try container.decodeIfPresent(Int.self, forKey: .pointer)
        isUnconverted = try container.decodeIfPresent(Bool.self, forKey: .isUnconverted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cells.map(\.text), forKey: .cells)
        try container.encode(verticalLines.indices.filter { verticalLines[$0] }, forKey: .verticalLines)
        try container.encode(statement, forKey: .statement)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(pointer, forKey: .pointer)
        try container.encode(isUnconverted, forKey: .isUnconverted)
    }
}

/// A ladder program as GX Works3's editor shows it: rows of 12 cells
/// (header 1…12), followed by the END block, which is always last and
/// cannot be deleted. Row `rows.count` is the END row.
nonisolated struct MelsecLadder: Hashable, Sendable, Codable {
    static let columnCount = 12
    static let contactColumns = 11
    static let coilColumn = 11

    var rows: [MelsecLadderRow]
    /// Pointer label on the END block (CJ P… to the end of the program).
    var endPointer: Int?

    init(rows: [MelsecLadderRow] = [], endPointer: Int? = nil) {
        self.rows = rows
        self.endPointer = endPointer
    }

    private enum CodingKeys: String, CodingKey {
        case rows, endPointer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent([MelsecLadderRow].self, forKey: .rows) ?? []
        endPointer = try container.decodeIfPresent(Int.self, forKey: .endPointer)
    }

    /// The row index of the END block.
    var endRow: Int { rows.count }

    subscript(cell: MelsecCellRef) -> MelsecLadderElement {
        guard rows.indices.contains(cell.row), (0..<MelsecLadder.columnCount).contains(cell.column) else { return .empty }
        return rows[cell.row].cells[cell.column]
    }

    /// Ladder blocks: runs of rows joined by vertical lines. Blank rows
    /// (nothing drawn, no statement) belong to no block.
    func blocks() -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for index in rows.indices {
            let row = rows[index]
            let joinedAbove = index > 0 && rows[index - 1].hasVerticalLine
            if start == nil {
                if row.isBlank && !joinedAbove { continue }
                start = index
            } else if !joinedAbove {
                if let begin = start { result.append(begin..<index) }
                start = row.isBlank ? nil : index
            }
        }
        if let begin = start { result.append(begin..<rows.count) }
        return result
    }

    /// The block a row belongs to.
    func block(containing row: Int) -> Range<Int>? {
        blocks().first { $0.contains(row) }
    }

    var hasUnconvertedRows: Bool { rows.contains { $0.isUnconverted } }

    /// Clears the grey "unconverted" state after a successful conversion.
    mutating func markConverted() {
        for index in rows.indices {
            rows[index].isUnconverted = false
        }
    }

    /// Removes blank rows, as conversion does in GX Works3.
    mutating func removeBlankRows() {
        var kept: [MelsecLadderRow] = []
        for (index, row) in rows.enumerated() {
            let joinedAbove = index > 0 && rows[index - 1].hasVerticalLine
            if row.isBlank && !joinedAbove { continue }
            kept.append(row)
        }
        rows = kept
    }
}

/// The symbol chosen in the Ladder Input dialog; used when only an operand
/// is typed ("X0").
nonisolated enum MelsecLadderSymbol: Hashable, Sendable {
    case openContact
    case openBranch
    case closeContact
    case closeBranch
    case risingPulse
    case fallingPulse
    case risingPulseBranch
    case fallingPulseBranch
    case coil
    case instruction
}

/// What a Ladder Input text means.
nonisolated enum MelsecLadderInputResult: Hashable, Sendable {
    /// An element; `branch` places a contact as an OR branch.
    case element(MelsecLadderElement, branch: Bool, note: String?)
    /// "; text": a line statement.
    case statement(String)
}

/// Why an edit can't be made; the message is shown to the user.
nonisolated struct MelsecEditError: Error, Hashable, Sendable {
    var message: String
}

/// Parses the text typed into the Ladder Input dialog.
nonisolated enum MelsecLadderInput {
    static func parse(_ rawText: String, symbol: MelsecLadderSymbol) throws -> MelsecLadderInputResult {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(";") {
            return .statement(String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        var body = text
        var note: String?
        if let semicolon = text.firstIndex(of: ";") {
            body = String(text[..<semicolon])
            note = String(text[text.index(after: semicolon)...]).trimmingCharacters(in: .whitespaces)
        }
        var tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first else {
            throw MelsecEditError(message: "Enter an instruction or a device.")
        }

        let definition: MelsecInstructionDefinition
        if let found = MelsecInstructionSet.definition(first) {
            definition = found
            tokens.removeFirst()
        } else {
            switch symbol {
            case .openContact, .openBranch, .closeContact, .closeBranch,
                 .risingPulse, .fallingPulse, .risingPulseBranch, .fallingPulseBranch:
                guard tokens.count == 1 else {
                    throw MelsecEditError(message: "'\(first)': the instruction does not exist.")
                }
                let (kind, branch) = contact(for: symbol)
                return .element(.contact(kind, operand: first), branch: branch, note: note)
            case .coil:
                guard let out = MelsecInstructionSet.definition("OUT") else {
                    throw MelsecEditError(message: "OUT is not available.")
                }
                definition = out
            case .instruction:
                throw MelsecEditError(message: "'\(first)': the instruction does not exist.")
            }
        }

        switch definition.kind {
        case let .contact(kind, position):
            guard tokens.count <= 1 else {
                throw MelsecEditError(message: "\(definition.mnemonic) takes one operand.")
            }
            return .element(.contact(kind, operand: tokens.first ?? "?"), branch: position == .or, note: note)
        case let .comparison(op, width, position):
            guard tokens.count <= 2 else {
                throw MelsecEditError(message: "\(definition.mnemonic) takes two operands.")
            }
            let operands = tokens + Array(repeating: "?", count: 2 - tokens.count)
            return .element(.comparison(op, width, operands: operands), branch: position == .or, note: note)
        case let .operationResult(kind):
            guard tokens.isEmpty else {
                throw MelsecEditError(message: "\(definition.mnemonic) has no operands.")
            }
            return .element(.operationResult(kind), branch: false, note: note)
        case .blockAnd, .blockOr, .push, .read, .pop, .pointerLabel:
            throw MelsecEditError(message: "\(definition.mnemonic) cannot be entered in the ladder: draw the lines instead.")
        default:
            let operands = try paddedOperands(definition, tokens)
            return .element(.output(mnemonic: definition.mnemonic, operands: operands), branch: false, note: note)
        }
    }

    private static func contact(for symbol: MelsecLadderSymbol) -> (MelsecContactKind, Bool) {
        switch symbol {
        case .openBranch: return (.normallyOpen, true)
        case .closeContact: return (.normallyClosed, false)
        case .closeBranch: return (.normallyClosed, true)
        case .risingPulse: return (.risingEdge, false)
        case .fallingPulse: return (.fallingEdge, false)
        case .risingPulseBranch: return (.risingEdge, true)
        case .fallingPulseBranch: return (.fallingEdge, true)
        default: return (.normallyOpen, false)
        }
    }

    /// Fills missing operands with "?", choosing the form the operands fit.
    private static func paddedOperands(_ definition: MelsecInstructionDefinition, _ tokens: [String]) throws -> [String] {
        let counts = definition.operandCounts.sorted()
        if definition.kind == .output, tokens.count == 1, isTimerOrCounter(tokens[0]) {
            return tokens + ["?"]
        }
        if counts.contains(tokens.count) { return tokens }
        guard let target = counts.first(where: { $0 > tokens.count }) else {
            throw MelsecEditError(message: "\(definition.mnemonic) takes at most \(counts.last ?? 0) operands.")
        }
        return tokens + Array(repeating: "?", count: target - tokens.count)
    }

    private static func isTimerOrCounter(_ text: String) -> Bool {
        guard case let .device(device, _)? = try? MelsecOperandParser.parse(text, profile: .fx5u) else { return false }
        return device.kind.isTimerOrCounter && device.facet == .whole
    }
}

/// Cursor directions for moving and Ctrl+arrow line drawing.
nonisolated enum MelsecDirection: Hashable, Sendable {
    case left, right, up, down
}

/// The ladder editor's document state and GX Works3's editing operations.
/// The UI maps keys to these: F5 `insertContact(.normallyOpen, …)`,
/// Shift+F5 the same with `branch: true`, F6/Shift+F6 close contacts,
/// Shift+F7/Shift+F8 rising/falling pulse, Alt+F7/Alt+F8 their branches,
/// F7 `insertCoil`, F8 `insertInstruction`, Alt+F5 MEP, Ctrl+Alt+F5 MEF,
/// Ctrl+Alt+F10 INV, F9/Shift+F9 lines, Ctrl+F9/Ctrl+F10 delete lines,
/// Ctrl+arrows `drawLine`, Shift+Insert/Delete rows, Ctrl+Insert/Delete
/// columns, Insert `toggleInsertMode`.
nonisolated struct MelsecLadderEditor: Hashable, Sendable {
    var ladder: MelsecLadder
    var cursor: MelsecCellRef
    /// GX Works3 starts in overwrite mode; the Insert key toggles.
    var isInsertMode: Bool

    init(ladder: MelsecLadder = MelsecLadder(), cursor: MelsecCellRef = MelsecCellRef(row: 0, column: 0), isInsertMode: Bool = false) {
        self.ladder = ladder
        self.cursor = cursor
        self.isInsertMode = isInsertMode
    }

    // MARK: Cursor

    mutating func moveCursor(to cell: MelsecCellRef) {
        cursor = MelsecCellRef(row: min(max(cell.row, 0), ladder.endRow),
                               column: min(max(cell.column, 0), MelsecLadder.coilColumn))
    }

    mutating func moveCursor(_ direction: MelsecDirection) {
        switch direction {
        case .left: moveCursor(to: MelsecCellRef(row: cursor.row, column: cursor.column - 1))
        case .right: moveCursor(to: MelsecCellRef(row: cursor.row, column: cursor.column + 1))
        case .up: moveCursor(to: MelsecCellRef(row: cursor.row - 1, column: cursor.column))
        case .down: moveCursor(to: MelsecCellRef(row: cursor.row + 1, column: cursor.column))
        }
    }

    mutating func toggleInsertMode() {
        isInsertMode.toggle()
    }

    // MARK: Elements

    /// F5 / F6 / Shift+F7 / Shift+F8 (branch: false) and Shift+F5 / Shift+F6
    /// / Alt+F7 / Alt+F8 (branch: true).
    mutating func insertContact(_ kind: MelsecContactKind, operand: String, branch: Bool = false) throws {
        try placeConnector(.contact(kind, operand: operand), branch: branch)
    }

    /// F5 / F6 and their branch forms, named by the contact.
    mutating func insertContact(normallyOpen: Bool, operand: String, branch: Bool = false) throws {
        try insertContact(normallyOpen ? .normallyOpen : .normallyClosed, operand: operand, branch: branch)
    }

    /// Comparison contact ([>= D0 K10]).
    mutating func insertComparison(_ op: ComparisonOperator, width: MelsecValueWidth = .word,
                                   operands: [String], branch: Bool = false) throws {
        let padded = Array((operands + ["?", "?"]).prefix(2))
        try placeConnector(.comparison(op, width, operands: padded), branch: branch)
    }

    /// Alt+F5 (MEP), Ctrl+Alt+F5 (MEF), Ctrl+Alt+F10 (INV).
    mutating func insertOperationResult(_ kind: MelsecOperationResultKind) throws {
        try placeConnector(.operationResult(kind), branch: false)
    }

    /// F7: OUT coil (a timer or counter takes its set value as second operand).
    mutating func insertCoil(operands: [String]) throws {
        try insertInstruction(mnemonic: "OUT", operands: operands)
    }

    /// F8: an application or output instruction, right-aligned into the
    /// coil column and joined to the cursor by a horizontal line.
    mutating func insertInstruction(mnemonic: String, operands: [String], note: String? = nil) throws {
        guard let definition = MelsecInstructionSet.definition(mnemonic), definition.isOutput else {
            throw MelsecEditError(message: "'\(mnemonic)': the instruction does not exist or is not an output.")
        }
        try placeOutput(.output(mnemonic: definition.mnemonic, operands: operands), note: note)
    }

    /// Applies text typed into the Ladder Input dialog at the cursor.
    mutating func enterLadderInput(_ text: String, symbol: MelsecLadderSymbol = .openContact) throws {
        switch try MelsecLadderInput.parse(text, symbol: symbol) {
        case let .statement(statement):
            let row = try rowForEditing()
            let target = ladder.block(containing: row)?.lowerBound ?? row
            ladder.rows[target].statement = statement
            ladder.rows[target].isUnconverted = true
        case let .element(element, branch, note):
            if element.isOutput {
                try placeOutput(element, note: note)
            } else {
                try placeConnector(element, branch: branch)
            }
        }
    }

    /// Delete key: clears the cell at the cursor.
    mutating func deleteElement() throws {
        guard cursor.row < ladder.endRow else {
            throw MelsecEditError(message: "END cannot be deleted.")
        }
        ladder.rows[cursor.row].cells[cursor.column] = .empty
        if cursor.column == MelsecLadder.coilColumn {
            ladder.rows[cursor.row].note = ""
        }
        ladder.rows[cursor.row].isUnconverted = true
    }

    mutating func setStatement(_ text: String) throws {
        let row = try rowForEditing()
        ladder.rows[row].statement = text
        ladder.rows[row].isUnconverted = true
    }

    mutating func setNote(_ text: String) throws {
        let row = try rowForEditing()
        ladder.rows[row].note = text
    }

    /// Sets (or clears) the pointer label of the block at the cursor.
    mutating func setPointer(_ number: Int?) throws {
        if cursor.row == ladder.endRow {
            ladder.endPointer = number
            return
        }
        let row = ladder.block(containing: cursor.row)?.lowerBound ?? cursor.row
        ladder.rows[row].pointer = number
        ladder.rows[row].isUnconverted = true
    }

    // MARK: Lines

    /// F9: horizontal line at the cursor.
    mutating func drawHorizontalLine() throws {
        guard cursor.column < MelsecLadder.coilColumn else {
            throw MelsecEditError(message: "A line cannot be drawn in the coil column.")
        }
        let row = try rowForEditing()
        ladder.rows[row].cells[cursor.column] = .line
        ladder.rows[row].isUnconverted = true
        moveCursor(.right)
    }

    /// Shift+F9: vertical line down from the left edge of the cursor cell.
    mutating func drawVerticalLine() throws {
        try setVertical(row: cursor.row, boundary: cursor.column, true)
        moveCursor(.down)
    }

    /// Ctrl+F9: deletes the horizontal line at the cursor.
    mutating func deleteHorizontalLine() throws {
        guard cursor.row < ladder.endRow, ladder.rows[cursor.row].cells[cursor.column] == .line else {
            throw MelsecEditError(message: "There is no horizontal line at the cursor.")
        }
        ladder.rows[cursor.row].cells[cursor.column] = .empty
        ladder.rows[cursor.row].isUnconverted = true
        moveCursor(.right)
    }

    /// Ctrl+F10: deletes the vertical line down from the left edge of the cursor cell.
    mutating func deleteVerticalLine() throws {
        guard cursor.row < ladder.endRow, cursor.column > 0, ladder.rows[cursor.row].verticalLines[cursor.column] else {
            throw MelsecEditError(message: "There is no vertical line at the cursor.")
        }
        ladder.rows[cursor.row].verticalLines[cursor.column] = false
        ladder.rows[cursor.row].isUnconverted = true
        moveCursor(.down)
    }

    /// Ctrl+arrow: draws a line while moving the cursor.
    mutating func drawLine(_ direction: MelsecDirection) throws {
        switch direction {
        case .right:
            try drawHorizontalLine()
        case .left:
            guard cursor.column > 0 else { throw MelsecEditError(message: "The cursor is at the left bus.") }
            moveCursor(.left)
            let row = try rowForEditing()
            ladder.rows[row].cells[cursor.column] = .line
            ladder.rows[row].isUnconverted = true
        case .down:
            try drawVerticalLine()
        case .up:
            guard cursor.row > 0 else { throw MelsecEditError(message: "There is no row above.") }
            try setVertical(row: cursor.row - 1, boundary: cursor.column, true)
            moveCursor(.up)
        }
    }

    // MARK: Rows and columns

    /// Shift+Insert: inserts an empty row at the cursor. Vertical lines that
    /// crossed into the cursor row continue through the new row.
    mutating func insertRow() {
        let index = min(cursor.row, ladder.endRow)
        var row = MelsecLadderRow()
        if index > 0 {
            row.verticalLines = ladder.rows[index - 1].verticalLines
        }
        ladder.rows.insert(row, at: index)
    }

    /// Shift+Delete: deletes the cursor row (END cannot be deleted).
    mutating func deleteRow() throws {
        guard cursor.row < ladder.endRow else {
            throw MelsecEditError(message: "END cannot be deleted.")
        }
        ladder.rows.remove(at: cursor.row)
        if cursor.row > 0 {
            ladder.rows[cursor.row - 1].isUnconverted = true
        }
        if cursor.row < ladder.endRow {
            ladder.rows[cursor.row].isUnconverted = true
        }
        moveCursor(to: cursor)
    }

    /// Ctrl+Insert: inserts a column at the cursor in every row of the block.
    /// Column 11's contents drop off (it must be empty or a line).
    mutating func insertColumn() throws {
        guard cursor.column < MelsecLadder.coilColumn else {
            throw MelsecEditError(message: "A column cannot be inserted in the coil column.")
        }
        let rows = try blockRowsForEditing()
        let column = cursor.column
        let last = MelsecLadder.coilColumn - 1
        if rows.contains(where: { !(ladder.rows[$0].cells[last].isEmpty || ladder.rows[$0].cells[last] == .line) }) {
            throw MelsecEditError(message: "There is no room to insert a column: column 11 is in use.")
        }
        for index in rows {
            var row = ladder.rows[index]
            let joined = !row.cells[column].isEmpty && (column == 0 || !row.cells[column - 1].isEmpty)
            row.cells.remove(at: last)
            row.cells.insert(joined ? .line : .empty, at: column)
            var lines = Array(repeating: false, count: MelsecLadder.columnCount)
            for boundary in 1..<MelsecLadder.columnCount where row.verticalLines[boundary] {
                lines[boundary <= column ? boundary : min(boundary + 1, MelsecLadder.coilColumn)] = true
            }
            row.verticalLines = lines
            row.isUnconverted = true
            ladder.rows[index] = row
        }
    }

    /// Ctrl+Delete: deletes the cursor column in every row of the block.
    mutating func deleteColumn() throws {
        guard cursor.column < MelsecLadder.coilColumn else {
            throw MelsecEditError(message: "The coil column cannot be deleted.")
        }
        let rows = try blockRowsForEditing()
        let column = cursor.column
        let last = MelsecLadder.coilColumn - 1
        for index in rows {
            var row = ladder.rows[index]
            let lastWasUsed = !row.cells[last].isEmpty
            row.cells.remove(at: column)
            let fill: MelsecLadderElement = row.cells[last].isOutput && lastWasUsed ? .line : .empty
            row.cells.insert(fill, at: last)
            var lines = Array(repeating: false, count: MelsecLadder.columnCount)
            for boundary in 1..<MelsecLadder.columnCount where row.verticalLines[boundary] {
                let target: Int
                if boundary <= column {
                    target = boundary
                } else if boundary == MelsecLadder.coilColumn {
                    target = boundary
                } else {
                    target = boundary - 1
                }
                if target > 0 { lines[target] = true }
            }
            row.verticalLines = lines
            row.isUnconverted = true
            ladder.rows[index] = row
        }
    }

    // MARK: Helpers

    /// The cursor row, creating a row in front of END when the cursor is on it.
    private mutating func rowForEditing() throws -> Int {
        if cursor.row >= ladder.endRow {
            ladder.rows.append(MelsecLadderRow())
            cursor.row = ladder.endRow - 1
        }
        return cursor.row
    }

    private func blockRowsForEditing() throws -> Range<Int> {
        guard cursor.row < ladder.endRow else {
            throw MelsecEditError(message: "Columns cannot be changed in the END block.")
        }
        return ladder.block(containing: cursor.row) ?? cursor.row..<(cursor.row + 1)
    }

    private mutating func setVertical(row: Int, boundary: Int, _ value: Bool) throws {
        guard boundary > 0, boundary < MelsecLadder.columnCount else {
            throw MelsecEditError(message: "A vertical line cannot be drawn on the left bus.")
        }
        guard row >= 0, row <= ladder.endRow else {
            throw MelsecEditError(message: "There is no row there.")
        }
        if row == ladder.endRow {
            ladder.rows.append(MelsecLadderRow())
        }
        if row + 1 == ladder.endRow {
            ladder.rows.append(MelsecLadderRow())
        }
        ladder.rows[row].verticalLines[boundary] = value
        ladder.rows[row].isUnconverted = true
        ladder.rows[row + 1].isUnconverted = true
    }

    /// Places a contact, comparison or INV/MEP/MEF at the cursor. A branch
    /// is joined to the row above by vertical lines on both sides.
    private mutating func placeConnector(_ element: MelsecLadderElement, branch: Bool) throws {
        guard cursor.column < MelsecLadder.coilColumn else {
            throw MelsecEditError(message: "Contacts cannot be placed in the coil column.")
        }
        if branch, cursor.row == 0 {
            throw MelsecEditError(message: "An OR branch needs a ladder above it.")
        }
        let row = try rowForEditing()
        let column = cursor.column
        if isInsertMode, !ladder.rows[row].cells[column].isEmpty {
            guard ladder.rows[row].cells[MelsecLadder.coilColumn - 1].isEmpty
                    || ladder.rows[row].cells[MelsecLadder.coilColumn - 1] == .line else {
                throw MelsecEditError(message: "There is no room to insert: column 11 is in use.")
            }
            ladder.rows[row].cells.remove(at: MelsecLadder.coilColumn - 1)
            ladder.rows[row].cells.insert(element, at: column)
        } else {
            ladder.rows[row].cells[column] = element
        }
        ladder.rows[row].isUnconverted = true
        if branch {
            ladder.rows[row - 1].verticalLines[column + 1] = true
            if column > 0 {
                ladder.rows[row - 1].verticalLines[column] = true
            }
            ladder.rows[row - 1].isUnconverted = true
        }
        moveCursor(.right)
    }

    /// Places a coil or instruction in the coil column of the cursor row and
    /// fills the empty cells from the cursor to it with a line.
    private mutating func placeOutput(_ element: MelsecLadderElement, note: String?) throws {
        let row = try rowForEditing()
        for column in cursor.column..<MelsecLadder.coilColumn where ladder.rows[row].cells[column].isEmpty {
            ladder.rows[row].cells[column] = .line
        }
        ladder.rows[row].cells[MelsecLadder.coilColumn] = element
        if let note {
            ladder.rows[row].note = note
        }
        ladder.rows[row].isUnconverted = true
        moveCursor(to: MelsecCellRef(row: row + 1, column: 0))
    }
}
