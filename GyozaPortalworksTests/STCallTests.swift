import Foundation
import Testing
@testable import GyozaPortalworks

/// Function block, function and procedure calls.
struct STCallTests {
    private func instance(_ name: String, _ typeName: String, dialect: LanguageDialect = .siemens) -> PLCMember {
        let type = FunctionBlockLibrary.type(named: typeName, dialect: dialect) ?? FunctionBlockType(name: typeName, members: [], builtIn: nil)
        return PLCMember(name, .instance(type))
    }

    @Test func onDelayTimerAcrossScans() throws {
        let run = try #require(STRun.make("""
            #t(IN := #start, PT := T#1s, Q => #done, ET => #elapsed);
            #direct := #t.Q;
            """, [instance("t", "TON_TIME"), ST.member("start", .bool), ST.member("done", .bool), ST.member("elapsed", .time),
                  ST.member("direct", .bool)]))
        run.write("start", .bool(true))
        try run.scan(clock: 0)
        #expect(run["done"] == .bool(false))
        try run.scan(clock: 400)
        #expect(run["elapsed"] == .time(400))
        try run.scan(clock: 999)
        #expect(run["done"] == .bool(false))
        try run.scan(clock: 1_000)
        #expect(run["done"] == .bool(true))
        #expect(run["direct"] == .bool(true))
        #expect(run["elapsed"] == .time(1_000))
        run.write("start", .bool(false))
        try run.scan(clock: 1_200)
        #expect(run["done"] == .bool(false))
        #expect(run["elapsed"] == .time(0))
    }

    @Test func unassignedInputsKeepTheirValues() throws {
        let run = try #require(STRun.make("""
            IF #first THEN
                #t(IN := TRUE, PT := T#100ms);
            ELSE
                #t();
            END_IF;
            #q := #t.Q;
            """, [instance("t", "TON_TIME"), ST.member("first", .bool, .staticVar, .bool(true)), ST.member("q", .bool)]))
        try run.scan(clock: 0)
        run.write("first", .bool(false))
        try run.scan(clock: 150)
        #expect(run["q"] == .bool(true))
        #expect(run.node("t")?.member("PT")?.read() == .time(100))
    }

    @Test func genericIECTimer() throws {
        let run = try #require(STRun.make("""
            "IEC_Timer_0_DB".TON(IN := #start, PT := T#100ms, Q => #q);
            #et := "IEC_Timer_0_DB".ET;
            """, [ST.member("start", .bool, .staticVar, .bool(true)), ST.member("q", .bool), ST.member("et", .time)],
            configure: { $0.addGlobal("IEC_Timer_0_DB", .instance(FunctionBlockLibrary.timer(.iecTimer, name: "IEC_TIMER"))) }))
        try run.scan(clock: 10)
        try run.scan(clock: 60)
        #expect(run["q"] == .bool(false))
        #expect(run["et"] == .time(50))
        try run.scan(clock: 110)
        #expect(run["q"] == .bool(true))
    }

    @Test func genericIECCounter() throws {
        let run = try #require(STRun.make("""
            "IEC_Counter_0_DB".CTU(CU := #pulse, R := #reset, PV := 3, Q => #q, CV => #cv);
            """, [ST.member("pulse", .bool), ST.member("reset", .bool), ST.member("q", .bool), ST.member("cv", .int)],
            configure: { $0.addGlobal("IEC_Counter_0_DB", .instance(FunctionBlockLibrary.counter(.iecCounter, valueType: .int, name: "IEC_COUNTER"))) }))
        for scan in 0..<6 {
            run.write("pulse", .bool(scan % 2 == 0))
            try run.scan(clock: Int64(scan * 10))
        }
        #expect(run["cv"] == .int(3))
        #expect(run["q"] == .bool(true))
        run.write("reset", .bool(true))
        try run.scan(clock: 100)
        #expect(run["cv"] == .int(0))
        #expect(run["q"] == .bool(false))
    }

    @Test func genericInstancesNeedAValidOperation() {
        let configure: (STTestResolver) -> Void = { resolver in
            resolver.addGlobal("T1", .instance(FunctionBlockLibrary.timer(.iecTimer, name: "IEC_TIMER")))
        }
        #expect(ST.errors("\"T1\"(IN := TRUE, PT := T#1s);", configure: configure)
                == ["The IEC_TIMER instance \"T1\" needs an operation, e.g. \"T1\".TON(…)."])
        #expect(ST.errors("\"T1\".CTU(CU := TRUE);", configure: configure) == ["CTU is not an operation of IEC_TIMER; use TON, TOF, TP, TONR."])
        #expect(ST.errors("\"T1\".TON(IN := TRUE, CU := TRUE);", configure: configure) == ["Parameter CU not defined for \"T1\".TON."])
    }

    @Test func melsecTimerWithGXWorks2StyleOutputs() throws {
        let run = try #require(STRun.make("""
            tonDelay(IN := X0, PT := T#50ms, Q := Y0);
            ctr(CU := X0, R := FALSE, PV := 2, Q => M1, CV => D10);
            """, [instance("tonDelay", "TON", dialect: .melsec), instance("ctr", "CTU", dialect: .melsec)], dialect: .melsec,
            configure: { resolver in
                resolver.addAbsolute("X0", .bool, isWritable: false).write(.bool(true))
                resolver.addAbsolute("Y0", .bool)
                resolver.addAbsolute("M1", .bool)
                resolver.addAbsolute("D10", .int)
            }))
        try run.scan(clock: 0)
        try run.scan(clock: 50)
        #expect(run.resolver.absolutes["Y0"]?.place.read() == .bool(true))
        #expect(run.resolver.absolutes["D10"]?.place.read() == .int(1))
        #expect(ST.errors("#t(IN := TRUE, Q := #q);", [instance("t", "TON_TIME"), ST.member("q", .bool)])
                == ["The output parameter Q must be assigned with '=>'."])
    }

    private func accumulator() -> BlockHandle {
        ST.userBlock("Accumulate", kind: .functionBlock, members: [
            ST.member("step", .int, .input),
            ST.member("total", .int, .inOut),
            ST.member("count", .int, .output),
            ST.member("calls", .int),
        ], source: "#total := #total + #step;\n#calls := #calls + 1;\n#count := #calls;")
    }

    @Test func userFunctionBlockWithInOut() throws {
        let block = accumulator()
        let type = try #require(block.functionBlockType)
        let run = try #require(STRun.make("""
            #acc(step := 5, total := #sum, count => #n);
            #acc(step := #sum, total := #values[2], count => #wide);
            """, [PLCMember("acc", .instance(type)), ST.member("sum", .int), ST.member("n", .int), ST.member("wide", .dint),
                  PLCMember("values", .array(lower: 1, upper: 3, element: .elementary(.int)))],
            configure: { $0.blocks["accumulate"] = block }))
        try run.scan()
        try run.scan()
        #expect(run["sum"] == .int(10))
        #expect(run["n"] == .int(3))
        #expect(run["wide"] == .int(4))
        #expect(run["values[2]"] == .int(15))
        #expect(run.node("acc")?.member("calls")?.read() == .int(4))
    }

    @Test func functionBlockParameterErrors() throws {
        let block = accumulator()
        let type = try #require(block.functionBlockType)
        let members = [PLCMember("acc", .instance(type)), ST.member("sum", .int), ST.member("r", .real), ST.member("d", .dint)]
        let configure: (STTestResolver) -> Void = { $0.blocks["accumulate"] = block }
        #expect(ST.errors("#acc(step := 1);", members, configure: configure) == ["The in/out parameter total of #acc must be supplied."])
        #expect(ST.errors("#acc(step := 1, total := 5);", members, configure: configure)
                == ["The in/out parameter total needs a tag, not an expression."])
        #expect(ST.errors("#acc(step := 1, total := #d);", members, configure: configure)
                == ["The data type DInt of the actual parameter does not match the data type Int of the formal parameter."])
        #expect(ST.errors("#acc(step := #r, total := #sum);", members, configure: configure)
                == ["The data type Real of the actual parameter does not match the data type Int of the formal parameter. Use REAL_TO_INT, ROUND or TRUNC."])
        #expect(ST.errors("#acc(step => #sum, total := #sum);", members, configure: configure)
                == ["The input parameter step must be assigned with ':='."])
        #expect(ST.errors("#acc(speed := 1, total := #sum);", members, configure: configure) == ["Parameter speed not defined for #acc."])
        #expect(ST.errors("#acc(1, #sum);", members, configure: configure).count == 3)
        #expect(ST.errors("#acc(step := 1, step := 2, total := #sum);", members, configure: configure)
                == ["Parameter step is assigned more than once."])
        #expect(ST.errors("#r := #acc(step := 1, total := #sum);", members, configure: configure)
                == ["A function block call cannot be used in an expression; call it as a statement and read its outputs."])
        #expect(ST.errors("\"Accumulate\"(step := 1, total := #sum);", members, configure: configure)
                == ["The function block \"Accumulate\" needs an instance: call its instance data block or a multi-instance, e.g. #Accumulate_Instance(…)."])
        #expect(ST.errors("#sum(step := 1);", members, configure: configure) == ["#sum is not a function block instance and cannot be called."])
    }

    @Test func singleInstanceDataBlock() throws {
        let block = accumulator()
        let type = try #require(block.functionBlockType)
        let run = try #require(STRun.make("\"Acc_DB\"(step := 2, total := #sum);\n#c := \"Acc_DB\".count;",
                                          [ST.member("sum", .int), ST.member("c", .int)],
                                          configure: { resolver in
                                              resolver.blocks["accumulate"] = block
                                              resolver.addGlobal("Acc_DB", .instance(type))
                                          }))
        try run.scan()
        try run.scan()
        #expect(run["sum"] == .int(4))
        #expect(run["c"] == .int(2))
    }

    private func adder() -> BlockHandle {
        ST.userBlock("Add3", kind: .function, members: [
            ST.member("a", .int, .input), ST.member("b", .int, .input), ST.member("Add3", .int, .returnValue),
        ], source: "#Add3 := #a + #b + 3;")
    }

    @Test func functionWithReturnValue() throws {
        let block = adder()
        let run = try #require(STRun.make("#r := \"Add3\"(a := 1, b := 2) * 2;\n#s := Add3(b := #r, a := 0);",
                                          [ST.member("r", .int), ST.member("s", .dint)],
                                          configure: { $0.blocks["add3"] = block }))
        try run.scan()
        #expect(run["r"] == .int(12))
        #expect(run["s"] == .int(15))
    }

    @Test func functionParametersMustAllBeSupplied() {
        let block = adder()
        let scale = ST.userBlock("Scale", kind: .function, members: [
            ST.member("x", .int, .input), ST.member("y", .int, .output),
        ], source: "#y := #x * 10;")
        let configure: (STTestResolver) -> Void = { resolver in
            resolver.blocks["add3"] = block
            resolver.blocks["scale"] = scale
        }
        let members = [ST.member("r", .int)]
        #expect(ST.errors("#r := \"Add3\"(a := 1);", members, configure: configure) == ["The input parameter b of \"Add3\" must be supplied."])
        #expect(ST.errors("\"Scale\"(x := 1);", members, configure: configure) == ["The output parameter y of \"Scale\" must be supplied."])
        #expect(ST.errors("#r := \"Scale\"(x := 1, y => #r);", members, configure: configure)
                == ["\"Scale\" has no return value (Void) and cannot be used in an expression."])
        #expect(ST.errors("#r := \"Add3\"(1, 2);", members, configure: configure)
                    .contains("Parameters of \"Add3\" must be named, e.g. IN := …; positional arguments are only possible for standard functions."))
        #expect(ST.errors("#r := \"Nothing\"(1);", members, configure: configure) == ["Block or instruction \"Nothing\" not defined."])
        #expect(ST.errors("r := Nothing(1);", members, dialect: .melsec, configure: configure)
                == ["Function or function block \"Nothing\" is not defined."])
        // GX Works: function outputs may be left open.
        #expect(ST.errors("Scale(x := 1);", members, dialect: .melsec, configure: configure).isEmpty)
    }

    @Test func functionWithOutputs() throws {
        let scale = ST.userBlock("Scale", kind: .function, members: [
            ST.member("x", .int, .input), ST.member("y", .int, .output), ST.member("z", .int, .inOut),
        ], source: "#y := #x * 10;\n#z := #z + 1;")
        let run = try #require(STRun.make("\"Scale\"(x := 4, y => #r, z := #counter);", [ST.member("r", .dint), ST.member("counter", .int)],
                                          configure: { $0.blocks["scale"] = scale }))
        try run.scan()
        try run.scan()
        #expect(run["r"] == .int(40))
        #expect(run["counter"] == .int(2))
    }

    @Test func functionReturningAStructure() throws {
        let point = PLCType.structure(name: "Point", members: [ST.member("x", .int), ST.member("y", .int)])
        let make = ST.userBlock("MakePoint", kind: .function, members: [
            ST.member("v", .int, .input), PLCMember("MakePoint", point, section: .returnValue),
        ], source: "#MakePoint.x := #v;\n#MakePoint.y := #v * 2;")
        let run = try #require(STRun.make("#p := \"MakePoint\"(v := 3);", [PLCMember("p", point)], configure: { $0.blocks["makepoint"] = make }))
        try run.scan()
        #expect(run["p.y"] == .int(6))
    }

    @Test func faultsInsideACalleeNameTheCallee() throws {
        let broken = ST.userBlock("Broken", kind: .function, members: [
            ST.member("i", .int, .input), PLCMember("a", .array(lower: 0, upper: 1, element: .elementary(.int)), section: .temp),
        ], source: "\n#a[#i] := 1;")
        let run = try #require(STRun.make("\"Broken\"(i := 5);", configure: { $0.blocks["broken"] = broken }))
        do {
            try run.scan()
            Issue.record("expected a fault")
        } catch let fault as RuntimeFault {
            #expect(fault.kind == .indexOutOfRange)
            #expect(fault.block == "Broken [FC2]")
            #expect(fault.location == "Line 2")
        }
    }

    private func setProcedure() -> NativeProcedure {
        NativeProcedure(name: "SET", parameters: [
            NativeProcedure.Parameter(name: "EN", type: .bool, isOutput: false),
            NativeProcedure.Parameter(name: "d", type: nil, isOutput: true),
        ], returnType: nil) { arguments, _ in
            if case let .value(enable) = arguments[0], enable.boolValue, case let .place(place) = arguments[1] {
                place.write(.bool(true))
            }
            return nil
        }
    }

    @Test func nativeProcedures() throws {
        let twice = NativeProcedure(name: "TWICE", parameters: [NativeProcedure.Parameter(name: "s", type: .int, isOutput: false)],
                                    returnType: .int) { arguments, _ in
            guard case let .value(value) = arguments[0] else { return nil }
            return .int(value.intValue * 2)
        }
        let run = try #require(STRun.make("SET(X0, Y1);\nD0 := TWICE(21) + 1;\nSET(EN := FALSE, d := Y2);", dialect: .melsec,
                                          configure: { resolver in
                                              resolver.procedures["SET"] = setProcedure()
                                              resolver.procedures["TWICE"] = twice
                                              resolver.addAbsolute("X0", .bool, isWritable: false).write(.bool(true))
                                              resolver.addAbsolute("Y1", .bool)
                                              resolver.addAbsolute("Y2", .bool)
                                              resolver.addAbsolute("D0", .int)
                                          }))
        try run.scan()
        #expect(run.resolver.absolutes["Y1"]?.place.read() == .bool(true))
        #expect(run.resolver.absolutes["Y2"]?.place.read() == .bool(false))
        #expect(run.resolver.absolutes["D0"]?.place.read() == .int(43))
    }

    @Test func nativeProcedureErrors() {
        let configure: (STTestResolver) -> Void = { resolver in
            resolver.procedures["SET"] = setProcedure()
            resolver.addAbsolute("X0", .bool, isWritable: false)
            resolver.addAbsolute("Y1", .bool)
        }
        #expect(ST.errors("SET(X0);", dialect: .melsec, configure: configure) == ["SET needs 2 arguments (EN, d), not 1."])
        #expect(ST.errors("SET(X0, TRUE);", dialect: .melsec, configure: configure) == ["Argument d of SET needs a tag to write to."])
        #expect(ST.errors("SET(X0, X0);", dialect: .melsec, configure: configure) == ["Cannot write the read-only operand X0."])
        #expect(ST.errors("SET(1, Y1);", dialect: .melsec, configure: configure)
                == ["Type mismatch: the argument is INT but the parameter needs BOOL. Use INT_TO_BOOL."])
        #expect(ST.errors("Y1 := SET(X0, Y1);", dialect: .melsec, configure: configure)
                == ["SET has no return value and cannot be used in an expression."])
    }
}
