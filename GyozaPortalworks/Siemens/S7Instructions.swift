import Foundation

/// The type a box pin carries.
nonisolated enum S7PinType: Hashable, Sendable {
    case bool
    case time
    /// The box's data type (ADD *Int*).
    case first
    /// The box's second data type (CONV Int to *Real*).
    case second
    /// Any integer or bit string (SHL's N).
    case anyInteger
    /// Any type; MOVE checks IN against each OUT.
    case any
}

nonisolated struct S7PinSpec: Hashable, Sendable {
    var name: String
    var type: S7PinType
    /// Whether leaving it open is a compile error.
    var isRequired: Bool
    /// INC/DEC's IN/OUT: read and written.
    var isInOut = false
}

/// How a box's data types are chosen.
nonisolated enum S7Typing: Hashable, Sendable {
    case none
    /// One type from the list: ADD Int.
    case single([PLCDataType])
    /// Two types: CONV Int to Real.
    case pair([PLCDataType], [PLCDataType])
}

/// Pins and typing of an instruction box.
nonisolated struct S7InstructionSpec: Hashable, Sendable {
    /// The input the rung feeds: EN, IN, CU, CLK…; "" for IN_RANGE's unnamed input.
    var powerInput: String
    /// The output the rung continues from: ENO, Q, QU…
    var powerOutput: String
    var inputs: [S7PinSpec]
    var outputs: [S7PinSpec]
    /// Whether the yellow star adds inputs (IN3, IN4…).
    var expandableInputs = false
    /// Whether the yellow star adds outputs (MOVE OUT2, OUT3…).
    var expandableOutputs = false
    var typing: S7Typing = .none
}

