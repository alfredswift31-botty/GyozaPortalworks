import Foundation

nonisolated enum SiemensBlockKind: String, Codable, CaseIterable, Hashable, Sendable {
    case organizationBlock = "OB"
    case function = "FC"
    case functionBlock = "FB"

    var handleKind: BlockHandle.Kind {
        switch self {
        case .organizationBlock: return .organizationBlock
        case .function: return .function
        case .functionBlock: return .functionBlock
        }
    }

    /// The name in "Add new block".
    var title: String {
        switch self {
        case .organizationBlock: return "Organization block"
        case .function: return "Function"
        case .functionBlock: return "Function block"
        }
    }
}

nonisolated enum SiemensLanguage: String, Codable, CaseIterable, Hashable, Sendable {
    case lad = "LAD"
    case fbd = "FBD"
    case scl = "SCL"

    var usesNetworks: Bool { self != .scl }
}

/// The event class of an organization block.
nonisolated enum SiemensOBEvent: String, Codable, CaseIterable, Hashable, Sendable {
    case programCycle = "Program cycle"
    case startup = "Startup"

    /// The number TIA gives the first OB of the class.
    var standardNumber: Int { self == .programCycle ? 1 : 100 }

    /// The name TIA gives the first OB of the class.
    var standardName: String { self == .programCycle ? "Main" : "Startup" }

    /// The title TIA gives the first OB of the class.
    var standardTitle: String {
        self == .programCycle ? "Main Program Sweep (Cycle)" : "Complete Restart"
    }

    /// Whether `number` is allowed for this class: 1 or ≥ 123 for program
    /// cycle OBs, 100 or ≥ 123 for startup OBs.
    func allows(_ number: Int) -> Bool {
        number == standardNumber || (number >= 123 && number <= 32_767)
    }

    /// The Input section TIA declares for the OB class.
    var standardInputs: [SiemensVariable] {
        switch self {
        case .programCycle:
            return [
                SiemensVariable("Initial_Call", "Bool", comment: "Initial call of this OB"),
                SiemensVariable("Remanence", "Bool", comment: "=True, if remanent data are available"),
            ]
        case .startup:
            return [
                SiemensVariable("LostRetentive", "Bool", comment: "=True, if retentive data are lost"),
                SiemensVariable("LostRTC", "Bool", comment: "=True, if real time clock is lost"),
            ]
        }
    }
}

/// An OB, FC or FB under "Program blocks".
nonisolated struct SiemensBlock: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: SiemensBlockKind
    var number: Int
    /// "Automatic" numbering in the block properties.
    var isNumberAutomatic: Bool
    var language: SiemensLanguage
    /// Organization blocks only.
    var event: SiemensOBEvent
    var title: String
    var comment: String
    var interface: SiemensInterface
    /// LAD/FBD networks.
    var networks: [S7Network]
    /// SCL source.
    var source: String

    init(name: String, kind: SiemensBlockKind, number: Int, language: SiemensLanguage = .lad,
         event: SiemensOBEvent = .programCycle, isNumberAutomatic: Bool = true, title: String = "",
         comment: String = "", interface: SiemensInterface? = nil, networks: [S7Network]? = nil,
         source: String = "", id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.number = number
        self.isNumberAutomatic = isNumberAutomatic
        self.language = language
        self.event = event
        self.title = title
        self.comment = comment
        if let interface {
            self.interface = interface
        } else {
            var standard = SiemensInterface()
            if kind == .organizationBlock { standard.input = event.standardInputs }
            self.interface = standard
        }
        self.networks = networks ?? (language.usesNetworks ? [S7Network()] : [])
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, number, isNumberAutomatic, language, event, title, comment, interface, networks, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "Block_1")
        kind = try container.s7Value(.kind, default: .function)
        number = try container.s7Value(.number, default: 1)
        isNumberAutomatic = try container.s7Value(.isNumberAutomatic, default: true)
        language = try container.s7Value(.language, default: .lad)
        event = try container.s7Value(.event, default: .programCycle)
        title = try container.s7Value(.title, default: "")
        comment = try container.s7Value(.comment, default: "")
        interface = try container.s7Value(.interface, default: SiemensInterface())
        networks = try container.s7Value(.networks, default: [])
        source = try container.s7Value(.source, default: "")
    }

    /// "Main [OB1]", "Motor [FB1]".
    var displayName: String { "\(name) [\(kind.rawValue)\(number)]" }

    /// TIA's project-tree label: "Main (OB1)".
    var treeLabel: String { "\(name) (\(kind.rawValue)\(number))" }

    /// Switches the programming language. LAD and FBD convert into each other
    /// and keep their networks; SCL can't be switched to or from.
    @discardableResult
    mutating func switchLanguage(to newLanguage: SiemensLanguage) -> Bool {
        guard newLanguage != language else { return true }
        guard language.usesNetworks, newLanguage.usesNetworks else { return false }
        language = newLanguage
        return true
    }

    // MARK: Networks

    /// Inserts an empty network (Ctrl+R) after `index`, or at the end.
    @discardableResult
    mutating func insertNetwork(after index: Int? = nil) -> S7Network {
        let network = S7Network()
        if let index, index >= 0, index < networks.count {
            networks.insert(network, at: index + 1)
        } else {
            networks.append(network)
        }
        return network
    }

    mutating func deleteNetwork(at index: Int) {
        guard networks.indices.contains(index) else { return }
        networks.remove(at: index)
    }

    mutating func moveNetwork(from source: Int, to destination: Int) {
        guard networks.indices.contains(source), destination >= 0, destination < networks.count else { return }
        let network = networks.remove(at: source)
        networks.insert(network, at: destination)
    }

    /// Declares a multi-instance in the Static section ("Call options" ›
    /// "Multi instance") and returns its operand, e.g. #IEC_Timer_0_Instance.
    mutating func addMultiInstance(for instruction: S7Instruction, dataType: PLCDataType? = nil) -> String? {
        guard kind == .functionBlock,
              let base = instruction.instanceNameBase(multiInstance: true),
              let typeName = instruction.multiInstanceTypeName(dataType: dataType)
        else { return nil }
        let name = SiemensNaming.unique(base, among: interface.allNames, style: .underscore)
        interface.staticVariables.append(SiemensVariable(name, typeName, retain: instruction.isCounter ? .retain : .nonRetain))
        return "#" + name
    }
}

