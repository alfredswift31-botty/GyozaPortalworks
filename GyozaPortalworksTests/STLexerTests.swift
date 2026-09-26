import Foundation
import Testing
@testable import GyozaPortalworks

struct STLexerTests {
    private func tokens(_ source: String) -> [STToken] {
        STLexer.tokenize(source).tokens.filter { $0.kind != .endOfFile }
    }

    private func literal(_ source: String) -> STLiteral? {
        let result = STLexer.tokenize(source)
        #expect(result.diagnostics.isEmpty, "\(source): \(result.diagnostics.map(\.message))")
        return result.tokens.first?.literal
    }

    private func lexError(_ source: String) -> String? {
        STLexer.tokenize(source).diagnostics.first?.message
    }

    @Test func integerLiterals() {
        #expect(literal("12") == .integer(12))
        #expect(literal("1_000") == .integer(1_000))
        #expect(literal("16#FF") == .integer(255))
        #expect(literal("16#ff_ff") == .integer(65_535))
        #expect(literal("2#1010_0101") == .integer(165))
        #expect(literal("8#17") == .integer(15))
        #expect(literal("0") == .integer(0))
    }

    @Test func realLiterals() {
        #expect(literal("1.5") == .real(1.5))
        #expect(literal("1.5E3") == .real(1_500))
        #expect(literal("2.0e-3") == .real(0.002))
        #expect(literal("3.25e+2") == .real(325))
        #expect(literal("1_000.5") == .real(1_000.5))
    }

    @Test func typedLiterals() {
        #expect(literal("INT#5") == .typed(.int(5), .int))
        #expect(literal("DINT#-5") == .typed(.int(-5), .dint))
        #expect(literal("REAL#1.5") == .typed(.real(1.5), .real))
        #expect(literal("LREAL#2") == .typed(.real(2), .lreal))
        #expect(literal("WORD#16#FF") == .typed(.int(255), .word))
        #expect(literal("W#16#FFFF") == .typed(.int(65_535), .word))
        #expect(literal("BYTE#2#1010") == .typed(.int(10), .byte))
        #expect(literal("BOOL#1") == .typed(.bool(true), .bool))
        #expect(literal("bool#false") == .typed(.bool(false), .bool))
        #expect(literal("USINT#255") == .typed(.int(255), .usint))
        #expect(literal("sint#-128") == .typed(.int(-128), .sint))
    }

    @Test func timeLiterals() {
        #expect(literal("TIME#5s") == .typed(.time(5_000), .time))
        #expect(literal("T#5s") == .typed(.time(5_000), .time))
        #expect(literal("T#1h2m3s4ms") == .typed(.time(3_723_004), .time))
        #expect(literal("t#-5s") == .typed(.time(-5_000), .time))
        #expect(literal("T#1S_500MS") == .typed(.time(1_500), .time))
        #expect(literal("T#2.5s") == .typed(.time(2_500), .time))
        #expect(literal("T#1d") == .typed(.time(86_400_000), .time))
    }

    @Test func badLiteralsAreReported() {
        #expect(lexError("16#GG") == "Invalid number '16#GG'.")
        #expect(lexError("2#102") == "Invalid number '2#102'.")
        #expect(lexError("8#9") == "Invalid number '8#9'.")
        #expect(lexError("3#10") == "Invalid number '3#10': the base must be 2, 8 or 16.")
        #expect(lexError("1__0") == "Invalid number '1__0': '_' may only separate digits.")
        #expect(lexError("1_") == "Invalid number '1_': '_' may only separate digits.")
        #expect(lexError("12abc") == "Invalid number '12abc'.")
        #expect(lexError("1E3") == "A real number needs a decimal point: write 1.0E3.")
        #expect(lexError("INT#40000") == "The value 40000 is outside the range of Int (-32768 to 32767).")
        #expect(lexError("USINT#-1") == "The value -1 is outside the range of USInt (0 to 255).")
        #expect(lexError("BOOL#2") == "Invalid Bool literal 'BOOL#2': use TRUE, FALSE, 1 or 0.")
        #expect(lexError("INT#1.5") == "Int needs an integer value, not 'INT#1.5'.")
        #expect(lexError("T#5x") == "Invalid time literal 'T#5x'.")
        #expect(lexError("T#") == "Invalid time literal 'T#'.")
        #expect(lexError("LTIME#5s") == "Data type LTIME is not supported in this simulator.")
        #expect(lexError("DATE#2024-01-01") == "Data type DATE is not supported in this simulator.")
        #expect(lexError("STRING#'abc'") == "Data type STRING is not supported in this simulator.")
        #expect(lexError("99999999999999999999") == "The number 99999999999999999999 is too large.")
    }

