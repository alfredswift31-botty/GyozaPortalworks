import Foundation
import Testing
@testable import GyozaPortalworks

struct MelsecLadderEditingTests {
    @Test func coilIsRightAlignedAndJoinedByALine() throws {
        var editor = MelsecLadderEditor()
        try editor.insertContact(normallyOpen: true, operand: "X0")
        try editor.insertCoil(operands: ["Y0"])
        let row = editor.ladder.rows[0]
        #expect(row.cells[0] == .contact(.normallyOpen, operand: "X0"))
        #expect((1...10).allSatisfy { row.cells[$0] == .line })
        #expect(row.cells[11] == .output(mnemonic: "OUT", operands: ["Y0"]))
        #expect(editor.cursor == MelsecCellRef(row: 1, column: 0))
        #expect(editor.ladder.endRow == 1)
    }

    @Test func orBranchDrawsVerticalLines() throws {
        var editor = MelsecLadderEditor()
        try editor.enterLadderInput("LD X0")
        try editor.enterLadderInput("AND X1")
        try editor.enterLadderInput("OUT Y0")
        editor.moveCursor(to: MelsecCellRef(row: 1, column: 1))
        try editor.enterLadderInput("OR X2")
        #expect(editor.ladder.rows[0].verticalLines[1])
        #expect(editor.ladder.rows[0].verticalLines[2])
        #expect(editor.ladder.rows[1].cells[1] == .contact(.normallyOpen, operand: "X2"))
        #expect(editor.ladder.blocks() == [0..<2])
        #expect(throws: MelsecEditError.self) {
            var top = MelsecLadderEditor()
            try top.enterLadderInput("OR X0")
        }
    }

    @Test func ladderInputParsing() throws {
        #expect(try MelsecLadderInput.parse("LD X0", symbol: .coil) == .element(.contact(.normallyOpen, operand: "X0"), branch: false, note: nil))
        #expect(try MelsecLadderInput.parse("X0", symbol: .closeBranch) == .element(.contact(.normallyClosed, operand: "X0"), branch: true, note: nil))
        #expect(try MelsecLadderInput.parse("T0 K50", symbol: .coil) == .element(.output(mnemonic: "OUT", operands: ["T0", "K50"]), branch: false, note: nil))
        #expect(try MelsecLadderInput.parse("OUT T0", symbol: .openContact) == .element(.output(mnemonic: "OUT", operands: ["T0", "?"]), branch: false, note: nil))
        #expect(try MelsecLadderInput.parse("MOV K10", symbol: .instruction) == .element(.output(mnemonic: "MOV", operands: ["K10", "?"]), branch: false, note: nil))
        #expect(try MelsecLadderInput.parse("OUT Y0;Motor on", symbol: .openContact) == .element(.output(mnemonic: "OUT", operands: ["Y0"]), branch: false, note: "Motor on"))
        #expect(try MelsecLadderInput.parse("; Start circuit", symbol: .openContact) == .statement("Start circuit"))
        #expect(try MelsecLadderInput.parse("ORP X3", symbol: .openContact) == .element(.contact(.risingEdge, operand: "X3"), branch: true, note: nil))
        #expect(try MelsecLadderInput.parse("LD>= D0 K10", symbol: .openContact) == .element(.comparison(.greaterOrEqual, .word, operands: ["D0", "K10"]), branch: false, note: nil))
        #expect(try MelsecLadderInput.parse("INV", symbol: .openContact) == .element(.operationResult(.invert), branch: false, note: nil))
        #expect(throws: MelsecEditError.self) { try MelsecLadderInput.parse("FOO X0", symbol: .instruction) }
        #expect(throws: MelsecEditError.self) { try MelsecLadderInput.parse("ANB", symbol: .openContact) }
    }

    @Test func linesRowsAndColumns() throws {
        var editor = MelsecLadderEditor()
        try editor.enterLadderInput("LD X0")
        try editor.drawHorizontalLine()
        #expect(editor.ladder.rows[0].cells[1] == .line)
        try editor.drawVerticalLine()
        #expect(editor.ladder.rows[0].verticalLines[2])
        #expect(editor.cursor == MelsecCellRef(row: 1, column: 2))
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 2))
        try editor.deleteVerticalLine()
        #expect(!editor.ladder.rows[0].verticalLines[2])
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 1))
        try editor.deleteHorizontalLine()
        #expect(editor.ladder.rows[0].cells[1] == .empty)
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 1))
        try editor.drawLine(.right)
        try editor.drawLine(.right)
        #expect(editor.ladder.rows[0].cells[2] == .line)

        editor.moveCursor(to: MelsecCellRef(row: 0, column: 0))
        try editor.insertColumn()
        #expect(editor.ladder.rows[0].cells[1] == .contact(.normallyOpen, operand: "X0"))
        #expect(editor.ladder.rows[0].cells[0] == .line)
        try editor.deleteColumn()
        #expect(editor.ladder.rows[0].cells[0] == .contact(.normallyOpen, operand: "X0"))

        let rowsBefore = editor.ladder.rows.count
        editor.insertRow()
        #expect(editor.ladder.rows.count == rowsBefore + 1)
        try editor.deleteRow()
        #expect(editor.ladder.rows.count == rowsBefore)
        editor.moveCursor(to: MelsecCellRef(row: editor.ladder.endRow, column: 0))
        #expect(throws: MelsecEditError.self) { try editor.deleteRow() }
    }

    @Test func insertModeShiftsTheRow() throws {
        var editor = MelsecLadderEditor()
        try editor.enterLadderInput("LD X1")
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 0))
        editor.toggleInsertMode()
        try editor.enterLadderInput("LD X0")
        #expect(editor.ladder.rows[0].cells[0] == .contact(.normallyOpen, operand: "X0"))
        #expect(editor.ladder.rows[0].cells[1] == .contact(.normallyOpen, operand: "X1"))
        editor.toggleInsertMode()
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 0))
        try editor.enterLadderInput("LDI X5")
        #expect(editor.ladder.rows[0].cells[0] == .contact(.normallyClosed, operand: "X5"))
        #expect(editor.ladder.rows[0].cells[1] == .contact(.normallyOpen, operand: "X1"))
    }

    @Test func ladderRoundTripsThroughJSONAndTracksConversion() throws {
        var editor = MelsecLadderEditor()
        try editor.enterLadderInput("; Motor")
        try editor.enterLadderInput("LD X0")
        try editor.enterLadderInput("OUT T0 K50;delay")
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 0))
        try editor.setPointer(3)
        var ladder = editor.ladder
        #expect(ladder.hasUnconvertedRows)
        ladder.markConverted()
        #expect(!ladder.hasUnconvertedRows)
        let data = try JSONEncoder().encode(ladder)
        let decoded = try JSONDecoder().decode(MelsecLadder.self, from: data)
        #expect(decoded == ladder)
        #expect(decoded.rows[0].statement == "Motor")
        #expect(decoded.rows[0].note == "delay")
        #expect(decoded.rows[0].pointer == 3)
        let old = try JSONDecoder().decode(MelsecLadder.self, from: Data("{}".utf8))
        #expect(old.rows.isEmpty)
    }
}

