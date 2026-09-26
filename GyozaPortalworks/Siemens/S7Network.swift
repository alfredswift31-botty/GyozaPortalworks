import Foundation

// One network model serves LAD and FBD: a network is a set of rungs that
// start at the left power rail; each rung is a series of elements, and
// branches are either closed (an OR that rejoins) or open (a rung that fans
// out to several ends). FBD draws the same structure as AND/OR boxes and
// assignments, so switching a block between LAD and FBD keeps its networks.

/// A LAD/FBD network.
nonisolated struct S7Network: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var comment: String
    /// Current paths starting at the power rail, top to bottom.
    var rungs: [S7Path]

    init(title: String = "", comment: String = "", rungs: [S7Path] = [S7Path()], id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.comment = comment
        self.rungs = rungs
    }

    enum CodingKeys: String, CodingKey {
        case id, title, comment, rungs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        title = try container.s7Value(.title, default: "")
        comment = try container.s7Value(.comment, default: "")
        rungs = try container.s7Value(.rungs, default: [S7Path()])
    }

    /// Whether the network has no elements at all (a freshly inserted network).
    var isEmpty: Bool { rungs.allSatisfy(\.items.isEmpty) }
}

/// A series of elements, evaluated left to right.
nonisolated struct S7Path: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var items: [S7Node]

    init(_ items: [S7Node] = [], id: UUID = UUID()) {
        self.id = id
        self.items = items
    }
}

/// A group of branches.
nonisolated struct S7Branches: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var branches: [S7Path]

    init(_ branches: [S7Path], id: UUID = UUID()) {
        self.id = id
        self.branches = branches
    }
}

/// An element of a path.
nonisolated enum S7Node: Codable, Hashable, Sendable {
    case contact(S7Contact)
    case coil(S7Coil)
    case box(S7Box)
    /// A closed branch: the branches are ORed and the path continues after them.
    case parallel(S7Branches)
    /// Open branches: the power flow splits and each branch ends on its own.
    /// Always the last element of its path.
    case fanOut(S7Branches)

    var id: UUID {
        switch self {
        case let .contact(contact): return contact.id
        case let .coil(coil): return coil.id
        case let .box(box): return box.id
        case let .parallel(group), let .fanOut(group): return group.id
        }
    }
}

// MARK: - Contacts

nonisolated enum S7ContactKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// -| |- Normally open contact.
    case normallyOpen = "-| |-"
    /// -|/|- Normally closed contact.
    case normallyClosed = "-|/|-"
    /// -|NOT|- Invert RLO.
    case invert = "-|NOT|-"
    /// -|P|- Scan operand for positive signal edge.
    case positiveEdge = "-|P|-"
    /// -|N|- Scan operand for negative signal edge.
    case negativeEdge = "-|N|-"
    /// CMP ==, CMP <>, … comparators.
    case compare = "CMP"

    /// The name in the Instructions task card.
    var title: String {
        switch self {
        case .normallyOpen: return "Normally open contact"
        case .normallyClosed: return "Normally closed contact"
        case .invert: return "Invert RLO"
        case .positiveEdge: return "Scan operand for positive signal edge"
        case .negativeEdge: return "Scan operand for negative signal edge"
        case .compare: return "Compare"
        }
    }
}

nonisolated enum S7Comparison: String, Codable, CaseIterable, Hashable, Sendable {
    case equal = "=="
    case notEqual = "<>"
    case greaterOrEqual = ">="
    case lessOrEqual = "<="
    case greater = ">"
    case less = "<"

    var runtimeOperator: ComparisonOperator {
        switch self {
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .greaterOrEqual: return .greaterOrEqual
        case .lessOrEqual: return .lessOrEqual
        case .greater: return .greater
        case .less: return .less
        }
    }

    /// The box label: "CMP ==".
    var label: String { "CMP " + rawValue }
}

