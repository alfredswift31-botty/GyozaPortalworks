import Foundation

/// The element types GX Works3 offers in its label editors.
nonisolated enum MelsecLabelElementType: String, CaseIterable, Hashable, Sendable {
    case bit = "Bit"
    case wordSigned = "Word [Signed]"
    case doubleWordSigned = "Double Word [Signed]"
    case wordUnsigned = "Word [Unsigned]/Bit String [16-bit]"
    case doubleWordUnsigned = "Double Word [Unsigned]/Bit String [32-bit]"
    case floatSingle = "FLOAT [Single Precision]"
    case floatDouble = "FLOAT [Double Precision]"
    case time = "Time"
    case timer = "Timer"
    case retentiveTimer = "Retentive Timer"
    case counter = "Counter"
    case longCounter = "Long Counter"

    /// The IEC name used in ST declarations and accepted when typing a type.
    var iecName: String {
        switch self {
        case .bit: return "BOOL"
        case .wordSigned: return "INT"
        case .doubleWordSigned: return "DINT"
        case .wordUnsigned: return "WORD"
        case .doubleWordUnsigned: return "DWORD"
        case .floatSingle: return "REAL"
        case .floatDouble: return "LREAL"
        case .time: return "TIME"
        case .timer: return "TIMER"
        case .retentiveTimer: return "RETENTIVETIMER"
        case .counter: return "COUNTER"
        case .longCounter: return "LONGCOUNTER"
        }
    }

    /// The runtime type of an elementary label; nil for timers and counters.
    /// "Word [Unsigned]/Bit String [16-bit]" is one type in GX Works3; it is
    /// stored as an unsigned 16-bit integer (UINT / UDINT).
    var dataType: PLCDataType? {
        switch self {
        case .bit: return .bool
        case .wordSigned: return .int
        case .doubleWordSigned: return .dint
        case .wordUnsigned: return .uint
        case .doubleWordUnsigned: return .udint
        case .floatSingle: return .real
        case .floatDouble: return .lreal
        case .time: return .time
        case .timer, .retentiveTimer, .counter, .longCounter: return nil
        }
    }

    /// The device family whose behaviour a Timer/Counter label has.
    var timerCounterKind: MelsecDeviceKind? {
        switch self {
        case .timer: return .timer
        case .retentiveTimer: return .retentiveTimer
        case .counter: return .counter
        case .longCounter: return .longCounter
        default: return nil
        }
    }

    /// The structure behind Timer/Counter labels: contact S, coil C and
    /// current value N.
    var structureMembers: [PLCMember]? {
        guard let kind = timerCounterKind else { return nil }
        return [
            PLCMember("S", .elementary(.bool)),
            PLCMember("C", .elementary(.bool)),
            PLCMember("N", .elementary(kind == .longCounter ? .udint : .int)),
        ]
    }

    /// Accepts the GX Works3 name, the IEC name, and a few common spellings.
    static func named(_ text: String) -> MelsecLabelElementType? {
        let key = text.trimmingCharacters(in: .whitespaces).uppercased()
        if let match = allCases.first(where: { $0.rawValue.uppercased() == key || $0.iecName == key }) {
            return match
        }
        switch key {
        case "UINT", "WORD [UNSIGNED]", "BIT STRING [16-BIT]": return .wordUnsigned
        case "UDINT", "DOUBLE WORD [UNSIGNED]", "BIT STRING [32-BIT]": return .doubleWordUnsigned
        case "RETENTIVE TIMER": return .retentiveTimer
        case "LONG COUNTER": return .longCounter
        default: return nil
        }
    }
}

