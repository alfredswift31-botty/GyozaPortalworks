import Foundation

/// Recursive-descent parser for SCL / ST block bodies. It reports every
/// syntax error it finds, recovering at `;` and at statement keywords.
///
/// Operator precedence (TIA Portal SCL, highest first): `( )`, unary `+ -`,
/// `NOT` and `**` (left to right), `* / MOD`, `+ -`, `< > <= >=`, `= <>`,
/// `AND &`, `XOR`, `OR`.
nonisolated struct STParser {
    private let tokens: [STToken]
    private let source: [UInt16]
    private var index = 0
    private(set) var diagnostics: [Diagnostic] = []
    /// Diagnostics count when the current statement began; a statement with
    /// an error already reported doesn't also report a missing `;`.
    private var statementErrorMark = 0

    init(tokens: [STToken], source: [UInt16]) {
        let significant = tokens.filter { $0.kind != .comment }
        self.tokens = significant.isEmpty
            ? [STToken(kind: .endOfFile, text: "", range: STSourceRange(start: STSourceLocation(line: 1, column: 1, offset: 0),
                                                                          end: STSourceLocation(line: 1, column: 1, offset: 0)),
                       name: "", literal: nil)]
            : significant
        self.source = source
    }

    /// Parses a whole block body.
    mutating func parseBody() -> [STStatement] {
        var statements: [STStatement] = []
        while !atEnd {
            statements += parseStatements(inCaseBranch: false)
            guard !atEnd else { break }
            error("Unexpected '\(current.text)'.", at: current.range)
            advance()
            if isSymbol(.semicolon) { advance() }
        }
        return statements
    }

    // MARK: - Token access

    private var current: STToken { tokens[index] }

    private func token(at distance: Int) -> STToken {
        tokens[min(index + distance, tokens.count - 1)]
    }

    private var atEnd: Bool { current.kind == .endOfFile }

    /// Where the last consumed token ends.
    private var previousEnd: STSourceLocation {
        index > 0 ? tokens[index - 1].range.end : current.range.start
    }

    @discardableResult
    private mutating func advance() -> STToken {
        let token = current
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private func isSymbol(_ symbol: STSymbol, at distance: Int = 0) -> Bool {
        token(at: distance).kind == .symbol(symbol)
    }

    private func isKeyword(_ keyword: STKeyword) -> Bool {
        current.kind == .keyword(keyword)
    }

    private var currentKeyword: STKeyword? {
        if case let .keyword(keyword) = current.kind { return keyword }
        return nil
    }

    private mutating func error(_ message: String, at range: STSourceRange) {
        diagnostics.append(.error(message, line: range.start.line, column: range.start.column))
    }

    private mutating func error(_ message: String, at location: STSourceLocation) {
        diagnostics.append(.error(message, line: location.line, column: location.column))
    }

    private func range(from start: STSourceLocation) -> STSourceRange {
        let end = previousEnd
        return STSourceRange(start: start, end: end.offset >= start.offset ? end : start)
    }

    private func text(of range: STSourceRange) -> String {
        guard range.start.offset <= range.end.offset, range.end.offset <= source.count else { return "" }
        return String(decoding: source[range.start.offset..<range.end.offset], as: UTF16.self)
    }

    // MARK: - Statement lists

    /// Statements up to a list-ending keyword (END_IF, ELSE…), the end of the
    /// text, or, inside CASE, the next label.
    private mutating func parseStatements(inCaseBranch: Bool) -> [STStatement] {
        var statements: [STStatement] = []
        while !atEnd {
            if let keyword = currentKeyword, keyword.endsStatementList { break }
            if inCaseBranch && caseLabelAhead() { break }
            let before = index
            statementErrorMark = diagnostics.count
            if let statement = parseStatement() {
                statements.append(statement)
            }
            if index == before { advance() }
        }
        return statements
    }

    /// Skips to the end of a broken statement: past the next `;`, or up to a
    /// statement keyword.
    private mutating func recover() {
        while !atEnd {
            if isSymbol(.semicolon) {
                advance()
                return
            }
            if let keyword = currentKeyword, keyword.beginsStatement || keyword.endsStatementList { return }
            advance()
        }
    }

    /// Whether the current token can begin a statement (or end a list).
    private var beginsStatement: Bool {
        switch current.kind {
        case .identifier, .localName, .globalName, .absolute, .endOfFile, .symbol(.semicolon):
            return true
        case let .keyword(keyword):
            return keyword.beginsStatement || keyword.endsStatementList
        default:
            return false
        }
    }

    /// Requires the `;` that ends a statement. A missing one is reported where
    /// it belongs (after the previous token) and parsing carries on.
    private mutating func expectSemicolon() {
        if isSymbol(.semicolon) {
            advance()
            return
        }
        if diagnostics.count > statementErrorMark {
            recover()
            return
        }
        if beginsStatement {
            error("';' is missing at the end of the statement.", at: previousEnd)
        } else {
            error("Unexpected '\(current.text)': an operator or ';' is missing before it.", at: current.range)
            recover()
        }
    }

    // MARK: - Statements

    private mutating func parseStatement() -> STStatement? {
        let start = current.range.start
        switch current.kind {
        case .symbol(.semicolon):
            advance()
            return simple(.empty, from: start)
        case .keyword(.ifKeyword):
            return parseIf()
        case .keyword(.caseKeyword):
            return parseCase()
        case .keyword(.forKeyword):
            return parseFor()
        case .keyword(.whileKeyword):
            return parseWhile()
        case .keyword(.repeatKeyword):
            return parseRepeat()
        case .keyword(.exit):
            advance()
            expectSemicolon()
            return simple(.exitLoop, from: start)
        case .keyword(.continueKeyword):
            advance()
            expectSemicolon()
            return simple(.continueLoop, from: start)
        case .keyword(.returnKeyword):
            advance()
            expectSemicolon()
            return simple(.returnBlock, from: start)
        case .keyword(.region):
            return parseRegion()
        case .keyword(.goto):
            error("GOTO is not supported in this simulator.", at: current.range)
            advance()
            recover()
            return nil
        case .identifier where isSymbol(.colon, at: 1):
            error("Jump labels are not supported in this simulator (GOTO is not supported).", at: current.range)
            advance()
            advance()
            return nil
        case .identifier, .localName, .globalName, .absolute:
            return parseAssignmentOrCall()
        case .invalid:
            advance()
            recover()
            return nil
        default:
            error("Unexpected '\(current.text)'.", at: current.range)
            advance()
            recover()
            return nil
        }
    }

    private func simple(_ kind: STStatement.Kind, from start: STSourceLocation) -> STStatement {
        let whole = range(from: start)
        return STStatement(kind: kind, range: whole, headerRange: whole)
    }

    private mutating func parseAssignmentOrCall() -> STStatement? {
        let start = current.range.start
        guard let target = parseOperand() else {
            recover()
            return nil
        }
        if isSymbol(.leftParen) {
            let call = parseCall(target)
            expectSemicolon()
            return simple(.call(call), from: start)
        }
        guard let operation = assignmentOperator else {
            switch current.kind {
            case .symbol(.attemptAssign):
                error("The assignment attempt '?=' is not supported in this simulator.", at: current.range)
            case .symbol(.equal):
                error("Use ':=' to assign a value; '=' compares.", at: current.range)
            default:
                error("Incomplete statement: ':=' or a parameter list is missing after \(target.text).", at: previousEnd)
            }
            recover()
            return nil
        }
        var targets = [STAssignmentTarget(operand: target, operation: operation, operatorRange: current.range)]
        advance()
        var value = parseExpression()
        while let next = assignmentOperator, let operand = value.operand {
            targets.append(STAssignmentTarget(operand: operand, operation: next, operatorRange: current.range))
            advance()
            value = parseExpression()
        }
        if isSymbol(.attemptAssign) {
            error("The assignment attempt '?=' is not supported in this simulator.", at: current.range)
            recover()
            return nil
        }
        expectSemicolon()
        return simple(.assignment(targets, value), from: start)
    }

    private var assignmentOperator: STAssignmentOperator? {
        switch current.kind {
        case .symbol(.assign): return .assign
        case .symbol(.addAssign): return .add
        case .symbol(.subtractAssign): return .subtract
        case .symbol(.multiplyAssign): return .multiply
        case .symbol(.divideAssign): return .divide
        default: return nil
        }
    }

    /// Consumes `keyword` or reports it missing (without consuming anything).
    @discardableResult
    private mutating func expect(_ keyword: STKeyword, _ message: String) -> Bool {
        if isKeyword(keyword) {
            advance()
            return true
        }
        if diagnostics.count == statementErrorMark {
            error(message, at: current.range)
        }
        return false
    }

    /// Consumes an END_… keyword and its `;`, or reports it missing.
    private mutating func expectEnd(_ keyword: STKeyword, opening: String) {
        guard isKeyword(keyword) else {
            error("'\(keyword.rawValue)' is missing to close \(opening).", at: current.range)
            return
        }
        advance()
        statementErrorMark = diagnostics.count
        expectSemicolon()
    }

    private mutating func parseIf() -> STStatement {
        let start = current.range.start
        var branches: [STConditionalBranch] = []
        var keyword = advance()
        while true {
            let condition = parseExpression()
            expect(.then, "'THEN' is missing after the condition.")
            let header = range(from: keyword.range.start)
            let body = parseStatements(inCaseBranch: false)
            branches.append(STConditionalBranch(keyword: keyword.text, keywordRange: keyword.range, condition: condition,
                                                headerRange: header, body: body))
            guard isKeyword(.elsif) else { break }
            statementErrorMark = diagnostics.count
            keyword = advance()
        }
        var elseBody: [STStatement]?
        var elseRange: STSourceRange?
        if isKeyword(.elseKeyword) {
            elseRange = advance().range
            elseBody = parseStatements(inCaseBranch: false)
        }
        let header = branches.first?.headerRange ?? range(from: start)
        expectEnd(.endIf, opening: "IF")
        return STStatement(kind: .ifThen(branches, elseBody: elseBody, elseRange: elseRange), range: range(from: start), headerRange: header)
    }

    private mutating func parseCase() -> STStatement {
        let start = current.range.start
        let keyword = advance()
        let selector = parseExpression()
        expect(.of, "'OF' is missing after the CASE expression.")
        let header = range(from: start)
        var branches: [STCaseBranch] = []
        while !atEnd && !isKeyword(.elseKeyword) && !isKeyword(.endCase) {
            if let keyword = currentKeyword, keyword.endsStatementList { break }
            statementErrorMark = diagnostics.count
            guard caseLabelAhead() else {
                error("A CASE label (such as 1:, 2, 4: or 5..9:) is expected here.", at: current.range)
                let before = index
                _ = parseStatements(inCaseBranch: true)
                if index == before { advance() }
                continue
            }
            let labelStart = current.range.start
            let labels = parseCaseLabels()
            let labelRange = range(from: labelStart)
            if isSymbol(.colon) { advance() }
            let body = parseStatements(inCaseBranch: true)
            branches.append(STCaseBranch(labels: labels, labelRange: labelRange, body: body))
        }
        var elseBody: [STStatement]?
        var elseRange: STSourceRange?
        if isKeyword(.elseKeyword) {
            elseRange = advance().range
            if isSymbol(.colon) {
                error("ELSE in CASE is not followed by ':'.", at: current.range)
                advance()
            }
            elseBody = parseStatements(inCaseBranch: false)
        }
        expectEnd(.endCase, opening: "CASE")
        return STStatement(kind: .caseOf(selector: selector, keywordRange: keyword.range, branches: branches,
                                         elseBody: elseBody, elseRange: elseRange),
                           range: range(from: start), headerRange: header)
    }

    /// Whether a CASE label list (`1:`, `2, 4:`, `5..9:`, `#IDLE:`, `-1:`) starts here.
    private func caseLabelAhead() -> Bool {
        var distance = 0
        while true {
            for _ in 0..<2 {
                if isSymbol(.plus, at: distance) || isSymbol(.minus, at: distance) { distance += 1 }
                switch token(at: distance).kind {
                case .literal, .identifier, .localName, .globalName: distance += 1
                default: return false
                }
                guard isSymbol(.range, at: distance) else { break }
                distance += 1
            }
            if isSymbol(.comma, at: distance) {
                distance += 1
                continue
            }
            return isSymbol(.colon, at: distance)
        }
    }

    private mutating func parseCaseLabels() -> [STCaseLabel] {
        var labels: [STCaseLabel] = []
        repeat {
            if !labels.isEmpty { advance() }
            let start = current.range.start
            let low = parseSignExpression()
            var high: STExpression?
            if isSymbol(.range) {
                advance()
                high = parseSignExpression()
            }
            labels.append(STCaseLabel(low: low, high: high, range: range(from: start)))
        } while isSymbol(.comma)
        return labels
    }

    private mutating func parseFor() -> STStatement {
        let start = current.range.start
        advance()
        var variable: STOperand?
        switch current.kind {
        case .identifier, .localName, .globalName, .absolute:
            variable = parseOperand()
        default:
            error("The FOR loop needs a counter tag after FOR.", at: current.range)
        }
        if isSymbol(.assign) {
            advance()
        } else if diagnostics.count == statementErrorMark {
            error("':=' is missing after the FOR loop counter.", at: current.range)
        }
        let first = parseExpression()
        expect(.to, "'TO' is missing in the FOR statement.")
        let last = parseExpression()
        var step: STExpression?
        if isKeyword(.by) {
            advance()
            step = parseExpression()
        }
        expect(.doKeyword, "'DO' is missing in the FOR statement.")
        let header = range(from: start)
        let body = parseStatements(inCaseBranch: false)
        expectEnd(.endFor, opening: "FOR")
        let whole = range(from: start)
        guard let variable else {
            return STStatement(kind: .empty, range: whole, headerRange: header)
        }
        let loop = STForLoop(variable: variable, start: first, end: last, step: step, body: body)
        return STStatement(kind: .forLoop(loop), range: whole, headerRange: header)
    }

    private mutating func parseWhile() -> STStatement {
        let start = current.range.start
        let keyword = advance()
        let condition = parseExpression()
        expect(.doKeyword, "'DO' is missing after the WHILE condition.")
        let header = range(from: start)
        let body = parseStatements(inCaseBranch: false)
        expectEnd(.endWhile, opening: "WHILE")
        return STStatement(kind: .whileLoop(keywordRange: keyword.range, condition: condition, body: body),
                           range: range(from: start), headerRange: header)
    }

    private mutating func parseRepeat() -> STStatement {
        let start = current.range.start
        let header = advance().range
        let body = parseStatements(inCaseBranch: false)
        statementErrorMark = diagnostics.count
        var untilRange = current.range
        var condition = STExpression.invalid(current.range)
        if isKeyword(.until) {
            untilRange = advance().range
            condition = parseExpression()
            if isSymbol(.semicolon) { advance() }
        } else {
            error("'UNTIL' is missing in the REPEAT loop.", at: current.range)
        }
        expectEnd(.endRepeat, opening: "REPEAT")
        return STStatement(kind: .repeatLoop(body: body, untilRange: untilRange, condition: condition),
                           range: range(from: start), headerRange: header)
    }

    private mutating func parseRegion() -> STStatement {
        let start = current.range.start
        advance()
        var name = ""
        if current.kind == .regionName {
            name = advance().text
        }
        let header = range(from: start)
        let body = parseStatements(inCaseBranch: false)
        if isKeyword(.endRegion) {
            advance()
        } else {
            error("'END_REGION' is missing to close REGION.", at: current.range)
        }
        return STStatement(kind: .region(name: name, body: body), range: range(from: start), headerRange: header)
    }

    // MARK: - Operands and calls

    /// `root { .member | [index] | .%X3 | .3 }`
    private mutating func parseOperand() -> STOperand? {
        let rootToken = current
        let root: SymbolName
        switch rootToken.kind {
        case .identifier: root = .plain(rootToken.text)
        case .localName: root = .local(rootToken.name)
        case .globalName: root = .global(rootToken.name)
        case .absolute: root = .absolute(rootToken.text)
        default:
            error("A tag is expected here.", at: rootToken.range)
            return nil
        }
        advance()
        var steps: [STAccessStep] = []
        while true {
            if isSymbol(.dot) {
                let dot = current.range.start
                let next = token(at: 1)
                switch next.kind {
                case .identifier, .keyword, .globalName:
                    advance()
                    advance()
                    steps.append(.member(next.name, range(from: dot)))
                case .literal where next.text.allSatisfy({ $0.isASCII && $0.isNumber }):
                    advance()
                    advance()
                    steps.append(.bitNumber(next.text, range(from: dot)))
                case .absolute:
                    advance()
                    advance()
                    steps.append(.slice(next.text, range(from: dot)))
                default:
                    error("A member name is expected after '.'.", at: next.range)
                    advance()
                    return nil
                }
            } else if isSymbol(.leftBracket) {
                let open = advance().range.start
                var indices: [STExpression] = [parseExpression()]
                while isSymbol(.comma) {
                    advance()
                    indices.append(parseExpression())
                }
                if isSymbol(.rightBracket) {
                    advance()
                } else {
                    error("']' is missing after the array index.", at: current.range)
                }
                steps.append(.index(indices, range(from: open)))
            } else {
                break
            }
        }
        let whole = range(from: rootToken.range.start)
        return STOperand(root: root, rootRange: rootToken.range, steps: steps, range: whole, text: text(of: whole))
    }

    /// The parameter list of a call: `(IN := x, Q => y)` or `(a, b)`.
    private mutating func parseCall(_ callee: STOperand) -> STCall {
        advance()
        var arguments: [STArgument] = []
        if isSymbol(.rightParen) {
            advance()
            return STCall(callee: callee, arguments: [], range: range(from: callee.range.start))
        }
        while true {
            let start = current.range.start
            var name: String?
            var nameRange: STSourceRange?
            var isOutput = false
            if current.kind == .identifier, isSymbol(.assign, at: 1) || isSymbol(.output, at: 1) {
                name = current.text
                nameRange = current.range
                advance()
                isOutput = isSymbol(.output)
                advance()
            }
            let value = parseExpression()
            arguments.append(STArgument(name: name, nameRange: nameRange, isOutput: isOutput, value: value, range: range(from: start)))
            if isSymbol(.comma) {
                advance()
                continue
            }
            if isSymbol(.rightParen) {
                advance()
                break
            }
            if diagnostics.count == statementErrorMark {
                error("')' is missing to close the parameter list.", at: current.range)
            }
            while !atEnd && !isSymbol(.rightParen) && !isSymbol(.semicolon) {
                if let keyword = currentKeyword, keyword.beginsStatement || keyword.endsStatementList { break }
                advance()
            }
            if isSymbol(.rightParen) { advance() }
            break
        }
        return STCall(callee: callee, arguments: arguments, range: range(from: callee.range.start))
    }

    // MARK: - Expressions

    mutating func parseExpression() -> STExpression {
        var left = parseXor()
        while isKeyword(.or) {
            let symbol = advance().text
            let right = parseXor()
            left = .binary(.or, symbol, left, right, left.range.through(right.range))
        }
        return left
    }

    private mutating func parseXor() -> STExpression {
        var left = parseAnd()
        while isKeyword(.xor) {
            let symbol = advance().text
            let right = parseAnd()
            left = .binary(.xor, symbol, left, right, left.range.through(right.range))
        }
        return left
    }

    private mutating func parseAnd() -> STExpression {
        var left = parseEquality()
        while isKeyword(.and) || isSymbol(.ampersand) {
            let symbol = advance().text
            let right = parseEquality()
            left = .binary(.and, symbol, left, right, left.range.through(right.range))
        }
        return left
    }

    private mutating func parseEquality() -> STExpression {
        var left = parseRelation()
        while true {
            let op: STBinaryOperator
            if isSymbol(.equal) {
                op = .equal
            } else if isSymbol(.notEqual) {
                op = .notEqual
            } else {
                return left
            }
            let symbol = advance().text
            let right = parseRelation()
            left = .binary(op, symbol, left, right, left.range.through(right.range))
        }
    }

    private mutating func parseRelation() -> STExpression {
        var left = parseAdditive()
        while true {
            let op: STBinaryOperator
            switch current.kind {
            case .symbol(.less): op = .less
            case .symbol(.lessOrEqual): op = .lessOrEqual
            case .symbol(.greater): op = .greater
            case .symbol(.greaterOrEqual): op = .greaterOrEqual
            default: return left
            }
            let symbol = advance().text
            let right = parseAdditive()
            left = .binary(op, symbol, left, right, left.range.through(right.range))
        }
    }

    private mutating func parseAdditive() -> STExpression {
        var left = parseMultiplicative()
        while true {
            let op: STBinaryOperator
            if isSymbol(.plus) {
                op = .add
            } else if isSymbol(.minus) {
                op = .subtract
            } else {
                return left
            }
            let symbol = advance().text
            let right = parseMultiplicative()
            left = .binary(op, symbol, left, right, left.range.through(right.range))
        }
    }

    private mutating func parseMultiplicative() -> STExpression {
        var left = parsePowerOrNot()
        while true {
            let op: STBinaryOperator
            if isSymbol(.star) {
                op = .multiply
            } else if isSymbol(.slash) {
                op = .divide
            } else if isKeyword(.mod) {
                op = .modulo
            } else {
                return left
            }
            let symbol = advance().text
            let right = parsePowerOrNot()
            left = .binary(op, symbol, left, right, left.range.through(right.range))
        }
    }

    /// `**` and NOT share a level and apply left to right: `NOT a ** b` is `(NOT a) ** b`.
    private mutating func parsePowerOrNot() -> STExpression {
        var left = parseNot()
        while isSymbol(.power) {
            let symbol = advance().text
            let right = parseNot()
            left = .binary(.power, symbol, left, right, left.range.through(right.range))
        }
        return left
    }

    private mutating func parseNot() -> STExpression {
        guard isKeyword(.not) else { return parseSignExpression() }
        let start = advance().range
        let operand = parseNot()
        return .unary(.not, operand, start.through(operand.range))
    }

    /// Unary `+` / `-` bind tightest: `-2 ** 2` is `(-2) ** 2`.
    private mutating func parseSignExpression() -> STExpression {
        guard isSymbol(.minus) || isSymbol(.plus) else { return parsePrimary() }
        let token = advance()
        let operand = isKeyword(.not) ? parseNot() : parseSignExpression()
        return .unary(token.kind == .symbol(.minus) ? .negate : .plus, operand, token.range.through(operand.range))
    }

    private mutating func parsePrimary() -> STExpression {
        let token = current
        switch token.kind {
        case .literal:
            advance()
            return .literal(token.literal ?? .invalid, token.range)
        case .keyword(.trueKeyword):
            advance()
            return .boolean(true, token.range)
        case .keyword(.falseKeyword):
            advance()
            return .boolean(false, token.range)
        case .string:
            advance()
            return .string(token.range)
        case .symbol(.leftParen):
            advance()
            let inner = parseExpression()
            if isSymbol(.rightParen) {
                advance()
            } else if diagnostics.count == statementErrorMark {
                error("')' is missing.", at: current.range)
            }
            return .parenthesized(inner, range(from: token.range.start))
        case .identifier, .localName, .globalName, .absolute:
            guard let operand = parseOperand() else { return .invalid(token.range) }
            if isSymbol(.leftParen) {
                return .call(parseCall(operand))
            }
            return .operand(operand)
        case .invalid:
            advance()
            return .invalid(token.range)
        default:
            if diagnostics.count == statementErrorMark {
                error(token.kind == .endOfFile ? "An operand is missing at the end of the text." : "An operand is expected instead of '\(token.text)'.",
                      at: token.range)
            }
            return .invalid(token.range)
        }
    }
}
