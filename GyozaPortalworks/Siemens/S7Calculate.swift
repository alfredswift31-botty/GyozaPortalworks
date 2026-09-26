import Foundation

/// The expression of a CALCULATE box: "(IN1 + IN2) * IN3", "SQRT(IN1)", "IN1 AND 16#00FF".
nonisolated indirect enum S7Expression: Hashable, Sendable {
    case literal(String)
    /// IN1 is input 0.
    case input(Int)
    case negate(S7Expression)
    case not(S7Expression)
    case binary(String, S7Expression, S7Expression)
    case function(String, S7Expression)

    static let functions = ["SQR", "SQRT", "LN", "EXP", "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ABS", "FRAC", "NEG"]

    /// Highest input the expression uses (IN3 → 3).
    var highestInput: Int {
        switch self {
        case .literal: return 0
        case let .input(index): return index + 1
        case let .negate(inner), let .not(inner), let .function(_, inner): return inner.highestInput
        case let .binary(_, left, right): return max(left.highestInput, right.highestInput)
        }
    }

    /// Parses the expression; throws a ResolveError naming the problem.
    static func parse(_ text: String) throws -> S7Expression {
        var parser = Parser(tokens: try tokenize(text))
        guard !parser.tokens.isEmpty else { throw ResolveError(message: S7Messages.invalidExpression("the expression is empty.")) }
        let expression = try parser.orExpression()
        guard parser.position == parser.tokens.count else {
            throw ResolveError(message: S7Messages.invalidExpression("unexpected \"\(parser.tokens[parser.position])\"."))
        }
        return expression
    }

    private static func tokenize(_ text: String) throws -> [String] {
        var tokens: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character.isLetter || character.isNumber || character == "_" || character == "#" || character == "." {
                var word = ""
                while index < characters.count {
                    let next = characters[index]
                    let exponentSign = (next == "+" || next == "-") && word.first?.isNumber == true
                        && (word.last == "E" || word.last == "e") && !word.contains("#")
                    guard next.isLetter || next.isNumber || next == "_" || next == "#" || next == "." || exponentSign else { break }
                    word.append(next)
                    index += 1
                }
                tokens.append(word)
            } else if character == "*" && index + 1 < characters.count && characters[index + 1] == "*" {
                tokens.append("**")
                index += 2
            } else if "+-*/()&".contains(character) {
                tokens.append(String(character))
                index += 1
            } else {
                throw ResolveError(message: S7Messages.invalidExpression("\"\(character)\" is not allowed."))
            }
        }
        return tokens
    }

    private struct Parser {
        let tokens: [String]
        var position = 0

        init(tokens: [String]) {
            self.tokens = tokens
        }

        private var current: String? { position < tokens.count ? tokens[position] : nil }

        private mutating func take(_ options: [String]) -> String? {
            guard let token = current?.uppercased(), options.contains(token) else { return nil }
            position += 1
            return token
        }

        mutating func orExpression() throws -> S7Expression {
            var left = try xorExpression()
            while take(["OR"]) != nil {
                left = .binary("OR", left, try xorExpression())
            }
            return left
        }

        private mutating func xorExpression() throws -> S7Expression {
            var left = try andExpression()
            while take(["XOR"]) != nil {
                left = .binary("XOR", left, try andExpression())
            }
            return left
        }

        private mutating func andExpression() throws -> S7Expression {
            var left = try additive()
            while take(["AND", "&"]) != nil {
                left = .binary("AND", left, try additive())
            }
            return left
        }

        private mutating func additive() throws -> S7Expression {
            var left = try multiplicative()
            while let op = take(["+", "-"]) {
                left = .binary(op, left, try multiplicative())
            }
            return left
        }

        private mutating func multiplicative() throws -> S7Expression {
            var left = try power()
            while let op = take(["*", "/", "MOD"]) {
                left = .binary(op, left, try power())
            }
            return left
        }

        private mutating func power() throws -> S7Expression {
            let left = try unary()
            if take(["**"]) != nil {
                return .binary("**", left, try power())
            }
            return left
        }

        private mutating func unary() throws -> S7Expression {
            if take(["-"]) != nil { return .negate(try unary()) }
            if take(["+"]) != nil { return try unary() }
            if take(["NOT"]) != nil { return .not(try unary()) }
            return try primary()
        }

        private mutating func primary() throws -> S7Expression {
            guard let token = current else {
                throw ResolveError(message: S7Messages.invalidExpression("the expression ends too early."))
            }
            position += 1
            if token == "(" {
                let inner = try orExpression()
                guard take([")"]) != nil else { throw ResolveError(message: S7Messages.invalidExpression("\")\" is missing.")) }
                return inner
            }
            let upper = token.uppercased()
            if S7Expression.functions.contains(upper) {
                guard take(["("]) != nil else { throw ResolveError(message: S7Messages.invalidExpression("\"(\" is missing after \(upper).")) }
                let inner = try orExpression()
                guard take([")"]) != nil else { throw ResolveError(message: S7Messages.invalidExpression("\")\" is missing.")) }
                return .function(upper, inner)
            }
            if upper.hasPrefix("IN"), let number = Int(upper.dropFirst(2)), number >= 1 {
                return .input(number - 1)
            }
            if let first = token.first, first.isNumber || upper.contains("#") {
                return .literal(token)
            }
            throw ResolveError(message: S7Messages.invalidExpression("\"\(token)\" is not an input (IN1, IN2…), a number or a function."))
        }
    }

    /// Checks literals against the box type before the program runs.
    func validate(as type: PLCDataType) throws {
        switch self {
        case let .literal(text):
            guard ValueParser.parse(text, as: type) != nil else {
                throw ResolveError(message: S7Messages.invalidConstant(text, type.rawValue))
            }
        case .input:
            break
        case let .negate(inner), let .not(inner):
            try inner.validate(as: type)
        case let .function(name, inner):
            if !type.isReal && name != "ABS" && name != "NEG" {
                throw ResolveError(message: S7Messages.invalidExpression("\(name) needs the data type Real or LReal."))
            }
            try inner.validate(as: type)
        case let .binary(op, left, right):
            if ["AND", "OR", "XOR"].contains(op) && type.isReal {
                throw ResolveError(message: S7Messages.invalidExpression("\(op) is not possible with \(type.rawValue)."))
            }
            if op == "MOD" && type.isReal {
                throw ResolveError(message: S7Messages.invalidExpression("MOD is not possible with \(type.rawValue)."))
            }
            try left.validate(as: type)
            try right.validate(as: type)
        }
    }

    /// Evaluates in the box type; `isValid` becomes false on overflow or an invalid result (ENO).
    func evaluate(_ inputs: [PLCValue], as type: PLCDataType) -> OperationResult {
        switch self {
        case let .literal(text):
            return OperationResult(value: ValueParser.parse(text, as: type) ?? type.defaultValue, isValid: true)
        case let .input(index):
            let value = index < inputs.count ? inputs[index].converted(to: type) : type.defaultValue
            return OperationResult(value: value, isValid: true)
        case let .negate(inner):
            let operand = inner.evaluate(inputs, as: type)
            let result = PLCOperations.arithmetic(.subtract, PLCOperations.integer(0, as: type), operand.value, as: type)
            return OperationResult(value: result.value, isValid: operand.isValid && result.isValid)
        case let .not(inner):
            let operand = inner.evaluate(inputs, as: type)
            return OperationResult(value: PLCOperations.invert(operand.value, as: type), isValid: operand.isValid)
        case let .function(name, inner):
            let operand = inner.evaluate(inputs, as: type)
            let result = S7Math.function(name, operand.value, as: type)
            return OperationResult(value: result.value, isValid: operand.isValid && result.isValid)
        case let .binary(op, left, right):
            let a = left.evaluate(inputs, as: type)
            let b = right.evaluate(inputs, as: type)
            let result: OperationResult
            switch op {
            case "AND": result = OperationResult(value: PLCOperations.bitLogic(.and, a.value, b.value, as: type), isValid: true)
            case "OR": result = OperationResult(value: PLCOperations.bitLogic(.or, a.value, b.value, as: type), isValid: true)
            case "XOR": result = OperationResult(value: PLCOperations.bitLogic(.xor, a.value, b.value, as: type), isValid: true)
            case "+": result = PLCOperations.arithmetic(.add, a.value, b.value, as: type)
            case "-": result = PLCOperations.arithmetic(.subtract, a.value, b.value, as: type)
            case "*": result = PLCOperations.arithmetic(.multiply, a.value, b.value, as: type)
            case "/": result = PLCOperations.arithmetic(.divide, a.value, b.value, as: type)
            case "MOD": result = PLCOperations.arithmetic(.modulo, a.value, b.value, as: type)
            default: result = PLCOperations.arithmetic(.power, a.value, b.value, as: type)
            }
            return OperationResult(value: result.value, isValid: a.isValid && b.isValid && result.isValid)
        }
    }
}

