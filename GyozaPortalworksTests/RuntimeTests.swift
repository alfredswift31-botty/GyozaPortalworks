import Testing
@testable import GyozaPortalworks

struct OperationTests {
    @Test func integerArithmeticWrapsAndReportsOverflow() {
        let overflow = PLCOperations.arithmetic(.add, .int(32_767), .int(1), as: .int)
        #expect(overflow == OperationResult(value: .int(-32_768), isValid: false))
        #expect(PLCOperations.arithmetic(.add, .int(100), .int(23), as: .int) == OperationResult(value: .int(123), isValid: true))
        #expect(PLCOperations.arithmetic(.multiply, .int(300), .int(300), as: .dint).value == .int(90_000))
        #expect(PLCOperations.arithmetic(.subtract, .int(0), .int(1), as: .uint) == OperationResult(value: .int(65_535), isValid: false))
    }

    @Test func integerDivisionTruncatesTowardZero() {
        #expect(PLCOperations.arithmetic(.divide, .int(-7), .int(2), as: .int).value == .int(-3))
        #expect(PLCOperations.arithmetic(.modulo, .int(-7), .int(2), as: .int).value == .int(-1))
        #expect(PLCOperations.arithmetic(.divide, .int(5), .int(0), as: .int).isValid == false)
        #expect(PLCOperations.arithmetic(.divide, .real(1), .real(4), as: .real).value == .real(0.25))
    }

    @Test func realToIntegerConversionRounds() {
        #expect(PLCOperations.convert(.real(2.5), from: .real, to: .int).value == .int(2))
        #expect(PLCOperations.convert(.real(3.5), from: .real, to: .int).value == .int(4))
        #expect(PLCOperations.convert(.real(2.5), from: .real, to: .int, rounding: .toNearestOrAwayFromZero).value == .int(3))
        #expect(PLCOperations.convert(.real(-2.7), from: .real, to: .int, rounding: .towardZero).value == .int(-2))
        #expect(PLCOperations.convert(.real(40_000), from: .real, to: .int).isValid == false)
        #expect(PLCOperations.convert(.real(.nan), from: .real, to: .dint).isValid == false)
    }

    @Test func bitStringsConvertByBitPattern() {
        #expect(PLCOperations.convert(.int(0xFFFF), from: .word, to: .int) == OperationResult(value: .int(-1), isValid: true))
        #expect(PLCOperations.convert(.int(-1), from: .int, to: .word).value == .int(0xFFFF))
        #expect(PLCOperations.convert(.time(1_500), from: .time, to: .dint).value == .int(1_500))
    }

    @Test func shiftsAndRotates() {
        #expect(PLCOperations.shiftLeft(.int(0x8001), by: 1, as: .word) == .int(0x0002))
        #expect(PLCOperations.shiftRight(.int(-8), by: 1, as: .int) == .int(-4))
        #expect(PLCOperations.shiftRight(.int(0x8000), by: 15, as: .word) == .int(1))
        #expect(PLCOperations.shiftLeft(.int(1), by: 16, as: .word) == .int(0))
        #expect(PLCOperations.rotate(.int(0x8001), by: 1, left: true, as: .word) == .int(0x0003))
        #expect(PLCOperations.rotate(.int(0x01), by: 1, left: false, as: .byte) == .int(0x80))
    }

    @Test func logicAndComparison() {
        #expect(PLCOperations.bitLogic(.and, .int(0x0F0F), .int(0x00FF), as: .word) == .int(0x000F))
        #expect(PLCOperations.bitLogic(.xor, .bool(true), .bool(true), as: .bool) == .bool(false))
        #expect(PLCOperations.invert(.int(0), as: .int) == .int(-1))
        #expect(PLCOperations.compare(.less, .int(3), .real(3.5)))
        #expect(!PLCOperations.compare(.equal, .real(.nan), .real(.nan)))
        #expect(PLCOperations.compare(.notEqual, .real(.nan), .real(.nan)))
    }

    @Test func scalingAndLimits() {
        let normalized = PLCOperations.normalize(.int(13_824), min: .int(0), max: .int(27_648), as: .real)
        #expect(normalized == OperationResult(value: .real(0.5), isValid: true))
        #expect(PLCOperations.scale(.real(0.5), min: .int(0), max: .int(100), as: .int).value == .int(50))
        #expect(PLCOperations.limit(.int(120), min: .int(0), max: .int(100)).value == .int(100))
        #expect(PLCOperations.limit(.int(5), min: .int(10), max: .int(0)).isValid == false)
        #expect(PLCOperations.maximum([.int(3), .int(9), .int(-2)]) == .int(9))
        #expect(PLCOperations.minimum([.int(3), .int(9), .int(-2)]) == .int(-2))
    }

