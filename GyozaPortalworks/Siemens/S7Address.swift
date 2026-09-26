import Foundation

/// An S7-1200 operand area that can be addressed absolutely.
nonisolated enum S7Area: String, Codable, CaseIterable, Hashable, Sendable {
    case input = "I"
    case output = "Q"
    case memory = "M"

    /// Size of the area on a CPU 1214C, in bytes.
    var size: Int {
        switch self {
        case .input, .output: return 1024
        case .memory: return 8192
        }
    }
}

/// How many bits an absolute operand spans: %I0.0, %IB0, %IW0, %ID0.
nonisolated enum S7AccessWidth: String, Codable, CaseIterable, Hashable, Sendable {
    case bit = ""
    case byte = "B"
    case word = "W"
    case doubleWord = "D"

    var byteCount: Int {
        switch self {
        case .bit, .byte: return 1
        case .word: return 2
        case .doubleWord: return 4
        }
    }

    /// The type TIA gives an untyped absolute operand: %MW10 is a Word.
    var defaultType: PLCDataType {
        switch self {
        case .bit: return .bool
        case .byte: return .byte
        case .word: return .word
        case .doubleWord: return .dword
        }
    }

    /// The width that holds a data type; nil for types absolute operands can't
    /// hold (LReal needs its tag).
    static func holding(_ type: PLCDataType) -> S7AccessWidth? {
        switch type.bitWidth {
        case 1: return .bit
        case 8: return .byte
        case 16: return .word
        case 32: return .doubleWord
        default: return nil
        }
    }
}

