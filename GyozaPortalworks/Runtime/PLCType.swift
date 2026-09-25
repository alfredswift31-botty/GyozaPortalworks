import Foundation

/// Where a variable is declared. Raw values are TIA Portal's interface section
/// names; GX Works label classes map onto them (VAR_INPUT → Input, VAR → Static).
nonisolated enum VariableSection: String, Codable, CaseIterable, Hashable, Sendable {
    case input = "Input"
    case output = "Output"
    case inOut = "InOut"
    case staticVar = "Static"
    case temp = "Temp"
    case constant = "Constant"
    case returnValue = "Return"

    /// Where the section's variables live while a block runs; nil for constants,
    /// which have no storage.
    var frameArea: FrameArea? {
        switch self {
        case .temp: return .temp
        case .constant: return nil
        default: return .instance
        }
    }

    /// Whether a call can assign it: `IN := …`, `Q => …`.
    var isParameter: Bool {
        self == .input || self == .output || self == .inOut
    }
}

/// One declared variable: an interface row, a structure member, or a member
/// of a function block instance.
nonisolated struct PLCMember: Hashable, Sendable {
    var name: String
    var type: PLCType
    var section: VariableSection
    /// Start value for elementary members (and every element of an array).
    var initialValue: PLCValue?
    var isRetain: Bool

    init(_ name: String, _ type: PLCType, section: VariableSection = .staticVar, initialValue: PLCValue? = nil, isRetain: Bool = false) {
        self.name = name
        self.type = type
        self.section = section
        self.initialValue = initialValue
        self.isRetain = isRetain
    }
}

/// The declared type of a variable.
nonisolated indirect enum PLCType: Hashable, Sendable {
    case elementary(PLCDataType)
    /// ARRAY[lower..upper] OF element (one dimension).
    case array(lower: Int, upper: Int, element: PLCType)
    /// A Struct, or a PLC data type (UDT) when `name` is set.
    case structure(name: String?, members: [PLCMember])
    /// An instance of a built-in or user function block.
    case instance(FunctionBlockType)

    var elementary: PLCDataType? {
        guard case let .elementary(type) = self else { return nil }
        return type
    }

    var functionBlock: FunctionBlockType? {
        guard case let .instance(type) = self else { return nil }
        return type
    }

    /// How TIA Portal writes the type: Int, Array[0..9] of Real, "Motor", TON_TIME.
    var displayName: String {
        switch self {
        case let .elementary(type):
            return type.rawValue
        case let .array(lower, upper, element):
            return "Array[\(lower)..\(upper)] of \(element.displayName)"
        case let .structure(name, _):
            guard let name else { return "Struct" }
            return "\"\(name)\""
        case let .instance(block):
            return block.builtIn == nil ? "\"\(block.name)\"" : block.name
        }
    }

    /// Number of elementary values it holds; used to cap array sizes.
    var leafCount: Int {
        switch self {
        case .elementary:
            return 1
        case let .array(lower, upper, element):
            return max(0, upper - lower + 1) * element.leafCount
        case let .structure(_, members):
            return members.reduce(0) { $0 + $1.type.leafCount }
        case let .instance(block):
            return block.members.reduce(0) { $0 + $1.type.leafCount }
        }
    }
}

/// Layout of a function block instance: what an instance DB or a
/// multi-instance holds.
nonisolated struct FunctionBlockType: Hashable, Sendable {
    var name: String
    /// Input, Output, InOut and Static members in interface order.
    var members: [PLCMember]
    /// Set for the standard timers, counters, edge and flip-flop blocks.
    var builtIn: BuiltInFunctionBlock?

    func memberIndex(_ name: String) -> Int? {
        members.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// A formal parameter as a call assigns it: `IN := …` or `Q => …`.
nonisolated struct CallParameter: Hashable, Sendable {
    var name: String
    /// .input, .inOut or .output.
    var section: VariableSection
    var type: PLCType
    /// Index of the backing member in the instance (FB) or parameter (FC) node.
    var memberIndex: Int
}
