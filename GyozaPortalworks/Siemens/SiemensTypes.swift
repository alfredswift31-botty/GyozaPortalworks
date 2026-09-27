import Foundation

nonisolated extension KeyedDecodingContainer {
    /// Decodes a value older project files may not contain, falling back to a default.
    func s7Value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

/// The Retain column of a block interface or data block.
nonisolated enum SiemensRetain: String, Codable, CaseIterable, Hashable, Sendable {
    case nonRetain = "Non-retain"
    case retain = "Retain"
    /// FB interfaces only: the instance DB decides.
    case setInIDB = "Set in IDB"
}

/// One row of a block interface, data block, PLC data type or Struct.
nonisolated struct SiemensVariable: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// The Data type column as typed: Int, Array[0..9] of Real, "Motor_UDT", TON_TIME, Struct.
    var dataType: String
    /// The Start value (Default value in FB/FC interfaces) column; empty = the type's default.
    var startValue: String
    var retain: SiemensRetain
    var comment: String
    /// Rows of a Struct.
    var members: [SiemensVariable]

    init(_ name: String, _ dataType: String, startValue: String = "", retain: SiemensRetain = .nonRetain,
         comment: String = "", members: [SiemensVariable] = [], id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.startValue = startValue
        self.retain = retain
        self.comment = comment
        self.members = members
    }

    enum CodingKeys: String, CodingKey {
        case id, name, dataType, startValue, retain, comment, members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "")
        dataType = try container.s7Value(.dataType, default: "Bool")
        startValue = try container.s7Value(.startValue, default: "")
        retain = try container.s7Value(.retain, default: .nonRetain)
        comment = try container.s7Value(.comment, default: "")
        members = try container.s7Value(.members, default: [])
    }
}

/// A block's interface, section by section, as the interface editor shows it.
nonisolated struct SiemensInterface: Codable, Hashable, Sendable {
    var input: [SiemensVariable] = []
    var output: [SiemensVariable] = []
    var inOut: [SiemensVariable] = []
    var staticVariables: [SiemensVariable] = []
    var temp: [SiemensVariable] = []
    var constant: [SiemensVariable] = []
    /// An FC's Return type: "Void" or an elementary type.
    var returnType = "Void"

    init() {}

    enum CodingKeys: String, CodingKey {
        case input, output, inOut, staticVariables, temp, constant, returnType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.s7Value(.input, default: [])
        output = try container.s7Value(.output, default: [])
        inOut = try container.s7Value(.inOut, default: [])
        staticVariables = try container.s7Value(.staticVariables, default: [])
        temp = try container.s7Value(.temp, default: [])
        constant = try container.s7Value(.constant, default: [])
        returnType = try container.s7Value(.returnType, default: "Void")
    }

    /// The sections a block kind's interface shows, in TIA's order.
    static func sections(for kind: SiemensBlockKind) -> [VariableSection] {
        switch kind {
        case .organizationBlock: return [.input, .temp, .constant]
        case .functionBlock: return [.input, .output, .inOut, .staticVar, .temp, .constant]
        case .function: return [.input, .output, .inOut, .temp, .constant, .returnValue]
        }
    }

    func variables(in section: VariableSection) -> [SiemensVariable] {
        switch section {
        case .input: return input
        case .output: return output
        case .inOut: return inOut
        case .staticVar: return staticVariables
        case .temp: return temp
        case .constant: return constant
        case .returnValue: return []
        }
    }

    mutating func setVariables(_ variables: [SiemensVariable], in section: VariableSection) {
        switch section {
        case .input: input = variables
        case .output: output = variables
        case .inOut: inOut = variables
        case .staticVar: staticVariables = variables
        case .temp: temp = variables
        case .constant: constant = variables
        case .returnValue: break
        }
    }

    /// Every declared name, for duplicate checks and name proposals.
    var allNames: [String] {
        [input, output, inOut, staticVariables, temp, constant].flatMap { $0.map(\.name) }
    }
}

/// A PLC data type (UDT) under "PLC data types".
nonisolated struct SiemensDataType: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var comment: String
    var members: [SiemensVariable]

    init(name: String, members: [SiemensVariable] = [], comment: String = "", id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.members = members
        self.comment = comment
    }

    enum CodingKeys: String, CodingKey {
        case id, name, comment, members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "User data type_1")
        comment = try container.s7Value(.comment, default: "")
        members = try container.s7Value(.members, default: [])
    }
}

/// A parsed Data type column.
nonisolated indirect enum SiemensTypeSpec: Hashable, Sendable {
    case elementary(PLCDataType)
    /// Array[lower..upper] of element.
    case array(lower: Int, upper: Int, element: SiemensTypeSpec)
    /// Struct: the rows come from the variable's `members`.
    case structure
    /// A PLC data type or a function block, by name ("Motor_UDT", "Conveyor").
    case named(String)
    /// A system function block type: TON_TIME, IEC_TIMER, CTU_INT, R_TRIG.
    case system(String)
    /// An FC's Return type when it returns nothing.
    case void

    /// How TIA shows it after entry: Int, Array[0..9] of Real, "Motor_UDT", TON_TIME.
    var text: String {
        switch self {
        case let .elementary(type): return type.rawValue
        case let .array(lower, upper, element): return "Array[\(lower)..\(upper)] of \(element.text)"
        case .structure: return "Struct"
        case let .named(name): return "\"\(name)\""
        case let .system(name): return name
        case .void: return "Void"
        }
    }
}

