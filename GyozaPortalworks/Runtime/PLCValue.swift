import Foundation

/// IEC 61131-3 elementary data types, shared by both environments. Raw values
/// are the spellings TIA Portal shows in its tag tables and block interfaces.
nonisolated enum PLCDataType: String, Codable, CaseIterable, Hashable, Sendable {
    case bool = "Bool"
    case byte = "Byte"
    case word = "Word"
    case dword = "DWord"
    case sint = "SInt"
    case int = "Int"
    case dint = "DInt"
    case usint = "USInt"
    case uint = "UInt"
    case udint = "UDInt"
    case real = "Real"
    case lreal = "LReal"
    case time = "Time"

    /// Looks a type up by any common spelling: "Int", "INT", "int".
    static func named(_ name: String) -> PLCDataType? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.rawValue.lowercased() == key }
    }

    var isBit: Bool { self == .bool }
    var isBitString: Bool { self == .byte || self == .word || self == .dword }
    var isSignedInteger: Bool { self == .sint || self == .int || self == .dint }
    var isUnsignedInteger: Bool { self == .usint || self == .uint || self == .udint }
    var isInteger: Bool { isSignedInteger || isUnsignedInteger || isBitString }
    var isReal: Bool { self == .real || self == .lreal }
    var isNumeric: Bool { isInteger || isReal }

    /// Storage width in bits.
    var bitWidth: Int {
        switch self {
        case .bool: 1
        case .byte, .sint, .usint: 8
        case .word, .int, .uint: 16
        case .dword, .dint, .udint, .real, .time: 32
        case .lreal: 64
        }
    }

    /// All-ones mask of the type's width, for bit-level work on integers.
    var bitMask: Int64 {
        bitWidth >= 64 ? -1 : (Int64(1) << Int64(bitWidth)) - 1
    }

    /// Value range for integer and time types.
    var integerRange: ClosedRange<Int64>? {
        switch self {
        case .sint: -128...127
        case .int: -32_768...32_767
        case .dint, .time: -2_147_483_648...2_147_483_647
        case .usint, .byte: 0...255
        case .uint, .word: 0...65_535
        case .udint, .dword: 0...4_294_967_295
        case .bool: 0...1
        case .real, .lreal: nil
        }
    }

    var defaultValue: PLCValue {
        switch self {
        case .bool: .bool(false)
        case .real, .lreal: .real(0)
        case .time: .time(0)
        default: .int(0)
        }
    }

    /// Wraps an integer into this type's width, the way the CPU's registers
    /// would (two's complement), e.g. Int 32_767 + 1 → -32_768.
    func wrap(_ value: Int64) -> Int64 {
        switch self {
        case .sint: Int64(Int8(truncatingIfNeeded: value))
        case .int: Int64(Int16(truncatingIfNeeded: value))
        case .dint, .time: Int64(Int32(truncatingIfNeeded: value))
        case .usint, .byte: Int64(UInt8(truncatingIfNeeded: value))
        case .uint, .word: Int64(UInt16(truncatingIfNeeded: value))
        case .udint, .dword: Int64(UInt32(truncatingIfNeeded: value))
        case .bool: value & 1
        case .real, .lreal: value
        }
    }

    /// Whether `value` fits without wrapping (used for overflow → ENO = FALSE).
    func contains(_ value: Int64) -> Bool {
        integerRange?.contains(value) ?? true
    }
}

