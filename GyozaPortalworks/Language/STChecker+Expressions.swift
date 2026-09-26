import Foundation

/// A binary operation's types and how to compute it.
nonisolated struct STOperatorPlan {
    /// Convert the operands to these before `apply`.
    var leftType: PLCDataType
    var rightType: PLCDataType
    var resultType: PLCDataType
    var apply: (PLCValue, PLCValue) throws -> PLCValue
}

// Expressions: literals, operators and their data types.
nonisolated extension STChecker {
    /// Compiles an expression. `expected` is the context's type (used only by
    /// untyped literals and context-typed functions); `target` is set when
    /// the expression is the whole right side of an assignment to that type.
    func compileExpression(_ expression: STExpression, expected: PLCDataType?, target: PLCDataType? = nil) -> STValue? {
        switch expression {
        case let .literal(literal, range):
            switch literal {
            case let .integer(value): return untyped(.integer(value), range: range)
            case let .real(value): return untyped(.real(value), range: range)
            case let .typed(value, type): return Self.constant(value, type: type, range: range)
            case .unsupported, .invalid: return nil
            }
        case let .boolean(value, range):
            return Self.constant(.bool(value), type: .bool, range: range)
        case let .string(range):
            error("Data type STRING is not supported in this simulator.", at: range)
            return nil
        case let .operand(operand):
            guard let place = resolvePlace(operand) else { return nil }
            return readValue(place)
        case let .parenthesized(inner, range):
            guard var value = compileExpression(inner, expected: expected, target: target) else { return nil }
            value.range = range
            return value
        case let .unary(op, operand, range):
            return compileUnary(op, operand, range: range, expected: expected)
        case let .binary(op, symbol, left, right, range):
            return compileBinary(op, symbol, left, right, range: range, expected: expected)
        case let .call(call):
            return compileCallExpression(call, expected: expected, target: target)
        case .invalid:
            return nil
        }
    }

    /// A condition of IF, ELSIF, WHILE or UNTIL: must be Bool.
    func compileCondition(_ expression: STExpression) -> STValue? {
        guard let value = compileExpression(expression, expected: .bool) else { return nil }
        guard value.untyped == nil, value.type == .bool else {
            notPermitted(value.type, at: value.range, hint: "A condition must be of data type \(typeName(.bool)).")
            return nil
        }
        return value
    }

    // MARK: - Unary operators

    private func compileUnary(_ op: STUnaryOperator, _ operandExpression: STExpression, range: STSourceRange,
                              expected: PLCDataType?) -> STValue? {
        guard let operand = compileExpression(operandExpression, expected: expected) else { return nil }
        switch op {
        case .plus, .negate:
            if let literal = operand.untyped {
                if op == .plus {
                    var result = operand
                    result.range = range
                    return result
                }
                switch literal {
                case let .integer(value):
                    guard value != Int64.min else { return nil }
                    return untyped(.integer(-value), range: range)
                case let .real(value):
                    return untyped(.real(-value), range: range)
                }
            }
            let type = operand.type
            guard type.isSignedInteger || type.isUnsignedInteger || type.isReal || type == .time else {
                notPermitted(type, at: operand.range)
                return nil
            }
            var result = operand
            result.range = range
            guard op == .negate else { return result }
            let zero = type.defaultValue
            let evaluate = operand.evaluate
            result.constant = operand.constant.map { PLCOperations.arithmetic(.subtract, zero, $0, as: type).value }
            result.evaluate = { state in PLCOperations.arithmetic(.subtract, zero, try evaluate(state), as: type).value }
            return result
        case .not:
            var value = operand
            if let literal = operand.untyped {
                guard case .integer = literal else {
                    notPermitted(operand.type, at: operand.range)
                    return nil
                }
                if let expected, expected.isInteger { value = adapted(operand, toward: expected) }
                value = Self.typed(value)
            }
            let type = value.type
            guard type == .bool || type.isInteger else {
                notPermitted(type, at: value.range)
                return nil
            }
            let evaluate = value.evaluate
            return STValue(type: type, untyped: nil, constant: value.constant.map { PLCOperations.invert($0, as: type) },
                           evaluate: { state in PLCOperations.invert(try evaluate(state), as: type) }, range: range)
        }
    }

    // MARK: - Binary operators

    private func compileBinary(_ op: STBinaryOperator, _ symbol: String, _ leftExpression: STExpression,
                               _ rightExpression: STExpression, range: STSourceRange, expected: PLCDataType?) -> STValue? {
        let hint = op.comparison == nil ? expected : nil
        let leftValue = compileExpression(leftExpression, expected: hint)
        let rightValue = compileExpression(rightExpression, expected: hint)
        guard var left = leftValue, var right = rightValue else { return nil }

        if let a = left.untyped, let b = right.untyped {
            switch fold(op, symbol, a, b, range: range) {
            case let .value(value): return value
            case .failed: return nil
            case .notFoldable:
                left = Self.typed(left)
                right = Self.typed(right)
            }
        }
        (left, right) = adaptPair(left, right, expected: expected)
        guard let plan = self.plan(op, symbol, left.type, right.type, range: range) else { return nil }
        let first = converted(left, to: plan.leftType)
        let second = converted(right, to: plan.rightType)
        let evaluateFirst = first.evaluate
        let evaluateSecond = second.evaluate
        let apply = plan.apply
        var constant: PLCValue?
        if let a = first.constant, let b = second.constant {
            constant = try? apply(a, b)
        }
        return STValue(type: plan.resultType, untyped: nil, constant: constant, evaluate: { state in
            let a = try evaluateFirst(state)
            let b = try evaluateSecond(state)
            return try apply(a, b)
        }, range: range)
    }

    /// Adapts an untyped literal to the data type of the other operand when
    /// it fits (`#int + 1` computes in Int, `#int + 100000` in DInt).
    func adaptPair(_ left: STValue, _ right: STValue, expected: PLCDataType?) -> (STValue, STValue) {
        switch (left.untyped, right.untyped) {
        case (.some, .none):
            return (adaptedLiteral(left, partner: right.type, expected: expected), right)
        case (.none, .some):
            return (left, adaptedLiteral(right, partner: left.type, expected: expected))
        case (.some, .some):
            return (Self.typed(left), Self.typed(right))
        default:
            return (left, right)
        }
    }

    private func adaptedLiteral(_ literal: STValue, partner: PLCDataType, expected: PLCDataType?) -> STValue {
        if case .real = literal.untyped, !partner.isReal {
            // A real constant with an integer: compute in the context's real type, else Real if the integer fits it.
            let realType: PLCDataType
            if let expected, expected.isReal {
                realType = expected
            } else {
                realType = PLCTypeRules.canConvertImplicitly(from: partner, to: .real, dialect: dialect) ? .real : .lreal
            }
            return Self.typed(adapted(literal, toward: realType))
        }
        if partner == .time, case .integer = literal.untyped {
            return Self.typed(adapted(literal, toward: .dint))
        }
        return Self.typed(adapted(literal, toward: partner))
    }

    nonisolated private enum FoldResult {
        case value(STValue)
        case notFoldable
        case failed
    }

    /// Computes an operation on two untyped literals at compile time.
    private func fold(_ op: STBinaryOperator, _ symbol: String, _ a: STUntyped, _ b: STUntyped, range: STSourceRange) -> FoldResult {
        if case let .integer(x) = a, case let .integer(y) = b {
            let result: (partialValue: Int64, overflow: Bool)
            switch op {
            case .add: result = x.addingReportingOverflow(y)
            case .subtract: result = x.subtractingReportingOverflow(y)
            case .multiply: result = x.multipliedReportingOverflow(by: y)
            case .divide:
                guard y != 0 else { return .notFoldable }
                result = x.dividedReportingOverflow(by: y)
            case .modulo:
                guard y != 0 else { return .notFoldable }
                result = x.remainderReportingOverflow(dividingBy: y)
            case .power:
                return untyped(.real(pow(Double(x), Double(y))), range: range).map(FoldResult.value) ?? .failed
            case .and: result = (x & y, false)
            case .or: result = (x | y, false)
            case .xor: result = (x ^ y, false)
            default:
                guard let comparison = op.comparison else { return .notFoldable }
                return .value(Self.constant(.bool(PLCOperations.compare(comparison, .int(x), .int(y))), type: .bool, range: range))
            }
            guard !result.overflow else {
                error("The constant expression is too large.", at: range)
                return .failed
            }
            return untyped(.integer(result.partialValue), range: range).map(FoldResult.value) ?? .failed
        }
        let x = Self.double(a)
        let y = Self.double(b)
        let value: Double
        switch op {
        case .add: value = x + y
        case .subtract: value = x - y
        case .multiply: value = x * y
        case .divide: value = x / y
        case .power: value = pow(x, y)
        case .modulo, .and, .or, .xor:
            notPermitted(.lreal, at: range)
            return .failed
        default:
            guard let comparison = op.comparison else { return .notFoldable }
            return .value(Self.constant(.bool(PLCOperations.compare(comparison, .real(x), .real(y))), type: .bool, range: range))
        }
        return untyped(.real(value), range: range).map(FoldResult.value) ?? .failed
    }

    private static func double(_ literal: STUntyped) -> Double {
        switch literal {
        case let .integer(value): return Double(value)
        case let .real(value): return value
        }
    }

    /// Checks the operand types of a binary operator (literals already
    /// adapted) and says how to compute it; reports and returns nil when
    /// the types don't go together.
    func plan(_ op: STBinaryOperator, _ symbol: String, _ left: PLCDataType, _ right: PLCDataType,
              range: STSourceRange) -> STOperatorPlan? {
        if let arithmetic = op.arithmetic {
            return arithmeticPlan(arithmetic, symbol, left, right, range: range)
        }
        if let comparison = op.comparison {
            return comparisonPlan(comparison, symbol, left, right, range: range)
        }
        if let logic = op.logic {
            return logicPlan(logic, symbol, left, right, range: range)
        }
        return nil
    }

    private func arithmeticPlan(_ op: ArithmeticOperator, _ symbol: String, _ left: PLCDataType, _ right: PLCDataType,
                                range: STSourceRange) -> STOperatorPlan? {
        if left == .time || right == .time {
            return timePlan(op, symbol, left, right, range: range)
        }
        for type in [left, right] where type == .bool {
            notPermitted(type, at: range)
            return nil
        }
        guard let common = PLCTypeRules.commonType(left, right, dialect: dialect) else {
            incompatible(symbol, left, right, at: range)
            return nil
        }
        if common.isBitString {
            notPermitted(common, at: range, hint: "Arithmetic needs integers or reals; convert first, e.g. \(STStandardLibrary.conversionName(from: common, to: .int)).")
            return nil
        }
        if op == .modulo && common.isReal {
            notPermitted(common, at: range, hint: "MOD needs integers.")
            return nil
        }
        var result = common
        if op == .power && !common.isReal {
            result = PLCTypeRules.canConvertImplicitly(from: common, to: .real, dialect: dialect) ? .real : .lreal
        }
        let throwsOnZero = dialect == .melsec && !result.isReal && (op == .divide || op == .modulo)
        let type = result
        return STOperatorPlan(leftType: result, rightType: result, resultType: result) { a, b in
            if throwsOnZero && b.intValue == 0 { throw STChecker.divisionByZero() }
            return PLCOperations.arithmetic(op, a, b, as: type).value
        }
    }

    /// Time ± Time, Time ± DInt (TIA), Time * integer, integer * Time, Time / integer.
    private func timePlan(_ op: ArithmeticOperator, _ symbol: String, _ left: PLCDataType, _ right: PLCDataType,
                          range: STSourceRange) -> STOperatorPlan? {
        func isInteger(_ type: PLCDataType) -> Bool {
            (type.isSignedInteger || type.isUnsignedInteger) && PLCTypeRules.canConvertImplicitly(from: type, to: .dint, dialect: dialect)
        }
        var leftType = PLCDataType.time
        var rightType = PLCDataType.time
        switch op {
        case .add, .subtract:
            if left == .time && right == .time {
                break
            } else if dialect == .siemens && left == .time && isInteger(right) {
                rightType = .dint
            } else {
                incompatible(symbol, left, right, at: range)
                return nil
            }
        case .multiply:
            if left == .time && isInteger(right) {
                rightType = .dint
            } else if right == .time && isInteger(left) {
                leftType = .dint
            } else {
                incompatible(symbol, left, right, at: range)
                return nil
            }
        case .divide:
            guard left == .time && isInteger(right) else {
                incompatible(symbol, left, right, at: range)
                return nil
            }
            rightType = .dint
        case .modulo, .power:
            notPermitted(.time, at: range)
            return nil
        }
        let throwsOnZero = dialect == .melsec && op == .divide
        return STOperatorPlan(leftType: leftType, rightType: rightType, resultType: .time) { a, b in
            if throwsOnZero && b.intValue == 0 { throw STChecker.divisionByZero() }
            return PLCOperations.arithmetic(op, a, b, as: .time).value
        }
    }

    private func comparisonPlan(_ op: ComparisonOperator, _ symbol: String, _ left: PLCDataType, _ right: PLCDataType,
                                range: STSourceRange) -> STOperatorPlan? {
        let common: PLCDataType
        if left == .bool || right == .bool || left == .time || right == .time {
            guard left == right else {
                incompatible(symbol, left, right, at: range)
                return nil
            }
            if left == .bool && op != .equal && op != .notEqual {
                notPermitted(.bool, at: range, hint: "Bool values can only be compared with = and <>.")
                return nil
            }
            common = left
        } else {
            guard let type = PLCTypeRules.commonType(left, right, dialect: dialect) else {
                incompatible(symbol, left, right, at: range)
                return nil
            }
            common = type
        }
        return STOperatorPlan(leftType: common, rightType: common, resultType: .bool) { a, b in
            .bool(PLCOperations.compare(op, a, b))
        }
    }

    private func logicPlan(_ op: BitLogicOperator, _ symbol: String, _ left: PLCDataType, _ right: PLCDataType,
                           range: STSourceRange) -> STOperatorPlan? {
        var common: PLCDataType
        if left == .bool || right == .bool {
            guard left == right else {
                incompatible(symbol, left, right, at: range)
                return nil
            }
            common = .bool
        } else {
            for type in [left, right] where !type.isInteger {
                notPermitted(type, at: range, hint: "\(symbol) needs Bool, bit strings or integers.")
                return nil
            }
            guard let type = PLCTypeRules.commonType(left, right, dialect: dialect), type.isInteger else {
                incompatible(symbol, left, right, at: range)
                return nil
            }
            common = type
            if !type.isBitString && (left.isBitString || right.isBitString), let bits = Self.bitString(width: type.bitWidth) {
                common = bits
            }
        }
        let type = common
        return STOperatorPlan(leftType: type, rightType: type, resultType: type) { a, b in
            PLCOperations.bitLogic(op, a, b, as: type)
        }
    }

    /// GX Works: an integer division by zero is an operation error that stops the CPU.
    static func divisionByZero() -> RuntimeFault {
        RuntimeFault(.divisionByZero, "Operation error: division by zero")
    }
}