    @Test func implicitConversionRules() {
        #expect(PLCTypeRules.canConvertImplicitly(from: .int, to: .dint, dialect: .siemens))
        #expect(!PLCTypeRules.canConvertImplicitly(from: .dint, to: .int, dialect: .siemens))
        #expect(!PLCTypeRules.canConvertImplicitly(from: .real, to: .int, dialect: .siemens))
        #expect(PLCTypeRules.canConvertImplicitly(from: .word, to: .int, dialect: .siemens))
        #expect(!PLCTypeRules.canConvertImplicitly(from: .word, to: .int, dialect: .melsec))
        #expect(!PLCTypeRules.canConvertImplicitly(from: .dint, to: .real, dialect: .melsec))
        #expect(PLCTypeRules.commonType(.int, .real, dialect: .siemens) == .real)
        #expect(PLCTypeRules.commonType(.uint, .int, dialect: .siemens) == .dint)
        #expect(PLCTypeRules.commonType(.bool, .int, dialect: .siemens) == nil)
    }
}

struct ValueTests {
    @Test func timeLiteralsParseAndFormat() {
        #expect(TimeLiteral.parse("5s") == 5_000)
        #expect(TimeLiteral.parse("1S_500MS") == 1_500)
        #expect(TimeLiteral.parse("1h2m3s4ms") == 3_723_004)
        #expect(TimeLiteral.parse("2.5s") == 2_500)
        #expect(TimeLiteral.parse("-5s") == -5_000)
        #expect(TimeLiteral.parse("5x") == nil)
        #expect(TimeLiteral.parse("") == nil)
        #expect(TimeLiteral.format(milliseconds: 1_500) == "T#1S_500MS")
        #expect(TimeLiteral.format(milliseconds: 90_000) == "T#1M_30S")
        #expect(TimeLiteral.format(milliseconds: 0) == "T#0MS")
        #expect(TimeLiteral.format(milliseconds: -2_000) == "-T#2S")
    }

    @Test func monitorFormatting() {
        #expect(PLCValue.int(255).formatted(as: .word) == "16#00FF")
        #expect(PLCValue.bool(true).formatted(as: .bool) == "TRUE")
        #expect(PLCValue.real(12.5).formatted(as: .real) == "12.5")
        #expect(PLCValue.real(3).formatted(as: .real) == "3.0")
        #expect(PLCValue.int(-5).formatted(as: .int) == "-5")
    }

    @Test func parsesTypedInput() {
        #expect(ValueParser.parse("TRUE", as: .bool) == .bool(true))
        #expect(ValueParser.parse("off", as: .bool) == .bool(false))
        #expect(ValueParser.parse("16#FF", as: .word) == .int(255))
        #expect(ValueParser.parse("16#FFFF", as: .int) == .int(-1))
        #expect(ValueParser.parse("40000", as: .int) == nil)
        #expect(ValueParser.parse("K10", as: .int) == .int(10))
        #expect(ValueParser.parse("H1F", as: .word) == .int(31))
        #expect(ValueParser.parse("INT#-5", as: .int) == .int(-5))
        #expect(ValueParser.parse("2#1010", as: .byte) == .int(10))
        #expect(ValueParser.parse("E1.5", as: .real) == .real(1.5))
        #expect(ValueParser.parse("12,5", as: .real) == nil)
        #expect(ValueParser.parse("T#1s_500ms", as: .time) == .time(1_500))
        #expect(ValueParser.parse("TIME#5s", as: .time) == .time(5_000))
    }

    @Test func storingWrapsIntoTheTargetType() {
        #expect(PLCValue.int(70_000).converted(to: .int) == .int(4_464))
        #expect(PLCValue.int(-1).converted(to: .byte) == .int(255))
        #expect(PLCValue.int(2).converted(to: .bool) == .bool(true))
        #expect(PLCValue.real(1.9).converted(to: .int) == .int(1))
        #expect(PLCDataType.named("dword") == .dword)
    }
}

