import Foundation

nonisolated enum ArithmeticOperator: String, CaseIterable, Hashable, Sendable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case modulo = "MOD"
    case power = "**"
}

nonisolated enum ComparisonOperator: String, CaseIterable, Hashable, Sendable {
    case equal = "="
    case notEqual = "<>"
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="

    /// How TIA Portal's LAD/FBD compare boxes are labelled (CMP ==, CMP <>).
    var siemensSymbol: String { self == .equal ? "==" : rawValue }
}

nonisolated enum BitLogicOperator: String, CaseIterable, Hashable, Sendable {
    case and = "AND"
    case or = "OR"
    case xor = "XOR"
}

/// A result plus whether the operation succeeded: an instruction's ENO.
nonisolated struct OperationResult: Hashable, Sendable {
    var value: PLCValue
    var isValid: Bool
}

/// The arithmetic, logic and conversion semantics every language shares, so
/// SCL/ST expressions and LAD/FBD/ladder boxes compute identical results.
/// Integers wrap like the CPU's registers (Int 32767 + 1 → -32768) and report
/// the overflow through `isValid`.
nonisolated enum PLCOperations {
    static func arithmetic(_ op: ArithmeticOperator, _ lhs: PLCValue, _ rhs: PLCValue, as type: PLCDataType) -> OperationResult {
        if type.isReal {
            return realArithmetic(op, lhs.doubleValue, rhs.doubleValue, as: type)
        }
        let a = lhs.intValue
        let b = rhs.intValue
        let result: (partialValue: Int64, overflow: Bool)
        switch op {
        case .add:
            result = a.addingReportingOverflow(b)
        case .subtract:
            result = a.subtractingReportingOverflow(b)
        case .multiply:
            result = a.multipliedReportingOverflow(by: b)
        case .divide:
            guard b != 0 else { return OperationResult(value: integer(0, as: type), isValid: false) }
            result = a.dividedReportingOverflow(by: b)
        case .modulo:
            guard b != 0 else { return OperationResult(value: integer(0, as: type), isValid: false) }
            result = a.remainderReportingOverflow(dividingBy: b)
        case .power:
            let power = pow(Double(a), Double(b))
            guard power.isFinite, power > -9.2e18, power < 9.2e18 else {
                return OperationResult(value: integer(0, as: type), isValid: false)
            }
            result = (Int64(power.rounded(.towardZero)), false)
        }
        let exact = result.partialValue
        return OperationResult(value: integer(type.wrap(exact), as: type), isValid: !result.overflow && type.contains(exact))
    }

    private static func realArithmetic(_ op: ArithmeticOperator, _ a: Double, _ b: Double, as type: PLCDataType) -> OperationResult {
        let raw: Double
        switch op {
        case .add: raw = a + b
        case .subtract: raw = a - b
        case .multiply: raw = a * b
        case .divide: raw = a / b
        case .modulo: return OperationResult(value: .real(0), isValid: false)
        case .power: raw = pow(a, b)
        }
        let result = type == .real ? Double(Float(raw)) : raw
        return OperationResult(value: .real(result), isValid: result.isFinite)
    }

    /// Compares numerically; reals when either side is real. NaN compares
    /// unequal to everything, as on the CPU.
    static func compare(_ op: ComparisonOperator, _ lhs: PLCValue, _ rhs: PLCValue) -> Bool {
        switch (lhs, rhs) {
        case (.real, _), (_, .real):
            let a = lhs.doubleValue
            let b = rhs.doubleValue
            switch op {
            case .equal: return a == b
            case .notEqual: return a != b
            case .less: return a < b
            case .lessOrEqual: return a <= b
            case .greater: return a > b
            case .greaterOrEqual: return a >= b
            }
        default:
            let a = lhs.intValue
            let b = rhs.intValue
            switch op {
            case .equal: return a == b
            case .notEqual: return a != b
            case .less: return a < b
            case .lessOrEqual: return a <= b
            case .greater: return a > b
            case .greaterOrEqual: return a >= b
            }
        }
    }

    /// AND / OR / XOR on Bool, or bitwise on integers and bit strings.
    static func bitLogic(_ op: BitLogicOperator, _ lhs: PLCValue, _ rhs: PLCValue, as type: PLCDataType) -> PLCValue {
        if type == .bool {
            let a = lhs.boolValue
            let b = rhs.boolValue
            switch op {
            case .and: return .bool(a && b)
            case .or: return .bool(a || b)
            case .xor: return .bool(a != b)
            }
        }
        let a = lhs.intValue
        let b = rhs.intValue
        let raw: Int64
        switch op {
        case .and: raw = a & b
        case .or: raw = a | b
        case .xor: raw = a ^ b
        }
        return integer(type.wrap(raw), as: type)
    }

    /// NOT on Bool, or the one's complement (INV_x) of an integer.
    static func invert(_ value: PLCValue, as type: PLCDataType) -> PLCValue {
        if type == .bool { return .bool(!value.boolValue) }
        return integer(type.wrap(~value.intValue), as: type)
    }

    /// SHL: bits shifted out are lost, zeros come in.
    static func shiftLeft(_ value: PLCValue, by count: Int64, as type: PLCDataType) -> PLCValue {
        guard count > 0 else { return value.converted(to: type) }
        guard count < Int64(type.bitWidth) else { return integer(0, as: type) }
        let raw = value.intValue & type.bitMask
        return integer(type.wrap((raw << count) & type.bitMask), as: type)
    }

    /// SHR: zeros come in, except signed integers, which keep their sign
    /// (TIA fills the vacated bits with the sign bit).
    static func shiftRight(_ value: PLCValue, by count: Int64, as type: PLCDataType) -> PLCValue {
        guard count > 0 else { return value.converted(to: type) }
        if type.isSignedInteger {
            let signed = type.wrap(value.intValue)
            let shifted = count >= Int64(type.bitWidth) ? (signed < 0 ? -1 : 0) : signed >> count
            return integer(type.wrap(shifted), as: type)
        }
        guard count < Int64(type.bitWidth) else { return integer(0, as: type) }
        let raw = value.intValue & type.bitMask
        return integer(raw >> count, as: type)
    }

    /// ROL / ROR: bits leaving one end come back in at the other.
    static func rotate(_ value: PLCValue, by count: Int64, left: Bool, as type: PLCDataType) -> PLCValue {
        let width = Int64(type.bitWidth)
        let steps = ((count % width) + width) % width
        guard steps > 0 else { return value.converted(to: type) }
        let raw = value.intValue & type.bitMask
        let rotated = left
            ? ((raw << steps) | (raw >> (width - steps))) & type.bitMask
            : ((raw >> steps) | (raw << (width - steps))) & type.bitMask
        return integer(type.wrap(rotated), as: type)
    }

    /// CONVERT / X_TO_Y. Real → integer rounds with `rounding`: TIA rounds half
    /// to even, GX Works rounds half away from zero; TRUNC passes
    /// `.towardZero`. Bit strings convert by bit pattern (WORD_TO_INT
    /// 16#FFFF → -1). Invalid when the value doesn't fit the target.
    static func convert(_ value: PLCValue, from source: PLCDataType, to target: PLCDataType,
                        rounding: FloatingPointRoundingRule = .toNearestOrEven) -> OperationResult {
        switch target {
        case .bool:
            return OperationResult(value: .bool(value.boolValue), isValid: true)
        case .real, .lreal:
            let raw = value.doubleValue
            let result = target == .real ? Double(Float(raw)) : raw
            return OperationResult(value: .real(result), isValid: result.isFinite || !raw.isFinite)
        default:
            if source.isReal {
                let rounded = value.doubleValue.rounded(rounding)
                guard rounded.isFinite, rounded > -9.2e18, rounded < 9.2e18 else {
                    return OperationResult(value: integer(0, as: target), isValid: false)
                }
                let whole = Int64(rounded)
                return OperationResult(value: integer(target.wrap(whole), as: target), isValid: target.contains(whole))
            }
            let whole = source.isSignedInteger || source == .time ? source.wrap(value.intValue) : value.intValue & source.bitMask
            let bitPattern = source.isBitString || target.isBitString
            return OperationResult(value: integer(target.wrap(whole), as: target),
                                   isValid: bitPattern ? source.bitWidth <= target.bitWidth || target.contains(whole) : target.contains(whole))
        }
    }

    /// NORM_X: maps VALUE from MIN..MAX onto 0.0..1.0.
    static func normalize(_ value: PLCValue, min: PLCValue, max: PLCValue, as type: PLCDataType) -> OperationResult {
        let span = max.doubleValue - min.doubleValue
        let raw = (value.doubleValue - min.doubleValue) / span
        let result = type == .real ? Double(Float(raw)) : raw
        return OperationResult(value: .real(result), isValid: span != 0 && result.isFinite)
    }

    /// SCALE_X: maps VALUE from 0.0..1.0 onto MIN..MAX.
    static func scale(_ value: PLCValue, min: PLCValue, max: PLCValue, as type: PLCDataType) -> OperationResult {
        let raw = value.doubleValue * (max.doubleValue - min.doubleValue) + min.doubleValue
        return convert(.real(raw), from: .lreal, to: type)
    }

    /// LIMIT: clamps VALUE to MN..MX. Invalid (value passed through) when MN > MX.
    static func limit(_ value: PLCValue, min: PLCValue, max: PLCValue) -> OperationResult {
        if compare(.greater, min, max) { return OperationResult(value: value, isValid: false) }
        if compare(.less, value, min) { return OperationResult(value: min, isValid: true) }
        if compare(.greater, value, max) { return OperationResult(value: max, isValid: true) }
        return OperationResult(value: value, isValid: true)
    }

    static func minimum(_ values: [PLCValue]) -> PLCValue? {
        values.dropFirst().reduce(values.first) { best, next in
            guard let best else { return next }
            return compare(.less, next, best) ? next : best
        }
    }

    static func maximum(_ values: [PLCValue]) -> PLCValue? {
        values.dropFirst().reduce(values.first) { best, next in
            guard let best else { return next }
            return compare(.greater, next, best) ? next : best
        }
    }

    /// Wraps an integer result in the right case for `type`.
    static func integer(_ value: Int64, as type: PLCDataType) -> PLCValue {
        switch type {
        case .bool: return .bool(value != 0)
        case .time: return .time(value)
        case .real, .lreal: return .real(Double(value))
        default: return .int(value)
        }
    }
}