/// Floating-point functions of the Math folder (SQR, SQRT, LN, …).
nonisolated enum S7Math {
    static func function(_ name: String, _ value: PLCValue, as type: PLCDataType) -> OperationResult {
        if name == "ABS" {
            if type.isReal { return OperationResult(value: .real(abs(value.doubleValue)), isValid: true) }
            let magnitude = abs(type.wrap(value.intValue))
            return OperationResult(value: PLCOperations.integer(type.wrap(magnitude), as: type), isValid: type.contains(magnitude))
        }
        if name == "NEG" {
            return PLCOperations.arithmetic(.subtract, PLCOperations.integer(0, as: type), value, as: type)
        }
        let x = value.doubleValue
        let raw: Double
        switch name {
        case "SQR": raw = x * x
        case "SQRT": raw = x.squareRoot()
        case "LN": raw = log(x)
        case "EXP": raw = exp(x)
        case "SIN": raw = sin(x)
        case "COS": raw = cos(x)
        case "TAN": raw = tan(x)
        case "ASIN": raw = asin(x)
        case "ACOS": raw = acos(x)
        case "ATAN": raw = atan(x)
        case "FRAC": raw = x - x.rounded(.towardZero)
        default: raw = x
        }
        let stored = type == .real ? Double(Float(raw)) : raw
        return OperationResult(value: .real(stored), isValid: stored.isFinite)
    }
}