/// A label's data type: an element type, optionally a one-dimensional array.
/// Stored as GX Works3's text ("Bit", "Word [Signed](0..9)").
nonisolated struct MelsecLabelDataType: Hashable, Sendable, Codable {
    var element: MelsecLabelElementType
    var arrayBounds: ClosedRange<Int>?

    init(_ element: MelsecLabelElementType, arrayBounds: ClosedRange<Int>? = nil) {
        self.element = element
        self.arrayBounds = arrayBounds
    }

    static let bit = MelsecLabelDataType(.bit)
    static let wordSigned = MelsecLabelDataType(.wordSigned)
    static let doubleWordSigned = MelsecLabelDataType(.doubleWordSigned)
    static let floatSingle = MelsecLabelDataType(.floatSingle)
    static let timer = MelsecLabelDataType(.timer)
    static let counter = MelsecLabelDataType(.counter)

    /// GX Works3 notation: "Bit", "Word [Signed](0..9)".
    var text: String {
        guard let bounds = arrayBounds else { return element.rawValue }
        return "\(element.rawValue)(\(bounds.lowerBound)..\(bounds.upperBound))"
    }

    var isArray: Bool { arrayBounds != nil }

    /// An elementary (non-array, non-structure) runtime type.
    var elementaryType: PLCDataType? {
        arrayBounds == nil ? element.dataType : nil
    }

    var plcType: PLCType {
        let elementType: PLCType
        if let members = element.structureMembers {
            elementType = .structure(name: element.rawValue, members: members)
        } else {
            elementType = .elementary(element.dataType ?? .int)
        }
        guard let bounds = arrayBounds else { return elementType }
        return .array(lower: bounds.lowerBound, upper: bounds.upperBound, element: elementType)
    }

    /// Parses "Bit", "INT", "Bit(0..9)", "Word [Signed](0..9)",
    /// "ARRAY[0..9] OF INT".
    init?(text rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        let upper = text.uppercased()
        if upper.hasPrefix("ARRAY") {
            guard let open = upper.firstIndex(of: "["), let close = upper.firstIndex(of: "]"), open < close,
                  let ofRange = upper.range(of: " OF ", range: close..<upper.endIndex),
                  let bounds = MelsecLabelDataType.bounds(String(upper[upper.index(after: open)..<close])),
                  let element = MelsecLabelElementType.named(String(upper[ofRange.upperBound...]))
            else { return nil }
            self.init(element, arrayBounds: bounds)
            return
        }
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            guard let bounds = MelsecLabelDataType.bounds(inner),
                  let element = MelsecLabelElementType.named(String(text[..<open]))
            else { return nil }
            self.init(element, arrayBounds: bounds)
            return
        }
        guard let element = MelsecLabelElementType.named(text) else { return nil }
        self.init(element)
    }

    /// "0..9" → 0...9; a single number n means 0...n-1 is not used by GX
    /// Works3, so only the range form is accepted.
    private static func bounds(_ text: String) -> ClosedRange<Int>? {
        let parts = text.replacingOccurrences(of: " ", with: "").components(separatedBy: "..")
        guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]), lower <= upper,
              upper - lower < 32768
        else { return nil }
        return lower...upper
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = MelsecLabelDataType(text: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown data type '\(text)'.")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// Label classes: VAR_GLOBAL / VAR_GLOBAL_CONSTANT in the global label
/// editor, VAR / VAR_CONSTANT in a program's local labels.
nonisolated enum MelsecLabelClass: String, Codable, CaseIterable, Hashable, Sendable {
    case global = "VAR_GLOBAL"
    case globalConstant = "VAR_GLOBAL_CONSTANT"
    case local = "VAR"
    case localConstant = "VAR_CONSTANT"

    var isConstant: Bool { self == .globalConstant || self == .localConstant }
    var isGlobal: Bool { self == .global || self == .globalConstant }
}

/// One row of a label editor.
nonisolated struct MelsecLabel: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var dataType: MelsecLabelDataType
    var labelClass: MelsecLabelClass
    /// Device assignment for global labels ("D100"); empty = none.
    var device: String
    /// Initial value (constants: the value); empty = 0 / FALSE.
    var initialValue: String
    var comment: String

    init(id: UUID = UUID(), name: String, dataType: MelsecLabelDataType, labelClass: MelsecLabelClass = .global,
         device: String = "", initialValue: String = "", comment: String = "") {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.labelClass = labelClass
        self.device = device
        self.initialValue = initialValue
        self.comment = comment
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, dataType, labelClass, device, initialValue, comment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        dataType = try container.decodeIfPresent(MelsecLabelDataType.self, forKey: .dataType) ?? .bit
        labelClass = try container.decodeIfPresent(MelsecLabelClass.self, forKey: .labelClass) ?? .global
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? ""
        initialValue = try container.decodeIfPresent(String.self, forKey: .initialValue) ?? ""
        comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
    }

    var hasDevice: Bool { !device.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The initial (or constant) value of an elementary label.
    var startValue: PLCValue? {
        guard let type = dataType.elementaryType else { return nil }
        let text = initialValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return type.defaultValue }
        return ValueParser.parse(text, as: type)
    }
}