struct DataNodeTests {
    @Test func structuresArraysAndSlices() {
        let node = DataNode(type: .structure(name: nil, members: [
            PLCMember("speed", .elementary(.int), initialValue: .int(5)),
            PLCMember("values", .array(lower: 1, upper: 3, element: .elementary(.real))),
            PLCMember("status", .elementary(.word)),
        ]))
        #expect(node.member("SPEED")?.read() == .int(5))
        let outOfRange = node.member("values")?.element(0) == nil
        #expect(outOfRange)
        node.member("values")?.element(3)?.write(.real(1.5))
        #expect(node.member("values")?.element(3)?.read() == .real(1.5))

        let status = Place.node(node.member("status")!)
        status.slice(width: 1, index: 3)?.write(.bool(true))
        #expect(status.read() == .int(8))
        status.slice(width: 8, index: 1)?.write(.int(0xAB))
        #expect(status.read() == .int(0xAB08))
        #expect(status.slice(width: 1, index: 15)?.read() == .bool(true))
        let tooWide = status.slice(width: 1, index: 16) == nil
        #expect(tooWide)

        node.member("speed")?.write(.int(70_000))
        #expect(node.member("speed")?.read() == .int(4_464))
        node.reset()
        #expect(node.member("speed")?.read() == .int(5))
        #expect(node.leaves().map { $0.path } == ["speed", "values[1]", "values[2]", "values[3]", "status"])
    }

    @Test func signedSliceWritesKeepTheSign() {
        let value = Place.node(DataNode(type: .elementary(.int)))
        value.slice(width: 1, index: 15)?.write(.bool(true))
        #expect(value.read() == .int(-32_768))
    }

    @Test func warmRestartKeepsRetainData() {
        let node = DataNode(type: .structure(name: nil, members: [
            PLCMember("kept", .elementary(.int), isRetain: true),
            PLCMember("lost", .elementary(.int)),
        ]))
        node.member("kept")?.write(.int(7))
        node.member("lost")?.write(.int(9))
        node.reset(keepingRetain: true)
        #expect(node.member("kept")?.read() == .int(7))
        #expect(node.member("lost")?.read() == .int(0))
    }
}

struct FunctionBlockTests {
    private func make(_ name: String, _ dialect: LanguageDialect = .siemens) -> (FunctionBlockType, DataNode) {
        let type = FunctionBlockLibrary.type(named: name, dialect: dialect)!
        return (type, DataNode(type: .instance(type)))
    }

    private func step(_ type: FunctionBlockType, _ node: DataNode, at now: Int64, _ inputs: [String: PLCValue] = [:]) {
        for (name, value) in inputs {
            node.member(name)?.write(value)
        }
        FunctionBlockLibrary.execute(type, instance: node, now: now)
    }

    @Test func libraryNames() {
        #expect(FunctionBlockLibrary.type(named: "ton", dialect: .siemens)?.name == "TON_TIME")
        #expect(FunctionBlockLibrary.type(named: "CTUD_DINT", dialect: .siemens)?.members.last?.type == .elementary(.dint))
        #expect(FunctionBlockLibrary.type(named: "IEC_DCOUNTER", dialect: .siemens)?.builtIn == .iecCounter)
        #expect(FunctionBlockLibrary.type(named: "SR", dialect: .siemens) == nil)
        #expect(FunctionBlockLibrary.type(named: "SR", dialect: .melsec)?.builtIn == .setDominant)
    }

