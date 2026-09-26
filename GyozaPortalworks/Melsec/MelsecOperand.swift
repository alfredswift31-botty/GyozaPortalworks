import Foundation

/// Which part of a timer or counter an operand names.
nonisolated enum MelsecDeviceFacet: String, Codable, Hashable, Sendable {
    /// `T0`: the contact where a bit is read, the current value where a word
    /// is read, and the timer itself for OUT/RST.
    case whole
    /// `TS0`, `STS0` (alias `SS0`), `CS0`, `LCS0`.
    case contact
    /// `TC0`, `STC0` (alias `SC0`), `CC0`, `LCC0`.
    case coil
    /// `TN0`, `STN0` (alias `SN0`), `CN0`, `LCN0`.
    case value
}

/// One device: family, number (octal and hexadecimal numbers already
/// converted) and, for timers and counters, the part it names.
nonisolated struct MelsecDevice: Hashable, Sendable {
    var kind: MelsecDeviceKind
    var number: Int
    var facet: MelsecDeviceFacet

    init(_ kind: MelsecDeviceKind, _ number: Int, facet: MelsecDeviceFacet = .whole) {
        self.kind = kind
        self.number = number
        self.facet = facet
    }

    /// The letters in front of the number: "X", "TS", "STN", "LCC".
    var prefix: String {
        guard kind.isTimerOrCounter else { return kind.rawValue }
        switch facet {
        case .whole: return kind.rawValue
        case .contact: return kind.rawValue + "S"
        case .coil: return kind.rawValue + "C"
        case .value: return kind.rawValue + "N"
        }
    }

    /// Text as GX Works3 shows it: X17, B1F, TS0, D100.
    func text(_ profile: MelsecCPUProfile) -> String {
        prefix + profile.format(number, for: kind)
    }

    /// The same device `offset` numbers further on (X7 + 1 = X10).
    func advanced(by offset: Int) -> MelsecDevice {
        MelsecDevice(kind, number + offset, facet: facet)
    }
}

/// K (decimal), H (hexadecimal) and E (real) constants.
nonisolated enum MelsecConstant: Hashable, Sendable {
    case decimal(Int64)
    /// Bit pattern, 0…FFFFFFFF.
    case hexadecimal(Int64)
    case real(Double)

    var text: String {
        switch self {
        case let .decimal(value): return "K\(value)"
        case let .hexadecimal(value): return "H" + String(value, radix: 16, uppercase: true)
        case let .real(value): return "E" + RealLiteral.format(value)
        }
    }
}