/// Label name rules, as GX Works3 checks them when a label is entered.
nonisolated enum MelsecLabelRules {
    static let maximumLength = 32

    /// Words a label may not be called: IEC keywords, data type names and
    /// ST operators. Instruction names and device-like names are checked
    /// separately.
    private static let reserved: Set<String> = [
        "IF", "THEN", "ELSE", "ELSIF", "END_IF", "CASE", "OF", "END_CASE", "FOR", "TO", "BY", "DO", "END_FOR",
        "WHILE", "END_WHILE", "REPEAT", "UNTIL", "END_REPEAT", "EXIT", "RETURN", "CONTINUE",
        "TRUE", "FALSE", "NOT", "MOD", "AND", "OR", "XOR",
        "VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_IN_OUT", "VAR_GLOBAL", "VAR_CONSTANT", "VAR_GLOBAL_CONSTANT",
        "VAR_TEMP", "VAR_EXTERNAL", "END_VAR", "CONSTANT", "RETAIN", "ARRAY", "STRUCT", "END_STRUCT",
        "FUNCTION", "END_FUNCTION", "FUNCTION_BLOCK", "END_FUNCTION_BLOCK", "PROGRAM", "END_PROGRAM", "TYPE", "END_TYPE",
        "BOOL", "INT", "DINT", "UINT", "UDINT", "WORD", "DWORD", "REAL", "LREAL", "TIME", "STRING", "WSTRING",
        "SINT", "USINT", "BYTE", "LINT", "ULINT", "LWORD", "TIMER", "COUNTER", "RETENTIVETIMER", "LONGCOUNTER",
        "ANY", "ANY_NUM", "ANY_INT", "ANY_BIT", "ANY_REAL", "EN", "ENO",
    ]

    /// nil when `name` is a valid label name, otherwise why not.
    static func problem(with rawName: String, profile: MelsecCPUProfile = .fx5u) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Enter a label name." }
        guard name.count <= maximumLength else { return "'\(name)' is longer than \(maximumLength) characters." }
        guard let first = name.first, first.isLetter || first == "_" else {
            return "'\(name)': a label name must start with a letter or an underscore."
        }
        guard name.allSatisfy({ ($0.isLetter || $0.isNumber || $0 == "_") && $0 != " " }) else {
            return "'\(name)' contains characters that cannot be used in a label name."
        }
        if name.contains("__") || name.hasSuffix("_") {
            return "'\(name)': consecutive underscores and a trailing underscore cannot be used."
        }
        let upper = name.uppercased()
        if reserved.contains(upper) {
            return "'\(name)' is a reserved word and cannot be used as a label name."
        }
        if MelsecInstructionSet.definition(upper) != nil {
            return "'\(name)' is an instruction name and cannot be used as a label name."
        }
        let isLabel: Bool
        if let parsed = try? MelsecOperandParser.parse(name, profile: profile), case .label = parsed {
            isLabel = true
        } else {
            isLabel = false
        }
        guard isLabel else {
            return "'\(name)' has the same form as a device or constant and cannot be used as a label name."
        }
        return nil
    }
}