struct MelsecConverterTests {
    @Test func seriesParallelAndSelfHold() throws {
        let ladder = try MelsecTestLadder.build(["LD X0", "ANI X1", "OUT Y0", "OR Y0"])
        #expect(MelsecTestLadder.codes(ladder) == ["LD X0", "OR Y0", "ANI X1", "OUT Y0", "END"])
        let result = MelsecConverter.convert(ladder)
        #expect(result.listing(.fx5u).map(\.step) == [0, 1, 2, 3, 4])
        #expect(result.cellInstructions[MelsecCellRef(row: 1, column: 0)] == [1])
        #expect(result.blockSteps == [MelsecBlockStep(rows: 0..<2, step: 0)])
        #expect(result.endStep == 4)
    }

    @Test func blockOrProducesORB() throws {
        var editor = MelsecLadderEditor()
        for input in ["LD X0", "AND X1", "OUT Y0", "LD X2", "AND X3"] {
            try editor.enterLadderInput(input)
        }
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 2))
        try editor.drawVerticalLine()
        #expect(MelsecTestLadder.codes(editor.ladder) == ["LD X0", "AND X1", "LD X2", "AND X3", "ORB", "OUT Y0", "END"])
    }

    @Test func blockAndProducesANB() throws {
        var editor = MelsecLadderEditor()
        for input in ["LD X0", "LD X1", "OUT Y0"] {
            try editor.enterLadderInput(input)
        }
        editor.moveCursor(to: MelsecCellRef(row: 1, column: 1))
        try editor.enterLadderInput("OR X2")
        #expect(MelsecTestLadder.codes(editor.ladder) == ["LD X0", "LD X1", "OR X2", "ANB", "OUT Y0", "END"])
    }

    @Test func branchingOutputsUseTheStack() throws {
        var editor = MelsecLadderEditor()
        for input in ["LD X0", "AND X1", "OUT Y0"] {
            try editor.enterLadderInput(input)
        }
        editor.moveCursor(to: MelsecCellRef(row: 1, column: 1))
        try editor.enterLadderInput("AND X2")
        try editor.enterLadderInput("OUT Y1")
        editor.moveCursor(to: MelsecCellRef(row: 2, column: 1))
        try editor.enterLadderInput("ANI X3")
        try editor.enterLadderInput("OUT Y2")
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 1))
        try editor.drawVerticalLine()
        try editor.drawVerticalLine()
        #expect(MelsecTestLadder.codes(editor.ladder) == [
            "LD X0", "MPS", "AND X1", "OUT Y0", "MRD", "AND X2", "OUT Y1", "MPP", "ANI X3", "OUT Y2", "END",
        ])
    }

    @Test func parallelCoilsNeedNoStack() throws {
        var editor = MelsecLadderEditor()
        for input in ["LD X0", "OUT Y0"] {
            try editor.enterLadderInput(input)
        }
        editor.moveCursor(to: MelsecCellRef(row: 1, column: 1))
        try editor.enterLadderInput("OUT Y1")
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 1))
        try editor.drawVerticalLine()
        #expect(MelsecTestLadder.codes(editor.ladder) == ["LD X0", "OUT Y0", "OUT Y1", "END"])

        var second = MelsecLadderEditor()
        for input in ["LD X0", "AND X1", "OUT Y0"] {
            try second.enterLadderInput(input)
        }
        second.moveCursor(to: MelsecCellRef(row: 1, column: 1))
        try second.enterLadderInput("OUT Y1")
        second.moveCursor(to: MelsecCellRef(row: 0, column: 1))
        try second.drawVerticalLine()
        #expect(MelsecTestLadder.codes(second.ladder) == ["LD X0", "MPS", "AND X1", "OUT Y0", "MPP", "OUT Y1", "END"])
    }

    @Test func pulsesComparisonsInvPointersAndUnconditionalInstructions() throws {
        var editor = MelsecLadderEditor()
        for input in ["LDP X0", "INV", "MEP", "INCP D0", "LD>= D0 K10", "ANDF X1", "OUT Y0", "LD X5", "MC N0 M50", "LD SM400", "CJ P0", "MCR N0"] {
            try editor.enterLadderInput(input)
        }
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 0))
        try editor.setPointer(0)
        #expect(MelsecTestLadder.codes(editor.ladder) == [
            "P0", "LDP X0", "INV", "MEP", "INCP D0", "LD>= D0 K10", "ANDF X1", "OUT Y0",
            "LD X5", "MC N0 M50", "LD SM400", "CJ P0", "MCR N0", "END",
        ])
    }

    private func errors(_ ladder: MelsecLadder) -> [MelsecConversionError] {
        MelsecConverter.convert(ladder).errors
    }

    private func row(_ cells: [Int: MelsecLadderElement]) -> MelsecLadderRow {
        var row = MelsecLadderRow()
        for (column, element) in cells {
            row.cells[column] = element
        }
        return row
    }

    @Test func unconnectedElementAndGapBeforeCoil() {
        let contact = MelsecLadderElement.contact(.normallyOpen, operand: "X0")
        let coil = MelsecLadderElement.output(mnemonic: "OUT", operands: ["Y0"])
        var lines: [Int: MelsecLadderElement] = [0: contact, 2: .contact(.normallyOpen, operand: "X1"), 11: coil]
        for column in 3...10 { lines[column] = .line }
        let unconnected = errors(MelsecLadder(rows: [row(lines)]))
        #expect(unconnected.contains { $0.column == 2 && $0.message.contains("not connected to the left bus") })
        #expect(unconnected.contains { $0.column == 0 && $0.message.contains("open branch") })

        let gap = errors(MelsecLadder(rows: [row([0: contact, 11: coil])]))
        #expect(gap.contains { $0.column == 11 && $0.message.contains("gap") })
    }

    @Test func coilDirectlyOnTheBus() throws {
        let ladder = try MelsecTestLadder.build(["OUT Y0"])
        let found = errors(ladder)
        #expect(found.count == 1)
        #expect(found.first?.message.contains("directly to the left bus") == true)
        #expect(found.first?.row == 0 && found.first?.column == 11)
        #expect(errors(try MelsecTestLadder.build(["MCR N0"])).isEmpty)
        #expect(errors(try MelsecTestLadder.build(["LD X0", "MCR N0"])).first?.message.contains("must be connected directly") == true)
    }

    @Test func openBranch() throws {
        var editor = MelsecLadderEditor()
        for input in ["LD X0", "OUT Y0"] {
            try editor.enterLadderInput(input)
        }
        editor.moveCursor(to: MelsecCellRef(row: 1, column: 1))
        try editor.enterLadderInput("LD X1")
        editor.moveCursor(to: MelsecCellRef(row: 0, column: 1))
        try editor.drawVerticalLine()
        let found = errors(editor.ladder)
        #expect(found.contains { $0.row == 1 && $0.column == 1 && $0.message.contains("does not lead to a coil") })
    }

    @Test func operandErrors() throws {
        let missing = errors(try MelsecTestLadder.build(["LD X0", "OUT"]))
        #expect(missing.contains { $0.message.contains("has not been entered") })
        let octal = errors(try MelsecTestLadder.build(["LD X8", "OUT Y0"]))
        #expect(octal.contains { $0.column == 0 && $0.message.contains("octal") })
        let range = errors(try MelsecTestLadder.build(["LD X0", "MOV K1 D8000"]))
        #expect(range.contains { $0.message.contains("D0-D7999") })
        let mismatch = errors(try MelsecTestLadder.build(["LD D0", "MOV K1 X0"]))
        #expect(mismatch.contains { $0.column == 0 && $0.message.contains("type mismatch") })
        #expect(mismatch.contains { $0.column == 11 && $0.message.contains("type mismatch") })
        let label = errors(try MelsecTestLadder.build(["LD Start", "OUT Y0"]))
        #expect(label.contains { $0.message.contains("not declared") })
        let declared = MelsecConverter.convert(try MelsecTestLadder.build(["LD Start", "OUT Y0"]),
                                               scope: MelsecLabelScope(globals: [MelsecLabel(name: "Start", dataType: .bit)]))
        #expect(declared.succeeded)
    }

    @Test func unknownInstruction() {
        var row = MelsecLadderRow()
        row.cells[0] = .contact(.normallyOpen, operand: "X0")
        for column in 1...10 { row.cells[column] = .line }
        row.cells[11] = .output(mnemonic: "FOO", operands: ["D0"])
        let found = errors(MelsecLadder(rows: [row]))
        #expect(found.contains { $0.column == 11 && $0.message.contains("does not exist") })
    }

    @Test func bridgeCircuitCannotBeConverted() {
        // LEFT→A (X0), A→OUT (X1), A→B (X3), LEFT→B (X2), B→OUT (X4): a bridge.
        var top = MelsecLadderRow()
        top.cells[0] = .contact(.normallyOpen, operand: "X0")
        top.cells[1] = .contact(.normallyOpen, operand: "X1")
        for column in 2...10 { top.cells[column] = .line }
        top.cells[11] = .output(mnemonic: "OUT", operands: ["Y0"])
        top.verticalLines[1] = true
        top.verticalLines[3] = true
        var middle = MelsecLadderRow()
        middle.cells[1] = .contact(.normallyOpen, operand: "X3")
        middle.cells[2] = .contact(.normallyOpen, operand: "X4")
        middle.verticalLines[2] = true
        var bottom = MelsecLadderRow()
        bottom.cells[0] = .contact(.normallyOpen, operand: "X2")
        bottom.cells[1] = .line
        let found = MelsecConverter.convert(MelsecLadder(rows: [top, middle, bottom])).errors
        #expect(found.count == 1)
        #expect(found.first?.message.contains("cannot be converted") == true)
    }

    @Test func conversionResultMapsCellsToSteps() throws {
        let ladder = try MelsecTestLadder.build(["LD X0", "OUT T0 K50", "LD T0", "MOV K1 D0"])
        let result = MelsecConverter.convert(ladder)
        #expect(result.succeeded)
        #expect(result.listing(.fx5u).map(\.step) == [0, 1, 4, 5, 10])
        #expect(result.cellInstructions[MelsecCellRef(row: 1, column: 11)] == [3])
        #expect(result.blockSteps.map(\.step) == [0, 4])
    }
}

