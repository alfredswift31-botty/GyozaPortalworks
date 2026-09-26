import Foundation

/// A literal without a data type: it takes the type its context needs.
nonisolated enum STUntyped: Hashable, Sendable {
    case integer(Int64)
    case real(Double)
}

/// A checked, compiled expression.
nonisolated struct STValue {
    var type: PLCDataType
    /// Set for untyped literals (and constant expressions of them); `type`
    /// is then their natural type (Int, DInt or UDInt; LReal).
    var untyped: STUntyped?
    /// The value when it is known at compile time.
    var constant: PLCValue?
    var evaluate: STEvaluator
    var range: STSourceRange
}

/// A checked, compiled storage location.
nonisolated struct STPlace {
    var type: PLCType
    var locate: STLocator
    var isWritable: Bool
    /// Set for named constants, which have no storage.
    var constantValue: PLCValue?
    /// The place itself when it is fixed at compile time (global paths without dynamic indices).
    var fixed: Place?
    /// The Temp variable it lives in, for the read-before-write warning.
    var tempIndex: Int?
    /// Names the storage when the path has no dynamic index (protects FOR counters).
    var identity: String?
    var operand: STOperand
}

/// What a value is converted for; decides the wording of a type error.
nonisolated enum STConversionPurpose {
    case assignment
    case parameter
    case operand
}