/// An instruction operand as written in the ladder or the list.
nonisolated enum MelsecOperand: Hashable, Sendable {
    /// X0, D100, TN5; `index` is the index register of `D0Z1`.
    case device(MelsecDevice, index: Int?)
    /// Digit specification: K4M0 is 4 digits (16 bits) from M0.
    case digit(count: Int, start: MelsecDevice, index: Int?)
    /// Bit of a word device: D0.F (hexadecimal bit number).
    case wordBit(MelsecDevice, bit: Int)
    case constant(MelsecConstant)
    /// A label, possibly with member access (`tmDelay.N`).
    case label(String)
    /// P0 (jump / call target).
    case pointer(Int)
    /// N0 (MC/MCR nesting).
    case nesting(Int)
    /// "?": an operand not entered yet.
    case unspecified

    /// Text as GX Works3 shows it.
    func text(_ profile: MelsecCPUProfile) -> String {
        switch self {
        case let .device(device, index):
            return device.text(profile) + (index.map { "Z\($0)" } ?? "")
        case let .digit(count, start, index):
            return "K\(count)" + start.text(profile) + (index.map { "Z\($0)" } ?? "")
        case let .wordBit(device, bit):
            return device.text(profile) + "." + String(bit, radix: 16, uppercase: true)
        case let .constant(constant):
            return constant.text
        case let .label(name):
            return name
        case let .pointer(number):
            return "P\(number)"
        case let .nesting(number):
            return "N\(number)"
        case .unspecified:
            return "?"
        }
    }

    var device: MelsecDevice? {
        switch self {
        case let .device(device, _), let .wordBit(device, _): return device
        case let .digit(_, start, _): return start
        default: return nil
        }
    }

    var isConstant: Bool {
        if case .constant = self { return true }
        return false
    }

    var labelName: String? {
        if case let .label(name) = self { return name }
        return nil
    }

    /// The operand `words` 16-bit words further on, for the second word of
    /// a 32-bit value and for block transfers: D0 → D1, K4M0 → K4M16,
    /// TN0 → TN1. nil for operands that have no successor.
    func advanced(words: Int) -> MelsecOperand? {
        switch self {
        case let .device(device, index):
            return .device(device.advanced(by: words), index: index)
        case let .digit(count, start, index):
            return .digit(count: count, start: start.advanced(by: words * count * 4), index: index)
        default:
            return words == 0 ? self : nil
        }
    }

    /// The operand `bits` bits further on, for bit arrays (SFTL, CMP's
    /// three results, ZRST): M0 → M3, X7 → X10, D0.F → D1.0.
    func advanced(bits: Int) -> MelsecOperand? {
        switch self {
        case let .device(device, index):
            return .device(device.advanced(by: bits), index: index)
        case let .wordBit(device, bit):
            let total = device.number * 16 + bit + bits
            guard total >= 0 else { return nil }
            return .wordBit(MelsecDevice(device.kind, total / 16, facet: device.facet), bit: total % 16)
        default:
            return bits == 0 ? self : nil
        }
    }
}

/// Why an operand's text can't be used.
nonisolated struct MelsecOperandError: Error, Hashable, Sendable {
    var message: String
}

