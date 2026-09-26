import Foundation

// The parsed form of an SCL / ST block body, before names are resolved.

nonisolated enum STUnaryOperator: Hashable, Sendable {
    case negate, plus, not
}

nonisolated enum STBinaryOperator: Hashable, Sendable {
    case add, subtract, multiply, divide, modulo, power
    case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
    case and, or, xor

    var arithmetic: ArithmeticOperator? {
        switch self {
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        case .modulo: return .modulo
        case .power: return .power
        default: return nil
        }
    }

    var comparison: ComparisonOperator? {
        switch self {
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .less: return .less
        case .lessOrEqual: return .lessOrEqual
        case .greater: return .greater
        case .greaterOrEqual: return .greaterOrEqual
        default: return nil
        }
    }

    var logic: BitLogicOperator? {
        switch self {
        case .and: return .and
        case .or: return .or
        case .xor: return .xor
        default: return nil
        }
    }
}

nonisolated indirect enum STExpression {
    case literal(STLiteral, STSourceRange)
    case boolean(Bool, STSourceRange)
    case string(STSourceRange)
    case operand(STOperand)
    case unary(STUnaryOperator, STExpression, STSourceRange)
    /// The operator as written (`AND` or `&`) is kept for messages.
    case binary(STBinaryOperator, String, STExpression, STExpression, STSourceRange)
    case parenthesized(STExpression, STSourceRange)
    case call(STCall)
    /// A part the parser could not read; already reported.
    case invalid(STSourceRange)

    var range: STSourceRange {
        switch self {
        case let .literal(_, range), let .boolean(_, range), let .string(range), let .unary(_, _, range),
             let .binary(_, _, _, _, range), let .parenthesized(_, range), let .invalid(range):
            return range
        case let .operand(operand):
            return operand.range
        case let .call(call):
            return call.range
        }
    }

    /// The operand when the expression is nothing but one (parentheses allowed).
    var operand: STOperand? {
        switch self {
        case let .operand(operand): return operand
        case let .parenthesized(inner, _): return inner.operand
        default: return nil
        }
    }
}

/// A variable reference with its access path: `#motor.speed`, `"DB".values[#i]`,
/// `#status.%X3`, `D0.3`.
nonisolated struct STOperand {
    var root: SymbolName
    var rootRange: STSourceRange
    var steps: [STAccessStep]
    var range: STSourceRange
    /// The source text, as the monitor shows it.
    var text: String
}

nonisolated enum STAccessStep {
    /// `.name` or `."name"`.
    case member(String, STSourceRange)
    /// `[i]` or `[i, j]` (one index per array level).
    case index([STExpression], STSourceRange)
    /// TIA slice `.%X3`, `.%B1`, `.%W0`, `.%D0` (the text after the dot).
    case slice(String, STSourceRange)
    /// GX Works bit-of-word `.3` (the digits after the dot).
    case bitNumber(String, STSourceRange)

    /// Includes the leading `.` or the brackets.
    var range: STSourceRange {
        switch self {
        case let .member(_, range), let .index(_, range), let .slice(_, range), let .bitNumber(_, range): return range
        }
    }
}

nonisolated struct STCall {
    var callee: STOperand
    var arguments: [STArgument]
    /// From the callee to the closing parenthesis.
    var range: STSourceRange
}

nonisolated struct STArgument {
    /// The formal parameter for `IN := …` / `Q => …`; nil for a positional argument.
    var name: String?
    var nameRange: STSourceRange?
    /// Written with `=>`.
    var isOutput: Bool
    var value: STExpression
    var range: STSourceRange
}

nonisolated enum STAssignmentOperator: Hashable, Sendable {
    case assign, add, subtract, multiply, divide

    var binary: STBinaryOperator? {
        switch self {
        case .assign: return nil
        case .add: return .add
        case .subtract: return .subtract
        case .multiply: return .multiply
        case .divide: return .divide
        }
    }

    var symbol: String {
        switch self {
        case .assign: return ":="
        case .add: return "+="
        case .subtract: return "-="
        case .multiply: return "*="
        case .divide: return "/="
        }
    }
}

nonisolated struct STAssignmentTarget {
    var operand: STOperand
    var operation: STAssignmentOperator
    var operatorRange: STSourceRange
}

/// `IF cond THEN …` or `ELSIF cond THEN …`.
nonisolated struct STConditionalBranch {
    var keyword: String
    var keywordRange: STSourceRange
    var condition: STExpression
    /// From the keyword to THEN.
    var headerRange: STSourceRange
    var body: [STStatement]
}

nonisolated struct STCaseLabel {
    var low: STExpression
    var high: STExpression?
    var range: STSourceRange
}

nonisolated struct STCaseBranch {
    var labels: [STCaseLabel]
    /// The label list up to its colon.
    var labelRange: STSourceRange
    var body: [STStatement]
}

nonisolated struct STForLoop {
    var variable: STOperand
    var start: STExpression
    var end: STExpression
    var step: STExpression?
    var body: [STStatement]
}

nonisolated struct STStatement {
    nonisolated enum Kind {
        /// `a := b;`, `a := b := c;`, `a += b;`: targets in source order.
        case assignment([STAssignmentTarget], STExpression)
        case call(STCall)
        case ifThen([STConditionalBranch], elseBody: [STStatement]?, elseRange: STSourceRange?)
        case caseOf(selector: STExpression, keywordRange: STSourceRange, branches: [STCaseBranch],
                    elseBody: [STStatement]?, elseRange: STSourceRange?)
        case forLoop(STForLoop)
        case whileLoop(keywordRange: STSourceRange, condition: STExpression, body: [STStatement])
        case repeatLoop(body: [STStatement], untilRange: STSourceRange, condition: STExpression)
        case exitLoop
        case continueLoop
        case returnBlock
        case empty
        case region(name: String, body: [STStatement])
    }

    var kind: Kind
    var range: STSourceRange
    /// What the monitor marks as executed: all of a simple statement, the
    /// header (up to THEN / OF / DO) of a compound one.
    var headerRange: STSourceRange
}
