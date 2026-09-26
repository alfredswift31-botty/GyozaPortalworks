import Foundation

/// Splits SCL / ST source into tokens, comments included. Works on UTF-16
/// code units so every position matches NSString.
nonisolated struct STLexer {
    private let units: [UInt16]
    private var position = 0
    private var line = 1
    private var lineStart = 0
    private var tokens: [STToken] = []
    private var diagnostics: [Diagnostic] = []
    /// The last token that isn't a comment: a word after `.` is a member name, never a keyword.
    private var previousKind: STTokenKind?

    private init(units: [UInt16]) {
        self.units = units
    }

    /// All tokens, comments included, ending with an end-of-file token, plus lexical errors.
    static func tokenize(_ units: [UInt16]) -> (tokens: [STToken], diagnostics: [Diagnostic]) {
        var lexer = STLexer(units: units)
        lexer.run()
        return (lexer.tokens, lexer.diagnostics)
    }

    static func tokenize(_ source: String) -> (tokens: [STToken], diagnostics: [Diagnostic]) {
        tokenize(Array(source.utf16))
    }

    // MARK: - Character classes

    nonisolated private enum Unit {
        static let lineFeed: UInt16 = 0x0A
        static let carriageReturn: UInt16 = 0x0D
        static let quote: UInt16 = 0x22
        static let hash: UInt16 = 0x23
        static let percent: UInt16 = 0x25
        static let apostrophe: UInt16 = 0x27
        static let leftParen: UInt16 = 0x28
        static let rightParen: UInt16 = 0x29
        static let star: UInt16 = 0x2A
        static let plus: UInt16 = 0x2B
        static let minus: UInt16 = 0x2D
        static let dot: UInt16 = 0x2E
        static let slash: UInt16 = 0x2F
        static let underscore: UInt16 = 0x5F
        static let dollar: UInt16 = 0x24
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isLetter(_ unit: UInt16) -> Bool { (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) }

    static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0B || unit == 0x0C || unit == 0xA0 || unit == 0x3000 || unit == 0xFEFF
            || unit == 0x2028 || unit == 0x2029
    }

    /// Letters, `_` and any non-ASCII character except spaces (GX Works labels may be Japanese).
    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        isLetter(unit) || unit == Unit.underscore || (unit >= 0x80 && !isSpace(unit))
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }

    static func isNewline(_ unit: UInt16) -> Bool { unit == Unit.lineFeed || unit == Unit.carriageReturn }

    private func unit(at index: Int) -> UInt16? {
        index < units.count ? units[index] : nil
    }

    private func peek(_ distance: Int = 0) -> UInt16 {
        unit(at: position + distance) ?? 0
    }

    private var location: STSourceLocation {
        STSourceLocation(line: line, column: position - lineStart + 1, offset: position)
    }

    private func text(from start: Int, to end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }

    // MARK: - Main loop

    private mutating func run() {
        while position < units.count {
            let current = units[position]
            if Self.isNewline(current) {
                advanceOne()
                continue
            }
            if Self.isSpace(current) {
                position += 1
                continue
            }
            let start = location
            if current == Unit.slash && peek(1) == Unit.slash {
                lexLineComment(start)
            } else if current == Unit.leftParen && peek(1) == Unit.star {
                lexBlockComment(start, closing: [Unit.star, Unit.rightParen])
            } else if current == Unit.leftParen && peek(1) == Unit.slash && peek(2) == Unit.star,
                      let end = multilingualCommentEnd() {
                while position < end { advanceOne() }
                append(.comment, from: start)
            } else if current == Unit.slash && peek(1) == Unit.star {
                lexBlockComment(start, closing: [Unit.star, Unit.slash])
            } else if current == Unit.hash {
                lexLocalName(start)
            } else if current == Unit.quote {
                lexQuotedName(start, kind: .globalName)
            } else if current == Unit.apostrophe {
                lexString(start)
            } else if current == Unit.percent {
                lexAbsolute(start)
            } else if Self.isDigit(current) {
                let literal = scanNumber()
                append(.literal, from: start, literal: literal)
            } else if Self.isIdentifierStart(current) {
                lexWord(start)
            } else {
                lexSymbol(start)
            }
        }
        let end = location
        tokens.append(STToken(kind: .endOfFile, text: "", range: STSourceRange(start: end, end: end), name: "", literal: nil))
    }

    /// Moves past one unit, counting a line break (CR, LF or CR LF) as one.
    private mutating func advanceOne() {
        let current = units[position]
        position += 1
        if current == Unit.carriageReturn {
            if position < units.count && units[position] == Unit.lineFeed { position += 1 }
            line += 1
            lineStart = position
        } else if current == Unit.lineFeed {
            line += 1
            lineStart = position
        }
    }

    private mutating func append(_ kind: STTokenKind, from start: STSourceLocation, name: String? = nil, literal: STLiteral? = nil) {
        let text = text(from: start.offset, to: position)
        tokens.append(STToken(kind: kind, text: text, range: STSourceRange(start: start, end: location), name: name ?? text, literal: literal))
        if kind != .comment { previousKind = kind }
    }

    private mutating func error(_ message: String, at start: STSourceLocation) {
        diagnostics.append(.error(message, line: start.line, column: start.column))
    }

    // MARK: - Comments

    private mutating func lexLineComment(_ start: STSourceLocation) {
        while position < units.count && !Self.isNewline(units[position]) { position += 1 }
        append(.comment, from: start)
    }

    private mutating func lexBlockComment(_ start: STSourceLocation, closing: [UInt16]) {
        position += 2
        var closed = false
        while position < units.count {
            if units[position] == closing[0] && peek(1) == closing[1] {
                position += 2
                closed = true
                break
            }
            advanceOne()
        }
        if !closed {
            let end = String(decoding: closing, as: UTF16.self)
            error("The comment is not closed: '\(end)' is missing.", at: start)
        }
        append(.comment, from: start)
    }

    /// TIA's multilingual comment `(/* … */)`: only when the first `*/` is followed by `)`.
    private func multilingualCommentEnd() -> Int? {
        var index = position + 3
        while index + 1 < units.count {
            if units[index] == Unit.star && units[index + 1] == Unit.slash {
                return unit(at: index + 2) == Unit.rightParen ? index + 3 : nil
            }
            index += 1
        }
        return nil
    }

    // MARK: - Names

    private mutating func lexLocalName(_ start: STSourceLocation) {
        if peek(1) == Unit.quote {
            position += 1
            lexQuotedName(start, kind: .localName)
            return
        }
        guard Self.isIdentifierStart(peek(1)) else {
            position += 1
            error("Invalid character '#'.", at: start)
            append(.invalid, from: start)
            return
        }
        position += 1
        let nameStart = position
        while position < units.count && Self.isIdentifierPart(units[position]) { position += 1 }
        append(.localName, from: start, name: text(from: nameStart, to: position))
    }

    /// `"Tag name"` (also after `#`): may hold spaces and dots, but not a line break.
    private mutating func lexQuotedName(_ start: STSourceLocation, kind: STTokenKind) {
        position += 1
        let nameStart = position
        while position < units.count && units[position] != Unit.quote && !Self.isNewline(units[position]) {
            position += 1
        }
        guard position < units.count && units[position] == Unit.quote else {
            error("The name is not closed: '\"' is missing.", at: start)
            append(.invalid, from: start)
            return
        }
        let name = text(from: nameStart, to: position)
        position += 1
        if name.isEmpty {
            error("A name is missing between the quotes.", at: start)
            append(.invalid, from: start)
            return
        }
        append(kind, from: start, name: name)
    }

    /// `'text'` with `$` escapes; strings are rejected later by the checker.
    private mutating func lexString(_ start: STSourceLocation) {
        position += 1
        while position < units.count && units[position] != Unit.apostrophe && !Self.isNewline(units[position]) {
            position += units[position] == Unit.dollar && position + 1 < units.count && !Self.isNewline(units[position + 1]) ? 2 : 1
        }
        guard position < units.count && units[position] == Unit.apostrophe else {
            error("The string is not closed: ''' is missing.", at: start)
            append(.invalid, from: start)
            return
        }
        position += 1
        append(.string, from: start)
    }

    /// `%I0.0`, `%MW10`, `%DB1.DBX0.0`; a dot is part of it only when a letter or digit follows.
    private mutating func lexAbsolute(_ start: STSourceLocation) {
        position += 1
        let bodyStart = position
        while position < units.count {
            let current = units[position]
            if Self.isLetter(current) || Self.isDigit(current) || current == Unit.underscore {
                position += 1
            } else if current == Unit.dot && (Self.isLetter(peek(1)) || Self.isDigit(peek(1))) {
                position += 1
            } else {
                break
            }
        }
        guard position > bodyStart else {
            error("Invalid character '%'.", at: start)
            append(.invalid, from: start)
            return
        }
        append(.absolute, from: start)
    }

    // MARK: - Numbers

    /// Reads a number at the current position: `12`, `1_000`, `16#FF`, `2#1010`,
    /// `1.5`, `2.0E-3`. Reports malformed numbers and returns `.invalid` for them.
    private mutating func scanNumber() -> STLiteral {
        let start = location
        let digitsStart = position
        while Self.isDigit(peek()) || peek() == Unit.underscore { position += 1 }
        let decimal = text(from: digitsStart, to: position)

        if peek() == Unit.hash {
            position += 1
            let bodyStart = position
            while Self.isDigit(peek()) || Self.isLetter(peek()) || peek() == Unit.underscore { position += 1 }
            let body = text(from: bodyStart, to: position)
            let whole = text(from: digitsStart, to: position)
            guard let base = Int(decimal), [2, 8, 16].contains(base) else {
                error("Invalid number '\(whole)': the base must be 2, 8 or 16.", at: start)
                return .invalid
            }
            guard Self.validDigitGroups(body), let value = Int64(body.replacingOccurrences(of: "_", with: ""), radix: base) else {
                error("Invalid number '\(whole)'.", at: start)
                return .invalid
            }
            return .integer(value)
        }

        var isReal = false
        var needsPoint = false
        if peek() == Unit.dot && Self.isDigit(peek(1)) {
            isReal = true
            position += 1
            while Self.isDigit(peek()) || peek() == Unit.underscore { position += 1 }
        }
        if (peek() == 0x45 || peek() == 0x65)
            && (Self.isDigit(peek(1)) || ((peek(1) == Unit.plus || peek(1) == Unit.minus) && Self.isDigit(peek(2)))) {
            needsPoint = !isReal
            isReal = true
            position += 2
            while Self.isDigit(peek()) { position += 1 }
        }
        if Self.isIdentifierPart(peek()) {
            while Self.isIdentifierPart(peek()) { position += 1 }
            error("Invalid number '\(text(from: digitsStart, to: position))'.", at: start)
            return .invalid
        }
        let whole = text(from: digitsStart, to: position)
        guard Self.validDigitGroups(whole) else {
            error("Invalid number '\(whole)': '_' may only separate digits.", at: start)
            return .invalid
        }
        let plain = whole.replacingOccurrences(of: "_", with: "")
        if isReal {
            if needsPoint {
                error("A real number needs a decimal point: write \(Self.withDecimalPoint(plain)).", at: start)
                return .invalid
            }
            guard let value = Double(plain) else {
                error("Invalid number '\(whole)'.", at: start)
                return .invalid
            }
            return .real(value)
        }
        guard let value = Int64(plain) else {
            error("The number \(whole) is too large.", at: start)
            return .invalid
        }
        return .integer(value)
    }

    /// Digits with single underscores between them, none leading or trailing.
    private static func validDigitGroups(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("_"), !text.hasSuffix("_"), !text.contains("__") else { return false }
        return !text.contains("_.") && !text.contains("._") && !text.contains("_E") && !text.contains("_e")
    }

    private static func withDecimalPoint(_ text: String) -> String {
        guard let exponent = text.firstIndex(where: { $0 == "E" || $0 == "e" }) else { return text + ".0" }
        return text[..<exponent] + ".0" + text[exponent...]
    }

    // MARK: - Words and typed literals

    private mutating func lexWord(_ start: STSourceLocation) {
        let wordStart = position
        while position < units.count && Self.isIdentifierPart(units[position]) { position += 1 }
        let word = text(from: wordStart, to: position)
        let isMember = previousKind == .symbol(.dot)

        if !isMember && peek() == Unit.hash, let prefix = STTypedPrefix.named(word.uppercased()) {
            position += 1
            let literal = lexTypedBody(prefix, start: start, prefixText: word)
            append(.literal, from: start, literal: literal)
            return
        }
        if !isMember, let keyword = STKeyword.named(word) {
            append(.keyword(keyword), from: start)
            if keyword == .region { lexRegionName() }
            return
        }
        append(.identifier, from: start)
    }

    private mutating func lexTypedBody(_ prefix: STTypedPrefix, start: STSourceLocation, prefixText: String) -> STLiteral {
        switch prefix {
        case .time:
            let bodyStart = position
            if peek() == Unit.minus || peek() == Unit.plus { position += 1 }
            while Self.isIdentifierPart(peek()) || peek() == Unit.dot { position += 1 }
            var body = text(from: bodyStart, to: position)
            if body.hasPrefix("+") { body.removeFirst() }
            guard let milliseconds = TimeLiteral.parse(body) else {
                error("Invalid time literal '\(text(from: start.offset, to: position))'.", at: start)
                return .invalid
            }
            return .typed(.time(milliseconds), .time)
        case let .data(type):
            return lexTypedValue(type, start: start)
        case let .unsupported(typeName, isText):
            if isText && peek() == Unit.apostrophe {
                position += 1
                while position < units.count && units[position] != Unit.apostrophe && !Self.isNewline(units[position]) {
                    position += 1
                }
                if position < units.count && units[position] == Unit.apostrophe { position += 1 }
            } else {
                while Self.isIdentifierPart(peek()) || [Unit.dot, Unit.plus, Unit.minus, 0x3A].contains(peek()) {
                    position += 1
                }
            }
            error("Data type \(typeName) is not supported in this simulator.", at: start)
            return .unsupported(typeName)
        }
    }

    /// The value after `INT#`, `WORD#`, `REAL#`, `BOOL#`…
    private mutating func lexTypedValue(_ type: PLCDataType, start: STSourceLocation) -> STLiteral {
        var negative = false
        if peek() == Unit.minus || peek() == Unit.plus {
            negative = peek() == Unit.minus
            position += 1
        }
        if type == .bool && Self.isLetter(peek()) {
            let wordStart = position
            while Self.isIdentifierPart(peek()) { position += 1 }
            switch text(from: wordStart, to: position).uppercased() {
            case "TRUE" where !negative: return .typed(.bool(true), .bool)
            case "FALSE" where !negative: return .typed(.bool(false), .bool)
            default:
                error("Invalid Bool literal '\(whole(from: start))': use TRUE, FALSE, 1 or 0.", at: start)
                return .invalid
            }
        }
        guard Self.isDigit(peek()) else {
            while Self.isIdentifierPart(peek()) { position += 1 }
            error("Invalid literal '\(whole(from: start))'.", at: start)
            return .invalid
        }
        let saved = diagnostics.count
        let number = scanNumber()
        guard diagnostics.count == saved else { return .invalid }
        let name = type.rawValue
        switch number {
        case let .integer(magnitude):
            let value = negative ? -magnitude : magnitude
            if type.isReal {
                let stored = type == .real ? Double(Float(Double(value))) : Double(value)
                return .typed(.real(stored), type)
            }
            if type == .bool {
                guard value == 0 || value == 1 else {
                    error("Invalid Bool literal '\(whole(from: start))': use TRUE, FALSE, 1 or 0.", at: start)
                    return .invalid
                }
                return .typed(.bool(value == 1), .bool)
            }
            guard let range = type.integerRange, range.contains(value) else {
                let limits = type.integerRange.map { " (\($0.lowerBound) to \($0.upperBound))" } ?? ""
                error("The value \(value) is outside the range of \(name)\(limits).", at: start)
                return .invalid
            }
            return .typed(.int(value), type)
        case let .real(magnitude):
            guard type.isReal else {
                error("\(name) needs an integer value, not '\(whole(from: start))'.", at: start)
                return .invalid
            }
            let value = negative ? -magnitude : magnitude
            if type == .real {
                let single = Float(value)
                guard single.isFinite else {
                    error("The value \(whole(from: start)) is outside the range of Real.", at: start)
                    return .invalid
                }
                return .typed(.real(Double(single)), .real)
            }
            return .typed(.real(value), .lreal)
        default:
            return .invalid
        }
    }

    private func whole(from start: STSourceLocation) -> String {
        text(from: start.offset, to: position)
    }

    /// REGION's name: the rest of the line, up to a trailing comment.
    private mutating func lexRegionName() {
        while position < units.count && Self.isSpace(units[position]) { position += 1 }
        let start = location
        var end = position
        while position < units.count && !Self.isNewline(units[position]) {
            if units[position] == Unit.slash && peek(1) == Unit.slash { break }
            if units[position] == Unit.leftParen && peek(1) == Unit.star { break }
            position += 1
            if !Self.isSpace(units[position - 1]) { end = position }
        }
        let stop = position
        position = end
        if end > start.offset {
            append(.regionName, from: start)
        }
        position = stop
    }

    // MARK: - Symbols

    private mutating func lexSymbol(_ start: STSourceLocation) {
        let current = units[position]
        let next = peek(1)
        var symbol: STSymbol?
        var width = 1
        switch current {
        case 0x3A: symbol = next == 0x3D ? .assign : .colon
        case 0x3D: symbol = next == 0x3E ? .output : .equal
        case 0x3C: symbol = next == 0x3E ? .notEqual : (next == 0x3D ? .lessOrEqual : .less)
        case 0x3E: symbol = next == 0x3D ? .greaterOrEqual : .greater
        case Unit.plus: symbol = next == 0x3D ? .addAssign : .plus
        case Unit.minus: symbol = next == 0x3D ? .subtractAssign : .minus
        case Unit.star: symbol = next == Unit.star ? .power : (next == 0x3D ? .multiplyAssign : .star)
        case Unit.slash: symbol = next == 0x3D ? .divideAssign : .slash
        case 0x3F: symbol = next == 0x3D ? .attemptAssign : nil
        case 0x26: symbol = .ampersand
        case Unit.leftParen: symbol = .leftParen
        case Unit.rightParen: symbol = .rightParen
        case 0x5B: symbol = .leftBracket
        case 0x5D: symbol = .rightBracket
        case 0x2C: symbol = .comma
        case 0x3B: symbol = .semicolon
        case Unit.dot: symbol = next == Unit.dot ? .range : .dot
        default: symbol = nil
        }
        if let symbol {
            width = symbol.rawValue.utf16.count
            position += width
            append(.symbol(symbol), from: start)
            return
        }
        // One character (a surrogate pair counts as one).
        position += (current >= 0xD800 && current <= 0xDBFF && position + 1 < units.count) ? 2 : 1
        error("Invalid character '\(text(from: start.offset, to: position))'.", at: start)
        append(.invalid, from: start)
    }
}

