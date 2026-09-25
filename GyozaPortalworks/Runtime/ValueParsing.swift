import Foundation

/// Parses values typed into watch tables, modify dialogs and start-value
/// columns. Accepts both vendors' notations: TRUE / FALSE / 1 / 0 / ON / OFF,
/// 123, -5, 16#FF, 2#1010, 8#17, INT#5, 12.5, 1.5E3, T#5S, TIME#1M30S, and
/// GX Works' K10, H1F, E1.5.
nonisolated enum ValueParser {
    static func parse(_ rawText: String, as type: PLCDataType) -> PLCValue? {
        var text = rawText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        guard !text.isEmpty else { return nil }

        // Typed prefix: INT#5, WORD#16#FF, REAL#1.5.
        if let hash = text.firstIndex(of: "#"), PLCDataType.named(String(text[..<hash])) != nil {
            text = String(text[text.index(after: hash)...])
        }

        switch type {
        case .bool:
            switch text.uppercased() {
            case "TRUE", "1", "ON": return .bool(true)
            case "FALSE", "0", "OFF": return .bool(false)
            default: return nil
            }
        case .time:
            let body = text.uppercased()
            for prefix in ["TIME#", "T#"] where body.hasPrefix(prefix) {
                return TimeLiteral.parse(String(body.dropFirst(prefix.count))).map { PLCValue.time($0) }
            }
            if let milliseconds = TimeLiteral.parse(body) { return .time(milliseconds) }
            return Int64(body).map { PLCValue.time($0) }
        case .real, .lreal:
            var body = text.uppercased()
            if body.hasPrefix("E"), body.count > 1 { body.removeFirst() }
            guard let value = Double(body), value.isFinite else { return nil }
            let stored = type == .real ? Double(Float(value)) : value
            guard stored.isFinite else { return nil }
            return .real(stored)
        default:
            guard let value = integer(text.uppercased()) else { return nil }
            if type.contains(value) { return .int(value) }
            // A bit pattern for a signed type: 16#FFFF into an Int is -1.
            if value >= 0, value <= type.bitMask, text.contains("#") || text.uppercased().hasPrefix("H") {
                return .int(type.wrap(value))
            }
            return nil
        }
    }

    /// Integer literal in any supported base, or nil.
    static func integer(_ text: String) -> Int64? {
        var body = text
        var negative = false
        if body.hasPrefix("-") {
            negative = true
            body.removeFirst()
        } else if body.hasPrefix("+") {
            body.removeFirst()
        }
        let magnitude: Int64?
        if body.hasPrefix("16#") {
            magnitude = Int64(body.dropFirst(3), radix: 16)
        } else if body.hasPrefix("2#") {
            magnitude = Int64(body.dropFirst(2), radix: 2)
        } else if body.hasPrefix("8#") {
            magnitude = Int64(body.dropFirst(2), radix: 8)
        } else if body.hasPrefix("K") {
            magnitude = Int64(body.dropFirst())
        } else if body.hasPrefix("H") {
            magnitude = Int64(body.dropFirst(), radix: 16)
        } else {
            magnitude = Int64(body)
        }
        guard let magnitude else { return nil }
        return negative ? -magnitude : magnitude
    }
}
