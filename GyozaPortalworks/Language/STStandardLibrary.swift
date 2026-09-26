import Foundation

/// The standard functions SCL / ST code can call.
nonisolated enum STStandardFunction: Hashable, Sendable {
    /// One Real/LReal in, same type out: SQR, SQRT, LN, LOG, EXP, SIN… FRAC.
    case math(STMathFunction)
    case abs
    case expt
    /// TRUNC, ROUND, CEIL, FLOOR: Real → integer.
    case rounding(STRoundingFunction)
    case min, max, limit, sel, mux
    case shl, shr, rol, ror
    case normX, scaleX
    case move
    /// `<A>_TO_<B>`.
    case convert(from: PLCDataType, to: PLCDataType)

    var name: String {
        switch self {
        case let .math(function): return function.rawValue
        case .abs: return "ABS"
        case .expt: return "EXPT"
        case let .rounding(function): return function.rawValue
        case .min: return "MIN"
        case .max: return "MAX"
        case .limit: return "LIMIT"
        case .sel: return "SEL"
        case .mux: return "MUX"
        case .shl: return "SHL"
        case .shr: return "SHR"
        case .rol: return "ROL"
        case .ror: return "ROR"
        case .normX: return "NORM_X"
        case .scaleX: return "SCALE_X"
        case .move: return "MOVE"
        case let .convert(from, to): return STStandardLibrary.conversionName(from: from, to: to)
        }
    }

    /// Formal parameter names in order, for the fixed-arity functions.
    var parameterNames: [String]? {
        switch self {
        case .math, .abs, .rounding, .move, .convert: return ["IN"]
        case .expt: return ["IN1", "IN2"]
        case .limit: return ["MN", "IN", "MX"]
        case .sel: return ["G", "IN0", "IN1"]
        case .shl, .shr, .rol, .ror: return ["IN", "N"]
        case .normX, .scaleX: return ["MIN", "VALUE", "MAX"]
        case .min, .max, .mux: return nil
        }
    }
}

nonisolated enum STMathFunction: String, CaseIterable, Hashable, Sendable {
    case sqr = "SQR", sqrt = "SQRT", ln = "LN", log = "LOG", exp = "EXP"
    case sin = "SIN", cos = "COS", tan = "TAN", asin = "ASIN", acos = "ACOS", atan = "ATAN", frac = "FRAC"
}

nonisolated enum STRoundingFunction: String, CaseIterable, Hashable, Sendable {
    case trunc = "TRUNC", round = "ROUND", ceil = "CEIL", floor = "FLOOR"
}

/// How a checked call's values are laid out for `STStandardLibrary.evaluate`.
nonisolated struct STCallShape: Hashable, Sendable {
    /// The function's result type.
    var result: PLCDataType
    /// The type the main input was converted to (the Real of TRUNC, the
    /// source of a conversion, the common type of NORM_X's inputs).
    var input: PLCDataType
    /// MUX: the last value is the INELSE input.
    var hasElse = false
    var dialect: LanguageDialect
}

