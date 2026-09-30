import SwiftUI

/// The ladder canvas: draws a `MelsecLadderDrawing` GX Works3-style.
struct MelsecLadderCanvas: View {
    let drawing: MelsecLadderDrawing
    let accent: Color

    var body: some View {
        Canvas { context, _ in
            MelsecLadderRenderer(drawing: drawing, accent: accent).draw(in: context)
        }
        .frame(width: drawing.layout.size.width, height: drawing.layout.size.height)
        .accessibilityLabel("Ladder editor")
    }
}

/// Drawing code for the ladder canvas.
struct MelsecLadderRenderer {
    let drawing: MelsecLadderDrawing
    let accent: Color

    private var layout: MelsecLadderLayout { drawing.layout }
    private var wire: Color { .primary }
    private var monitorBlue: Color { Color(red: 0.12, green: 0.45, blue: 1.0) }
    private var commentGreen: Color { Color(red: 0.12, green: 0.58, blue: 0.24) }
    private var labelPurple: Color { .purple }
    private var valueBlue: Color { Color(red: 0.1, green: 0.4, blue: 0.95) }

    func draw(in context: GraphicsContext) {
        drawHeader(context)
        let endRow = drawing.ladder.endRow
        for row in 0...endRow {
            drawRowBackground(context, row: row)
        }
        drawBuses(context)
        for row in 0..<endRow {
            drawRow(context, row: row)
        }
        drawEnd(context)
        drawCursor(context)
    }

    // MARK: Frame

    private func text(_ context: GraphicsContext, _ string: String, at point: CGPoint, size: CGFloat = 10,
                      color: Color = .primary, weight: Font.Weight = .regular, anchor: UnitPoint = .center) {
        guard !string.isEmpty else { return }
        context.draw(Text(string).font(.system(size: size, weight: weight, design: .monospaced)).foregroundColor(color),
                     at: point, anchor: anchor)
    }