/// A contact, NOT, edge contact or comparator.
nonisolated struct S7Contact: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: S7ContactKind
    /// The operand above the contact (a comparator's first operand); empty = placeholder.
    var operand: String
    /// Below the contact: an edge contact's edge memory bit, a comparator's second operand.
    var secondOperand: String
    var comparison: S7Comparison
    /// A comparator's data type; nil = not yet determined ("???").
    var dataType: PLCDataType?

    init(_ kind: S7ContactKind = .normallyOpen, _ operand: String = "", secondOperand: String = "",
         comparison: S7Comparison = .equal, dataType: PLCDataType? = nil, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.operand = operand
        self.secondOperand = secondOperand
        self.comparison = comparison
        self.dataType = dataType
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, operand, secondOperand, comparison, dataType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        kind = try container.s7Value(.kind, default: .normallyOpen)
        operand = try container.s7Value(.operand, default: "")
        secondOperand = try container.s7Value(.secondOperand, default: "")
        comparison = try container.s7Value(.comparison, default: .equal)
        dataType = try container.decodeIfPresent(PLCDataType.self, forKey: .dataType)
    }
}

// MARK: - Coils

nonisolated enum S7CoilKind: String, Codable, CaseIterable, Hashable, Sendable {
    case assign = "-( )-"
    case negate = "-(/)-"
    case set = "-(S)-"
    case reset = "-(R)-"
    case setBitField = "SET_BF"
    case resetBitField = "RESET_BF"
    case positiveEdge = "-(P)-"
    case negativeEdge = "-(N)-"
    case pulseTimer = "-(TP)-"
    case onDelayTimer = "-(TON)-"
    case offDelayTimer = "-(TOF)-"
    case accumulatingTimer = "-(TONR)-"
    case resetTimer = "-(RT)-"
    case presetTimer = "-(PT)-"

    var title: String {
        switch self {
        case .assign: return "Assignment"
        case .negate: return "Negate assignment"
        case .set: return "Set output"
        case .reset: return "Reset output"
        case .setBitField: return "Set bit field"
        case .resetBitField: return "Reset bit field"
        case .positiveEdge: return "Set operand on positive signal edge"
        case .negativeEdge: return "Set operand on negative signal edge"
        case .pulseTimer: return "Start pulse timer"
        case .onDelayTimer: return "Start on-delay timer"
        case .offDelayTimer: return "Start off-delay timer"
        case .accumulatingTimer: return "Time accumulator"
        case .resetTimer: return "Reset timer"
        case .presetTimer: return "Load time duration"
        }
    }

    /// Timer coils work on an IEC timer instance instead of a bit.
    var isTimerCoil: Bool {
        switch self {
        case .pulseTimer, .onDelayTimer, .offDelayTimer, .accumulatingTimer, .resetTimer, .presetTimer: return true
        default: return false
        }
    }

    /// Whether the coil has an operand below it (duration, count, edge bit).
    var hasSecondOperand: Bool {
        switch self {
        case .setBitField, .resetBitField, .positiveEdge, .negativeEdge, .pulseTimer, .onDelayTimer,
             .offDelayTimer, .accumulatingTimer, .presetTimer:
            return true
        default:
            return false
        }
    }

    /// Instructions TIA only allows as the last element of a rung.
    var mustBeLast: Bool {
        switch self {
        case .setBitField, .resetBitField, .pulseTimer, .onDelayTimer, .offDelayTimer, .accumulatingTimer:
            return true
        default:
            return false
        }
    }

    /// The timer operation a starting timer coil performs.
    var timerOperation: BuiltInFunctionBlock? {
        switch self {
        case .pulseTimer: return .tp
        case .onDelayTimer: return .ton
        case .offDelayTimer: return .tof
        case .accumulatingTimer: return .tonr
        default: return nil
        }
    }
}

/// A coil: assignment, set/reset, edge coil, bit field or timer coil.
nonisolated struct S7Coil: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var kind: S7CoilKind
    /// The bit (or, for timer coils, the IEC timer instance) above the coil.
    var operand: String
    /// Below the coil: duration (timer coils), bit count (SET_BF/RESET_BF) or edge memory bit.
    var secondOperand: String

    init(_ kind: S7CoilKind = .assign, _ operand: String = "", secondOperand: String = "", id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.operand = operand
        self.secondOperand = secondOperand
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, operand, secondOperand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        kind = try container.s7Value(.kind, default: .assign)
        operand = try container.s7Value(.operand, default: "")
        secondOperand = try container.s7Value(.secondOperand, default: "")
    }
}

// MARK: - Boxes

/// Where a box pin gets its value from, or sends it to.
nonisolated enum S7PinSource: Codable, Hashable, Sendable {
    /// A tag, constant or address as typed; "" is the placeholder.
    case operand(String)
    /// A Bool input fed by its own branch from the power rail, or a Bool output
    /// feeding a branch (e.g. QD of a CTUD driving a coil).
    case branch(S7Path)

    var operandText: String? {
        guard case let .operand(text) = self else { return nil }
        return text
    }
}

