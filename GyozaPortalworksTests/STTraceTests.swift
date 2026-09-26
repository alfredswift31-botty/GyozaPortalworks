import Foundation
import Testing
@testable import GyozaPortalworks

/// Monitoring: executed lines and operand values.
struct STTraceTests {
    private let members = [ST.member("a", .int), ST.member("b", .int), ST.member("c", .bool)]

    private let source = """
        #a := #b + 1;
        IF #a > 5 THEN
            #c := TRUE;
        ELSE
            #c := FALSE;
        END_IF;
        """

    @Test func recordsExecutedLinesAndValues() throws {
        let run = try #require(STRun.make(source, members))
        run.monitor()
        run.write("b", .int(2))
        try run.scan()
        let trace = run.program.trace
        #expect(trace.executedLines == [1, 2, 4, 5])
        let first = trace.entries(line: 1)
        #expect(first.map(\.text) == ["#a", "#b"])
        #expect(first.map(\.display) == ["3", "2"])
        #expect(first.first?.column == 1)
        #expect(first.first?.length == 2)
        #expect(first.last?.column == 7)
        let condition = trace.entries(line: 2)
        #expect(condition.map(\.text) == ["IF", "#a"])
        #expect(condition.first?.value == .bool(false))
        #expect(condition.first?.display == "FALSE")
        #expect(trace.entries(line: 5).first?.display == "FALSE")
        #expect(trace.entries(line: 3).isEmpty)

        run.write("b", .int(10))
        try run.scan()
        #expect(trace.executedLines == [1, 2, 3])
        #expect(trace.entries(line: 2).first?.display == "TRUE")
        #expect(trace.entries(line: 3).first?.display == "TRUE")
        // Lines that didn't run keep their last values.
        #expect(trace.entries(line: 5).first?.display == "FALSE")
        #expect(trace.allEntries.count == 6)
    }

    @Test func recordsNothingWhenNotMonitored() throws {
        let run = try #require(STRun.make(source, members))
        try run.scan()
        #expect(run.program.trace.executedLines.isEmpty)
        #expect(run.program.trace.allEntries.isEmpty)
    }

