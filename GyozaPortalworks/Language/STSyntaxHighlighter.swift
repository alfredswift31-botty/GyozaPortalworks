import Foundation

/// A coloured range of SCL / ST source.
nonisolated struct STHighlight: Hashable {
    nonisolated enum Kind: Hashable, Sendable {
        case keyword, comment, number, timeLiteral, string
        /// `#x`
        case localName
        /// `"x"`
        case globalName
        /// `%I0.0`, `%MW10`, and GX Works devices: `X0`, `D100`, `D0.3`.
        case absoluteAddress
        case identifier
        case `operator`
        case invalid
    }

    /// In UTF-16 code units, as NSTextView expects.
    var range: NSRange
    var kind: Kind
}

/// Syntax highlighting for the SCL / ST editors; fast enough to run on
/// every keystroke.
nonisolated enum STSyntax {
    static func highlight(_ source: String, dialect: LanguageDialect) -> [STHighlight] {
        let tokens = STLexer.tokenize(source).tokens
        var highlights: [STHighlight] = []
        highlights.reserveCapacity(tokens.count)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            let kind: STHighlight.Kind
            switch token.kind {
            case .endOfFile:
                continue
            case .keyword:
                kind = .keyword
            case .comment:
                kind = .comment
            case .localName:
                kind = .localName
            case .globalName:
                kind = .globalName
            case .absolute:
                kind = .absoluteAddress
            case .string:
                kind = .string
            case .symbol:
                kind = .operator
            case .invalid:
                kind = .invalid
            case .regionName:
                kind = .identifier
            case .literal:
                kind = literalKind(token)
            case .identifier:
                if reservedWords.contains(token.text.uppercased()) {
                    kind = .keyword
                } else if dialect == .melsec && isDevice(token.text) {
                    // D0.3: the bit number belongs to the device.
                    if index + 1 < tokens.count, tokens[index].kind == .symbol(.dot),
                       tokens[index].range.start.offset == token.range.end.offset,
                       tokens[index + 1].range.start.offset == tokens[index].range.end.offset,
                       tokens[index + 1].text.count == 1, tokens[index + 1].text.first?.isHexDigit == true {
                        let end = tokens[index + 1].range.end.offset
                        highlights.append(STHighlight(range: NSRange(location: token.range.start.offset, length: end - token.range.start.offset),
                                                      kind: .absoluteAddress))
                        index += 2
                        continue
                    }
                    kind = .absoluteAddress
                } else {
                    kind = .identifier
                }
            }
            highlights.append(STHighlight(range: NSRange(location: token.range.start.offset, length: token.range.length), kind: kind))
        }
        return highlights
    }

    private static func literalKind(_ token: STToken) -> STHighlight.Kind {
        if case .invalid = token.literal { return .invalid }
        guard let hash = token.text.firstIndex(of: "#"), let first = token.text.first, !first.isNumber else { return .number }
        switch token.text[..<hash].uppercased() {
        case "T", "TIME", "LT", "LTIME", "S5T", "S5TIME", "D", "DATE", "TOD", "TIME_OF_DAY", "LTOD", "LTIME_OF_DAY",
             "DT", "DATE_AND_TIME", "LDT", "DTL":
            return .timeLiteral
        case "CHAR", "WCHAR", "STRING", "WSTRING":
            return .string
        default:
            return .number
        }
    }

    /// Declaration keywords: not part of a code body, but still keywords when typed.
    private static let reservedWords: Set<String> = [
        "VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_IN_OUT", "VAR_TEMP", "VAR_STAT", "VAR_GLOBAL", "VAR_EXTERNAL", "END_VAR",
        "CONSTANT", "RETAIN", "NON_RETAIN", "FUNCTION", "END_FUNCTION", "FUNCTION_BLOCK", "END_FUNCTION_BLOCK",
        "PROGRAM", "END_PROGRAM", "ORGANIZATION_BLOCK", "END_ORGANIZATION_BLOCK", "DATA_BLOCK", "END_DATA_BLOCK",
        "BEGIN", "TYPE", "END_TYPE", "STRUCT", "END_STRUCT", "ARRAY", "AT", "REF_TO",
    ]

    /// GX Works (FX5U) device names: X0, Y17 (octal), M100, D0, SM400, SD100,
    /// TS0, CN1, B1F / W1F (hexadecimal), K4M0 (digit-specified).
    static func isDevice(_ name: String) -> Bool {
        let text = name.uppercased()
        if text.count >= 4, text.hasPrefix("K"), let digits = text.dropFirst().first, ("1"..."8").contains(digits) {
            let rest = String(text.dropFirst(2))
            for prefix in ["SB", "X", "Y", "M", "L", "B", "F", "S"] where rest.hasPrefix(prefix) {
                if isNumber(rest.dropFirst(prefix.count), for: prefix) { return true }
            }
        }
        for prefix in devicePrefixes where text.hasPrefix(prefix) {
            if isNumber(text.dropFirst(prefix.count), for: prefix) { return true }
        }
        return false
    }

    private static let devicePrefixes = [
        "LCS", "LCC", "LCN", "STS", "STC", "STN", "SM", "SD", "SB", "SW", "TS", "TC", "TN", "CS", "CC", "CN", "LC", "LZ",
        "ST", "X", "Y", "M", "L", "B", "F", "V", "S", "D", "W", "R", "T", "C", "Z",
    ]

    private static func isNumber(_ digits: Substring, for prefix: String) -> Bool {
        guard !digits.isEmpty else { return false }
        switch prefix {
        case "X", "Y": return digits.allSatisfy { ("0"..."7").contains($0) }
        case "B", "W", "SB", "SW": return digits.allSatisfy(\.isHexDigit)
        default: return digits.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