/// The LAD/FBD box instructions this simulator offers.
nonisolated enum S7Instruction: String, Codable, CaseIterable, Hashable, Sendable {
    /// The empty box "??" before an instruction is picked.
    case empty = "??"
    case pulseTimer = "TP"
    case onDelayTimer = "TON"
    case offDelayTimer = "TOF"
    case accumulatingTimer = "TONR"
    case countUp = "CTU"
    case countDown = "CTD"
    case countUpDown = "CTUD"
    case risingEdgeTrigger = "R_TRIG"
    case fallingEdgeTrigger = "F_TRIG"
    case positiveEdgeBox = "P_TRIG"
    case negativeEdgeBox = "N_TRIG"
    /// Set/reset flip-flop: R1 dominates.
    case setReset = "SR"
    /// Reset/set flip-flop: S1 dominates.
    case resetSet = "RS"
    case move = "MOVE"
    case add = "ADD"
    case subtract = "SUB"
    case multiply = "MUL"
    case divide = "DIV"
    case modulo = "MOD"
    case negate = "NEG"
    case absolute = "ABS"
    case increment = "INC"
    case decrement = "DEC"
    case minimum = "MIN"
    case maximum = "MAX"
    case limit = "LIMIT"
    case square = "SQR"
    case squareRoot = "SQRT"
    case naturalLogarithm = "LN"
    case exponential = "EXP"
    case sine = "SIN"
    case cosine = "COS"
    case tangent = "TAN"
    case arcSine = "ASIN"
    case arcCosine = "ACOS"
    case arcTangent = "ATAN"
    case fraction = "FRAC"
    case power = "EXPT"
    case convert = "CONV"
    case round = "ROUND"
    case truncate = "TRUNC"
    case ceiling = "CEIL"
    case floor = "FLOOR"
    case scale = "SCALE_X"
    case normalize = "NORM_X"
    case inRange = "IN_RANGE"
    case outOfRange = "OUT_RANGE"
    case wordAnd = "AND"
    case wordOr = "OR"
    case wordXor = "XOR"
    case invert = "INV"
    case shiftLeft = "SHL"
    case shiftRight = "SHR"
    case rotateLeft = "ROL"
    case rotateRight = "ROR"
    case calculate = "CALCULATE"
    /// A call of a user FC or FB.
    case call = "CALL"

    static let integerTypes: [PLCDataType] = [.sint, .int, .dint, .usint, .uint, .udint]
    static let realTypes: [PLCDataType] = [.real, .lreal]
    static let numberTypes: [PLCDataType] = integerTypes + realTypes
    static let bitStringTypes: [PLCDataType] = [.byte, .word, .dword]
    static let signedNumberTypes: [PLCDataType] = [.sint, .int, .dint, .real, .lreal]
    static let convertibleTypes: [PLCDataType] = bitStringTypes + numberTypes

    /// Finds an instruction by what a user types in an empty box: "ton", "CONVERT", "INVERT".
    static func named(_ text: String) -> S7Instruction? {
        let key = text.trimmingCharacters(in: .whitespaces).uppercased()
        switch key {
        case "CONVERT": return .convert
        case "INVERT": return .invert
        case "", "??", "CALL": return nil
        default: return allCases.first { $0.rawValue == key }
        }
    }

    /// The box title: "TON", "CONV", "SCALE_X".
    var boxTitle: String { rawValue }

    /// The folder of the Instructions task card it lives in.
    var category: String {
        switch self {
        case .empty, .call: return "General"
        case .pulseTimer, .onDelayTimer, .offDelayTimer, .accumulatingTimer: return "Timer operations"
        case .countUp, .countDown, .countUpDown: return "Counter operations"
        case .risingEdgeTrigger, .fallingEdgeTrigger, .positiveEdgeBox, .negativeEdgeBox, .setReset, .resetSet:
            return "Bit logic operations"
        case .inRange, .outOfRange: return "Comparator operations"
        case .move: return "Move operations"
        case .convert, .round, .truncate, .ceiling, .floor, .scale, .normalize: return "Conversion operations"
        case .wordAnd, .wordOr, .wordXor, .invert: return "Word logic operations"
        case .shiftLeft, .shiftRight, .rotateLeft, .rotateRight: return "Shift and rotate"
        default: return "Math functions"
        }
    }

    var isTimer: Bool {
        switch self {
        case .pulseTimer, .onDelayTimer, .offDelayTimer, .accumulatingTimer: return true
        default: return false
        }
    }

    var isCounter: Bool {
        self == .countUp || self == .countDown || self == .countUpDown
    }

    /// Timers, counters and R_TRIG/F_TRIG keep their data in an instance.
    var needsInstance: Bool {
        isTimer || isCounter || self == .risingEdgeTrigger || self == .fallingEdgeTrigger
    }

    /// SR/RS store their state in a bit operand; P_TRIG/N_TRIG in an edge memory bit.
    var needsBitOperand: Bool {
        self == .setReset || self == .resetSet || self == .positiveEdgeBox || self == .negativeEdgeBox
    }

    /// TIA: "requires a preceding logic operation" — may not sit directly on the rail.
    var requiresPrecedingLogic: Bool {
        isTimer || isCounter || self == .positiveEdgeBox || self == .negativeEdgeBox
    }

    /// Whether the rung may end with it (edge boxes and range checks may not).
    var canTerminate: Bool {
        !(self == .positiveEdgeBox || self == .negativeEdgeBox || self == .inRange || self == .outOfRange)
    }

    /// The built-in operation a timer or counter box runs.
    var builtInOperation: BuiltInFunctionBlock? {
        switch self {
        case .pulseTimer: return .tp
        case .onDelayTimer: return .ton
        case .offDelayTimer: return .tof
        case .accumulatingTimer: return .tonr
        case .countUp: return .ctu
        case .countDown: return .ctd
        case .countUpDown: return .ctud
        case .risingEdgeTrigger: return .risingEdge
        case .fallingEdgeTrigger: return .fallingEdge
        default: return nil
        }
    }

    var defaultDataType: PLCDataType? {
        isCounter ? .int : nil
    }

    var defaultSecondDataType: PLCDataType? { nil }

    var typing: S7Typing { spec.typing }

    var spec: S7InstructionSpec {
        let bool = { (name: String, required: Bool) in S7PinSpec(name: name, type: .bool, isRequired: required) }
        let first = { (name: String) in S7PinSpec(name: name, type: .first, isRequired: true) }
        let second = { (name: String) in S7PinSpec(name: name, type: .second, isRequired: true) }
        switch self {
        case .empty, .call:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [], outputs: [])
        case .pulseTimer, .onDelayTimer, .offDelayTimer:
            return S7InstructionSpec(powerInput: "IN", powerOutput: "Q",
                                     inputs: [S7PinSpec(name: "PT", type: .time, isRequired: true)],
                                     outputs: [S7PinSpec(name: "ET", type: .time, isRequired: false)])
        case .accumulatingTimer:
            return S7InstructionSpec(powerInput: "IN", powerOutput: "Q",
                                     inputs: [bool("R", false), S7PinSpec(name: "PT", type: .time, isRequired: true)],
                                     outputs: [S7PinSpec(name: "ET", type: .time, isRequired: false)])
        case .countUp:
            return S7InstructionSpec(powerInput: "CU", powerOutput: "Q",
                                     inputs: [bool("R", false), first("PV")],
                                     outputs: [S7PinSpec(name: "CV", type: .first, isRequired: false)],
                                     typing: .single(Self.integerTypes))
        case .countDown:
            return S7InstructionSpec(powerInput: "CD", powerOutput: "Q",
                                     inputs: [bool("LD", false), first("PV")],
                                     outputs: [S7PinSpec(name: "CV", type: .first, isRequired: false)],
                                     typing: .single(Self.integerTypes))
        case .countUpDown:
            return S7InstructionSpec(powerInput: "CU", powerOutput: "QU",
                                     inputs: [bool("CD", false), bool("R", false), bool("LD", false), first("PV")],
                                     outputs: [bool("QD", false), S7PinSpec(name: "CV", type: .first, isRequired: false)],
                                     typing: .single(Self.integerTypes))
        case .risingEdgeTrigger, .fallingEdgeTrigger:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [bool("CLK", true)], outputs: [bool("Q", false)])
        case .positiveEdgeBox, .negativeEdgeBox:
            return S7InstructionSpec(powerInput: "CLK", powerOutput: "Q", inputs: [], outputs: [])
        case .setReset:
            return S7InstructionSpec(powerInput: "S", powerOutput: "Q", inputs: [bool("R1", true)], outputs: [])
        case .resetSet:
            return S7InstructionSpec(powerInput: "R", powerOutput: "Q", inputs: [bool("S1", true)], outputs: [])
        case .move:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO",
                                     inputs: [S7PinSpec(name: "IN", type: .any, isRequired: true)],
                                     outputs: [S7PinSpec(name: "OUT1", type: .any, isRequired: true)],
                                     expandableOutputs: true)
        case .add, .multiply:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN1"), first("IN2")],
                                     outputs: [first("OUT")], expandableInputs: true, typing: .single(Self.numberTypes))
        case .subtract, .divide:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN1"), first("IN2")],
                                     outputs: [first("OUT")], typing: .single(Self.numberTypes))
        case .modulo:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN1"), first("IN2")],
                                     outputs: [first("OUT")], typing: .single(Self.integerTypes))
        case .negate, .absolute:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN")], outputs: [first("OUT")],
                                     typing: .single(Self.signedNumberTypes))
        case .increment, .decrement:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO",
                                     inputs: [S7PinSpec(name: "IN/OUT", type: .first, isRequired: true, isInOut: true)],
                                     outputs: [], typing: .single(Self.integerTypes))
        case .minimum, .maximum:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN1"), first("IN2")],
                                     outputs: [first("OUT")], expandableInputs: true, typing: .single(Self.numberTypes))
        case .limit:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("MN"), first("IN"), first("MX")],
                                     outputs: [first("OUT")], typing: .single(Self.numberTypes))
        case .square, .squareRoot, .naturalLogarithm, .exponential, .sine, .cosine, .tangent,
             .arcSine, .arcCosine, .arcTangent, .fraction:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN")], outputs: [first("OUT")],
                                     typing: .single(Self.realTypes))
        case .power:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN1"), second("IN2")],
                                     outputs: [first("OUT")], typing: .pair(Self.realTypes, Self.numberTypes))
        case .convert:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN")], outputs: [second("OUT")],
                                     typing: .pair(Self.convertibleTypes, Self.convertibleTypes))
        case .round, .truncate, .ceiling, .floor:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN")], outputs: [second("OUT")],
                                     typing: .pair(Self.realTypes, Self.numberTypes))
        case .scale:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [second("MIN"), first("VALUE"), second("MAX")],
                                     outputs: [second("OUT")], typing: .pair(Self.realTypes, Self.numberTypes))
        case .normalize:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("MIN"), first("VALUE"), first("MAX")],
                                     outputs: [second("OUT")], typing: .pair(Self.numberTypes, Self.realTypes))
        case .inRange, .outOfRange:
            return S7InstructionSpec(powerInput: "", powerOutput: "", inputs: [first("MIN"), first("VAL"), first("MAX")],
                                     outputs: [], typing: .single(Self.numberTypes))
        case .wordAnd, .wordOr, .wordXor:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN1"), first("IN2")],
                                     outputs: [first("OUT")], expandableInputs: true, typing: .single(Self.bitStringTypes))
        case .invert:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN")], outputs: [first("OUT")],
                                     typing: .single(Self.bitStringTypes + Self.integerTypes))
        case .shiftLeft, .shiftRight, .rotateLeft, .rotateRight:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO",
                                     inputs: [first("IN"), S7PinSpec(name: "N", type: .anyInteger, isRequired: true)],
                                     outputs: [first("OUT")], typing: .single(Self.bitStringTypes + Self.integerTypes))
        case .calculate:
            return S7InstructionSpec(powerInput: "EN", powerOutput: "ENO", inputs: [first("IN1"), first("IN2")],
                                     outputs: [first("OUT")], expandableInputs: true,
                                     typing: .single(Self.numberTypes + Self.bitStringTypes))
        }
    }

    // MARK: Instances created by "Call options"

    /// The type of the single-instance DB TIA creates for the box: IEC_TIMER,
    /// IEC_COUNTER (IEC_DCOUNTER for a DInt counter…), R_TRIG, F_TRIG.
    func instanceTypeName(dataType: PLCDataType?) -> String? {
        if isTimer { return "IEC_TIMER" }
        if isCounter { return Self.genericCounterName(for: dataType ?? .int) }
        switch self {
        case .risingEdgeTrigger: return "R_TRIG"
        case .fallingEdgeTrigger: return "F_TRIG"
        default: return nil
        }
    }

    /// The type of a multi-instance TIA declares in an FB's Static section:
    /// TON_TIME, CTU_INT, R_TRIG.
    func multiInstanceTypeName(dataType: PLCDataType?) -> String? {
        if isTimer { return rawValue + "_TIME" }
        if isCounter { return rawValue + "_" + (dataType ?? .int).rawValue.uppercased() }
        switch self {
        case .risingEdgeTrigger: return "R_TRIG"
        case .fallingEdgeTrigger: return "F_TRIG"
        default: return nil
        }
    }

    /// The name TIA proposes for an instance: "IEC_Timer_0_DB", "IEC_Counter_0_DB",
    /// "R_TRIG_DB" (multi-instances end in "_Instance" instead of "_DB").
    func instanceNameBase(multiInstance: Bool) -> String? {
        let suffix = multiInstance ? "_Instance" : "_DB"
        if isTimer { return "IEC_Timer_0" + suffix }
        if isCounter { return "IEC_Counter_0" + suffix }
        switch self {
        case .risingEdgeTrigger: return "R_TRIG" + suffix
        case .fallingEdgeTrigger: return "F_TRIG" + suffix
        default: return nil
        }
    }

    static func genericCounterName(for type: PLCDataType) -> String {
        switch type {
        case .sint: return "IEC_SCOUNTER"
        case .dint: return "IEC_DCOUNTER"
        case .usint: return "IEC_USCOUNTER"
        case .uint: return "IEC_UCOUNTER"
        case .udint: return "IEC_UDCOUNTER"
        default: return "IEC_COUNTER"
        }
    }

    /// Whether an instance of `type` can serve this box.
    func accepts(instanceType type: FunctionBlockType, dataType: PLCDataType?) -> Bool {
        guard let builtIn = type.builtIn, let operation = builtInOperation else { return false }
        if isTimer {
            return builtIn == .iecTimer || builtIn == operation
        }
        if isCounter {
            guard builtIn == .iecCounter || builtIn == operation else { return false }
            let valueType = type.members.first { $0.name == "CV" }?.type.elementary
            return valueType == (dataType ?? .int)
        }
        return builtIn == operation
    }
}