/// Parses the Data type column.
nonisolated enum SiemensTypeParser {
    /// TIA types this simulator's shared runtime can't hold.
    static let unsupportedTypes = [
        "String", "WString", "Char", "WChar", "Date", "Time_Of_Day", "TOD", "DTL", "DT", "Date_And_Time",
        "LInt", "ULInt", "LWord", "LTime", "LTOD", "LDT", "S5Time", "Variant", "Pointer", "Any",
    ]

    static func parse(_ rawText: String) throws -> SiemensTypeSpec {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw ResolveError(message: S7Messages.selectDataType) }
        let lower = text.lowercased()
        if lower == "void" { return .void }
        if lower == "struct" { return .structure }
        if lower.hasPrefix("array") {
            return try parseArray(text)
        }
        if text.hasPrefix("\"") {
            guard text.count >= 3, text.hasSuffix("\"") else {
                throw ResolveError(message: S7Messages.dataTypeNotDefined(text))
            }
            return .named(String(text.dropFirst().dropLast()))
        }
        if let elementary = PLCDataType.named(text) { return .elementary(elementary) }
        if let system = FunctionBlockLibrary.type(named: text, dialect: .siemens) {
            return .system(system.name)
        }
        if unsupportedTypes.contains(where: { $0.lowercased() == lower }) {
            throw ResolveError(message: S7Messages.dataTypeNotSupported(text))
        }
        guard text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw ResolveError(message: S7Messages.dataTypeNotDefined(text))
        }
        return .named(text)
    }

    /// "Array[0..9] of Int", "Array [1..3] of \"UDT\"".
    private static func parseArray(_ text: String) throws -> SiemensTypeSpec {
        guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]"), open < close else {
            throw ResolveError(message: S7Messages.dataTypeNotDefined(text))
        }
        let bounds = String(text[text.index(after: open)..<close])
        if bounds.contains(",") {
            throw ResolveError(message: S7Messages.multiDimensionalArray)
        }
        let limits = bounds.components(separatedBy: "..").map { $0.trimmingCharacters(in: .whitespaces) }
        guard limits.count == 2, let lower = Int(limits[0]), let upper = Int(limits[1]) else {
            throw ResolveError(message: "Invalid array limits in \"\(text)\".")
        }
        guard lower <= upper else {
            throw ResolveError(message: "Invalid array limits in \"\(text)\": the low limit must not be greater than the high limit.")
        }
        guard upper - lower < 65_536 else {
            throw ResolveError(message: "The array \"\(text)\" is too large for this simulator.")
        }
        let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.lowercased().hasPrefix("of ") else {
            throw ResolveError(message: S7Messages.dataTypeNotDefined(text))
        }
        let element = try parse(String(rest.dropFirst(3)))
        if case .array = element { throw ResolveError(message: S7Messages.multiDimensionalArray) }
        if case .void = element { throw ResolveError(message: S7Messages.dataTypeNotDefined(text)) }
        return .array(lower: lower, upper: upper, element: element)
    }
}