nonisolated enum SiemensDataBlockKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// A global DB with its own declarations.
    case global = "Global DB"
    /// The instance DB of a user FB.
    case instance = "Instance DB"
    /// The instance DB of a system block (IEC_TIMER, IEC_COUNTER, R_TRIG…),
    /// kept under "Program resources".
    case systemInstance = "System instance DB"
}

/// A data block. All are "optimized block access", the S7-1200 default.
nonisolated struct SiemensDataBlock: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var number: Int
    var isNumberAutomatic: Bool
    var kind: SiemensDataBlockKind
    /// The FB (instance DB) or system type (IEC_TIMER…) it is an instance of.
    var instanceOf: String
    /// A global DB's declarations.
    var members: [SiemensVariable]
    /// Instance DBs: retentivity of members declared "Set in IDB" (all members of a system IDB).
    var isRetain: Bool
    var title: String
    var comment: String
    /// Created by "Call options" for a box; removed by the compiler once no box uses it.
    var isCreatedAutomatically: Bool

    init(name: String, number: Int, kind: SiemensDataBlockKind = .global, instanceOf: String = "",
         members: [SiemensVariable] = [], isRetain: Bool = false, isNumberAutomatic: Bool = true,
         isCreatedAutomatically: Bool = false, title: String = "", comment: String = "", id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.number = number
        self.isNumberAutomatic = isNumberAutomatic
        self.kind = kind
        self.instanceOf = instanceOf
        self.members = members
        self.isRetain = isRetain
        self.title = title
        self.comment = comment
        self.isCreatedAutomatically = isCreatedAutomatically
    }

    enum CodingKeys: String, CodingKey {
        case id, name, number, isNumberAutomatic, kind, instanceOf, members, isRetain, title, comment, isCreatedAutomatically
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "Data_block_1")
        number = try container.s7Value(.number, default: 1)
        isNumberAutomatic = try container.s7Value(.isNumberAutomatic, default: true)
        kind = try container.s7Value(.kind, default: .global)
        instanceOf = try container.s7Value(.instanceOf, default: "")
        members = try container.s7Value(.members, default: [])
        isRetain = try container.s7Value(.isRetain, default: false)
        title = try container.s7Value(.title, default: "")
        comment = try container.s7Value(.comment, default: "")
        isCreatedAutomatically = try container.s7Value(.isCreatedAutomatically, default: false)
    }

    /// "Data_block_1 [DB1]".
    var displayName: String { "\(name) [DB\(number)]" }

    /// System instance DBs live under "Program resources" in the project tree.
    var isProgramResource: Bool { kind == .systemInstance }
}

/// Name proposals the way TIA makes them.
nonisolated enum SiemensNaming {
    nonisolated enum Style {
        /// "Tag_1" → "Tag_1(1)": duplicate names typed by the user.
        case parenthesis
        /// "IEC_Timer_0_DB" → "IEC_Timer_0_DB_1": names TIA proposes itself.
        case underscore
        /// "Block_1" → "Block_2": the trailing number counts up.
        case counting
    }

    /// `name` if it is free (compared case-insensitively), else the next free variant.
    static func unique(_ name: String, among existing: [String], style: Style) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        switch style {
        case .parenthesis:
            var counter = 1
            while taken.contains("\(name)(\(counter))".lowercased()) { counter += 1 }
            return "\(name)(\(counter))"
        case .underscore:
            var counter = 1
            while taken.contains("\(name)_\(counter)".lowercased()) { counter += 1 }
            return "\(name)_\(counter)"
        case .counting:
            var stem = name
            var counter = 1
            if let underscore = name.lastIndex(of: "_"), let number = Int(name[name.index(after: underscore)...]) {
                stem = String(name[..<underscore])
                counter = number
            }
            while taken.contains("\(stem)_\(counter)".lowercased()) { counter += 1 }
            return "\(stem)_\(counter)"
        }
    }
}
