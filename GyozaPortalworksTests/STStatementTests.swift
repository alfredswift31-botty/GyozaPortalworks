import Foundation
import Testing
@testable import GyozaPortalworks

/// Statements and control flow.
struct STStatementTests {
    private func ints(_ names: String...) -> [PLCMember] {
        names.map { ST.member($0, .int) }
    }

    @Test func ifElsifElse() throws {
        let run = try #require(STRun.make("""
            IF x > 10 THEN
                r := 1;
            ELSIF x > 5 THEN
                r := 2;
            ELSIF x > 0 THEN
                r := 3;
            ELSE
                r := 4;
            END_IF;
            """, ints("x", "r")))
        for (x, expected) in [(11, 1), (6, 2), (1, 3), (0, 4), (-5, 4)] {
            run.write("x", .int(Int64(x)))
            try run.scan()
            #expect(run["r"] == .int(Int64(expected)), "x = \(x)")
        }
    }

    @Test func caseWithListsRangesAndElse() throws {
        let run = try #require(STRun.make("""
            CASE x OF
                0: r := 10;
                1, 3, 5: r := 20;
                6..10: r := 30;
                16, 17, 20..25:
                    r := 40;
                    r := r + 1;
                -5..-1: r := 50;
            ELSE
                r := 99;
            END_CASE;
            """, ints("x", "r")))
        for (x, expected) in [(0, 10), (3, 20), (6, 30), (10, 30), (17, 41), (22, 41), (-3, 50), (2, 99), (11, 99), (26, 99)] {
            run.write("x", .int(Int64(x)))
            try run.scan()
            #expect(run["r"] == .int(Int64(expected)), "x = \(x)")
        }
    }

    @Test func caseOnBitStringsAndConstants() throws {
        let run = try #require(STRun.make("""
            CASE #state OF
                16#01: #r := 1;
                #IDLE: #r := 2;
                "Busy": #r := 3;
            END_CASE;
            """, [ST.member("state", .byte), ST.member("r", .int),
                  PLCMember("IDLE", .elementary(.byte), section: .constant, initialValue: .int(2))],
            configure: { $0.constants["Busy"] = (.int(4), .byte) }))
        for (state, expected) in [(1, 1), (2, 2), (4, 3), (5, 3)] {
            run.write("state", .int(Int64(state)))
            try run.scan()
            #expect(run["r"] == .int(Int64(expected)))
        }
    }

    @Test func caseLabelErrors() {
        let members = [ST.member("x", .int), ST.member("b", .byte), ST.member("r", .real), ST.member("y", .int)]
        #expect(ST.errors("CASE x OF 1: ; 2, 1: ; END_CASE;", members) == ["The CASE value 1 is already used by another label."])
        #expect(ST.errors("CASE x OF 1..5: ; 5..9: ; END_CASE;", members) == ["The CASE range 5..9 is already used by another label."])
        #expect(ST.errors("CASE x OF 9..5: ; END_CASE;", members)
                == ["Invalid CASE range 9..5: the first value must not be greater than the second."])
        #expect(ST.errors("CASE b OF 300: ; END_CASE;", members) == ["The value 300 is outside the range of Byte (0 to 255)."])
        #expect(ST.errors("CASE r OF 1: ; END_CASE;", members)
                == ["Data type Real is not permitted here. The CASE expression must be an integer or a bit string."])
        #expect(ST.errors("CASE x OF y: ; END_CASE;", members) == ["A CASE label must be a constant."])
        #expect(ST.errors("CASE x OF 1: ; 1: ; END_CASE;", members, dialect: .melsec) == ["Duplicate CASE label: the value 1 is already used."])
    }

    @Test func forLoops() throws {
        let run = try #require(STRun.make("""
            sum := 0;
            FOR i := 1 TO 10 DO
                sum := sum + i;
            END_FOR;
            after := i;
            evens := 0;
            FOR i := 10 TO 1 BY -2 DO
                evens := evens + 1;
            END_FOR;
            none := 0;
            FOR i := 5 TO 1 DO
                none := none + 1;
            END_FOR;
            """, ints("i", "sum", "after", "evens", "none")))
        try run.scan()
        #expect(run["sum"] == .int(55))
        #expect(run["after"] == .int(11))
        #expect(run["evens"] == .int(5))
        #expect(run["none"] == .int(0))
    }

    @Test func forEvaluatesTheLimitsOnce() throws {
        let run = try #require(STRun.make("""
            n := 3;
            count := 0;
            FOR i := 1 TO n BY step DO
                n := 10;
                step := 5;
                count := count + 1;
            END_FOR;
            """, ints("i", "n", "count") + [ST.member("step", .int, .staticVar, .int(1))]))
        try run.scan()
        #expect(run["count"] == .int(3))
    }

    @Test func forStopsInsteadOfWrappingAround() throws {
        let run = try #require(STRun.make("""
            n := 0;
            FOR s := 120 TO 127 DO
                n := n + 1;
            END_FOR;
            m := 0;
            FOR u := 250 TO 255 BY 10 DO
                m := m + 1;
            END_FOR;
            """, [ST.member("s", .sint), ST.member("u", .usint)] + ints("n", "m")))
        try run.scan()
        #expect(run["n"] == .int(8))
        #expect(run["s"] == .int(127))
        #expect(run["m"] == .int(1))
    }

    @Test func forErrors() {
        let members = ints("i", "x") + [ST.member("r", .real), ST.member("u", .uint)]
        #expect(ST.errors("FOR i := 1 TO 10 BY 0 DO x := 1; END_FOR;", members) == ["The increment of a FOR loop must not be 0."])
        #expect(ST.errors("FOR i := 1 TO 10 DO i := 5; END_FOR;", members) == ["The FOR loop counter i cannot be changed inside the loop."])
        #expect(ST.errors("FOR r := 1 TO 10 DO x := 1; END_FOR;", members)
                == ["Data type Real is not permitted here. The FOR loop counter must be an integer (SInt, Int, DInt, USInt, UInt or UDInt)."])
        #expect(ST.errors("FOR u := 10 TO 1 BY -1 DO x := 1; END_FOR;", members) == ["The value -1 is outside the range of UInt (0 to 65535)."])
        #expect(ST.errors("FOR i := 1 TO r DO x := 1; END_FOR;", members)
                == ["Implicit conversion from 'Real' to 'Int' is not possible. Use REAL_TO_INT, ROUND or TRUNC."])
        // Writing the counter after the loop is fine.
        #expect(ST.errors("FOR i := 1 TO 10 DO x := i; END_FOR; i := 0;", members).isEmpty)
    }

    @Test func whileAndRepeat() throws {
        let run = try #require(STRun.make("""
            i := 0;
            WHILE i < 5 DO
                i := i + 1;
            END_WHILE;
            j := 0;
            REPEAT
                j := j + 2;
            UNTIL j >= 7
            END_REPEAT;
            k := 100;
            REPEAT
                k := k + 1;
            UNTIL TRUE END_REPEAT;
            """, ints("i", "j", "k")))
        try run.scan()
        #expect(run["i"] == .int(5))
        #expect(run["j"] == .int(8))
        #expect(run["k"] == .int(101))
    }

    @Test func exitAndContinueInNestedLoops() throws {
        let run = try #require(STRun.make("""
            total := 0;
            FOR i := 1 TO 5 DO
                IF i = 2 THEN
                    CONTINUE;
                END_IF;
                j := 0;
                WHILE TRUE DO
                    j := j + 1;
                    IF j > 3 THEN
                        EXIT;
                    END_IF;
                    IF j = 2 THEN
                        CONTINUE;
                    END_IF;
                    total := total + 1;
                END_WHILE;
                IF i = 4 THEN
                    EXIT;
                END_IF;
            END_FOR;
            n := 0;
            REPEAT
                n := n + 1;
                IF n < 3 THEN
                    CONTINUE;
                END_IF;
                EXIT;
            UNTIL FALSE
            END_REPEAT;
            """, ints("i", "j", "total", "n")))
        try run.scan()
        // i = 1, 3, 4 each add 2 (j = 1 and 3); the loop leaves at i = 4.
        #expect(run["total"] == .int(6))
        #expect(run["i"] == .int(4))
        #expect(run["n"] == .int(3))
    }

    @Test func exitOutsideALoopIsAnError() {
        #expect(ST.errors("EXIT;") == ["EXIT is only permitted in a FOR, WHILE or REPEAT loop."])
        #expect(ST.errors("CONTINUE;", dialect: .melsec) == ["CONTINUE can only be used inside FOR, WHILE or REPEAT."])
    }

    @Test func returnLeavesTheBlock() throws {
        let run = try #require(STRun.make("""
            a := 1;
            IF stop THEN
                RETURN;
            END_IF;
            FOR i := 1 TO 3 DO
                WHILE TRUE DO
                    RETURN;
                END_WHILE;
            END_FOR;
            a := 2;
            """, ints("a", "i") + [ST.member("stop", .bool)]))
        run.write("stop", .bool(true))
        try run.scan()
        #expect(run["a"] == .int(1))
        run.write("stop", .bool(false))
        try run.scan()
        #expect(run["i"] == .int(1))
        #expect(run["a"] == .int(1))
    }

    @Test func watchdogStopsEndlessLoops() throws {
        for source in ["WHILE TRUE DO\nEND_WHILE;", "REPEAT\nUNTIL FALSE\nEND_REPEAT;"] {
            let run = try #require(STRun.make("x := 1;\n" + source, ints("x")))
            do {
                try run.scan()
                Issue.record("the watchdog should fire")
            } catch let fault as RuntimeFault {
                #expect(fault.kind == .cycleTimeExceeded)
                #expect(fault.block == "Main [OB1]")
                #expect(fault.location == "Line 2")
            }
        }
    }

    @Test func regionsGroupStatements() throws {
        let run = try #require(STRun.make("""
            REGION Feeder system (setup)
                a := 1;
                REGION nested
                    a := a + 1;
                END_REGION
            END_REGION
            """, ints("a")))
        try run.scan()
        #expect(run["a"] == .int(2))
        #expect(ST.errors("REGION x\na := 1;\nEND_REGION", ints("a"), dialect: .melsec) == ["REGION is not available in GX Works."])
    }

    @Test func chainedAndCompoundAssignment() throws {
        let run = try #require(STRun.make("""
            a := b := 5;
            c := 1;
            c += 2;
            c -= 1;
            c *= 3;
            c /= 4;
            d := e += 10;
            r := 1.5;
            r *= 2;
            t := T#1s;
            t += T#500ms;
            """, ints("a", "b", "c") + [ST.member("d", .dint), ST.member("e", .int, .staticVar, .int(1)), ST.member("r", .real),
                                         ST.member("t", .time)]))
        try run.scan()
        #expect(run["a"] == .int(5))
        #expect(run["b"] == .int(5))
        #expect(run["c"] == .int(1))
        #expect(run["e"] == .int(11))
        #expect(run["d"] == .int(11))
        #expect(run["r"] == .real(3))
        #expect(run["t"] == .time(1_500))
    }

    @Test func chainedAssignmentStoresRightToLeft() throws {
        // a receives b's stored value: USInt 255 + 1 wraps to 0 first.
        let run = try #require(STRun.make("a := b := b + 1;", [ST.member("a", .int, .staticVar, .int(7)),
                                                               ST.member("b", .usint, .staticVar, .int(255))]))
        try run.scan()
        #expect(run["b"] == .int(0))
        #expect(run["a"] == .int(0))
        #expect(ST.errors("i := d := 5;", [ST.member("i", .int), ST.member("d", .dint)])
                == ["Implicit conversion from 'DInt' to 'Int' is not possible. Use DINT_TO_INT."])
        #expect(ST.errors("a := b := 300;", [ST.member("a", .int), ST.member("b", .usint)])
                == ["The value 300 is outside the range of USInt (0 to 255)."])
    }

    @Test func assignmentFormErrors() {
        let members = ints("a", "b") + [ST.member("r", .real)]
        #expect(ST.errors("a += r;", members) == ["Implicit conversion from 'Real' to 'Int' is not possible. Use REAL_TO_INT, ROUND or TRUNC."])
        #expect(ST.errors("a ?= b;", members) == ["The assignment attempt '?=' is not supported in this simulator."])
        #expect(ST.errors("a = b;", members) == ["Use ':=' to assign a value; '=' compares."])
        #expect(ST.errors("a += 1;", members, dialect: .melsec) == ["Compound assignment '+=' is not available in GX Works; write x := x + y."])
        #expect(ST.errors("a := b := 1;", members, dialect: .melsec) == ["Multiple assignment (a := b := c) is not available in GX Works."])
    }

    @Test func gotoAndLabelsAreRejected() {
        #expect(ST.errors("GOTO Next;", ints("a")) == ["GOTO is not supported in this simulator."])
        #expect(ST.errors("Next: a := 1;", ints("a")) == ["Jump labels are not supported in this simulator (GOTO is not supported)."])
    }

    @Test func missingSemicolonIsReportedWhereItBelongs() {
        let diagnostics = ST.compile("a := 1\nb := 2;\nIF a = 1 THEN\n  b := 3;\nEND_IF\na := 4;", ints("a", "b")).diagnostics
        #expect(diagnostics.map(\.message) == ["';' is missing at the end of the statement.", "';' is missing at the end of the statement."])
        #expect(diagnostics.first?.line == 1)
        #expect(diagnostics.first?.column == 7)
        #expect(diagnostics.last?.line == 5)
        #expect(diagnostics.last?.column == 7)
    }

    @Test func manyErrorsAreReportedAtOnce() {
        let source = """
            a := ;
            b := TRUE + 1;
            IF a THEN
                c := 1;
            END_IF;
            x := 1 2;
            WHILE a < 3 DO
                a := a + 1;
            """
        let diagnostics = ST.compile(source, ints("a", "b", "c")).diagnostics
        let lines = diagnostics.map { $0.line ?? 0 }
        #expect(diagnostics.allSatisfy { $0.severity == .error && $0.column != nil })
        #expect(lines.contains(1))
        #expect(lines.contains(2))
        #expect(lines.contains(3))
        #expect(lines.contains(6))
        #expect(diagnostics.contains { $0.message == "'END_WHILE' is missing to close WHILE." })
        #expect(diagnostics.contains { $0.message == "An operand is expected instead of ';'." })
        #expect(diagnostics.contains { $0.message == "Unexpected '2': an operator or ';' is missing before it." })
    }

    @Test func parserMessages() {
        let members = ints("a", "b")
        #expect(ST.errors("IF a = 1 b := 2; END_IF;", members) == ["'THEN' is missing after the condition."])
        #expect(ST.errors("IF a = 1 THEN b := 2;", members) == ["'END_IF' is missing to close IF."])
        #expect(ST.errors("FOR a := 1 TO 3 b := 2; END_FOR;", members) == ["'DO' is missing in the FOR statement."])
        #expect(ST.errors("END_IF;", members) == ["Unexpected 'END_IF'."])
        #expect(ST.errors("a := (1 + 2;", members) == ["')' is missing."])
        #expect(ST.errors("a;", members) == ["Incomplete statement: ':=' or a parameter list is missing after a."])
        #expect(ST.errors("CASE a OF b := 1; END_CASE;", members) == ["A CASE label (such as 1:, 2, 4: or 5..9:) is expected here."])
        #expect(ST.errors("REPEAT a := 1; END_REPEAT;", members) == ["'UNTIL' is missing in the REPEAT loop."])
    }

    @Test func emptyStatementsAndEmptyBodies() throws {
        let run = try #require(STRun.make(";;\nIF TRUE THEN END_IF;\nFOR i := 1 TO 3 DO END_FOR;\na := 7;", ints("a", "i")))
        try run.scan()
        #expect(run["a"] == .int(7))
    }
}