/// The labels a program sees: its local labels, then the global labels.
nonisolated struct MelsecLabelScope: Hashable, Sendable {
    var locals: [MelsecLabel]
    var globals: [MelsecLabel]

    init(locals: [MelsecLabel] = [], globals: [MelsecLabel] = []) {
        self.locals = locals
        self.globals = globals
    }

    /// Case-insensitive lookup; locals hide globals.
    func label(named name: String) -> MelsecLabel? {
        locals.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? globals.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Problems in a label list: invalid or duplicate names, unknown
    /// initial values, invalid device assignments.
    static func problems(in labels: [MelsecLabel], profile: MelsecCPUProfile) -> [String] {
        var problems: [String] = []
        var seen: Set<String> = []
        for label in labels {
            if let problem = MelsecLabelRules.problem(with: label.name, profile: profile) {
                problems.append(problem)
                continue
            }
            let key = label.name.lowercased()
            if seen.contains(key) {
                problems.append("The label '\(label.name)' is declared more than once.")
            }
            seen.insert(key)
            if label.labelClass.isConstant {
                if label.dataType.elementaryType == nil {
                    problems.append("'\(label.name)': a constant must have an elementary data type.")
                } else if label.initialValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    problems.append("'\(label.name)': enter the constant's value.")
                }
            }
            if label.dataType.elementaryType != nil, label.startValue == nil {
                problems.append("'\(label.name)': '\(label.initialValue)' is not a valid \(label.dataType.text) value.")
            }
            if label.hasDevice {
                if !label.labelClass.isGlobal || label.labelClass.isConstant {
                    problems.append("'\(label.name)': only global labels (VAR_GLOBAL) can be assigned to a device.")
                } else if let problem = deviceProblem(label, profile: profile) {
                    problems.append(problem)
                }
            }
        }
        return problems
    }

    private static func deviceProblem(_ label: MelsecLabel, profile: MelsecCPUProfile) -> String? {
        let operand: MelsecOperand
        do {
            operand = try MelsecOperandParser.parse(label.device, profile: profile)
        } catch let error as MelsecOperandError {
            return "'\(label.name)': \(error.message)"
        } catch {
            return "'\(label.name)': '\(label.device)' is not a device."
        }
        guard !label.dataType.isArray else {
            return "'\(label.name)': arrays cannot be assigned to a device in this simulator."
        }
        switch (label.dataType.element, operand) {
        case (.bit, .device(let device, nil)) where device.kind.isBitDevice || device.facet == .contact || device.facet == .coil:
            return nil
        case (.bit, .wordBit):
            return nil
        case (.wordSigned, .device(let device, nil)), (.wordUnsigned, .device(let device, nil)):
            if device.kind.isWordDevice || (device.kind.isTimerOrCounter && device.kind != .longCounter && device.facet != .contact && device.facet != .coil) {
                return nil
            }
        case (.wordSigned, .digit(let count, _, nil)), (.wordUnsigned, .digit(let count, _, nil)):
            if count <= 4 { return nil }
        case (.doubleWordSigned, .device(let device, nil)), (.doubleWordUnsigned, .device(let device, nil)),
             (.floatSingle, .device(let device, nil)), (.time, .device(let device, nil)):
            if device.kind.isWordDevice || device.kind == .longIndexRegister || (device.kind == .longCounter && device.facet != .contact && device.facet != .coil) {
                return nil
            }
        case (.doubleWordSigned, .digit(_, _, nil)), (.doubleWordUnsigned, .digit(_, _, nil)):
            return nil
        case (.timer, .device(let device, nil)), (.retentiveTimer, .device(let device, nil)),
             (.counter, .device(let device, nil)), (.longCounter, .device(let device, nil)):
            if device.facet == .whole, device.kind == label.dataType.element.timerCounterKind { return nil }
        default:
            break
        }
        return "'\(label.name)': a \(label.dataType.text) label cannot be assigned to \(operand.text(profile))."
    }
}