/// Resolves names, checks types and turns the syntax tree into executable
/// closures. Everything a closure needs is copied into it: the closures
/// never capture the checker.
nonisolated final class STChecker {
    let resolver: SymbolResolver
    let dialect: LanguageDialect
    let source: [UInt16]
    /// Real → integer rounding of conversions: TIA rounds half to even, GX Works half away from zero.
    let rounding: FloatingPointRoundingRule
    var diagnostics: [Diagnostic] = []
    var sites: [STTraceSite] = []
    var loopDepth = 0
    /// Identities of the counters of the FOR loops being compiled.
    var forCounters: [String] = []
    var writtenTemps: Set<Int> = []
    var warnedTemps: Set<Int> = []

    init(resolver: SymbolResolver, source: [UInt16]) {
        self.resolver = resolver
        dialect = resolver.dialect
        self.source = source
        rounding = resolver.dialect == .siemens ? .toNearestOrEven : .toNearestOrAwayFromZero
    }

    func makeTrace() -> STTrace {
        STTrace(sites: sites)
    }

    // MARK: - Diagnostics

    func error(_ message: String, at range: STSourceRange) {
        diagnostics.append(.error(message, line: range.start.line, column: range.start.column))
    }

    func warning(_ message: String, at range: STSourceRange) {
        diagnostics.append(.warning(message, line: range.start.line, column: range.start.column))
    }

    func text(_ range: STSourceRange) -> String {
        guard range.start.offset <= range.end.offset, range.end.offset <= source.count else { return "" }
        return String(decoding: source[range.start.offset..<range.end.offset], as: UTF16.self)
    }

    /// A data type as the vendor writes it: Int (TIA), INT (GX Works).
    func typeName(_ type: PLCDataType) -> String {
        dialect == .siemens ? type.rawValue : type.rawValue.uppercased()
    }

    func typeName(_ type: PLCType) -> String {
        if let elementary = type.elementary { return typeName(elementary) }
        return type.displayName
    }

    func notPermitted(_ type: PLCDataType, at range: STSourceRange, hint: String = "") {
        let suffix = hint.isEmpty ? "" : " " + hint
        switch dialect {
        case .siemens: error("Data type \(typeName(type)) is not permitted here.\(suffix)", at: range)
        case .melsec: error("Type mismatch: data type \(typeName(type)) cannot be used here.\(suffix)", at: range)
        }
    }

    func incompatible(_ symbol: String, _ left: PLCDataType, _ right: PLCDataType, at range: STSourceRange) {
        switch dialect {
        case .siemens:
            error("Data types \(typeName(left)) and \(typeName(right)) cannot be combined with '\(symbol)'.", at: range)
        case .melsec:
            error("Type mismatch: \(typeName(left)) and \(typeName(right)) cannot be combined with '\(symbol)'.", at: range)
        }
    }

    func reportConversion(from source: PLCDataType, to target: PLCDataType, at range: STSourceRange, for purpose: STConversionPurpose) {
        var hint = ""
        if STStandardLibrary.conversionExists(from: source, to: target) {
            let function = STStandardLibrary.conversionName(from: source, to: target)
            hint = source.isReal && !target.isReal ? " Use \(function), ROUND or TRUNC." : " Use \(function)."
        }
        switch (dialect, purpose) {
        case (.siemens, .parameter):
            error("The data type \(typeName(source)) of the actual parameter does not match the data type \(typeName(target)) of the formal parameter.\(hint)", at: range)
        case (.siemens, _):
            error("Implicit conversion from '\(typeName(source))' to '\(typeName(target))' is not possible.\(hint)", at: range)
        case (.melsec, .parameter):
            error("Type mismatch: the argument is \(typeName(source)) but the parameter needs \(typeName(target)).\(hint)", at: range)
        case (.melsec, _):
            error("Type mismatch: \(typeName(source)) cannot be converted to \(typeName(target)) implicitly.\(hint)", at: range)
        }
    }

    func reportAggregateMismatch(from source: PLCType, to target: PLCType, at range: STSourceRange, for purpose: STConversionPurpose) {
        switch (dialect, purpose) {
        case (.siemens, .parameter):
            error("The data type \(typeName(source)) of the actual parameter does not match the data type \(typeName(target)) of the formal parameter.", at: range)
        case (.siemens, _):
            error("Implicit conversion from '\(typeName(source))' to '\(typeName(target))' is not possible.", at: range)
        case (.melsec, _):
            error("Type mismatch: \(typeName(source)) and \(typeName(target)) are different data types.", at: range)
        }
    }

    // MARK: - Trace sites

    func addSite(_ range: STSourceRange, text: String, type: PLCDataType) -> Int {
        sites.append(STTraceSite(line: range.start.line, column: range.start.column, length: range.length, text: text, type: type))
        return sites.count - 1
    }

    // MARK: - Values

    static func constant(_ value: PLCValue, type: PLCDataType, range: STSourceRange) -> STValue {
        STValue(type: type, untyped: nil, constant: value, evaluate: { _ in value }, range: range)
    }

    /// An untyped literal: Int if it fits, else DInt, else UDInt; LReal for reals.
    func untyped(_ literal: STUntyped, range: STSourceRange) -> STValue? {
        switch literal {
        case let .integer(value):
            guard let type = [PLCDataType.int, .dint, .udint].first(where: { $0.contains(value) }) else {
                error("The value \(value) is outside the range of every supported integer data type.", at: range)
                return nil
            }
            let stored = PLCValue.int(value)
            return STValue(type: type, untyped: literal, constant: stored, evaluate: { _ in stored }, range: range)
        case let .real(value):
            let stored = PLCValue.real(value)
            return STValue(type: .lreal, untyped: literal, constant: stored, evaluate: { _ in stored }, range: range)
        }
    }

    /// An untyped literal's value as `type`; nil if it doesn't fit or can't be that type.
    static func literalValue(_ literal: STUntyped, as type: PLCDataType) -> PLCValue? {
        switch literal {
        case let .integer(value):
            if type.isInteger {
                return type.contains(value) ? .int(value) : nil
            }
            if type == .real { return .real(Double(Float(Double(value)))) }
            if type == .lreal { return .real(Double(value)) }
            return nil
        case let .real(value):
            if type == .lreal { return .real(value) }
            if type == .real {
                let single = Float(value)
                return single.isFinite || !value.isFinite ? .real(Double(single)) : nil
            }
            return nil
        }
    }

    /// Drops the untyped flag: the value keeps its natural type.
    static func typed(_ value: STValue) -> STValue {
        var result = value
        result.untyped = nil
        return result
    }

    /// An untyped literal adapted to `type` when it fits; unchanged otherwise.
    func adapted(_ value: STValue, toward type: PLCDataType) -> STValue {
        guard let literal = value.untyped, let adapted = Self.literalValue(literal, as: type) else { return value }
        return Self.constant(adapted, type: type, range: value.range)
    }

    /// Converts `value` to `target`: untyped literals adapt (and must fit),
    /// typed values need an implicit conversion.
    func coerce(_ value: STValue, to target: PLCDataType, for purpose: STConversionPurpose) -> STValue? {
        if let literal = value.untyped {
            if let adapted = Self.literalValue(literal, as: target) {
                return Self.constant(adapted, type: target, range: value.range)
            }
            if case let .integer(number) = literal, target.isInteger, let range = target.integerRange {
                switch dialect {
                case .siemens:
                    error("The value \(number) is outside the range of \(typeName(target)) (\(range.lowerBound) to \(range.upperBound)).", at: value.range)
                case .melsec:
                    error("Constant \(number) is out of range for \(typeName(target)) (\(range.lowerBound) to \(range.upperBound)).", at: value.range)
                }
                return nil
            }
            if case .real = literal, target == .real {
                error("The value is outside the range of \(typeName(target)).", at: value.range)
                return nil
            }
            reportConversion(from: value.type, to: target, at: value.range, for: purpose)
            return nil
        }
        if value.type == target { return value }
        guard PLCTypeRules.canConvertImplicitly(from: value.type, to: target, dialect: dialect) else {
            reportConversion(from: value.type, to: target, at: value.range, for: purpose)
            return nil
        }
        return converted(value, to: target)
    }

    /// A conversion already known to be allowed.
    func converted(_ value: STValue, to target: PLCDataType) -> STValue {
        if let literal = value.untyped, let adapted = Self.literalValue(literal, as: target) {
            return Self.constant(adapted, type: target, range: value.range)
        }
        let source = value.type
        guard source != target else { return Self.typed(value) }
        let rounding = self.rounding
        let evaluate = value.evaluate
        var result = value
        result.type = target
        result.untyped = nil
        result.constant = value.constant.map { PLCOperations.convert($0, from: source, to: target, rounding: rounding).value }
        result.evaluate = { state in
            PLCOperations.convert(try evaluate(state), from: source, to: target, rounding: rounding).value
        }
        return result
    }

    /// A run-time conversion between two types, nil when none is needed.
    func conversion(from source: PLCDataType, to target: PLCDataType) -> ((PLCValue) -> PLCValue)? {
        guard source != target else { return nil }
        let rounding = self.rounding
        return { PLCOperations.convert($0, from: source, to: target, rounding: rounding).value }
    }

    /// Whether two aggregate types are the same data type: same UDT or FB
    /// name, or the same structure, and the same array limits.
    static func identical(_ first: PLCType, _ second: PLCType) -> Bool {
        switch (first, second) {
        case let (.elementary(a), .elementary(b)):
            return a == b
        case let (.array(lowerA, upperA, elementA), .array(lowerB, upperB, elementB)):
            return lowerA == lowerB && upperA == upperB && identical(elementA, elementB)
        case let (.structure(nameA, membersA), .structure(nameB, membersB)):
            if (nameA == nil) != (nameB == nil) { return false }
            if let nameA, let nameB, nameA.caseInsensitiveCompare(nameB) != .orderedSame { return false }
            return sameMembers(membersA, membersB)
        case let (.instance(blockA), .instance(blockB)):
            return blockA.name.caseInsensitiveCompare(blockB.name) == .orderedSame && blockA.builtIn == blockB.builtIn
                && sameMembers(blockA.members, blockB.members)
        default:
            return false
        }
    }

    private static func sameMembers(_ first: [PLCMember], _ second: [PLCMember]) -> Bool {
        guard first.count == second.count else { return false }
        for (a, b) in zip(first, second) where a.name.caseInsensitiveCompare(b.name) != .orderedSame || !identical(a.type, b.type) {
            return false
        }
        return true
    }

    /// The bit string of the same width as an integer type.
    static func bitString(width: Int) -> PLCDataType? {
        switch width {
        case 8: return .byte
        case 16: return .word
        case 32: return .dword
        default: return nil
        }
    }

    static func invalidAccess() -> RuntimeFault {
        RuntimeFault(.invalidOperation, "Invalid access to a tag.")
    }
}
