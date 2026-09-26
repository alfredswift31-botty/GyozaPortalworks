import Foundation

/// A position in ST source text. Columns and offsets count UTF-16 code
/// units, like NSString and NSTextView.
nonisolated struct STSourceLocation: Hashable, Sendable {
    /// 1-based line.
    var line: Int
    /// 1-based column.
    var column: Int
    /// Offset from the start of the text.
    var offset: Int
}

/// A span of source text; `end` is just past its last character.
nonisolated struct STSourceRange: Hashable, Sendable {
    var start: STSourceLocation
    var end: STSourceLocation

    var length: Int { end.offset - start.offset }

    /// The lines the span touches.
    var lines: ClosedRange<Int> { start.line...max(start.line, end.line) }

    func through(_ other: STSourceRange) -> STSourceRange {
        STSourceRange(start: start.offset <= other.start.offset ? start : other.start,
                      end: end.offset >= other.end.offset ? end : other.end)
    }
}

/// Reserved words of SCL / ST, matched case-insensitively.
nonisolated enum STKeyword: String, CaseIterable, Hashable, Sendable {
    case ifKeyword = "IF", then = "THEN", elsif = "ELSIF", elseKeyword = "ELSE", endIf = "END_IF"
    case caseKeyword = "CASE", of = "OF", endCase = "END_CASE"
    case forKeyword = "FOR", to = "TO", by = "BY", doKeyword = "DO", endFor = "END_FOR"
    case whileKeyword = "WHILE", endWhile = "END_WHILE"
    case repeatKeyword = "REPEAT", until = "UNTIL", endRepeat = "END_REPEAT"
    case exit = "EXIT", continueKeyword = "CONTINUE", returnKeyword = "RETURN"
    case region = "REGION", endRegion = "END_REGION", goto = "GOTO"
    case trueKeyword = "TRUE", falseKeyword = "FALSE"
    case not = "NOT", and = "AND", or = "OR", xor = "XOR", mod = "MOD"

    static func named(_ word: String) -> STKeyword? {
        guard word.utf16.count <= 10 else { return nil }
        return STKeyword(rawValue: word.uppercased())
    }

    /// Keywords that end a statement list; the enclosing statement decides
    /// whether it is the one it expects.
    var endsStatementList: Bool {
        switch self {
        case .elsif, .elseKeyword, .endIf, .endCase, .endFor, .endWhile, .until, .endRepeat, .endRegion: return true
        default: return false
        }
    }

    /// Keywords that begin a statement.
    var beginsStatement: Bool {
        switch self {
        case .ifKeyword, .caseKeyword, .forKeyword, .whileKeyword, .repeatKeyword, .exit, .continueKeyword,
             .returnKeyword, .region, .goto:
            return true
        default:
            return false
        }
    }
}

/// Operators and punctuation.
nonisolated enum STSymbol: String, Hashable, Sendable {
    case assign = ":=", output = "=>", addAssign = "+=", subtractAssign = "-=", multiplyAssign = "*="
    case divideAssign = "/=", attemptAssign = "?="
    case plus = "+", minus = "-", star = "*", slash = "/", power = "**"
    case equal = "=", notEqual = "<>", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
    case ampersand = "&", leftParen = "(", rightParen = ")", leftBracket = "[", rightBracket = "]"
    case comma = ",", semicolon = ";", colon = ":", dot = ".", range = ".."
}

/// A literal's value as the lexer read it.
nonisolated enum STLiteral: Hashable, Sendable {
    /// An untyped integer (`12`, `16#FF`): it adapts to its context.
    case integer(Int64)
    /// An untyped real (`1.5`, `2.0E-3`): it adapts to Real or LReal.
    case real(Double)
    /// A typed literal: `INT#5`, `T#1S`, `WORD#16#FF`.
    case typed(PLCValue, PLCDataType)
    /// A literal of a data type the simulator lacks (LTIME#…, DATE#…); already reported.
    case unsupported(String)
    /// A malformed literal; already reported.
    case invalid
}

nonisolated enum STTokenKind: Hashable, Sendable {
    case identifier
    case keyword(STKeyword)
    /// `#name`: the block interface (TIA).
    case localName
    /// `"name"`: a PLC tag or data block (TIA).
    case globalName
    /// `%I0.0`, `%MW10`, and the slice part of `x.%X3`.
    case absolute
    case literal
    /// `'text'`: lexed so the checker can reject it.
    case string
    case symbol(STSymbol)
    case comment
    /// The free text after REGION.
    case regionName
    /// Text the lexer could not read; already reported.
    case invalid
    case endOfFile
}

nonisolated struct STToken: Hashable, Sendable {
    var kind: STTokenKind
    /// The exact source text.
    var text: String
    var range: STSourceRange
    /// The name without `#` or quotes for local and global names; `text` otherwise.
    var name: String
    var literal: STLiteral?
}