    @Test func booleansAndKeywordsAreCaseInsensitive() {
        let kinds = tokens("true False if Then end_if").map(\.kind)
        #expect(kinds == [.keyword(.trueKeyword), .keyword(.falseKeyword), .keyword(.ifKeyword), .keyword(.then), .keyword(.endIf)])
    }

    @Test func namesAndAddresses() {
        let lexed = tokens("#speed \"Motor DB\".on %I0.0 %MW10 %DB1.DBX0.0 plain #\"with space\"")
        #expect(lexed.map(\.kind) == [.localName, .globalName, .symbol(.dot), .identifier, .absolute, .absolute, .absolute,
                                      .identifier, .localName])
        #expect(lexed[0].name == "speed")
        #expect(lexed[1].name == "Motor DB")
        #expect(lexed[4].text == "%I0.0")
        #expect(lexed[6].text == "%DB1.DBX0.0")
        #expect(lexed[8].name == "with space")
    }

    @Test func slicesAndBitsOfWords() {
        #expect(tokens("#w.%X3").map(\.kind) == [.localName, .symbol(.dot), .absolute])
        #expect(tokens("%MW10.%B1").map(\.text) == ["%MW10", ".", "%B1"])
        #expect(tokens("D0.3").map(\.kind) == [.identifier, .symbol(.dot), .literal])
        #expect(tokens("D0.F").map(\.kind) == [.identifier, .symbol(.dot), .identifier])
    }

    @Test func keywordsAfterADotAreMemberNames() {
        #expect(tokens("#a.region := 1;").map(\.kind) == [.localName, .symbol(.dot), .identifier, .symbol(.assign), .literal, .symbol(.semicolon)])
    }

    @Test func operators() {
        let texts = tokens(":= => += -= *= /= ?= ** <> <= >= < > = & .. . , ; : ( ) [ ] + - * /").map(\.text)
        #expect(texts == [":=", "=>", "+=", "-=", "*=", "/=", "?=", "**", "<>", "<=", ">=", "<", ">", "=", "&", "..", ".", ",", ";", ":",
                          "(", ")", "[", "]", "+", "-", "*", "/"])
        #expect(tokens("1..5").map(\.kind) == [.literal, .symbol(.range), .literal])
    }

    @Test func comments() {
        let lexed = tokens("a // line\n(* block\nmore *) b /* c */ (/* multilingual */) d")
        #expect(lexed.map(\.kind) == [.identifier, .comment, .comment, .identifier, .comment, .comment, .identifier])
        #expect(lexer("(* open").diagnostics.first?.message == "The comment is not closed: '*)' is missing.")
        #expect(lexer("/* open").diagnostics.first?.message == "The comment is not closed: '*/' is missing.")
        // A plain comment inside parentheses is not a multilingual one.
        #expect(tokens("(/* c */ a)").map(\.kind) == [.symbol(.leftParen), .comment, .identifier, .symbol(.rightParen)])
    }

    private func lexer(_ source: String) -> (tokens: [STToken], diagnostics: [Diagnostic]) {
        STLexer.tokenize(source)
    }

    @Test func stringsAndUnclosedNames() {
        #expect(tokens("'abc' 'it$'s'").map(\.kind) == [.string, .string])
        #expect(lexer("'abc").diagnostics.first?.message == "The string is not closed: ''' is missing.")
        #expect(lexer("\"Motor\nx").diagnostics.first?.message == "The name is not closed: '\"' is missing.")
        #expect(lexer("a @ b").diagnostics.first?.message == "Invalid character '@'.")
    }

    @Test func regionNameRunsToTheEndOfTheLine() {
        let lexed = tokens("REGION Feeder System  // note\nEND_REGION")
        #expect(lexed.map(\.kind) == [.keyword(.region), .regionName, .comment, .keyword(.endRegion)])
        #expect(lexed[1].text == "Feeder System")
    }

    @Test func positionsCountUTF16AndLines() {
        let lexed = tokens("a\r\n  (* 日本 😀 *) bc\n\tx")
        #expect(lexed[0].range.start == STSourceLocation(line: 1, column: 1, offset: 0))
        let comment = lexed[1]
        #expect(comment.range.start == STSourceLocation(line: 2, column: 3, offset: 5))
        // "(* 日本 😀 *)" is 11 UTF-16 units: the emoji takes two.
        #expect(comment.range.length == 11)
        #expect(lexed[2].text == "bc")
        #expect(lexed[2].range.start == STSourceLocation(line: 2, column: 15, offset: 17))
        #expect(lexed[3].range.start == STSourceLocation(line: 3, column: 2, offset: 21))
    }

    @Test func japaneseLabelsAreIdentifiers() {
        let lexed = tokens("運転 := TRUE;")
        #expect(lexed.first?.kind == .identifier)
        #expect(lexed.first?.text == "運転")
    }
}