/// Standard function semantics, built on PLCOperations so SCL results match
/// the LAD / ladder boxes.
nonisolated enum STStandardLibrary {
    static func function(named rawName: String) -> STStandardFunction? {
        let name = rawName.uppercased()
        if let math = STMathFunction(rawValue: name) { return .math(math) }
        if let rounding = STRoundingFunction(rawValue: name) { return .rounding(rounding) }
        switch name {
        case "ABS": return .abs
        case "EXPT": return .expt
        case "MIN": return .min
        case "MAX": return .max
        case "LIMIT": return .limit
        case "SEL": return .sel
        case "MUX": return .mux
        case "SHL": return .shl
        case "SHR": return .shr
        case "ROL": return .rol
        case "ROR": return .ror
        case "NORM_X": return .normX
        case "SCALE_X": return .scaleX
        case "MOVE": return .move
        default: break
        }
        guard let separator = name.range(of: "_TO_"),
              let from = PLCDataType.named(String(name[..<separator.lowerBound])),
              let to = PLCDataType.named(String(name[separator.upperBound...])),
              conversionExists(from: from, to: to)
        else { return nil }
        return .convert(from: from, to: to)
    }

    static func conversionName(from: PLCDataType, to: PLCDataType) -> String {
        "\(from.rawValue.uppercased())_TO_\(to.rawValue.uppercased())"
    }

    /// Conversions with a clear meaning: Bool, integers and bit strings among
    /// each other, integers ↔ reals, Real ↔ LReal, Time ↔ Bool / integers.
    /// Bit strings ↔ reals are left out (TIA reinterprets the bit pattern there).
    static func conversionExists(from: PLCDataType, to: PLCDataType) -> Bool {
        guard from != to else { return false }
        if from.isReal || to.isReal {
            let other = from.isReal ? to : from
            return other.isReal || other.isSignedInteger || other.isUnsignedInteger
        }
        return true
    }

    /// Evaluates a call whose arguments were already converted as `shape`
    /// describes. `isValid` is the function's ENO.
    static func evaluate(_ function: STStandardFunction, _ arguments: [PLCValue], shape: STCallShape) -> OperationResult {
        let result = shape.result
        let first = arguments.first ?? result.defaultValue
        switch function {
        case let .math(math):
            return mathematics(math, first, as: result)
        case .abs:
            if first.doubleValue < 0 || (result.isReal && first.doubleValue.sign == .minus) {
                return PLCOperations.arithmetic(.subtract, result.defaultValue, first, as: result)
            }
            return OperationResult(value: first, isValid: result.isReal ? first.doubleValue.isFinite : true)
        case .expt:
            return PLCOperations.arithmetic(.power, first, arguments.count > 1 ? arguments[1] : .real(1), as: result)
        case let .rounding(rounding):
            let rule: FloatingPointRoundingRule
            switch rounding {
            case .trunc: rule = .towardZero
            case .round: rule = shape.dialect == .siemens ? .toNearestOrEven : .toNearestOrAwayFromZero
            case .ceil: rule = .up
            case .floor: rule = .down
            }
            return PLCOperations.convert(first, from: shape.input, to: result, rounding: rule)
        case .min:
            return OperationResult(value: PLCOperations.minimum(arguments) ?? first, isValid: true)
        case .max:
            return OperationResult(value: PLCOperations.maximum(arguments) ?? first, isValid: true)
        case .limit:
            guard arguments.count == 3 else { return OperationResult(value: first, isValid: false) }
            return PLCOperations.limit(arguments[1], min: arguments[0], max: arguments[2])
        case .sel:
            guard arguments.count == 3 else { return OperationResult(value: first, isValid: false) }
            return OperationResult(value: arguments[0].boolValue ? arguments[2] : arguments[1], isValid: true)
        case .mux:
            let inputs = Array(arguments.dropFirst().dropLast(shape.hasElse ? 1 : 0))
            let selector = first.intValue
            if selector >= 0, selector < Int64(inputs.count) {
                return OperationResult(value: inputs[Int(selector)], isValid: true)
            }
            let fallback = shape.hasElse ? arguments.last : inputs.last
            return OperationResult(value: fallback ?? result.defaultValue, isValid: false)
        case .shl, .shr, .rol, .ror:
            let count = arguments.count > 1 ? arguments[1].intValue : 0
            let value: PLCValue
            switch function {
            case .shl: value = PLCOperations.shiftLeft(first, by: count, as: result)
            case .shr: value = PLCOperations.shiftRight(first, by: count, as: result)
            case .rol: value = PLCOperations.rotate(first, by: count, left: true, as: result)
            default: value = PLCOperations.rotate(first, by: count, left: false, as: result)
            }
            return OperationResult(value: value, isValid: true)
        case .normX:
            guard arguments.count == 3 else { return OperationResult(value: result.defaultValue, isValid: false) }
            return PLCOperations.normalize(arguments[1], min: arguments[0], max: arguments[2], as: result)
        case .scaleX:
            guard arguments.count == 3 else { return OperationResult(value: result.defaultValue, isValid: false) }
            return PLCOperations.scale(arguments[1], min: arguments[0], max: arguments[2], as: result)
        case .move:
            return OperationResult(value: first, isValid: true)
        case let .convert(from, to):
            let rounding: FloatingPointRoundingRule = shape.dialect == .siemens ? .toNearestOrEven : .toNearestOrAwayFromZero
            return PLCOperations.convert(first, from: from, to: to, rounding: rounding)
        }
    }

    private static func mathematics(_ function: STMathFunction, _ value: PLCValue, as type: PLCDataType) -> OperationResult {
        if function == .sqr {
            return PLCOperations.arithmetic(.multiply, value, value, as: type)
        }
        let x = value.doubleValue
        let raw: Double
        switch function {
        case .sqr: raw = x * x
        case .sqrt: raw = x.squareRoot()
        case .ln: raw = log(x)
        case .log: raw = log10(x)
        case .exp: raw = exp(x)
        case .sin: raw = sin(x)
        case .cos: raw = cos(x)
        case .tan: raw = tan(x)
        case .asin: raw = asin(x)
        case .acos: raw = acos(x)
        case .atan: raw = atan(x)
        case .frac: raw = x - x.rounded(.towardZero)
        }
        let stored = type == .real ? Double(Float(raw)) : raw
        return OperationResult(value: .real(stored), isValid: stored.isFinite)
    }
}
