import Foundation
import Testing
@testable import GyozaPortalworks

/// Expressions, operators and data types.
struct STExpressionTests {
    private let bools = [ST.member("a", .bool), ST.member("b", .bool), ST.member("c", .bool)]

    @Test func precedenceFollowsTIA() {
        #expect(ST.evaluate("2 + 3 * 4", as: .int) == .int(14))
        #expect(ST.evaluate("(2 + 3) * 4", as: .int) == .int(20))
        #expect(ST.evaluate("10 - 4 - 3", as: .int) == .int(3))
        #expect(ST.evaluate("100 / 10 / 5", as: .int) == .int(2))
        #expect(ST.evaluate("2 * 3 MOD 4", as: .int) == .int(2))
        // Unary minus binds tighter than **: (-2) ** 2.
        #expect(ST.evaluate("-2 ** 2", as: .real) == .real(4))
        #expect(ST.evaluate("-2 ** 2", as: .real, dialect: .melsec) == .real(4))
        // ** is evaluated left to right.
        #expect(ST.evaluate("2 ** 3 ** 2", as: .real) == .real(64))
        #expect(ST.evaluate("2 ** -1", as: .real) == .real(0.5))
        #expect(ST.evaluate("- 3 * 2", as: .int) == .int(-6))
        #expect(ST.evaluate("1 < 2 = TRUE", as: .bool) == .bool(true))
    }