/// What a `PREFIX#` in front of a value means.
nonisolated enum STTypedPrefix: Hashable, Sendable {
    case time
    case data(PLCDataType)
    /// A data type the simulator lacks; `isText` for STRING / CHAR literals.
    case unsupported(String, isText: Bool)

    static func named(_ upper: String) -> STTypedPrefix? {
        switch upper {
        case "T", "TIME": return .time
        case "B": return .data(.byte)
        case "W": return .data(.word)
        case "DW": return .data(.dword)
        case "LT", "LTIME": return .unsupported("LTIME", isText: false)
        case "S5T", "S5TIME": return .unsupported("S5TIME", isText: false)
        case "D", "DATE": return .unsupported("DATE", isText: false)
        case "TOD", "TIME_OF_DAY": return .unsupported("TIME_OF_DAY", isText: false)
        case "LTOD", "LTIME_OF_DAY": return .unsupported("LTIME_OF_DAY", isText: false)
        case "DT", "DATE_AND_TIME": return .unsupported("DATE_AND_TIME", isText: false)
        case "LDT": return .unsupported("LDT", isText: false)
        case "DTL": return .unsupported("DTL", isText: false)
        case "LINT", "ULINT", "LWORD": return .unsupported(upper, isText: false)
        case "CHAR", "WCHAR", "STRING", "WSTRING": return .unsupported(upper, isText: true)
        default:
            guard let type = PLCDataType.named(upper), type != .time else { return nil }
            return .data(type)
        }
    }
}