/// Parses operand text: devices, constants, labels, pointers and nesting.
nonisolated enum MelsecOperandParser {
    /// Device prefixes, longest first so "LCS" wins over "LC" and "L".
    private static let prefixes: [(text: String, kind: MelsecDeviceKind, facet: MelsecDeviceFacet)] = [
        ("LCS", .longCounter, .contact), ("LCC", .longCounter, .coil), ("LCN", .longCounter, .value),
        ("STS", .retentiveTimer, .contact), ("STC", .retentiveTimer, .coil), ("STN", .retentiveTimer, .value),
        ("LC", .longCounter, .whole), ("LZ", .longIndexRegister, .whole), ("ST", .retentiveTimer, .whole),
        ("SB", .linkSpecialRelay, .whole), ("SM", .specialRelay, .whole), ("SD", .specialRegister, .whole),
        ("SW", .linkSpecialRegister, .whole), ("SS", .retentiveTimer, .contact), ("SC", .retentiveTimer, .coil),
        ("SN", .retentiveTimer, .value), ("TS", .timer, .contact), ("TC", .timer, .coil), ("TN", .timer, .value),
        ("CS", .counter, .contact), ("CC", .counter, .coil), ("CN", .counter, .value),
        ("X", .input, .whole), ("Y", .output, .whole), ("M", .internalRelay, .whole), ("L", .latchRelay, .whole),
        ("B", .linkRelay, .whole), ("F", .annunciator, .whole), ("S", .stepRelay, .whole), ("T", .timer, .whole),
        ("C", .counter, .whole), ("D", .dataRegister, .whole), ("W", .linkRegister, .whole),
        ("R", .fileRegister, .whole), ("Z", .indexRegister, .whole),
    ]

    /// Parses one operand. Throws for text that is recognizably a device or
    /// constant but invalid (X8, D8000, K99999999999); anything else that is
    /// a valid name becomes a label.
    static func parse(_ rawText: String, profile: MelsecCPUProfile) throws -> MelsecOperand {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw MelsecOperandError(message: "An operand is missing.") }
        if text == "?" { return .unspecified }
        let upper = text.uppercased()

        if let constant = try constant(upper) { return .constant(constant) }
        if let digit = try digitSpecification(upper, original: text, profile: profile) { return digit }
        if let special = try pointerOrNesting(upper, profile: profile) { return special }
        if let device = try device(upper, original: text, profile: profile) { return device }
        guard isLabelName(text) else {
            throw MelsecOperandError(message: "'\(text)' is not a valid device, constant or label.")
        }
        return .label(text)
    }

    /// Whether `text` could name a label: letters, digits and underscores,
    /// not starting with a digit, with optional `.member` parts.
    static func isLabelName(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let head = first.first, head.isLetter || head == "_" else { return false }
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        }
        return true
    }

    // MARK: Constants

    private static func constant(_ upper: String) throws -> MelsecConstant? {
        if upper.hasPrefix("K") {
            let body = upper.dropFirst()
            guard isSignedInteger(body) else { return nil }
            guard let value = Int64(body) else {
                throw MelsecOperandError(message: "The constant '\(upper)' is out of range.")
            }
            return .decimal(value)
        }
        if upper.hasPrefix("H") {
            let body = upper.dropFirst()
            guard !body.isEmpty, body.allSatisfy({ $0.isHexDigit }) else { return nil }
            guard body.count <= 8, let value = Int64(body, radix: 16) else {
                throw MelsecOperandError(message: "The constant '\(upper)' is out of range (H0-HFFFFFFFF).")
            }
            return .hexadecimal(value)
        }
        if upper.hasPrefix("E") {
            let body = String(upper.dropFirst())
            guard let first = body.first, first.isNumber || first == "-" || first == "+" || first == "." else { return nil }
            if let value = realValue(body) {
                guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude) else {
                    throw MelsecOperandError(message: "The real constant '\(upper)' is out of range.")
                }
                return .real(value)
            }
            return nil
        }
        if isSignedInteger(Substring(upper)) {
            guard let value = Int64(upper) else {
                throw MelsecOperandError(message: "The constant '\(upper)' is out of range.")
            }
            return .decimal(value)
        }
        return nil
    }

    private static func isSignedInteger(_ text: Substring) -> Bool {
        var body = text
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        return !body.isEmpty && body.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// E-constants: 1.5, -1.5, 1.5E3, 1.5E+3 and MELSEC's 1.5+3.
    private static func realValue(_ body: String) -> Double? {
        guard body.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.E".contains($0)) }) else { return nil }
        if let value = Double(body) { return value }
        guard let signIndex = body.dropFirst().lastIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let mantissa = String(body[..<signIndex])
        let exponent = String(body[signIndex...])
        return Double(mantissa + "E" + exponent)
    }

    // MARK: Digit specification, pointers, nesting

    private static func digitSpecification(_ upper: String, original: String, profile: MelsecCPUProfile) throws -> MelsecOperand? {
        let characters = Array(upper)
        guard characters.count >= 3, characters[0] == "K", characters[1].isNumber, characters[2].isLetter else { return nil }
        guard let count = characters[1].wholeNumberValue, (1...8).contains(count) else {
            throw MelsecOperandError(message: "'\(original)': the digit specification must be K1 to K8.")
        }
        let rest = String(characters[2...])
        guard let parsed = try device(rest, original: String(original.dropFirst(2)), profile: profile) else {
            throw MelsecOperandError(message: "'\(original)': the digit specification needs a bit device, e.g. K4M0.")
        }
        guard case let .device(start, index) = parsed, start.kind.isBitDevice else {
            throw MelsecOperandError(message: "'\(original)': digit specification is only possible with bit devices (X, Y, M, L, B, F, SB, S, SM).")
        }
        let last = start.number + count * 4 - 1
        if index == nil, !profile.contains(start.kind, last) {
            throw MelsecOperandError(message: "'\(original)' reaches beyond \(profile.rangeText(start.kind)).")
        }
        return .digit(count: count, start: start, index: index)
    }

    private static func pointerOrNesting(_ upper: String, profile: MelsecCPUProfile) throws -> MelsecOperand? {
        guard let first = upper.first, first == "P" || first == "N" else { return nil }
        let body = upper.dropFirst()
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let number = Int(body) else {
            throw MelsecOperandError(message: "'\(upper)' is out of range.")
        }
        if first == "P" {
            guard number < profile.pointerCount else {
                throw MelsecOperandError(message: "'\(upper)' is out of range (P0-P\(profile.pointerCount - 1)).")
            }
            return .pointer(number)
        }
        guard number < profile.nestingLevels else {
            throw MelsecOperandError(message: "'\(upper)' is out of range (N0-N\(profile.nestingLevels - 1)).")
        }
        return .nesting(number)
    }

    // MARK: Devices

    /// A device with an optional `.b` bit or `Zn` index suffix. nil when the
    /// text doesn't have device syntax (so it may be a label).
    private static func device(_ upper: String, original: String, profile: MelsecCPUProfile) throws -> MelsecOperand? {
        for entry in prefixes where upper.hasPrefix(entry.text) {
            let body = Array(upper.dropFirst(entry.text.count))
            let numbering = profile.numbering(for: entry.kind)
            // The number must start right after the prefix: with a decimal
            // digit, or any hex digit for hexadecimal families.
            guard let head = body.first, head.isASCII,
                  head.isNumber || (numbering == .hexadecimal && head.isHexDigit)
            else { continue }
            var position = 0
            while position < body.count, body[position].isASCII, body[position].isHexDigit {
                position += 1
            }
            let digits = String(body[0..<position])
            var bit: Int?
            var index: Int?
            if position < body.count {
                if body[position] == "." {
                    let suffix = body[(position + 1)...]
                    guard suffix.count == 1, let value = suffix.first?.hexDigitValue else { continue }
                    bit = value
                } else if body[position] == "Z" {
                    let suffix = body[(position + 1)...]
                    guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(String(suffix)) else { continue }
                    index = value
                } else {
                    continue
                }
            }
            return try makeDevice(kind: entry.kind, facet: entry.facet, digits: digits, bit: bit, index: index,
                                  original: original, profile: profile)
        }
        return nil
    }

    private static func makeDevice(kind: MelsecDeviceKind, facet: MelsecDeviceFacet, digits: String, bit: Int?, index: Int?,
                                   original: String, profile: MelsecCPUProfile) throws -> MelsecOperand {
        let numbering = profile.numbering(for: kind)
        guard let number = Int(digits, radix: numbering.rawValue) else {
            switch numbering {
            case .octal:
                throw MelsecOperandError(message: "'\(original)' is not a valid device: \(kind.rawValue) is numbered in octal (\(kind.rawValue)0-\(kind.rawValue)7, \(kind.rawValue)10-\(kind.rawValue)17, …).")
            case .decimal:
                throw MelsecOperandError(message: "'\(original)' is not a valid device: \(kind.rawValue) is numbered in decimal.")
            case .hexadecimal:
                throw MelsecOperandError(message: "'\(original)' is not a valid device number.")
            }
        }
        guard profile.count(kind) > 0 else {
            throw MelsecOperandError(message: "\(kind.displayName) (\(kind.rawValue)) is not available on the \(profile.series).")
        }
        guard profile.contains(kind, number) else {
            throw MelsecOperandError(message: "'\(original)' is out of range (\(profile.rangeText(kind))).")
        }
        let device = MelsecDevice(kind, number, facet: facet)
        if let bit {
            guard kind.allowsBitSpecification else {
                throw MelsecOperandError(message: "'\(original)': bit specification (.0-.F) is only possible with word devices (D, W, SW, SD, R).")
            }
            return .wordBit(device, bit: bit)
        }
        if let index {
            guard index < profile.count(.indexRegister) else {
                throw MelsecOperandError(message: "'\(original)': Z\(index) is out of range (Z0-Z\(profile.count(.indexRegister) - 1)).")
            }
            guard kind != .specialRelay, kind != .specialRegister, kind != .indexRegister, kind != .longIndexRegister else {
                throw MelsecOperandError(message: "'\(original)': index modification is not possible with \(kind.rawValue).")
            }
        }
        return .device(device, index: index)
    }
}