/// Turns declarations into runtime types: resolves PLC data types, function
/// block instances and start values, and detects types that contain themselves.
nonisolated final class SiemensTypeEnvironment {
    private let dataTypes: [String: SiemensDataType]
    private let functionBlocks: [String: SiemensBlock]
    private var resolving: Set<String> = []
    private var functionBlockCache: [String: FunctionBlockType] = [:]
    private var dataTypeCache: [String: PLCType] = [:]

    init(dataTypes: [SiemensDataType], blocks: [SiemensBlock]) {
        var types: [String: SiemensDataType] = [:]
        for type in dataTypes where types[type.name.lowercased()] == nil {
            types[type.name.lowercased()] = type
        }
        var functionBlocks: [String: SiemensBlock] = [:]
        for block in blocks where block.kind == .functionBlock && functionBlocks[block.name.lowercased()] == nil {
            functionBlocks[block.name.lowercased()] = block
        }
        self.dataTypes = types
        self.functionBlocks = functionBlocks
    }

    /// The runtime type of a declaration.
    func type(of variable: SiemensVariable) throws -> PLCType {
        try type(for: try SiemensTypeParser.parse(variable.dataType), members: variable.members)
    }

    func type(for spec: SiemensTypeSpec, members: [SiemensVariable]) throws -> PLCType {
        switch spec {
        case let .elementary(type):
            return .elementary(type)
        case let .array(lower, upper, element):
            return .array(lower: lower, upper: upper, element: try type(for: element, members: members))
        case .structure:
            return .structure(name: nil, members: try structureMembers(members))
        case let .named(name):
            if let udt = try dataType(named: name) { return udt }
            if let block = try functionBlockType(named: name) { return .instance(block) }
            throw ResolveError(message: S7Messages.dataTypeNotDefined(name))
        case let .system(name):
            guard let block = FunctionBlockLibrary.type(named: name, dialect: .siemens) else {
                throw ResolveError(message: S7Messages.dataTypeNotDefined(name))
            }
            return .instance(block)
        case .void:
            throw ResolveError(message: S7Messages.dataTypeNotPermitted("Void"))
        }
    }

    /// A PLC data type by name; nil if there is none.
    func dataType(named name: String) throws -> PLCType? {
        let key = name.lowercased()
        if let cached = dataTypeCache[key] { return cached }
        guard let udt = dataTypes[key] else { return nil }
        guard !resolving.contains("udt:" + key) else {
            throw ResolveError(message: S7Messages.recursiveType(udt.name))
        }
        resolving.insert("udt:" + key)
        defer { resolving.remove("udt:" + key) }
        let type = PLCType.structure(name: udt.name, members: try structureMembers(udt.members))
        dataTypeCache[key] = type
        return type
    }

    /// A user function block's instance type by name; nil if there is no such FB.
    func functionBlockType(named name: String) throws -> FunctionBlockType? {
        let key = name.lowercased()
        if let cached = functionBlockCache[key] { return cached }
        guard let block = functionBlocks[key] else { return nil }
        guard !resolving.contains("fb:" + key) else {
            throw ResolveError(message: S7Messages.recursiveType(block.name))
        }
        resolving.insert("fb:" + key)
        defer { resolving.remove("fb:" + key) }
        let members = interfaceMembers(of: block).members
        let type = FunctionBlockType(name: block.name, members: members.filter { $0.section.frameArea == .instance }, builtIn: nil)
        functionBlockCache[key] = type
        return type
    }

    /// The members of a Struct or PLC data type.
    private func structureMembers(_ variables: [SiemensVariable]) throws -> [PLCMember] {
        try variables.map { variable in
            let memberType = try type(of: variable)
            return PLCMember(variable.name, memberType, section: .staticVar,
                             initialValue: try startValue(variable.startValue, for: memberType),
                             isRetain: variable.retain == .retain)
        }
    }

    /// A start value for an elementary type or an array of one; nil when empty.
    func startValue(_ text: String, for type: PLCType) throws -> PLCValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var elementType = type
        while case let .array(_, _, element) = elementType { elementType = element }
        guard let dataType = elementType.elementary else {
            throw ResolveError(message: S7Messages.invalidStartValue(trimmed, type.displayName))
        }
        guard let value = ValueParser.parse(trimmed, as: dataType) else {
            throw ResolveError(message: S7Messages.invalidStartValue(trimmed, dataType.rawValue))
        }
        return value
    }

    /// A block's interface as runtime members, in the order BlockHandle
    /// expects (Input, Output, InOut, Static, Temp, Constant, Return), with a
    /// message for each row that doesn't resolve (those rows are left out).
    func interfaceMembers(of block: SiemensBlock) -> (members: [PLCMember], errors: [(row: String, message: String)]) {
        var members: [PLCMember] = []
        var errors: [(row: String, message: String)] = []
        var seen: Set<String> = []
        for section in SiemensInterface.sections(for: block.kind) where section != .returnValue {
            for variable in block.interface.variables(in: section) {
                let key = variable.name.lowercased()
                if variable.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    errors.append((variable.name, S7Messages.emptyName))
                    continue
                }
                guard !seen.contains(key) else {
                    errors.append((variable.name, S7Messages.nameUsedTwice(variable.name)))
                    continue
                }
                seen.insert(key)
                do {
                    let memberType = try type(of: variable)
                    if memberType.functionBlock != nil, !(block.kind == .functionBlock && (section == .staticVar || section == .inOut)) {
                        throw ResolveError(message: "Instances of function blocks can only be declared in the Static or InOut section of a function block.")
                    }
                    if section == .constant, memberType.elementary == nil {
                        throw ResolveError(message: S7Messages.dataTypeNotPermitted(memberType.displayName))
                    }
                    let start = try startValue(variable.startValue, for: memberType)
                    let retain = block.kind == .functionBlock && variable.retain == .retain && section != .temp && section != .constant
                    members.append(PLCMember(variable.name, memberType, section: section, initialValue: start, isRetain: retain))
                } catch let error as ResolveError {
                    errors.append((variable.name, error.message))
                } catch {
                    errors.append((variable.name, error.localizedDescription))
                }
            }
        }
        if block.kind == .function {
            do {
                let spec = try SiemensTypeParser.parse(block.interface.returnType)
                if spec != .void {
                    guard case let .elementary(type) = spec else {
                        throw ResolveError(message: S7Messages.dataTypeNotPermitted(spec.text))
                    }
                    members.append(PLCMember(block.name, .elementary(type), section: .returnValue))
                }
            } catch let error as ResolveError {
                errors.append(("Return", error.message))
            } catch {
                errors.append(("Return", error.localizedDescription))
            }
        }
        return (members, errors)
    }
}