nonisolated struct S7Pin: Codable, Hashable, Sendable {
    var name: String
    var source: S7PinSource

    init(_ name: String, _ source: S7PinSource = .operand("")) {
        self.name = name
        self.source = source
    }

    init(_ name: String, _ operand: String) {
        self.init(name, .operand(operand))
    }
}

/// An instruction box: timer, counter, math, move, conversion, call…
nonisolated struct S7Box: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var instruction: S7Instruction
    /// The called FC/FB for `.call`.
    var calledBlock: String
    /// The box data type (ADD Int, CTU Int, CONV *Int* to Real); nil = Auto / "???".
    var dataType: PLCDataType?
    /// The second type of CONV, ROUND, NORM_X, SCALE_X… (CONV Int to *Real*).
    var secondDataType: PLCDataType?
    /// Instance above a timer/counter/edge/FB box: "IEC_Timer_0_DB", #Timer.
    var instance: String
    /// Bit operand above an SR/RS flip-flop or the edge memory bit of P_TRIG/N_TRIG.
    var operand: String
    /// Inputs other than the one the rung feeds, by pin name.
    var inputs: [S7Pin]
    /// Outputs other than the one the rung continues from, by pin name.
    var outputs: [S7Pin]
    /// CALCULATE's expression: "(IN1 + IN2) * IN3".
    var expression: String

    init(_ instruction: S7Instruction, dataType: PLCDataType? = nil, secondDataType: PLCDataType? = nil,
         instance: String = "", operand: String = "", calledBlock: String = "",
         inputs: [S7Pin]? = nil, outputs: [S7Pin]? = nil, expression: String = "", id: UUID = UUID()) {
        self.id = id
        self.instruction = instruction
        self.calledBlock = calledBlock
        self.dataType = dataType ?? instruction.defaultDataType
        self.secondDataType = secondDataType ?? instruction.defaultSecondDataType
        self.instance = instance
        self.operand = operand
        let spec = instruction.spec
        self.inputs = inputs ?? spec.inputs.map { S7Pin($0.name) }
        self.outputs = outputs ?? spec.outputs.map { S7Pin($0.name) }
        self.expression = expression
    }

    enum CodingKeys: String, CodingKey {
        case id, instruction, calledBlock, dataType, secondDataType, instance, operand, inputs, outputs, expression
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        instruction = try container.s7Value(.instruction, default: .empty)
        calledBlock = try container.s7Value(.calledBlock, default: "")
        dataType = try container.decodeIfPresent(PLCDataType.self, forKey: .dataType)
        secondDataType = try container.decodeIfPresent(PLCDataType.self, forKey: .secondDataType)
        instance = try container.s7Value(.instance, default: "")
        operand = try container.s7Value(.operand, default: "")
        inputs = try container.s7Value(.inputs, default: [])
        outputs = try container.s7Value(.outputs, default: [])
        expression = try container.s7Value(.expression, default: "")
    }

    func input(_ name: String) -> S7Pin? {
        inputs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func output(_ name: String) -> S7Pin? {
        outputs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The title shown in the box: "TON", "CTU", "ADD", "CONV", "Motor".
    var title: String {
        instruction == .call ? calledBlock : instruction.boxTitle
    }

    /// The type line under the title: "Int", "Int to Real", "Time", "Auto (???)".
    var typeLabel: String? {
        switch instruction.typing {
        case .none:
            return instruction.isTimer ? "Time" : nil
        case .single:
            return dataType?.rawValue ?? "Auto (???)"
        case .pair:
            return "\(dataType?.rawValue ?? "???") to \(secondDataType?.rawValue ?? "???")"
        }
    }
}

/// Placeholders the editor shows for operands not yet entered.
nonisolated enum S7Placeholder {
    /// "<??.?>" for Bool operands.
    static let bool = "<??.?>"
    /// "<???>" for every other operand.
    static let value = "<???>"
    /// "..." for optional parameters left open.
    static let optional = "..."

    static func text(for type: PLCDataType?) -> String {
        type == .bool ? bool : value
    }

    /// Whether operand text is still a placeholder.
    static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == bool || trimmed == value || trimmed == optional
    }
}