    private func line(_ context: GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color? = nil, width: CGFloat = 1) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color ?? wire), lineWidth: width)
    }

    private func drawHeader(_ context: GraphicsContext) {
        let band = CGRect(x: 0, y: 0, width: layout.size.width, height: MelsecLadderLayout.headerHeight)
        context.fill(Path(band), with: .color(Color.gray.opacity(0.15)))
        for column in 0..<MelsecLadder.columnCount {
            let x = layout.columnX(column) + layout.columnWidth(column) / 2
            text(context, "\(column + 1)", at: CGPoint(x: x, y: MelsecLadderLayout.headerHeight / 2), color: .secondary)
        }
    }

    private func drawRowBackground(_ context: GraphicsContext, row: Int) {
        let top = layout.rowTop(row)
        if row < drawing.ladder.rows.count {
            let data = drawing.ladder.rows[row]
            if data.isUnconverted {
                let rect = CGRect(x: MelsecLadderLayout.busX, y: top, width: layout.rightBusX - MelsecLadderLayout.busX,
                                  height: MelsecLadderLayout.rowHeight)
                context.fill(Path(rect), with: .color(Color.gray.opacity(0.18)))
            }
            if layout.statementRows.contains(row) {
                let band = CGRect(x: MelsecLadderLayout.busX, y: top - MelsecLadderLayout.statementHeight,
                                  width: layout.rightBusX - MelsecLadderLayout.busX, height: MelsecLadderLayout.statementHeight)
                context.fill(Path(band), with: .color(commentGreen.opacity(0.18)))
                text(context, "; " + data.statement, at: CGPoint(x: band.minX + 6, y: band.midY), color: commentGreen, anchor: .leading)
            }
            if let pointer = data.pointer {
                text(context, "P\(pointer)", at: CGPoint(x: MelsecLadderLayout.rowNumberWidth + MelsecLadderLayout.pointerWidth / 2,
                                                         y: layout.wireY(row)), weight: .semibold)
            }
        }
        for column in 0..<MelsecLadder.columnCount where drawing.errorCells.contains(MelsecCellRef(row: row, column: column)) {
            context.fill(Path(layout.cellRect(MelsecCellRef(row: row, column: column))), with: .color(Color.yellow.opacity(0.45)))
        }
        text(context, "\(row + 1)", at: CGPoint(x: 4, y: top + 8), size: 9, color: .secondary, anchor: .leading)
        if let step = row == drawing.ladder.endRow ? drawing.endStep : drawing.blockSteps[row] {
            text(context, "(\(step))", at: CGPoint(x: 4, y: layout.wireY(row)), size: 9, color: .secondary, anchor: .leading)
        }
    }

    private func drawBuses(_ context: GraphicsContext) {
        let top = MelsecLadderLayout.headerHeight
        let bottom = layout.rowTop(drawing.ladder.endRow) + MelsecLadderLayout.rowHeight
        line(context, from: CGPoint(x: MelsecLadderLayout.busX, y: top), to: CGPoint(x: MelsecLadderLayout.busX, y: bottom), width: 2)
        line(context, from: CGPoint(x: layout.rightBusX, y: top), to: CGPoint(x: layout.rightBusX, y: bottom),
             color: Color.secondary.opacity(0.6), width: 1)
    }

    private func drawCursor(_ context: GraphicsContext) {
        guard drawing.showsCursor else { return }
        let rect = layout.cellRect(drawing.cursor).insetBy(dx: 1, dy: 1)
        context.stroke(Path(rect), with: .color(drawing.isFocused ? accent : Color.secondary), lineWidth: 2)
    }

    private func drawEnd(_ context: GraphicsContext) {
        let row = drawing.ladder.endRow
        let y = layout.wireY(row)
        let box = CGRect(x: layout.columnX(MelsecLadder.coilColumn) + 20, y: y - 10, width: layout.coilWidth - 40, height: 20)
        line(context, from: CGPoint(x: MelsecLadderLayout.busX, y: y), to: CGPoint(x: box.minX, y: y))
        context.stroke(Path(box), with: .color(wire), lineWidth: 1)
        text(context, "END", at: CGPoint(x: box.midX, y: y), size: 11, weight: .semibold)
        if let pointer = drawing.ladder.endPointer {
            text(context, "P\(pointer)", at: CGPoint(x: MelsecLadderLayout.rowNumberWidth + MelsecLadderLayout.pointerWidth / 2, y: y),
                 weight: .semibold)
        }
    }

    // MARK: Rows

    private func drawRow(_ context: GraphicsContext, row: Int) {
        let data = drawing.ladder.rows[row]
        let y = layout.wireY(row)
        for (column, element) in data.cells.enumerated() {
            let cell = MelsecCellRef(row: row, column: column)
            let rect = layout.cellRect(cell)
            switch element {
            case .empty:
                continue
            case .line:
                line(context, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y))
            default:
                drawElement(context, element, cell: cell, rect: rect, y: y)
            }
        }
        for boundary in 1..<MelsecLadder.columnCount where data.verticalLines[boundary] {
            let x = layout.columnX(boundary)
            line(context, from: CGPoint(x: x, y: y), to: CGPoint(x: x, y: layout.wireY(row + 1)))
        }
        if !data.note.isEmpty {
            let x = layout.columnX(MelsecLadder.coilColumn) + 4
            text(context, data.note, at: CGPoint(x: x, y: layout.rowTop(row) + MelsecLadderLayout.rowHeight - 6), size: 9,
                 color: commentGreen, anchor: .leading)
        }
    }

    private func drawElement(_ context: GraphicsContext, _ element: MelsecLadderElement, cell: MelsecCellRef, rect: CGRect, y: CGFloat) {
        guard let glyph = MelsecLadderDrawing.glyph(for: element) else { return }
        let on = drawing.energized.contains(cell)
        let operands = element.operands
        switch glyph {
        case let .contact(kind):
            drawContact(context, kind: kind, rect: rect, y: y, on: on)
            drawOperand(context, operands.first ?? "", rect: rect, y: y)
        case let .comparison(symbol):
            drawBox(context, title: "[\(symbol) \(operands.joined(separator: " "))]", rect: rect, y: y, on: on, inset: 3)
            drawValues(context, operands, rect: rect, y: y)
        case let .operationResult(kind):
            drawOperationResult(context, kind: kind, rect: rect, y: y)
        case .coil:
            drawCoil(context, rect: rect, y: y, on: on)
            drawOperand(context, operands.joined(separator: " "), rect: rect, y: y, device: operands.first)
            if let value = drawing.coilValues[cell] {
                text(context, value, at: CGPoint(x: rect.midX + 22, y: y), color: valueBlue, weight: .semibold, anchor: .leading)
            }
        case let .instructionBox(mnemonic):
            let title = ([mnemonic] + operands).joined(separator: " ")
            drawBox(context, title: title, rect: rect, y: y, on: on, inset: 6)
            drawValues(context, operands, rect: rect, y: y)
            if let first = operands.first, let comment = drawing.comments[first] {
                drawComment(context, comment, rect: rect, y: y + 18)
            }
        }
    }

    private func drawContact(_ context: GraphicsContext, kind: MelsecContactKind, rect: CGRect, y: CGFloat, on: Bool) {
        let left = rect.minX + rect.width * 0.40
        let right = rect.minX + rect.width * 0.60
        line(context, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: left, y: y))
        line(context, from: CGPoint(x: right, y: y), to: CGPoint(x: rect.maxX, y: y))
        if drawing.isMonitoring, on {
            context.fill(Path(CGRect(x: left, y: y - 8, width: right - left, height: 16)), with: .color(monitorBlue))
        }
        line(context, from: CGPoint(x: left, y: y - 8), to: CGPoint(x: left, y: y + 8), width: 1.5)
        line(context, from: CGPoint(x: right, y: y - 8), to: CGPoint(x: right, y: y + 8), width: 1.5)
        let negated = kind == .normallyClosed || kind == .risingEdgeNegated || kind == .fallingEdgeNegated
        if negated {
            line(context, from: CGPoint(x: left - 2, y: y + 8), to: CGPoint(x: right + 2, y: y - 8))
        }
        let arrow: String?
        switch kind {
        case .risingEdge, .risingEdgeNegated: arrow = "↑"
        case .fallingEdge, .fallingEdgeNegated: arrow = "↓"
        default: arrow = nil
        }
        if let arrow {
            text(context, arrow, at: CGPoint(x: (left + right) / 2, y: y), size: 11, color: on && drawing.isMonitoring ? .white : .primary)
        }
    }

    private func drawCoil(_ context: GraphicsContext, rect: CGRect, y: CGFloat, on: Bool) {
        let center = CGPoint(x: rect.midX, y: y)
        let circle = Path(ellipseIn: CGRect(x: center.x - 9, y: y - 9, width: 18, height: 18))
        line(context, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: center.x - 9, y: y))
        if drawing.isMonitoring, on {
            context.fill(circle, with: .color(monitorBlue))
        }
        context.stroke(circle, with: .color(wire), lineWidth: 1.5)
    }

    private func drawBox(_ context: GraphicsContext, title: String, rect: CGRect, y: CGFloat, on: Bool, inset: CGFloat) {
        let box = CGRect(x: rect.minX + inset, y: y - 10, width: rect.width - inset * 2, height: 20)
        line(context, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: box.minX, y: y))
        line(context, from: CGPoint(x: box.maxX, y: y), to: CGPoint(x: rect.maxX, y: y))
        context.fill(Path(box), with: .color(Color.gray.opacity(0.16)))
        let active = drawing.isMonitoring && on
        context.stroke(Path(box), with: .color(active ? monitorBlue : wire), lineWidth: active ? 2.5 : 1)
        text(context, title, at: CGPoint(x: box.midX, y: y), size: 9, weight: .medium)
    }

    private func drawOperationResult(_ context: GraphicsContext, kind: MelsecOperationResultKind, rect: CGRect, y: CGFloat) {
        line(context, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y))
        let center = CGPoint(x: rect.midX, y: y)
        switch kind {
        case .invert:
            line(context, from: CGPoint(x: center.x - 7, y: y + 9), to: CGPoint(x: center.x + 7, y: y - 9), width: 1.5)
        case .risingPulse:
            text(context, "↑", at: CGPoint(x: center.x, y: y - 9), size: 13, weight: .bold)
        case .fallingPulse:
            text(context, "↓", at: CGPoint(x: center.x, y: y - 9), size: 13, weight: .bold)
        }
        text(context, kind.rawValue, at: CGPoint(x: center.x, y: y + 14), size: 8, color: .secondary)
    }

    /// The operand above the symbol, and its comment or value below.
    private func drawOperand(_ context: GraphicsContext, _ operand: String, rect: CGRect, y: CGFloat, device: String? = nil) {
        let key = device ?? operand
        let color: Color = drawing.labels.contains(key) ? labelPurple : (operand.contains("?") ? .red : .primary)
        text(context, operand, at: CGPoint(x: rect.midX, y: y - 16), color: color)
        if let value = drawing.values[key] {
            text(context, value, at: CGPoint(x: rect.midX, y: y + 16), color: valueBlue, weight: .semibold)
        } else if let comment = drawing.comments[key] {
            drawComment(context, comment, rect: rect, y: y + 16)
        }
    }

    /// A device comment kept inside its cell, as GX Works3 does: one line if
    /// it fits, then a smaller font, then wrapped onto two lines. Centred on
    /// a wide cell, a long comment would otherwise run over the bus bar.
    private func drawComment(_ context: GraphicsContext, _ comment: String, rect: CGRect, y: CGFloat) {
        let width = rect.width - 4
        for size in [CGFloat(9), 8] {
            let resolved = context.resolve(Text(comment).font(.system(size: size, design: .monospaced)).foregroundColor(commentGreen))
            if resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width <= width {
                context.draw(resolved, at: CGPoint(x: rect.midX, y: y), anchor: .center)
                return
            }
        }
        let wrapped = context.resolve(Text(comment).font(.system(size: 8, design: .monospaced)).foregroundColor(commentGreen))
        // Just under the symbol, and inside the row.
        let box = CGRect(x: rect.minX + 2, y: y - 9, width: width, height: 20)
        var clipped = context
        clipped.clip(to: Path(box))
        clipped.draw(wrapped, in: box)
    }

    /// Monitored word values of an instruction's operands, in blue below.
    private func drawValues(_ context: GraphicsContext, _ operands: [String], rect: CGRect, y: CGFloat) {
        let shown = operands.compactMap { operand in drawing.values[operand].map { "\(operand)=\($0)" } }
        guard !shown.isEmpty else { return }
        text(context, shown.joined(separator: " "), at: CGPoint(x: rect.midX, y: y + 18), size: 9, color: valueBlue, weight: .semibold)
    }
}