    @Test func displaysValuesInTheVendorsNotation() throws {
        let run = try #require(STRun.make("""
            #w := 16#FF;
            #t := T#1s + T#500ms;
            #r := 12.5;
            #arr[#i] := #w;
            """, [ST.member("w", .word), ST.member("t", .time), ST.member("r", .real), ST.member("i", .int, .staticVar, .int(1)),
                  PLCMember("arr", .array(lower: 0, upper: 2, element: .elementary(.word)))]))
        run.monitor()
        try run.scan()
        let trace = run.program.trace
        #expect(trace.entries(line: 1).first?.display == "16#00FF")
        #expect(trace.entries(line: 2).first?.display == "T#1S_500MS")
        #expect(trace.entries(line: 3).first?.display == "12.5")
        #expect(trace.entries(line: 4).map(\.text) == ["#arr[#i]", "#i", "#w"])
        #expect(trace.entries(line: 4).map(\.display) == ["16#00FF", "1", "16#00FF"])
    }

    @Test func loopsAndCaseRecordTheirConditions() throws {
        let run = try #require(STRun.make("""
            #n := 0;
            WHILE #n < 3 DO
                #n := #n + 1;
            END_WHILE;
            REPEAT
                #n := #n - 1;
            UNTIL #n <= 1
            END_REPEAT;
            FOR #i := 1 TO 4 DO
            END_FOR;
            CASE #n OF
                1:
                    #n := 7;
            ELSE
                #n := 8;
            END_CASE;
            IF FALSE THEN
                #n := 0;
            ELSIF #n = 7 THEN
                #n := 9;
            END_IF;
            """, [ST.member("n", .int), ST.member("i", .int)]))
        run.monitor()
        try run.scan()
        let trace = run.program.trace
        #expect(trace.entries(line: 2).first?.text == "WHILE")
        #expect(trace.entries(line: 2).first?.value == .bool(false))
        #expect(trace.entries(line: 7).first?.text == "UNTIL")
        #expect(trace.entries(line: 7).first?.value == .bool(true))
        #expect(trace.entries(line: 9).first?.text == "#i")
        #expect(trace.entries(line: 9).first?.value == .int(5))
        #expect(trace.entries(line: 11).first?.text == "CASE")
        #expect(trace.entries(line: 11).first?.value == .int(1))
        #expect(trace.entries(line: 19).first?.text == "ELSIF")
        #expect(trace.entries(line: 19).first?.value == .bool(true))
        #expect(trace.executedLines.isSuperset(of: [1, 2, 3, 5, 6, 7, 9, 11, 12, 13, 17, 19, 20]))
        #expect(!trace.executedLines.contains(15))
        #expect(!trace.executedLines.contains(18))
    }

    @Test func multiLineStatementsMarkAllTheirLines() throws {
        let run = try #require(STRun.make("#a :=\n    #b\n    + 1;\n#b := 0;", members))
        run.monitor()
        try run.scan()
        #expect(run.program.trace.executedLines == [1, 2, 3, 4])
        #expect(run.program.trace.entries(line: 2).first?.text == "#b")
    }

    @Test func callParametersAreMonitored() throws {
        let type = try #require(FunctionBlockLibrary.type(named: "TON", dialect: .siemens))
        let run = try #require(STRun.make("#t(IN := #go,\n   PT := T#1s,\n   Q => #done);",
                                          [PLCMember("t", .instance(type)), ST.member("go", .bool, .staticVar, .bool(true)), ST.member("done", .bool)]))
        run.monitor()
        try run.scan()
        let trace = run.program.trace
        #expect(trace.executedLines == [1, 2, 3])
        #expect(trace.entries(line: 1).map(\.text) == ["#go"])
        #expect(trace.entries(line: 3).map(\.display) == ["FALSE"])
    }
}

/// Syntax highlighting.
struct STSyntaxTests {
    private func spans(_ source: String, _ dialect: LanguageDialect = .siemens) -> [(String, STHighlight.Kind)] {
        let text = NSString(string: source)
        return STSyntax.highlight(source, dialect: dialect).map { (text.substring(with: $0.range), $0.kind) }
    }

    @Test func kinds() {
        let result = spans("IF #a AND \"Tag\" THEN %Q0.0 := x; END_IF; // done")
        #expect(result.map(\.0) == ["IF", "#a", "AND", "\"Tag\"", "THEN", "%Q0.0", ":=", "x", ";", "END_IF", ";", "// done"])
        #expect(result.map(\.1) == [.keyword, .localName, .keyword, .globalName, .keyword, .absoluteAddress, .operator, .identifier,
                                    .operator, .keyword, .operator, .comment])
    }

    @Test func literals() {
        let result = spans("16#FF 1.5 INT#5 T#1s LTIME#2s 'abc' 16#GG TRUE @")
        #expect(result.map(\.1) == [.number, .number, .number, .timeLiteral, .timeLiteral, .string, .invalid, .keyword, .invalid])
    }

    @Test func rangesAreUTF16() {
        let source = "(* 日本語 😀 *) #x := T#5s; (* 閉じて\nいない"
        let highlights = STSyntax.highlight(source, dialect: .siemens)
        #expect(highlights.first?.range == NSRange(location: 0, length: 12))
        #expect(highlights[1].range == NSRange(location: 13, length: 2))
        #expect(highlights[1].kind == .localName)
        #expect(highlights[3].range == NSRange(location: 19, length: 4))
        #expect(highlights[3].kind == .timeLiteral)
        // An unclosed comment runs to the end of the text.
        #expect(highlights.last?.kind == .comment)
        #expect(highlights.last.map { NSMaxRange($0.range) } == NSString(string: source).length)
    }

    @Test func melsecDevices() {
        let result = spans("D0.3 := X0 AND M1 OR K4M0.Bit OR Start;", .melsec)
        #expect(result.first.map { $0.0 } == "D0.3")
        #expect(result.first.map { $0.1 } == .absoluteAddress)
        #expect(result.filter { $0.1 == .absoluteAddress }.map(\.0) == ["D0.3", "X0", "M1", "K4M0"])
        #expect(result.contains { $0.0 == "Start" && $0.1 == .identifier })
        #expect(spans("X8 := TRUE;", .melsec).first.map { $0.1 } == .identifier)
        #expect(spans("X0 := TRUE;", .siemens).first.map { $0.1 } == .identifier)
        #expect(STSyntax.isDevice("SM400") && STSyntax.isDevice("W1F") && STSyntax.isDevice("Y17") && !STSyntax.isDevice("Y18"))
    }

    @Test func declarationWordsAreKeywords() {
        #expect(spans("VAR x END_VAR").map(\.1) == [.keyword, .identifier, .keyword])
    }

    @Test func largeSourcesHighlightQuickly() {
        let line = "IF #a > 5 AND \"Tag\".x THEN #b := LIMIT(MN := 0, IN := #c * 2, MX := 100); END_IF; // comment 日本\n"
        let source = String(repeating: line, count: 500)
        let start = Date()
        let highlights = STSyntax.highlight(source, dialect: .siemens)
        #expect(highlights.count > 500 * 20)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

/// TIA's auto-correction.
struct STFormatterTests {
    private func resolver(_ dialect: LanguageDialect = .siemens) -> STTestResolver {
        let block = BlockHandle(name: "Main", kind: .organizationBlock, number: 1, members: [
            ST.member("a", .int), ST.member("b", .int), ST.member("c", .int),
            PLCMember("MAXIMUM", .elementary(.int), section: .constant, initialValue: .int(9)),
        ])
        let resolver = STTestResolver(dialect: dialect, block: block)
        resolver.addGlobal("Start", .elementary(.bool))
        resolver.addGlobal("Motor", .elementary(.bool))
        resolver.blocks["scale"] = BlockHandle(name: "Scale", kind: .function, number: 2, members: [])
        return resolver
    }

    @Test func addsPrefixesQuotesAndUpperCase() {
        let source = "a := b + limit(mn := 0, in := c, mx := MAXIMUM);\nif Start then Motor := true; end_if; // a stays\nscale(x := a); \"Start\" := #a.x;"
        let expected = "#a := #b + LIMIT(mn := 0, in := #c, mx := #MAXIMUM);\nIF \"Start\" THEN \"Motor\" := TRUE; END_IF; // a stays\n\"Scale\"(x := #a); \"Start\" := #a.x;"
        #expect(STFormatter.canonicalize(source, resolver: resolver()) == expected)
    }

    @Test func leavesCommentsLiteralsAndUnknownNamesAlone() {
        let source = "(* a b *) unknown := 'a' ; t#5s; REGION a b\nEND_REGION"
        #expect(STFormatter.canonicalize(source, resolver: resolver()) == "(* a b *) unknown := 'a' ; t#5s; REGION a b\nEND_REGION")
    }

    @Test func gxWorksCodeIsUnchanged() {
        let source = "if a then b := 1; end_if;"
        #expect(STFormatter.canonicalize(source, resolver: resolver(.melsec)) == source)
    }
}