    @Test func booleanPrecedence() throws {
        let run = try #require(STRun.make("""
            r1 := NOT a AND b;
            r2 := a OR b AND c;
            r3 := a XOR b OR c;
            r4 := NOT (a AND b);
            r5 := a & NOT c;
            r6 := a = b;
            """, bools + ["r1", "r2", "r3", "r4", "r5", "r6"].map { ST.member($0, .bool) }))
        run.write("a", .bool(false))
        run.write("b", .bool(true))
        run.write("c", .bool(false))
        try run.scan()
        #expect(run["r1"] == .bool(true))
        #expect(run["r2"] == .bool(false))
        #expect(run["r3"] == .bool(true))
        #expect(run["r4"] == .bool(true))
        #expect(run["r5"] == .bool(false))
        #expect(run["r6"] == .bool(false))
    }

    @Test func notAndPowerShareALevel() throws {
        // NOT i ** 2 is (NOT i) ** 2.
        let value = ST.evaluate("NOT i ** 2", as: .real, [ST.member("i", .int, .staticVar, .int(2))])
        #expect(value == .real(9))
    }

    @Test func untypedLiteralsAdaptToTheirContext() {
        #expect(ST.evaluate("200", as: .byte) == .int(200))
        #expect(ST.evaluate("16#FFFF", as: .word) == .int(65_535))
        #expect(ST.evaluate("-32768", as: .int) == .int(-32_768))
        #expect(ST.evaluate("4_000_000_000", as: .udint) == .int(4_000_000_000))
        #expect(ST.evaluate("5", as: .real) == .real(5))
        #expect(ST.evaluate("0.1", as: .lreal) == .real(0.1))
        #expect(ST.evaluate("0.1", as: .real) == .real(Double(Float(0.1))))
        #expect(ST.evaluate("1.5 * 2", as: .real) == .real(3))
        #expect(ST.evaluate("i + 100000", as: .dint, [ST.member("i", .int, .staticVar, .int(5))]) == .int(100_005))
        #expect(ST.evaluate("x * 1.5", as: .real, [ST.member("x", .int, .staticVar, .int(3))]) == .real(4.5))
        #expect(ST.evaluate("x * 0.1", as: .lreal, [ST.member("x", .dint, .staticVar, .int(3))]) == .real(3 * 0.1))
    }

    @Test func literalRangeErrors() {
        #expect(ST.errors("r := 40000;", [ST.member("r", .int)]) == ["The value 40000 is outside the range of Int (-32768 to 32767)."])
        #expect(ST.errors("r := -1;", [ST.member("r", .word)]) == ["The value -1 is outside the range of Word (0 to 65535)."])
        #expect(ST.errors("r := 256;", [ST.member("r", .byte)], dialect: .melsec)
                == ["Constant 256 is out of range for BYTE (0 to 255)."])
        #expect(ST.errors("r := 1;", [ST.member("r", .bool)]) == ["Implicit conversion from 'Int' to 'Bool' is not possible. Use INT_TO_BOOL."])
        #expect(ST.errors("r := 1.5;", [ST.member("r", .int)])
                == ["Implicit conversion from 'LReal' to 'Int' is not possible. Use LREAL_TO_INT, ROUND or TRUNC."])
        #expect(ST.errors("r := 5000;", [ST.member("r", .time)]) == ["Implicit conversion from 'Int' to 'Time' is not possible. Use INT_TO_TIME."])
    }

    @Test func implicitConversions() {
        let members = [ST.member("i", .int), ST.member("d", .dint), ST.member("r", .real), ST.member("w", .word),
                       ST.member("u", .uint), ST.member("l", .lreal)]
        #expect(ST.errors("d := i; r := i; l := r; w := i; i := w;", members).isEmpty)
        #expect(ST.errors("i := r;", members) == ["Implicit conversion from 'Real' to 'Int' is not possible. Use REAL_TO_INT, ROUND or TRUNC."])
        #expect(ST.errors("i := d;", members) == ["Implicit conversion from 'DInt' to 'Int' is not possible. Use DINT_TO_INT."])
        #expect(ST.errors("r := l;", members) == ["Implicit conversion from 'LReal' to 'Real' is not possible. Use LREAL_TO_REAL."])
        #expect(ST.errors("i := r;", members, dialect: .melsec)
                == ["Type mismatch: REAL cannot be converted to INT implicitly. Use REAL_TO_INT, ROUND or TRUNC."])
        #expect(ST.errors("i := w;", members, dialect: .melsec)
                == ["Type mismatch: WORD cannot be converted to INT implicitly. Use WORD_TO_INT."])
        #expect(ST.errors("r := d;", members, dialect: .melsec)
                == ["Type mismatch: DINT cannot be converted to REAL implicitly. Use DINT_TO_REAL."])
    }

    @Test func operandTypeErrors() {
        let members = [ST.member("i", .int), ST.member("b", .bool), ST.member("w", .word), ST.member("r", .real),
                       ST.member("t", .time), ST.member("x", .dint)]
        #expect(ST.errors("i := b + 1;", members) == ["Data type Bool is not permitted here."])
        #expect(ST.errors("x := t + i;", members) == ["Implicit conversion from 'Time' to 'DInt' is not possible. Use TIME_TO_DINT."])
        #expect(ST.errors("b := b AND i;", members) == ["Data types Bool and Int cannot be combined with 'AND'."])
        #expect(ST.errors("b := b < TRUE;", members) == ["Data type Bool is not permitted here. Bool values can only be compared with = and <>."])
        #expect(ST.errors("r := r MOD 2;", members) == ["Data type Real is not permitted here. MOD needs integers."])
        #expect(ST.errors("w := w + 1;", members)
                == ["Data type Word is not permitted here. Arithmetic needs integers or reals; convert first, e.g. WORD_TO_INT."])
        #expect(ST.errors("b := r AND r;", members) == ["Data type Real is not permitted here. AND needs Bool, bit strings or integers."])
        #expect(ST.errors("b := NOT r;", members) == ["Data type Real is not permitted here."])
        #expect(ST.errors("i := -b;", members) == ["Data type Bool is not permitted here."])
        #expect(ST.errors("b := b AND i;", members, dialect: .melsec)
                == ["Type mismatch: BOOL and INT cannot be combined with 'AND'."])
    }

    @Test func integersWrapLikeTheCPU() throws {
        let run = try #require(STRun.make("""
            i := i + 1;
            u := u - 1;
            s := s * 2;
            d := d + 1;
            n := -n;
            """, [ST.member("i", .int, .staticVar, .int(32_767)), ST.member("u", .usint), ST.member("s", .sint, .staticVar, .int(100)),
                  ST.member("d", .dint, .staticVar, .int(2_147_483_647)), ST.member("n", .int, .staticVar, .int(-32_768))]))
        try run.scan()
        #expect(run["i"] == .int(-32_768))
        #expect(run["u"] == .int(255))
        #expect(run["s"] == .int(-56))
        #expect(run["d"] == .int(-2_147_483_648))
        #expect(run["n"] == .int(-32_768))
    }

    @Test func integerDivisionAndModulo() {
        #expect(ST.evaluate("-7 / 2", as: .int) == .int(-3))
        #expect(ST.evaluate("-7 MOD 2", as: .int) == .int(-1))
        #expect(ST.evaluate("x / 4", as: .int, [ST.member("x", .int, .staticVar, .int(-9))]) == .int(-2))
        #expect(ST.evaluate("x MOD 4", as: .int, [ST.member("x", .int, .staticVar, .int(-9))]) == .int(-1))
        #expect(ST.evaluate("1.0 / 4", as: .real) == .real(0.25))
    }

    @Test func siemensDivisionByZeroGivesZero() throws {
        let run = try #require(STRun.make("q := x / z; m := x MOD z; t := T#1s / z;",
                                          [ST.member("x", .int, .staticVar, .int(7)), ST.member("z", .int), ST.member("q", .int, .staticVar, .int(9)),
                                           ST.member("m", .int, .staticVar, .int(9)), ST.member("t", .time, .staticVar, .time(5))]))
        try run.scan()
        #expect(run["q"] == .int(0))
        #expect(run["m"] == .int(0))
        #expect(run["t"] == .time(0))
    }

    @Test func melsecDivisionByZeroIsAnOperationError() throws {
        for source in ["q := x / z;", "q := x MOD z;", "q := 1 / 0;"] {
            let run = try #require(STRun.make("x := 7;\n" + source, [ST.member("x", .int), ST.member("z", .int), ST.member("q", .int)],
                                              dialect: .melsec))
            do {
                try run.scan()
                Issue.record("\(source) should fault")
            } catch let fault as RuntimeFault {
                #expect(fault.kind == .divisionByZero)
                #expect(fault.message == "Operation error: division by zero")
                #expect(fault.block == "Main [OB1]")
                #expect(fault.location == "Line 2")
            }
        }
        // Real division by zero stops the CPU too, like the ladder's E/;
        // a small divisor that truncates to 0 as an integer is fine.
        let real = try #require(STRun.make("y := 1.0;\nr := y / z;", [ST.member("y", .real), ST.member("z", .real), ST.member("r", .real)],
                                           dialect: .melsec))
        #expect(throws: RuntimeFault.self) { try real.scan() }
        #expect(ST.evaluate("y / 0.5", as: .real, dialect: .melsec, [ST.member("y", .real, .staticVar, .real(1))]) == .real(2))
    }

    @Test func timeArithmetic() {
        #expect(ST.evaluate("T#1s + T#500ms", as: .time) == .time(1_500))
        #expect(ST.evaluate("T#1s - T#1500ms", as: .time) == .time(-500))
        #expect(ST.evaluate("T#1s * 3", as: .time) == .time(3_000))
        #expect(ST.evaluate("2 * T#1s", as: .time) == .time(2_000))
        #expect(ST.evaluate("T#3s / 2", as: .time) == .time(1_500))
        #expect(ST.evaluate("T#1s + 500", as: .time) == .time(1_500))
        #expect(ST.evaluate("-T#2s", as: .time) == .time(-2_000))
        #expect(ST.evaluate("T#1s > T#500ms", as: .bool) == .bool(true))
        #expect(ST.evaluate("T#1s = T#1000ms", as: .bool) == .bool(true))
        #expect(ST.errors("r := T#1s * 1.5;", [ST.member("r", .time)]) == ["Data types Time and LReal cannot be combined with '*'."])
        #expect(ST.errors("r := T#1s + 500;", [ST.member("r", .time)], dialect: .melsec)
                == ["Type mismatch: TIME and DINT cannot be combined with '+'."])
        #expect(ST.errors("r := T#1s > 5;", [ST.member("r", .bool)]) == ["Data types Time and DInt cannot be combined with '>'."])
    }

    @Test func bitStringLogic() {
        let members = [ST.member("w", .word, .staticVar, .int(0xF0F0)), ST.member("i", .int, .staticVar, .int(0x0F))]
        #expect(ST.evaluate("w AND 16#FF00", as: .word, members) == .int(0xF000))
        #expect(ST.evaluate("w OR 16#000F", as: .word, members) == .int(0xF0FF))
        #expect(ST.evaluate("w XOR 16#FFFF", as: .word, members) == .int(0x0F0F))
        #expect(ST.evaluate("NOT w", as: .word, members) == .int(0x0F0F))
        #expect(ST.evaluate("w AND i", as: .word, members) == .int(0))
        #expect(ST.evaluate("NOT 0", as: .byte) == .int(0xFF))
        #expect(ST.evaluate("i AND 16#07", as: .int, members) == .int(7))
    }

    @Test func comparisons() {
        let members = [ST.member("i", .int, .staticVar, .int(3)), ST.member("x", .real, .staticVar, .real(3.5)),
                       ST.member("w", .word, .staticVar, .int(0xFFFF))]
        #expect(ST.evaluate("i < x", as: .bool, members) == .bool(true))
        #expect(ST.evaluate("i <> 3", as: .bool, members) == .bool(false))
        #expect(ST.evaluate("i >= 3 AND x <= 3.5", as: .bool, members) == .bool(true))
        #expect(ST.evaluate("w = 16#FFFF", as: .bool, members) == .bool(true))
        #expect(ST.evaluate("w > 16#7FFF", as: .bool, members) == .bool(true))
        #expect(ST.evaluate("TRUE <> FALSE", as: .bool) == .bool(true))
    }

    @Test func stringsAreRejected() {
        #expect(ST.errors("r := 'abc';", [ST.member("r", .int)]) == ["Data type STRING is not supported in this simulator."])
    }
}

/// Names, access paths, slices and diagnostics about them.
struct STOperandTests {
    @Test func undefinedNamesUseTIAWording() {
        #expect(ST.errors("#x := 1;") == ["Tag #x not defined."])
        #expect(ST.errors("\"Start\" := TRUE;") == ["Tag \"Start\" not defined."])
        #expect(ST.errors("y := 1;") == ["Tag \"y\" not defined."])
        #expect(ST.errors("#s.zz := 1;", [PLCMember("s", .structure(name: nil, members: [ST.member("a", .int)]))])
                == ["Tag #s.zz not defined."])
        #expect(ST.errors("y := 1;", dialect: .melsec) == ["Label or device \"y\" is not defined."])
        #expect(ST.errors("%MW10 := 1;") == ["%MW10 is not a valid address."])
    }

    @Test func placeholdersMustBeReplaced() {
        #expect(ST.errors("#b := _bool_in_;", [ST.member("b", .bool)]) == ["Placeholder _bool_in_ must be replaced with an operand."])
        #expect(ST.errors("_int_out_ := 1;") == ["Placeholder _int_out_ must be replaced with an operand."])
    }

    @Test func readOnlyOperandsAndConstants() {
        let configure: (STTestResolver) -> Void = { resolver in
            resolver.addGlobal("Input", .elementary(.bool), isWritable: false)
            resolver.constants["MaxSpeed"] = (.int(100), .int)
        }
        #expect(ST.errors("\"Input\" := TRUE;", configure: configure) == ["The tag is read-only."])
        #expect(ST.errors("\"MaxSpeed\" := 1;", configure: configure) == ["The tag is read-only."])
        #expect(ST.errors("#K := 1;", [PLCMember("K", .elementary(.int), section: .constant, initialValue: .int(3))]) == ["The tag is read-only."])
        #expect(ST.errors("Input := TRUE;", dialect: .melsec, configure: configure) == ["Cannot write the read-only operand Input."])
    }

    @Test func constantsAreTyped() throws {
        let run = try #require(STRun.make("r := #K * 2; s := \"Max\" + 1;",
                                          [ST.member("r", .int), ST.member("s", .dint),
                                           PLCMember("K", .elementary(.int), section: .constant, initialValue: .int(21))],
                                          configure: { $0.constants["Max"] = (.int(9), .dint) }))
        try run.scan()
        #expect(run["r"] == .int(42))
        #expect(run["s"] == .int(10))
    }

    @Test func arraysWithDynamicIndices() throws {
        let members = [PLCMember("values", .array(lower: 1, upper: 5, element: .elementary(.int))), ST.member("i", .int),
                       ST.member("sum", .int), PLCMember("grid", .array(lower: 0, upper: 2, element: .array(lower: 0, upper: 2, element: .elementary(.int))))]
        let run = try #require(STRun.make("""
            FOR i := 1 TO 5 DO
                values[i] := i * 10;
            END_FOR;
            sum := values[values[1] / 10 + 1] + values[5];
            grid[1, 2] := 7;
            grid[2][0] := grid[1][2] + 1;
            """, members))
        try run.scan()
        #expect(run["values[3]"] == .int(30))
        #expect(run["sum"] == .int(70))
        #expect(run.node("grid")?.element(1)?.element(2)?.read() == .int(7))
        #expect(run.node("grid")?.element(2)?.element(0)?.read() == .int(8))
    }

    @Test func dynamicIndexOutOfRangeFaults() throws {
        let run = try #require(STRun.make("i := 6;\nvalues[i] := 1;",
                                          [PLCMember("values", .array(lower: 1, upper: 5, element: .elementary(.int))), ST.member("i", .int)]))
        do {
            try run.scan()
            Issue.record("expected an index fault")
        } catch let fault as RuntimeFault {
            #expect(fault.kind == .indexOutOfRange)
            #expect(fault.message == "Array index 6 is outside the limits [1..5] of values.")
            #expect(fault.block == "Main [OB1]")
            #expect(fault.location == "Line 2")
        }
    }

    @Test func constantIndexOutOfRangeIsACompileError() {
        let members = [PLCMember("values", .array(lower: 1, upper: 5, element: .elementary(.int))), ST.member("r", .real)]
        #expect(ST.errors("values[6] := 1;", members) == ["Index 6 is outside the array limits [1..5]."])
        #expect(ST.errors("values[r] := 1;", members) == ["Data type Real is not permitted here. An array index must be an integer."])
        #expect(ST.errors("r[1] := 1;", members) == ["r is not an array."])
    }

    @Test func structuresAndGlobalDataBlocks() throws {
        let motor = PLCType.structure(name: "Motor", members: [ST.member("speed", .int), ST.member("on", .bool)])
        let run = try #require(STRun.make("""
            #m.speed := 5;
            #m.on := TRUE;
            #copy := #m;
            "Plant".motors[2] := #m;
            "Plant".motors[2].speed := "Plant".motors[2].speed * 3;
            "Plant"."Line speed" := #copy.speed;
            """, [PLCMember("m", motor), PLCMember("copy", motor)],
            configure: { resolver in
                resolver.addGlobal("Plant", .structure(name: nil, members: [
                    PLCMember("motors", .array(lower: 1, upper: 3, element: motor)),
                    ST.member("Line speed", .int),
                ]))
            }))
        try run.scan()
        #expect(run["copy.speed"] == .int(5))
        #expect(run["copy.on"] == .bool(true))
        let plant = try #require(run.resolver.globals["plant"]?.place.node)
        #expect(STRun.node("motors[2].speed", in: plant)?.read() == .int(15))
        #expect(plant.member("Line speed")?.read() == .int(5))
    }

    @Test func wholeAssignmentNeedsIdenticalTypes() {
        let members = [PLCMember("a", .structure(name: "A", members: [ST.member("x", .int)])),
                       PLCMember("b", .structure(name: "B", members: [ST.member("x", .int)])),
                       PLCMember("v", .array(lower: 0, upper: 3, element: .elementary(.int))),
                       PLCMember("w", .array(lower: 0, upper: 4, element: .elementary(.int)))]
        #expect(ST.errors("a := b;", members) == ["Implicit conversion from '\"B\"' to '\"A\"' is not possible."])
        #expect(ST.errors("v := w;", members) == ["Implicit conversion from 'Array[0..4] of Int' to 'Array[0..3] of Int' is not possible."])
        #expect(ST.errors("v := 1;", members) == ["Data type Array[0..3] of Int is not permitted here: assign a tag of the same data type."])
        #expect(ST.errors("v[0] := a;", members) == ["Data type \"A\" is not permitted here."])
    }

    @Test func slices() throws {
        let run = try #require(STRun.make("""
            #w.%X3 := TRUE;
            #w.%B1 := 16#AB;
            #bit := #w.%X15;
            #low := #d.%W0;
            #d.%W1 := #w;
            %MW10.%X0 := TRUE;
            """, [ST.member("w", .word), ST.member("bit", .bool), ST.member("low", .word),
                  ST.member("d", .dword, .staticVar, .int(0x1234_5678))],
            configure: { $0.addAbsolute("%MW10", .word) }))
        try run.scan()
        #expect(run["w"] == .int(0xAB08))
        #expect(run["bit"] == .bool(true))
        #expect(run["low"] == .int(0x5678))
        #expect(run["d"] == .int(0xAB08_5678))
        #expect(run.resolver.absolutes["%MW10"]?.place.read() == .int(1))
        #expect(ST.errors("#w.%X16 := TRUE;", [ST.member("w", .word)]) == ["The slice .%X16 is outside the 16 bits of Word."])
        #expect(ST.errors("#w.%Q1 := TRUE;", [ST.member("w", .word)])
                == ["Invalid slice access '.%Q1': use .%X<bit>, .%B<byte>, .%W<word> or .%D<double word>."])
        #expect(ST.errors("#r.%X1 := TRUE;", [ST.member("r", .real)]) == ["Data type Real is not permitted here. Slice access needs a bit string or an integer."])
        #expect(ST.errors("#w.3 := TRUE;", [ST.member("w", .word)]) == ["Bit access is written .%X3 in SCL."])
    }

    @Test func melsecBitOfWord() throws {
        let run = try #require(STRun.make("""
            D0.3 := TRUE;
            D0.F := X0;
            M0 := D0.3;
            status.A := TRUE;
            """, [ST.member("status", .word)], dialect: .melsec,
            configure: { resolver in
                resolver.addAbsolute("D0", .int)
                resolver.addAbsolute("M0", .bool)
                resolver.addAbsolute("X0", .bool, isWritable: false).write(.bool(true))
            }))
        try run.scan()
        #expect(run.resolver.absolutes["D0"]?.place.read() == .int(-32_760))
        #expect(run.resolver.absolutes["M0"]?.place.read() == .bool(true))
        #expect(run["status"] == .int(0x0400))
        let errors = ST.errors("D0.10 := TRUE; M0.1 := TRUE; X0 := TRUE;", dialect: .melsec) { resolver in
            resolver.addAbsolute("D0", .int)
            resolver.addAbsolute("M0", .bool)
            resolver.addAbsolute("X0", .bool, isWritable: false)
        }
        #expect(errors == ["Invalid bit number '10': use one hexadecimal digit, 0 to F.",
                           "Type mismatch: data type BOOL cannot be used here. A bit number needs a word device or an integer label.",
                           "Cannot write the read-only operand X0."])
        #expect(ST.errors("#w.%X1 := TRUE;", [ST.member("w", .word)], dialect: .melsec)
                == ["Slice access such as .%X3 is not available in GX Works; write the bit number, e.g. D0.3."])
    }

    @Test func enoCanBeWrittenAndRead() throws {
        let block = BlockHandle(name: "Check", kind: .function, number: 3, members: [ST.member("ok", .bool, .output)])
        let resolver = STTestResolver(dialect: .siemens, block: block)
        let program = try #require(STCompiler.compile("ENO := FALSE;\n#ok := ENO;", resolver: resolver).program)
        let context = ExecutionContext(dialect: .siemens)
        let frame = Frame(context: context, block: block, instance: block.makeInstanceArea(), temps: block.makeTemps())
        try program.execute(frame)
        #expect(frame.enableOutput == false)
        #expect(frame.instance.member("ok")?.read() == .bool(false))
    }

    @Test func tempReadBeforeWriteWarns() {
        let members = [ST.member("t", .int, .temp), ST.member("u", .int, .temp), ST.member("x", .int)]
        let diagnostics = ST.compile("x := t + 1;\nu := 5;\nx := u + t;", members).diagnostics
        #expect(diagnostics.map(\.severity) == [.warning])
        #expect(diagnostics.first?.message == "The temporary tag t is read before it is written; its value is undefined.")
        #expect(diagnostics.first?.line == 1)
        #expect(ST.compile("t := 1; x := t;", members).diagnostics.isEmpty)
        #expect(ST.compile("x := t + 1;", members, dialect: .melsec).diagnostics.isEmpty)
    }
}