/// A runtime value. Every integer type is carried as `int` and kept in range
/// by `PLCDataType.wrap`; `time` is milliseconds.
nonisolated enum PLCValue: Hashable, Codable, Sendable {
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case time(Int64)

    var boolValue: Bool {
        switch self {
        case let .bool(value): value
        case let .int(value): value != 0
        case let .real(value): value != 0
        case let .time(value): value != 0
        }
    }

    var intValue: Int64 {
        switch self {
        case let .bool(value): value ? 1 : 0
        case let .int(value): value
        case let .real(value):
            if value.isNaN { 0 } else if value >= 9.2e18 { Int64.max } else if value <= -9.2e18 { Int64.min } else { Int64(value.rounded(.towardZero)) }
        case let .time(value): value
        }
    }

    var doubleValue: Double {
        switch self {
        case let .bool(value): value ? 1 : 0
        case let .int(value): Double(value)
        case let .real(value): value
        case let .time(value): Double(value)
        }
    }

    /// The value as it would be stored in an operand of `type`.
    func converted(to type: PLCDataType) -> PLCValue {
        switch type {
        case .bool: return .bool(boolValue)
        case .real: return .real(Double(Float(doubleValue)))
        case .lreal: return .real(doubleValue)
        case .time: return .time(type.wrap(intValue))
        default:
            // Real → integer assignment truncates toward zero, like TRUNC.
            return .int(type.wrap(intValue))
        }
    }

    /// Text as the monitor shows it: TRUE/FALSE, T#1S_500MS, 16#00FF, 12.5.
    func formatted(as type: PLCDataType) -> String {
        switch type {
        case .bool:
            return boolValue ? "TRUE" : "FALSE"
        case .time:
            return TimeLiteral.format(milliseconds: intValue)
        case .byte:
            return "16#" + String(format: "%02X", UInt8(truncatingIfNeeded: intValue))
        case .word:
            return "16#" + String(format: "%04X", UInt16(truncatingIfNeeded: intValue))
        case .dword:
            return "16#" + String(format: "%08X", UInt32(truncatingIfNeeded: intValue))
        case .real, .lreal:
            return RealLiteral.format(doubleValue)
        default:
            return String(intValue)
        }
    }
}

/// IEC duration literals: T#5S, T#1H_2M, TIME#250MS, T#1.5S.
nonisolated enum TimeLiteral {
    /// Parses the part after "T#" / "TIME#" (case-insensitive, underscores
    /// allowed), e.g. "1h2m3s4ms", "1S_500MS", "2.5s", "-5s". Returns
    /// milliseconds, or nil if it isn't a valid duration.
    static func parse(_ text: String) -> Int64? {
        var body = text.lowercased().replacingOccurrences(of: "_", with: "")
        var sign: Int64 = 1
        if body.hasPrefix("-") {
            sign = -1
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }

        let multipliers: [(String, Double)] = [("ms", 1), ("d", 86_400_000), ("h", 3_600_000), ("m", 60_000), ("s", 1_000)]
        var total: Double = 0
        var index = body.startIndex
        var sawComponent = false
        while index < body.endIndex {
            let numberStart = index
            while index < body.endIndex, body[index].isNumber || body[index] == "." {
                index = body.index(after: index)
            }
            guard numberStart < index, let number = Double(body[numberStart..<index]) else { return nil }
            let rest = body[index...]
            guard let unit = multipliers.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += number * unit.1
            index = body.index(index, offsetBy: unit.0.count)
            sawComponent = true
        }
        guard sawComponent, total <= 2_147_483_647 else { return nil }
        return sign * Int64(total.rounded())
    }

    /// Formats milliseconds the way TIA Portal displays them: T#0MS, T#5S,
    /// T#1M_30S, T#1S_500MS, -T#2S.
    static func format(milliseconds: Int64) -> String {
        guard milliseconds != 0 else { return "T#0MS" }
        var remaining = abs(milliseconds)
        var parts: [String] = []
        for (unit, size) in [("D", Int64(86_400_000)), ("H", 3_600_000), ("M", 60_000), ("S", 1_000), ("MS", 1)] {
            let count = remaining / size
            if count > 0 {
                parts.append("\(count)\(unit)")
                remaining -= count * size
            }
        }
        return (milliseconds < 0 ? "-T#" : "T#") + parts.joined(separator: "_")
    }
}

nonisolated enum RealLiteral {
    /// Shortest readable text: 12.5, 3.0, 1.0E+20.
    static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "+Inf" : "-Inf" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.1f", value)
        }
        if abs(value) >= 1e7 || abs(value) < 1e-4 {
            return String(format: "%.6E", value)
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text += "0" }
        return text
    }
}