    @Test func onDelay() {
        let (type, node) = make("TON_TIME")
        step(type, node, at: 0, ["PT": .time(1_000), "IN": .bool(true)])
        #expect(node.member("Q")?.read() == .bool(false))
        step(type, node, at: 999)
        #expect(node.member("ET")?.read() == .time(999))
        #expect(node.member("Q")?.read() == .bool(false))
        step(type, node, at: 1_000)
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 5_000)
        #expect(node.member("ET")?.read() == .time(1_000))
        step(type, node, at: 5_010, ["IN": .bool(false)])
        #expect(node.member("Q")?.read() == .bool(false))
        #expect(node.member("ET")?.read() == .time(0))
    }

    @Test func offDelay() {
        let (type, node) = make("TOF_TIME")
        step(type, node, at: 0, ["PT": .time(500), "IN": .bool(true)])
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 100, ["IN": .bool(false)])
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 599)
        #expect(node.member("ET")?.read() == .time(499))
        step(type, node, at: 600)
        #expect(node.member("Q")?.read() == .bool(false))
        #expect(node.member("ET")?.read() == .time(500))
    }

    @Test func pulseIgnoresTheInputWhileRunning() {
        let (type, node) = make("TP_TIME")
        step(type, node, at: 0, ["PT": .time(1_000), "IN": .bool(true)])
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 100, ["IN": .bool(false)])
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 200, ["IN": .bool(true)])
        #expect(node.member("ET")?.read() == .time(200))
        step(type, node, at: 1_000)
        #expect(node.member("Q")?.read() == .bool(false))
        #expect(node.member("ET")?.read() == .time(1_000))
        step(type, node, at: 1_100, ["IN": .bool(false)])
        #expect(node.member("ET")?.read() == .time(0))
    }

    @Test func retentiveOnDelayAccumulates() {
        let (type, node) = make("TONR_TIME")
        step(type, node, at: 0, ["PT": .time(1_000), "IN": .bool(true)])
        step(type, node, at: 600, ["IN": .bool(false)])
        #expect(node.member("ET")?.read() == .time(600))
        step(type, node, at: 5_000, ["IN": .bool(true)])
        #expect(node.member("Q")?.read() == .bool(false))
        step(type, node, at: 5_400)
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 6_000, ["IN": .bool(false)])
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 6_100, ["R": .bool(true)])
        #expect(node.member("Q")?.read() == .bool(false))
        #expect(node.member("ET")?.read() == .time(0))
    }

    @Test func upCounterCountsRisingEdgesOnly() {
        let (type, node) = make("CTU_INT")
        step(type, node, at: 0, ["PV": .int(2), "CU": .bool(true)])
        step(type, node, at: 10)
        #expect(node.member("CV")?.read() == .int(1))
        step(type, node, at: 20, ["CU": .bool(false)])
        step(type, node, at: 30, ["CU": .bool(true)])
        #expect(node.member("CV")?.read() == .int(2))
        #expect(node.member("Q")?.read() == .bool(true))
        step(type, node, at: 40, ["R": .bool(true)])
        #expect(node.member("CV")?.read() == .int(0))
        #expect(node.member("Q")?.read() == .bool(false))
    }

    @Test func downCounterLoadsAndCountsDown() {
        let (type, node) = make("CTD_INT")
        step(type, node, at: 0, ["PV": .int(2), "LD": .bool(true)])
        #expect(node.member("CV")?.read() == .int(2))
        step(type, node, at: 10, ["LD": .bool(false), "CD": .bool(true)])
        step(type, node, at: 20, ["CD": .bool(false)])
        step(type, node, at: 30, ["CD": .bool(true)])
        #expect(node.member("CV")?.read() == .int(0))
        #expect(node.member("Q")?.read() == .bool(true))
    }

    @Test func upDownCounterIgnoresSimultaneousEdges() {
        let (type, node) = make("CTUD_INT")
        step(type, node, at: 0, ["PV": .int(5), "CU": .bool(true)])
        #expect(node.member("CV")?.read() == .int(1))
        step(type, node, at: 10, ["CU": .bool(false)])
        step(type, node, at: 20, ["CU": .bool(true), "CD": .bool(true)])
        #expect(node.member("CV")?.read() == .int(1))
        step(type, node, at: 30, ["R": .bool(true), "LD": .bool(true)])
        #expect(node.member("CV")?.read() == .int(0))
        step(type, node, at: 40, ["R": .bool(false)])
        #expect(node.member("CV")?.read() == .int(5))
        #expect(node.member("QU")?.read() == .bool(true))
    }

    @Test func genericCounterMapsQToQU() {
        let (type, node) = make("IEC_COUNTER")
        let parameters = FunctionBlockLibrary.callParameters(of: type, operation: .ctu)
        #expect(parameters.map { $0.name } == ["CU", "R", "PV", "Q", "CV"])
        #expect(parameters.first { $0.name == "Q" }?.memberIndex == type.memberIndex("QU"))
        #expect(FunctionBlockLibrary.callParameters(of: type).isEmpty)
        node.member("PV")?.write(.int(1))
        node.member("CU")?.write(.bool(true))
        FunctionBlockLibrary.execute(type, operation: .ctu, instance: node, now: 0)
        #expect(node.member("QU")?.read() == .bool(true))
    }

    @Test func edgeDetectionHasNoFirstScanPulse() {
        let (rising, risingNode) = make("R_TRIG")
        step(rising, risingNode, at: 0, ["CLK": .bool(true)])
        #expect(risingNode.member("Q")?.read() == .bool(true))
        step(rising, risingNode, at: 10)
        #expect(risingNode.member("Q")?.read() == .bool(false))

        let (falling, fallingNode) = make("F_TRIG")
        step(falling, fallingNode, at: 0)
        #expect(fallingNode.member("Q")?.read() == .bool(false))
        step(falling, fallingNode, at: 10, ["CLK": .bool(true)])
        step(falling, fallingNode, at: 20, ["CLK": .bool(false)])
        #expect(fallingNode.member("Q")?.read() == .bool(true))
    }

    @Test func flipFlopsFollowTheirDominance() {
        let (sr, srNode) = make("SR", .melsec)
        step(sr, srNode, at: 0, ["S1": .bool(true), "R": .bool(true)])
        #expect(srNode.member("Q1")?.read() == .bool(true))
        let (rs, rsNode) = make("RS", .melsec)
        step(rs, rsNode, at: 0, ["S": .bool(true), "R1": .bool(true)])
        #expect(rsNode.member("Q1")?.read() == .bool(false))
    }
}

