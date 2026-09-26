import Foundation
import Testing
@testable import GyozaPortalworks

struct STStandardLibraryTests {
    private func real(_ value: Double) -> PLCValue { .real(Double(Float(value))) }

    @Test func mathematics() {
        #expect(ST.evaluate("ABS(-5)", as: .int) == .int(5))
        #expect(ST.evaluate("ABS(-2.5)", as: .real) == .real(2.5))
        #expect(ST.evaluate("ABS(x)", as: .int, [ST.member("x", .int, .staticVar, .int(-32_768))]) == .int(-32_768))
        #expect(ST.evaluate("SQR(3.0)", as: .real) == .real(9))
        #expect(ST.evaluate("SQRT(16.0)", as: .real) == .real(4))
        #expect(ST.evaluate("SQRT(x)", as: .real, [ST.member("x", .int, .staticVar, .int(9))]) == .real(3))
        #expect(ST.evaluate("LN(1.0)", as: .real) == .real(0))
        #expect(ST.evaluate("LOG(100.0)", as: .lreal) == .real(2))
        #expect(ST.evaluate("EXP(0.0)", as: .real) == .real(1))
        #expect(ST.evaluate("SIN(0.0) + COS(0.0)", as: .real) == .real(1))
        #expect(ST.evaluate("ATAN(1.0) * 4.0", as: .lreal) == .real(Double.pi))
        #expect(ST.evaluate("TAN(0.0) + ASIN(0.0) + ACOS(1.0)", as: .real) == .real(0))
        #expect(ST.evaluate("FRAC(2.75)", as: .real) == .real(0.75))
        #expect(ST.evaluate("EXPT(2.0, 3)", as: .real) == .real(8))
        #expect(ST.evaluate("EXPT(IN1 := 4.0, IN2 := 0.5)", as: .real) == .real(2))
    }