struct MelsecProgramCheckTests {
    private func check(_ text: String) -> [MelsecCheckFinding] {
        MelsecProgramCheck.check([(name: "ProgPou", program: MelsecILParser.parse(text).program)])
    }

    @Test func duplicatedCoil() {
        let findings = check("LD X0 OUT Y0\nLD X1 OUT Y0")
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("Duplicated coil: Y0") == true)
        #expect(check("LD X0 OUT Y0\nLD X1 SET Y0").isEmpty)
    }

    @Test func masterControlPairing() {
        #expect(check("LD X0 MC N0 M0\nLD X1 OUT Y0\nMCR N0").isEmpty)
        #expect(check("LD X0 MC N0 M0\nLD X1 OUT Y0").contains { $0.message.contains("no matching MCR N0") })
        #expect(check("MCR N1").contains { $0.message.contains("no matching MC N1") })
        #expect(check("LD X0 MC N1 M0\nLD X1 MC N0 M1\nMCR N0").contains { $0.message.contains("must increase") })
    }

    @Test func jumpAndCallTargets() {
        #expect(check("LD X0 CJ P3").contains { $0.message.contains("P3 does not exist") })
        #expect(check("LD X0 CJ P3\nP3\nLD X1 OUT Y0").isEmpty)
        #expect(check("P1\nLD X0 CALL P1").contains { $0.message.contains("after FEND") })
        #expect(check("LD X0 CALL P1\nFEND\nP1\nLD X1 OUT Y1\nRET").isEmpty)
        #expect(check("P1\nLD X0 OUT Y0\nP1").contains { $0.message.contains("more than once") })
    }

    @Test func deviceRanges() {
        #expect(check("LD X0 BMOV D0 D7990 K20").contains { $0.message.contains("D0-D7999") })
        #expect(check("LD X0 BMOV D0 D100 K20").isEmpty)
        #expect(check("LD X0 CMP K1 K2 M7679").contains { $0.message.contains("M0-M7679") })
    }
}