/// Which types mix without an explicit conversion function.
nonisolated enum PLCTypeRules {
    /// TIA Portal (IEC check off) and GX Works 3 allow widening conversions:
    /// integers into larger integers and reals, Real into LReal. TIA also lets
    /// bit strings and integers of the same or larger width mix. Narrowing,
    /// Real → integer, and anything to or from Bool or Time needs a function.
    static func canConvertImplicitly(from source: PLCDataType, to target: PLCDataType, dialect: LanguageDialect) -> Bool {
        if source == target { return true }
        if source == .bool || target == .bool || source == .time || target == .time { return false }
        if target.isReal {
            if source == .real { return target == .lreal }
            if source.isReal || source.isBitString { return false }
            switch dialect {
            case .siemens: return true
            case .melsec: return target == .lreal || source.bitWidth <= 16
            }
        }
        if source.isReal { return false }
        if source.isBitString || target.isBitString {
            if source.isBitString && target.isBitString { return target.bitWidth >= source.bitWidth }
            return dialect == .siemens && target.bitWidth >= source.bitWidth
        }
        guard let from = source.integerRange, let to = target.integerRange else { return false }
        return to.lowerBound <= from.lowerBound && to.upperBound >= from.upperBound
    }

    /// The type a binary operation on `a` and `b` computes in: the smaller of
    /// the two if the other widens into it, else the first common wider type.
    static func commonType(_ a: PLCDataType, _ b: PLCDataType, dialect: LanguageDialect) -> PLCDataType? {
        if a == b { return a }
        if canConvertImplicitly(from: a, to: b, dialect: dialect) { return b }
        if canConvertImplicitly(from: b, to: a, dialect: dialect) { return a }
        let candidates: [PLCDataType] = [.int, .dint, .word, .dword, .real, .lreal]
        return candidates.first {
            canConvertImplicitly(from: a, to: $0, dialect: dialect) && canConvertImplicitly(from: b, to: $0, dialect: dialect)
        }
    }
}