    @Test func invalidResultsClearENO() throws {
        let run = try #require(STRun.make("""
            #r := SQRT(IN := -1.0, ENO => #ok1);
            #x := LIMIT(MN := 10, IN := 5, MX := 0, ENO => #ok2);
            #y := LIMIT(MN := 0, IN := 5, MX := 10, ENO => #ok3);
            """, [ST.member("r", .real), ST.member("x", .int), ST.member("y", .int), ST.member("ok1", .bool, .staticVar, .bool(true)),
                  ST.member("ok2", .bool, .staticVar, .bool(true)), ST.member("ok3", .bool)]))
        try run.scan()
        #expect(run["r"].map { $0.doubleValue.isNaN } == true)
        #expect(run["ok1"] == .bool(false))
        #expect(run["x"] == .int(5))
        #expect(run["ok2"] == .bool(false))
        #expect(run["y"] == .int(5))
        #expect(run["ok3"] == .bool(true))
    }

    @Test func roundingFunctions() {
        #expect(ST.evaluate("ROUND(2.5)", as: .int) == .int(2))
        #expect(ST.evaluate("ROUND(3.5)", as: .int) == .int(4))
        #expect(ST.evaluate("ROUND(2.5)", as: .int, dialect: .melsec) == .int(3))
        #expect(ST.evaluate("ROUND(-2.5)", as: .int, dialect: .melsec) == .int(-3))
        #expect(ST.evaluate("TRUNC(-2.7)", as: .int) == .int(-2))
        #expect(ST.evaluate("CEIL(2.1)", as: .int) == .int(3))
        #expect(ST.evaluate("FLOOR(-2.1)", as: .dint) == .int(-3))
        #expect(ST.evaluate("ROUND(x) + 1", as: .dint, [ST.member("x", .real, .staticVar, .real(2.4))]) == .int(3))
        #expect(ST.evaluate("ROUND(2.5)", as: .real) == .real(2))
    }

    @Test func roundingReturnsTheTargetTypeOnlyAsTheWholeRightSide() {
        let members = [ST.member("i", .int), ST.member("r", .real)]
        #expect(ST.errors("i := ROUND(r);", members).isEmpty)
        #expect(ST.errors("i := (TRUNC(r));", members).isEmpty)
        #expect(ST.errors("i := ROUND(r) + 1;", members) == ["Implicit conversion from 'DInt' to 'Int' is not possible. Use DINT_TO_INT."])
    }

    @Test func selection() {
        let members = [ST.member("i", .int, .staticVar, .int(7)), ST.member("x", .real, .staticVar, .real(1.5))]
        #expect(ST.evaluate("MIN(3, 9, -2)", as: .int) == .int(-2))
        #expect(ST.evaluate("MAX(IN1 := 3, IN2 := 9, IN3 := -2)", as: .int) == .int(9))
        #expect(ST.evaluate("MAX(i, 100000)", as: .dint, members) == .int(100_000))
        #expect(ST.evaluate("MAX(x, 2)", as: .real, members) == .real(2))
        #expect(ST.evaluate("MIN(T#1s, T#2s)", as: .time) == .time(1_000))
        #expect(ST.evaluate("LIMIT(MN := 0, IN := 150, MX := 100)", as: .int) == .int(100))
        #expect(ST.evaluate("LIMIT(0, -5, 100)", as: .int) == .int(0))
        #expect(ST.evaluate("SEL(G := TRUE, IN0 := 1, IN1 := 2)", as: .int) == .int(2))
        #expect(ST.evaluate("SEL(FALSE, T#1s, T#2s)", as: .time) == .time(1_000))
        #expect(ST.evaluate("MUX(1, 10, 20, 30)", as: .int) == .int(20))
        #expect(ST.evaluate("MUX(K := 0, IN0 := 10, IN1 := 20)", as: .int) == .int(10))
        #expect(ST.evaluate("MUX(7, 1, 2)", as: .int) == .int(2))
    }

    @Test func muxOutOfRangeUsesElse() throws {
        let run = try #require(STRun.make("#r := MUX(K := #k, IN0 := 1, IN1 := 2, INELSE := 99, ENO => #ok);",
                                          [ST.member("k", .int, .staticVar, .int(5)), ST.member("r", .int), ST.member("ok", .bool)]))
        try run.scan()
        #expect(run["r"] == .int(99))
        #expect(run["ok"] == .bool(false))
        run.write("k", .int(1))
        try run.scan()
        #expect(run["r"] == .int(2))
        #expect(run["ok"] == .bool(true))
    }

    @Test func shiftsAndRotates() {
        let members = [ST.member("w", .word, .staticVar, .int(0x00FF)), ST.member("i", .int, .staticVar, .int(-8))]
        #expect(ST.evaluate("SHL(IN := w, N := 4)", as: .word, members) == .int(0x0FF0))
        #expect(ST.evaluate("SHR(IN := 16#8000, N := 15)", as: .word) == .int(1))
        #expect(ST.evaluate("SHR(IN := i, N := 1)", as: .int, members) == .int(-4))
        #expect(ST.evaluate("ROL(IN := BYTE#16#81, N := 1)", as: .byte) == .int(0x03))
        #expect(ST.evaluate("ROR(BYTE#16#01, 1)", as: .byte) == .int(0x80))
    }

    @Test func scaling() {
        #expect(ST.evaluate("NORM_X(MIN := 0, VALUE := 13824, MAX := 27648)", as: .real) == .real(0.5))
        #expect(ST.evaluate("SCALE_X(MIN := 0, VALUE := 0.5, MAX := 100)", as: .int) == .int(50))
        #expect(ST.evaluate("SCALE_X(MIN := 0, VALUE := 0.25, MAX := 10)", as: .real) == .real(2.5))
        #expect(ST.evaluate("MOVE(5)", as: .int) == .int(5))
    }

    @Test func conversions() {
        #expect(ST.evaluate("INT_TO_REAL(3)", as: .real) == .real(3))
        #expect(ST.evaluate("REAL_TO_INT(2.5)", as: .int) == .int(2))
        #expect(ST.evaluate("REAL_TO_INT(2.5)", as: .int, dialect: .melsec) == .int(3))
        #expect(ST.evaluate("REAL_TO_DINT(-3.5)", as: .dint) == .int(-4))
        #expect(ST.evaluate("WORD_TO_INT(16#FFFF)", as: .int) == .int(-1))
        #expect(ST.evaluate("INT_TO_WORD(-1)", as: .word) == .int(0xFFFF))
        #expect(ST.evaluate("DINT_TO_TIME(1500)", as: .time) == .time(1_500))
        #expect(ST.evaluate("TIME_TO_DINT(T#2s)", as: .dint) == .int(2_000))
        #expect(ST.evaluate("BOOL_TO_INT(TRUE)", as: .int) == .int(1))
        #expect(ST.evaluate("INT_TO_BOOL(5)", as: .bool) == .bool(true))
        #expect(ST.evaluate("LREAL_TO_REAL(0.1)", as: .real) == real(0.1))
        #expect(ST.evaluate("DINT_TO_INT(70000)", as: .int) == .int(4_464))
        #expect(ST.evaluate("int_to_dint(5)", as: .dint) == .int(5))
        #expect(ST.errors("r := INT_TO_REAL(d);", [ST.member("r", .real), ST.member("d", .dint)])
                == ["The data type DInt of the actual parameter does not match the data type Int of the formal parameter. Use DINT_TO_INT."])
        #expect(ST.errors("w := REAL_TO_WORD(1.0);", [ST.member("w", .word)]) == ["Block or instruction \"REAL_TO_WORD\" not defined."])
    }

    @Test func argumentErrors() {
        let members = [ST.member("x", .int), ST.member("b", .bool), ST.member("w", .word)]
        #expect(ST.errors("x := LIMIT(MN := 0, IN := 1);", members) == ["LIMIT needs 3 parameters (MN, IN, MX)."])
        #expect(ST.errors("x := LIMIT(0, IN := 1, MX := 2);", members) == ["Use either named or positional arguments for LIMIT, not both."])
        #expect(ST.errors("x := LIMIT(MN := 0, IN := 1, MAX := 2);", members)
                == ["LIMIT has no parameter MAX; its parameters are MN, IN, MX."])
        #expect(ST.errors("x := ABS(IN => x);", members) == ["The input IN of ABS must be assigned with ':='."])
        #expect(ST.errors("x := MIN(1);", members) == ["MIN needs at least two inputs (IN1, IN2)."])
        #expect(ST.errors("x := MIN(IN1 := 1, IN3 := 2);", members) == ["The inputs of MIN must be numbered without gaps, starting at IN1."])
        #expect(ST.errors("x := MUX(IN0 := 1, IN1 := 2);", members) == ["MUX needs the selector K."])
        #expect(ST.errors("x := ABS(IN := x, ENO => b);", members, dialect: .melsec) == ["ENO is not available here in GX Works."])
        #expect(ST.errors("x := ABS(w);", members) == ["Data type Word is not permitted here. ABS needs an integer or a floating-point number."])
        #expect(ST.errors("x := REAL_TO_INT(SQRT(b));", members) == ["Data type Bool is not permitted here. SQRT needs a floating-point number."])
        #expect(ST.errors("x := MAX(b, 1);", members) == ["Data types Bool and Int cannot be combined with 'MAX'."])
    }
}