/// An absolute S7 operand: %I0.0, %QW80, %MD20, %I0.3:P.
///
/// All areas are big-endian: %MW10 is %MB10 (high byte) followed by %MB11,
/// so %M10.0 is bit 0 of the *high* byte of %MW10.
nonisolated struct S7Address: Hashable, Codable, Sendable, CustomStringConvertible {
    var area: S7Area
    var width: S7AccessWidth
    var byteOffset: Int
    /// 0…7; always 0 unless `width == .bit`.
    var bitNumber: Int
    /// ":P" — direct access to the I/O (the board), bypassing the process image.
    var isPeripheral: Bool

    init(area: S7Area, width: S7AccessWidth, byteOffset: Int, bitNumber: Int = 0, isPeripheral: Bool = false) {
        self.area = area
        self.width = width
        self.byteOffset = byteOffset
        self.bitNumber = width == .bit ? bitNumber : 0
        self.isPeripheral = isPeripheral
    }

    static func bit(_ area: S7Area, _ byteOffset: Int, _ bitNumber: Int, peripheral: Bool = false) -> S7Address {
        S7Address(area: area, width: .bit, byteOffset: byteOffset, bitNumber: bitNumber, isPeripheral: peripheral)
    }

    /// TIA notation: "%I0.0", "%MW10", "%QW80:P".
    var description: String {
        var text = "%" + area.rawValue + width.rawValue + String(byteOffset)
        if width == .bit { text += "." + String(bitNumber) }
        if isPeripheral { text += ":P" }
        return text
    }

    /// The same address without ":P".
    var processImageAddress: S7Address {
        var copy = self
        copy.isPeripheral = false
        return copy
    }

    /// Bytes the operand occupies.
    var byteRange: Range<Int> { byteOffset..<(byteOffset + width.byteCount) }

    /// Whether a tag of `type` may use this address (TIA's "permissible
    /// addresses and data types"): Bool needs a bit, Int a word, Real a double
    /// word; LReal lives in bit memory at %Mx.0 and spans eight bytes.
    func accepts(_ type: PLCDataType) -> Bool {
        if type == .lreal {
            return area == .memory && width == .bit && bitNumber == 0 && byteOffset + 8 <= area.size
        }
        return S7AccessWidth.holding(type) == width
    }

    /// Bytes a tag of `type` at this address occupies.
    func byteRange(for type: PLCDataType) -> Range<Int> {
        type == .lreal ? byteOffset..<(byteOffset + 8) : byteRange
    }

    /// Parses TIA notation, with or without the "%": "%I0.0", "I0.0", "%MW10",
    /// "%QD4:P". Throws a ResolveError that says exactly what is wrong.
    static func parse(_ rawText: String) throws -> S7Address {
        let shown = rawText.trimmingCharacters(in: .whitespaces)
        var text = shown.uppercased()
        if text.hasPrefix("%") { text.removeFirst() }
        var peripheral = false
        if text.hasSuffix(":P") {
            peripheral = true
            text.removeLast(2)
        }
        guard let first = text.first else {
            throw ResolveError(message: S7Messages.notAnAddress(shown))
        }
        let area: S7Area
        switch first {
        case "I": area = .input
        case "Q": area = .output
        case "M": area = .memory
        case "D" where text.hasPrefix("DB"):
            throw ResolveError(message: S7Messages.absoluteDataBlockAccess)
        case "L":
            throw ResolveError(message: S7Messages.absoluteLocalAccess)
        case "E", "A":
            throw ResolveError(message: "\"\(shown)\" uses German mnemonics. This project uses international mnemonics: I for inputs, Q for outputs.")
        default:
            throw ResolveError(message: S7Messages.notAnAddress(shown))
        }
        var rest = Substring(text.dropFirst())
        var width = S7AccessWidth.bit
        if let letter = rest.first, letter == "B" || letter == "W" || letter == "D" {
            width = S7AccessWidth(rawValue: String(letter)) ?? .bit
            rest = rest.dropFirst()
        }
        if peripheral && area == .memory {
            throw ResolveError(message: "\"\(shown)\": direct I/O access (:P) is only possible for inputs and outputs.")
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard let bytePart = parts.first, !bytePart.isEmpty, bytePart.allSatisfy(\.isASCIIDigit) else {
            throw ResolveError(message: S7Messages.notAnAddress(shown))
        }
        let byteOffset = Int(bytePart) ?? Int.max
        var bitNumber = 0
        if width == .bit {
            guard parts.count == 2 else {
                if parts.count == 1 {
                    throw ResolveError(message: "\"\(shown)\" needs a bit number, e.g. %\(area.rawValue)\(bytePart).0.")
                }
                throw ResolveError(message: S7Messages.notAnAddress(shown))
            }
            let bitPart = parts[1]
            guard !bitPart.isEmpty, bitPart.allSatisfy(\.isASCIIDigit) else {
                throw ResolveError(message: S7Messages.notAnAddress(shown))
            }
            bitNumber = Int(bitPart) ?? Int.max
            guard bitNumber <= 7 else {
                throw ResolveError(message: "Invalid bit number \(bitPart) in \"\(shown)\": bit numbers range from 0 to 7.")
            }
        } else if parts.count != 1 {
            throw ResolveError(message: "\"\(shown)\" is not a valid address: only bit addresses have a bit number.")
        }
        let highest = area.size - width.byteCount
        guard byteOffset <= highest else {
            let form = "%" + area.rawValue + width.rawValue
            throw ResolveError(message: "Address \"\(shown)\" is out of range: \(form) allows byte addresses 0 to \(highest).")
        }
        return S7Address(area: area, width: width, byteOffset: byteOffset, bitNumber: bitNumber, isPeripheral: peripheral)
    }

    /// Whether `text` looks like an absolute address, e.g. to tell "I0.0" (an
    /// address) from "Start" (a name).
    static func looksLikeAddress(_ text: String) -> Bool {
        var body = text.trimmingCharacters(in: .whitespaces).uppercased()
        if body.hasPrefix("%") { return true }
        if body.hasSuffix(":P") { body.removeLast(2) }
        guard let first = body.first, "IQM".contains(first) else { return false }
        var rest = body.dropFirst()
        if let letter = rest.first, "BWD".contains(letter) { rest = rest.dropFirst() }
        guard let digit = rest.first, digit.isASCIIDigit else { return false }
        return rest.allSatisfy { $0.isASCIIDigit || $0 == "." }
    }
}

nonisolated private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
