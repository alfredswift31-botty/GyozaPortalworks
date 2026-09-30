import CoreGraphics
import Foundation

/// Geometry of the ladder editor: row header, pointer column, 11 contact
/// columns and the wider coil/instruction column; rows grow for statements.
nonisolated struct MelsecLadderLayout: Hashable, Sendable {
    static let rowNumberWidth: CGFloat = 40
    static let pointerWidth: CGFloat = 34
    static let headerHeight: CGFloat = 20
    /// Cell widths when no pane width is known, and the smallest widths
    /// before the editor scrolls horizontally.
    static let defaultContactWidth: CGFloat = 76
    static let defaultCoilWidth: CGFloat = 170
    static let minimumContactWidth: CGFloat = 46
    static let minimumCoilWidth: CGFloat = 112
    /// The coil column is this many contact columns wide.
    static let coilRatio: CGFloat = 2.2
    static let rightMargin: CGFloat = 12
    static let rowHeight: CGFloat = 50
    static let statementHeight: CGFloat = 18
    /// Where the symbol's wire runs, from the top of the element area.
    static let wireOffset: CGFloat = 24

    /// Top of each row (0…rows.count, the last being END), after its statement band.
    let rowTops: [CGFloat]
    let statementRows: Set<Int>
    let contactWidth: CGFloat
    let coilWidth: CGFloat

    /// `availableWidth` is the editor pane's width: all 12 columns are fitted
    /// into it, as GX Works3 does, down to a minimum cell width below which
    /// the editor scrolls. 0 uses the default widths.
    init(ladder: MelsecLadder, availableWidth: CGFloat = 0) {
        if availableWidth > 0 {
            let usable = availableWidth - Self.busX - Self.rightMargin
            let unit = usable / (CGFloat(MelsecLadder.contactColumns) + Self.coilRatio)
            contactWidth = max(Self.minimumContactWidth, unit.rounded(.down))
            coilWidth = max(Self.minimumCoilWidth, (unit * Self.coilRatio).rounded(.down))
        } else {
            contactWidth = Self.defaultContactWidth
            coilWidth = Self.defaultCoilWidth
        }
        var tops: [CGFloat] = []
        var statements: Set<Int> = []
        var y = Self.headerHeight
        for index in 0...ladder.rows.count {
            if index < ladder.rows.count, !ladder.rows[index].statement.isEmpty {
                statements.insert(index)
                y += Self.statementHeight
            }
            tops.append(y)
            y += Self.rowHeight
        }
        tops.append(y)
        rowTops = tops
        statementRows = statements
    }

    /// The left bus.
    static var busX: CGFloat { rowNumberWidth + pointerWidth }

    func columnX(_ column: Int) -> CGFloat {
        Self.busX + CGFloat(min(column, MelsecLadder.contactColumns)) * contactWidth
    }

    func columnWidth(_ column: Int) -> CGFloat {
        column == MelsecLadder.coilColumn ? coilWidth : contactWidth
    }

    /// The right bus.
    var rightBusX: CGFloat { columnX(MelsecLadder.coilColumn) + coilWidth }

    var size: CGSize {
        CGSize(width: rightBusX + Self.rightMargin, height: (rowTops.last ?? 0) + 8)
    }

    func rowTop(_ row: Int) -> CGFloat {
        rowTops[max(0, min(row, rowTops.count - 1))]
    }

    /// The y of a row's wire.
    func wireY(_ row: Int) -> CGFloat {
        rowTop(row) + Self.wireOffset
    }

    func cellRect(_ cell: MelsecCellRef) -> CGRect {
        CGRect(x: columnX(cell.column), y: rowTop(cell.row), width: columnWidth(cell.column), height: Self.rowHeight)
    }

    /// The cell under a point, for clicks; nil outside the grid.
    func cell(at point: CGPoint, endRow: Int) -> MelsecCellRef? {
        guard point.x >= Self.busX, point.x < rightBusX, point.y >= Self.headerHeight else { return nil }
        guard let row = (0...endRow).last(where: { rowTop($0) <= point.y }) else { return nil }
        guard point.y < rowTop(row) + Self.rowHeight else { return nil }
        let column = min(Int((point.x - Self.busX) / contactWidth), MelsecLadder.coilColumn)
        return MelsecCellRef(row: row, column: column)
    }
}

/// Everything the ladder canvas draws, captured as plain values so the
/// drawing code doesn't touch the workspace.
nonisolated struct MelsecLadderDrawing: Sendable {
    var ladder: MelsecLadder
    var layout: MelsecLadderLayout
    var cursor: MelsecCellRef
    var isFocused: Bool
    var isMonitoring: Bool
    var errorCells: Set<MelsecCellRef>
    var energized: Set<MelsecCellRef>
    /// Monitored word values by operand text.
    var values: [String: String]
    /// Current values shown by timer/counter coils, by cell.
    var coilValues: [MelsecCellRef: String]
    /// Device comments by operand text.
    var comments: [String: String]
    /// Operand texts that are labels (drawn purple).
    var labels: Set<String>
    /// Step number at the start of each block, by first row.
    var blockSteps: [Int: Int]
    var endStep: Int?
    /// False for a display-only ladder, such as an exercise's reference.
    var showsCursor = true

    /// How an element is drawn.
    nonisolated enum Glyph: Hashable {
        case contact(MelsecContactKind)
        case comparison(String)
        case operationResult(MelsecOperationResultKind)
        case coil
        case instructionBox(String)
    }

    static func glyph(for element: MelsecLadderElement) -> Glyph? {
        switch element {
        case .empty, .line:
            return nil
        case let .contact(kind, _):
            return .contact(kind)
        case let .comparison(op, width, _):
            return .comparison(width.prefix + op.rawValue)
        case let .operationResult(kind):
            return .operationResult(kind)
        case let .output(mnemonic, _):
            return mnemonic == "OUT" ? .coil : .instructionBox(mnemonic)
        }
    }

    /// Operands shown over the symbol (a timer coil shows "T0 K50").
    static func operandText(for element: MelsecLadderElement) -> String {
        element.operands.joined(separator: " ")
    }
}