nonisolated final class ClosureBody: ExecutableBody {
    let action: (Frame) throws -> Void

    init(_ action: @escaping (Frame) throws -> Void) {
        self.action = action
    }

    func execute(_ frame: Frame) throws {
        try action(frame)
    }
}

struct ExecutionTests {
    @Test func functionBlockKeepsStaticsAndGetsFreshTemps() throws {
        let block = BlockHandle(name: "Adder", kind: .functionBlock, number: 1, members: [
            PLCMember("a", .elementary(.int), section: .input),
            PLCMember("sum", .elementary(.int), section: .output),
            PLCMember("total", .elementary(.int), section: .staticVar),
            PLCMember("scratch", .elementary(.int), section: .temp),
            PLCMember("step", .elementary(.int), section: .constant, initialValue: .int(2)),
        ])
        var tempsWereFresh = true
        block.body = ClosureBody { frame in
            let scratch = frame.temps.member("scratch")!
            if scratch.read() != .int(0) { tempsWereFresh = false }
            scratch.write(.int(99))
            let total = frame.instance.member("total")!
            total.write(PLCOperations.arithmetic(.add, total.read(), frame.instance.member("a")!.read(), as: .int).value)
            frame.instance.member("sum")!.write(total.read())
        }
        let type = try #require(block.functionBlockType)
        let context = ExecutionContext(dialect: .siemens, blocks: [block])
        let instance = DataNode(type: .instance(type))
        instance.member("a")?.write(.int(5))
        try context.callFunctionBlock(type, instance: instance)
        try context.callFunctionBlock(type, instance: instance)
        #expect(instance.member("sum")?.read() == .int(10))
        #expect(tempsWereFresh)

        guard case let .local(area, index, _)? = block.localBinding("TOTAL") else {
            Issue.record("total should bind to the interface")
            return
        }
        #expect(area == .instance)
        #expect(index == 2)
        guard case let .constant(_, value, _)? = block.localBinding("step") else {
            Issue.record("step should bind to a constant")
            return
        }
        #expect(value == .int(2))
        #expect(block.callParameters.map { $0.name } == ["a", "sum"])
    }

    @Test func missingCodeAndRunawayLoopsFault() {
        let block = BlockHandle(name: "Looper", kind: .function, number: 1, members: [])
        let context = ExecutionContext(dialect: .siemens, blocks: [block])
        #expect(throws: RuntimeFault.self) {
            try context.run(block, instance: block.makeInstanceArea())
        }
        block.body = ClosureBody { frame in
            while true {
                try frame.context.countLoopIteration()
            }
        }
        context.beginScan(clock: 0)
        do {
            try context.run(block, instance: block.makeInstanceArea())
            Issue.record("the watchdog should have fired")
        } catch let fault as RuntimeFault {
            #expect(fault.kind == .cycleTimeExceeded)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func builtInCallsUseTheCPUClock() throws {
        let type = try #require(FunctionBlockLibrary.type(named: "TON", dialect: .melsec))
        let timer = DataNode(type: .instance(type))
        timer.member("IN")?.write(.bool(true))
        timer.member("PT")?.write(.time(100))
        let context = ExecutionContext(dialect: .melsec)
        context.beginScan(clock: 1_000)
        try context.callFunctionBlock(type, instance: timer)
        context.beginScan(clock: 1_100)
        try context.callFunctionBlock(type, instance: timer)
        #expect(timer.member("Q")?.read() == .bool(true))
    }
}
