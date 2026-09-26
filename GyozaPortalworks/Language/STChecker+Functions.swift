import Foundation

/// A standard function call's arguments in parameter order.
nonisolated struct STStandardArguments {
    var inputs: [STArgument]
    /// MUX's INELSE.
    var elseInput: STArgument?
    /// `ENO => #ok` (TIA).
    var eno: STArgument?
}

// Standard functions: argument lists and data types. Their semantics live in STStandardLibrary.
nonisolated extension STChecker {
    func compileStandardCall(_ function: STStandardFunction, _ call: STCall, expected: PLCDataType?,
                             target: PLCDataType?) -> STValue? {
        guard let arguments = standardArguments(function, call) else { return nil }
        let name = function.name
        var values: [STValue] = []
        var valid = true
        let inputs = arguments.inputs + (arguments.elseInput.map { [$0] } ?? [])
        for input in inputs {
            if let value = compileExpression(input.value, expected: expected) {
                values.append(value)
            } else {
                valid = false
            }
        }
        let enoStore = compileENO(arguments.eno)
        guard valid, arguments.eno == nil || enoStore != nil else { return nil }

        var coerced: [STValue] = []
        var shape = STCallShape(result: .int, input: .int, hasElse: arguments.elseInput != nil, dialect: dialect)
        switch function {
        case .math:
            guard let type = realType(of: values[0], expected: expected, function: name),
                  let value = coerce(values[0], to: type, for: .parameter) else { return nil }
            coerced = [value]
            shape.result = type
            shape.input = type
        case .abs, .move:
            var value = values[0]
            if value.untyped != nil {
                if let expected, expected.isNumeric || function == .move { value = adapted(value, toward: expected) }
                value = Self.typed(value)
            }
            if function == .abs && !(value.type.isSignedInteger || value.type.isUnsignedInteger || value.type.isReal) {
                notPermitted(value.type, at: value.range, hint: "ABS needs an integer or a floating-point number.")
                return nil
            }
            coerced = [value]
            shape.result = value.type
            shape.input = value.type
        case .expt:
            guard let type = realType(of: values[0], expected: expected, function: name),
                  let base = coerce(values[0], to: type, for: .parameter) else { return nil }
            let exponent = Self.typed(values[1])
            guard exponent.type.isNumeric && !exponent.type.isBitString else {
                notPermitted(exponent.type, at: exponent.range, hint: "The exponent must be a number.")
                return nil
            }
            coerced = [base, exponent]
            shape.result = type
            shape.input = type
        case .rounding:
            guard let type = realType(of: values[0], expected: nil, function: name),
                  let value = coerce(values[0], to: type, for: .parameter) else { return nil }
            coerced = [value]
            shape.input = type
            if let target, target.isSignedInteger || target.isUnsignedInteger {
                shape.result = target
            } else {
                shape.result = .dint
            }
        case .min, .max, .limit:
            guard let common = commonType(of: values, expected: expected, function: name) else { return nil }
            guard (common.isNumeric && !common.isBitString) || common == .time else {
                notPermitted(common, at: call.range, hint: "\(name) needs numbers or times.")
                return nil
            }
            guard let all = coerceAll(values, to: common) else { return nil }
            coerced = all
            shape.result = common
            shape.input = common
        case .sel:
            guard let selector = coerce(values[0], to: .bool, for: .parameter),
                  let common = commonType(of: Array(values.dropFirst()), expected: expected, function: name),
                  let rest = coerceAll(Array(values.dropFirst()), to: common) else { return nil }
            coerced = [selector] + rest
            shape.result = common
            shape.input = common
        case .mux:
            let selector = Self.typed(adapted(values[0], toward: .dint))
            guard selector.type.isSignedInteger || selector.type.isUnsignedInteger else {
                notPermitted(selector.type, at: selector.range, hint: "MUX's K must be an integer.")
                return nil
            }
            guard let common = commonType(of: Array(values.dropFirst()), expected: expected, function: name),
                  let rest = coerceAll(Array(values.dropFirst()), to: common) else { return nil }
            coerced = [selector] + rest
            shape.result = common
            shape.input = common
        case .shl, .shr, .rol, .ror:
            var value = values[0]
            if value.untyped != nil {
                if let expected, expected.isInteger { value = adapted(value, toward: expected) }
                value = Self.typed(value)
            }
            guard value.type.isInteger else {
                notPermitted(value.type, at: value.range, hint: "\(name) needs a bit string or an integer.")
                return nil
            }
            let count = Self.typed(values[1])
            guard count.type.isInteger else {
                notPermitted(count.type, at: count.range, hint: "N must be an integer.")
                return nil
            }
            coerced = [value, count]
            shape.result = value.type
            shape.input = value.type
        case .normX:
            guard let common = commonType(of: values, expected: nil, function: name) else { return nil }
            guard common.isNumeric && !common.isBitString else {
                notPermitted(common, at: call.range, hint: "NORM_X needs integers or floating-point numbers.")
                return nil
            }
            guard let all = coerceAll(values, to: common) else { return nil }
            coerced = all
            shape.input = common
            if let target, target.isReal {
                shape.result = target
            } else {
                shape.result = common == .lreal ? .lreal : .real
            }
        case .scaleX:
            guard let valueType = realType(of: values[1], expected: nil, function: name),
                  let value = coerce(values[1], to: valueType, for: .parameter) else { return nil }
            let limits = [values[0], values[2]]
            let result: PLCDataType
            if let target, target.isNumeric && !target.isBitString {
                result = target
            } else {
                guard let common = commonType(of: limits, expected: expected, function: name) else { return nil }
                result = common
            }
            guard result.isNumeric && !result.isBitString else {
                notPermitted(result, at: call.range, hint: "SCALE_X needs integers or floating-point numbers.")
                return nil
            }
            guard let low = coerce(values[0], to: result, for: .parameter),
                  let high = coerce(values[2], to: result, for: .parameter) else { return nil }
            coerced = [low, value, high]
            shape.result = result
            shape.input = valueType
        case let .convert(from, to):
            guard let value = coerce(values[0], to: from, for: .parameter) else { return nil }
            coerced = [value]
            shape.result = to
            shape.input = from
        }

        let evaluators = coerced.map(\.evaluate)
        let finalShape = shape
        var constant: PLCValue?
        let constants = coerced.compactMap(\.constant)
        if constants.count == coerced.count && enoStore == nil {
            constant = STStandardLibrary.evaluate(function, constants, shape: finalShape).value
        }
        return STValue(type: finalShape.result, untyped: nil, constant: constant, evaluate: { state in
            var arguments: [PLCValue] = []
            arguments.reserveCapacity(evaluators.count)
            for evaluate in evaluators {
                arguments.append(try evaluate(state))
            }
            let result = STStandardLibrary.evaluate(function, arguments, shape: finalShape)
            if let enoStore {
                try enoStore(state, result.isValid)
            }
            return result.value
        }, range: call.range)
    }

    /// Matches the arguments to the IEC parameter names (or takes them in order).
    private func standardArguments(_ function: STStandardFunction, _ call: STCall) -> STStandardArguments? {
        let name = function.name
        var eno: STArgument?
        var rest: [STArgument] = []
        for argument in call.arguments {
            if let parameter = argument.name, parameter.caseInsensitiveCompare("ENO") == .orderedSame {
                guard dialect == .siemens else {
                    error("ENO is not available here in GX Works.", at: argument.range)
                    return nil
                }
                guard argument.isOutput, eno == nil else {
                    error("ENO is an output: write ENO => #tag, once.", at: argument.range)
                    return nil
                }
                eno = argument
            } else {
                rest.append(argument)
            }
        }
        let namedCount = rest.filter { $0.name != nil }.count
        guard namedCount == 0 || namedCount == rest.count else {
            error("Use either named or positional arguments for \(name), not both.", at: call.range)
            return nil
        }
        for argument in rest where argument.isOutput {
            error("The input \(argument.name ?? "") of \(name) must be assigned with ':='.", at: argument.range)
            return nil
        }

        if let fixed = function.parameterNames {
            var ordered: [STArgument] = rest
            if namedCount > 0 {
                var slots: [STArgument?] = Array(repeating: nil, count: fixed.count)
                for argument in rest {
                    guard let index = fixed.firstIndex(where: { $0.caseInsensitiveCompare(argument.name ?? "") == .orderedSame }) else {
                        error("\(name) has no parameter \(argument.name ?? ""); its parameters are \(fixed.joined(separator: ", ")).",
                              at: argument.nameRange ?? argument.range)
                        return nil
                    }
                    guard slots[index] == nil else {
                        error("Parameter \(fixed[index]) is assigned more than once.", at: argument.nameRange ?? argument.range)
                        return nil
                    }
                    slots[index] = argument
                }
                ordered = slots.compactMap { $0 }
            }
            guard ordered.count == fixed.count else {
                error("\(name) needs \(fixed.count == 1 ? "one parameter" : "\(fixed.count) parameters") (\(fixed.joined(separator: ", "))).", at: call.range)
                return nil
            }
            return STStandardArguments(inputs: ordered, elseInput: nil, eno: eno)
        }

        // MIN / MAX: IN1…INn. MUX: K, IN0…INn, INELSE.
        let isMux = function == .mux
        var inputs = rest
        var elseInput: STArgument?
        if namedCount > 0 {
            var selector: STArgument?
            var numbered: [Int: STArgument] = [:]
            for argument in rest {
                let parameter = (argument.name ?? "").uppercased()
                if isMux && parameter == "K" && selector == nil {
                    selector = argument
                } else if isMux && parameter == "INELSE" && elseInput == nil {
                    elseInput = argument
                } else if parameter.hasPrefix("IN"), let number = Int(parameter.dropFirst(2)), numbered[number] == nil {
                    numbered[number] = argument
                } else {
                    error("\(name) has no parameter \(argument.name ?? "") here.", at: argument.nameRange ?? argument.range)
                    return nil
                }
            }
            let first = isMux ? 0 : 1
            let ordered = (first..<(first + numbered.count)).compactMap { numbered[$0] }
            guard ordered.count == numbered.count else {
                error("The inputs of \(name) must be numbered without gaps, starting at IN\(first).", at: call.range)
                return nil
            }
            if isMux {
                guard let selector else {
                    error("MUX needs the selector K.", at: call.range)
                    return nil
                }
                inputs = [selector] + ordered
            } else {
                inputs = ordered
            }
        }
        let minimum = isMux ? 3 : 2
        guard inputs.count >= minimum else {
            error(isMux ? "MUX needs K and at least two inputs (IN0, IN1)." : "\(name) needs at least two inputs (IN1, IN2).", at: call.range)
            return nil
        }
        return STStandardArguments(inputs: inputs, elseInput: elseInput, eno: eno)
    }

    /// `ENO => #tag`: a writable Bool.
    private func compileENO(_ argument: STArgument?) -> ((STRunState, Bool) throws -> Void)? {
        guard let argument else { return nil }
        guard let operand = argument.value.operand else {
            error("ENO needs a Bool tag to write to.", at: argument.value.range)
            return nil
        }
        guard let place = resolvePlace(operand), checkWritable(place) else { return nil }
        guard place.type.elementary == .bool else {
            notPermitted(place.type.elementary ?? .int, at: operand.range, hint: "ENO is a Bool.")
            return nil
        }
        markWritten(place)
        let locate = place.locate
        let store = recordingStore(place, type: .bool)
        return { state, isValid in
            _ = store(state, try locate(state), .bool(isValid))
        }
    }

    /// The floating-point type a Real/LReal parameter takes for `value`.
    private func realType(of value: STValue, expected: PLCDataType?, function: String) -> PLCDataType? {
        if let literal = value.untyped {
            if let expected, expected.isReal, Self.literalValue(literal, as: expected) != nil { return expected }
            return .lreal
        }
        let type = value.type
        if type.isReal { return type }
        if type.isSignedInteger || type.isUnsignedInteger {
            if PLCTypeRules.canConvertImplicitly(from: type, to: .real, dialect: dialect) { return .real }
            if PLCTypeRules.canConvertImplicitly(from: type, to: .lreal, dialect: dialect) { return .lreal }
        }
        notPermitted(type, at: value.range, hint: "\(function) needs a floating-point number.")
        return nil
    }

    /// The data type several inputs share; untyped literals adapt to it.
    private func commonType(of values: [STValue], expected: PLCDataType?, function: String) -> PLCDataType? {
        var common: PLCDataType?
        for value in values where value.untyped == nil {
            guard let current = common else {
                common = value.type
                continue
            }
            guard let next = PLCTypeRules.commonType(current, value.type, dialect: dialect) else {
                incompatible(function, current, value.type, at: value.range)
                return nil
            }
            common = next
        }
        let literals = values.compactMap(\.untyped)
        guard let typed = common else {
            if let expected, !literals.isEmpty, literals.allSatisfy({ Self.literalValue($0, as: expected) != nil }) {
                return expected
            }
            var natural = values.first?.type ?? .int
            for value in values.dropFirst() {
                natural = PLCTypeRules.commonType(natural, value.type, dialect: dialect) ?? .lreal
            }
            return natural
        }
        var result = typed
        for value in values where value.untyped != nil {
            guard let literal = value.untyped, Self.literalValue(literal, as: result) == nil else { continue }
            guard let wider = PLCTypeRules.commonType(result, value.type, dialect: dialect) else {
                incompatible(function, result, value.type, at: value.range)
                return nil
            }
            result = wider
        }
        return result
    }

    private func coerceAll(_ values: [STValue], to type: PLCDataType) -> [STValue]? {
        var result: [STValue] = []
        for value in values {
            guard let coerced = coerce(value, to: type, for: .parameter) else { return nil }
            result.append(coerced)
        }
        return result
    }
}
