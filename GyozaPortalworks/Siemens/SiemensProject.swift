import Foundation

/// The PLC in the project: CPU 1214C DC/DC/DC with an optional SB 1232 AQ
/// signal board, plus the device settings the program depends on.
nonisolated struct SiemensDevice: Codable, Hashable, Sendable {
    var name = "PLC_1"
    var cpuType = "CPU 1214C DC/DC/DC"
    var articleNumber = "6ES7 214-1AG40-0XB0"
    var firmware = "V4.4"
    /// SB 1232 AQ: one analog output at %QW80.
    var hasSignalBoard = true
    var signalBoard = "SB 1232 AQ"
    /// Properties › System and clock memory.
    var isSystemMemoryEnabled = true
    var systemMemoryByte = 1
    var isClockMemoryEnabled = true
    var clockMemoryByte = 0
    /// Retentive bit memory: MB0 … MB(n-1).
    var retentiveMarkerBytes = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case name, cpuType, articleNumber, firmware, hasSignalBoard, signalBoard, isSystemMemoryEnabled, systemMemoryByte
        case isClockMemoryEnabled, clockMemoryByte, retentiveMarkerBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = SiemensDevice()
        name = try container.s7Value(.name, default: standard.name)
        cpuType = try container.s7Value(.cpuType, default: standard.cpuType)
        articleNumber = try container.s7Value(.articleNumber, default: standard.articleNumber)
        firmware = try container.s7Value(.firmware, default: standard.firmware)
        hasSignalBoard = try container.s7Value(.hasSignalBoard, default: standard.hasSignalBoard)
        signalBoard = try container.s7Value(.signalBoard, default: standard.signalBoard)
        isSystemMemoryEnabled = try container.s7Value(.isSystemMemoryEnabled, default: standard.isSystemMemoryEnabled)
        systemMemoryByte = try container.s7Value(.systemMemoryByte, default: standard.systemMemoryByte)
        isClockMemoryEnabled = try container.s7Value(.isClockMemoryEnabled, default: standard.isClockMemoryEnabled)
        clockMemoryByte = try container.s7Value(.clockMemoryByte, default: standard.clockMemoryByte)
        retentiveMarkerBytes = try container.s7Value(.retentiveMarkerBytes, default: standard.retentiveMarkerBytes)
    }

    /// Input bytes the hardware supplies: DI %IB0…%IB1, AI %IW64/%IW66.
    var inputRanges: [Range<Int>] { [0..<2, 64..<68] }

    /// Output bytes the hardware takes: DQ %QB0…%QB1, AQ %QW80 with the signal board.
    var outputRanges: [Range<Int>] { hasSignalBoard ? [0..<2, 80..<82] : [0..<2] }

    /// Whether an I/O operand exists in the configured hardware (bit memory always does).
    func isConfigured(_ address: S7Address, type: PLCDataType) -> Bool {
        let bytes = address.byteRange(for: type)
        switch address.area {
        case .memory: return true
        case .input: return inputRanges.contains { $0.lowerBound <= bytes.lowerBound && bytes.upperBound <= $0.upperBound }
        case .output: return outputRanges.contains { $0.lowerBound <= bytes.lowerBound && bytes.upperBound <= $0.upperBound }
        }
    }
}

/// The watch table's Display format column.
nonisolated enum S7DisplayFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case bool = "Bool"
    case hex = "Hex"
    case decimal = "DEC"
    case signedDecimal = "DEC+/-"
    case binary = "Bin"
    case octal = "Octal"
    case floatingPoint = "Floating-point number"
    case time = "Time"
    case character = "Character"

    /// The format TIA picks for a type.
    static func standard(for type: PLCDataType) -> S7DisplayFormat {
        switch type {
        case .bool: return .bool
        case .byte, .word, .dword: return .hex
        case .sint, .int, .dint: return .signedDecimal
        case .usint, .uint, .udint: return .decimal
        case .real, .lreal: return .floatingPoint
        case .time: return .time
        }
    }

    /// The formats offered for a type.
    static func available(for type: PLCDataType) -> [S7DisplayFormat] {
        switch type {
        case .bool: return [.bool, .hex, .binary, .octal]
        case .byte: return [.hex, .binary, .octal, .decimal, .signedDecimal, .character]
        case .word, .dword, .sint, .int, .dint, .usint, .uint, .udint: return [.hex, .binary, .octal, .decimal, .signedDecimal]
        case .real, .lreal: return [.floatingPoint, .hex, .binary]
        case .time: return [.time, .hex, .signedDecimal]
        }
    }

    /// A value as the Monitor value column shows it.
    func format(_ value: PLCValue, as type: PLCDataType) -> String {
        let bits = type.isReal ? Int64(bitPattern: S7Memory.encode(value, as: type)) : value.intValue
        let mask = type.bitMask
        let raw = UInt64(bitPattern: bits) & UInt64(bitPattern: mask)
        let digits = max(1, type.bitWidth)
        switch self {
        case .bool:
            return value.boolValue ? "TRUE" : "FALSE"
        case .hex:
            let text = String(raw, radix: 16, uppercase: true)
            let width = max(1, (digits + 3) / 4)
            return "16#" + String(repeating: "0", count: max(0, width - text.count)) + text
        case .binary:
            let text = String(raw, radix: 2)
            let padded = String(repeating: "0", count: max(0, digits - text.count)) + text
            var grouped = ""
            for (index, character) in padded.enumerated() {
                if index > 0 && (padded.count - index) % 4 == 0 { grouped += "_" }
                grouped.append(character)
            }
            return "2#" + grouped
        case .octal:
            return "8#" + String(raw, radix: 8)
        case .decimal:
            return String(raw)
        case .signedDecimal:
            if type.isReal || type == .time { return String(bits) }
            let signed = type.isSignedInteger || type == .time ? type.wrap(value.intValue) : value.intValue
            return signed >= 0 && type.isSignedInteger ? "+" + String(signed) : String(signed)
        case .floatingPoint:
            return RealLiteral.format(value.doubleValue)
        case .time:
            return TimeLiteral.format(milliseconds: value.intValue)
        case .character:
            let scalar = UnicodeScalar(UInt8(truncatingIfNeeded: raw))
            return "'" + String(Character(scalar)) + "'"
        }
    }

    /// Parses a Modify value typed for this format; nil when it doesn't fit the type.
    func parse(_ text: String, as type: PLCDataType) -> PLCValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if self == .character, trimmed.count == 3, trimmed.hasPrefix("'"), trimmed.hasSuffix("'"),
           let ascii = trimmed.dropFirst().first?.asciiValue {
            return .int(Int64(ascii))
        }
        return ValueParser.parse(trimmed, as: type)
    }
}

/// When a watch table's modify values are written.
nonisolated enum S7ModifyTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case permanent = "Permanent"
    case permanentlyAtStartOfCycle = "Permanently at start of scan cycle"
    case onceAtStartOfCycle = "Once at start of scan cycle"
    case permanentlyAtEndOfCycle = "Permanently at end of scan cycle"
    case onceAtEndOfCycle = "Once at end of scan cycle"
    case permanentlyAtTransitionToStop = "Permanently at transition to STOP"
    case onceAtTransitionToStop = "Once at transition to STOP"
}

/// A row of a watch table.
nonisolated struct SiemensWatchRow: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The Name/Address column as typed: "Motor", %MW10, "Data".speed, %IW64:P.
    var operand: String
    /// nil = the type's standard format.
    var displayFormat: S7DisplayFormat?
    var modifyValue: String
    /// The lightning checkbox: include this row in "Modify".
    var isModifyEnabled: Bool
    var comment: String
    /// A comment line ("//" in the Name column).
    var isCommentLine: Bool

    init(_ operand: String, displayFormat: S7DisplayFormat? = nil, modifyValue: String = "", isModifyEnabled: Bool = false,
         comment: String = "", isCommentLine: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.operand = operand
        self.displayFormat = displayFormat
        self.modifyValue = modifyValue
        self.isModifyEnabled = isModifyEnabled
        self.comment = comment
        self.isCommentLine = isCommentLine
    }

    enum CodingKeys: String, CodingKey {
        case id, operand, displayFormat, modifyValue, isModifyEnabled, comment, isCommentLine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        operand = try container.s7Value(.operand, default: "")
        displayFormat = try container.decodeIfPresent(S7DisplayFormat.self, forKey: .displayFormat)
        modifyValue = try container.s7Value(.modifyValue, default: "")
        isModifyEnabled = try container.s7Value(.isModifyEnabled, default: false)
        comment = try container.s7Value(.comment, default: "")
        isCommentLine = try container.s7Value(.isCommentLine, default: false)
    }
}

/// A watch table under "Watch and force tables".
nonisolated struct SiemensWatchTable: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var rows: [SiemensWatchRow]
    var monitorTrigger: S7ModifyTrigger
    var modifyTrigger: S7ModifyTrigger

    init(name: String = "Watch table_1", rows: [SiemensWatchRow] = [], id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.rows = rows
        self.monitorTrigger = .permanent
        self.modifyTrigger = .permanent
    }

    enum CodingKeys: String, CodingKey {
        case id, name, rows, monitorTrigger, modifyTrigger
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "Watch table_1")
        rows = try container.s7Value(.rows, default: [])
        monitorTrigger = try container.s7Value(.monitorTrigger, default: .permanent)
        modifyTrigger = try container.s7Value(.modifyTrigger, default: .permanent)
    }
}

/// A row of the force table (I/O addresses only: %I0.0:P, %QW80:P).
nonisolated struct SiemensForceRow: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var operand: String
    var displayFormat: S7DisplayFormat?
    var forceValue: String
    /// The "F" checkbox.
    var isForceEnabled: Bool
    var comment: String

    init(_ operand: String, forceValue: String = "", isForceEnabled: Bool = false, displayFormat: S7DisplayFormat? = nil,
         comment: String = "", id: UUID = UUID()) {
        self.id = id
        self.operand = operand
        self.displayFormat = displayFormat
        self.forceValue = forceValue
        self.isForceEnabled = isForceEnabled
        self.comment = comment
    }

    enum CodingKeys: String, CodingKey {
        case id, operand, displayFormat, forceValue, isForceEnabled, comment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        operand = try container.s7Value(.operand, default: "")
        displayFormat = try container.decodeIfPresent(S7DisplayFormat.self, forKey: .displayFormat)
        forceValue = try container.s7Value(.forceValue, default: "")
        isForceEnabled = try container.s7Value(.isForceEnabled, default: false)
        comment = try container.s7Value(.comment, default: "")
    }
}

/// A TIA Portal project with one S7-1200 station.
nonisolated struct SiemensProject: Codable, Hashable, Sendable {
    var name: String
    var device: SiemensDevice
    var tagTables: [SiemensTagTable]
    var blocks: [SiemensBlock]
    var dataBlocks: [SiemensDataBlock]
    /// PLC data types (UDTs).
    var dataTypes: [SiemensDataType]
    var watchTables: [SiemensWatchTable]
    var forceTable: [SiemensForceRow]

    init(name: String = "Project1", device: SiemensDevice = SiemensDevice(), tagTables: [SiemensTagTable] = [],
         blocks: [SiemensBlock] = [], dataBlocks: [SiemensDataBlock] = [], dataTypes: [SiemensDataType] = [],
         watchTables: [SiemensWatchTable] = [], forceTable: [SiemensForceRow] = []) {
        self.name = name
        self.device = device
        self.tagTables = tagTables
        self.blocks = blocks
        self.dataBlocks = dataBlocks
        self.dataTypes = dataTypes
        self.watchTables = watchTables
        self.forceTable = forceTable
    }

    enum CodingKeys: String, CodingKey {
        case name, device, tagTables, blocks, dataBlocks, dataTypes, watchTables, forceTable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.s7Value(.name, default: "Project1")
        device = try container.s7Value(.device, default: SiemensDevice())
        tagTables = try container.s7Value(.tagTables, default: [SiemensTagTable(name: SiemensTagTable.defaultName)])
        blocks = try container.s7Value(.blocks, default: [])
        dataBlocks = try container.s7Value(.dataBlocks, default: [])
        dataTypes = try container.s7Value(.dataTypes, default: [])
        watchTables = try container.s7Value(.watchTables, default: [])
        forceTable = try container.s7Value(.forceTable, default: [])
    }

    /// What "Create new project" and "Add new device" give: Project1 with PLC_1
    /// (CPU 1214C DC/DC/DC), Main [OB1] in LAD with one empty network, and
    /// the default tag table holding the system and clock memory tags.
    static func newProject(name: String = "Project1") -> SiemensProject {
        let device = SiemensDevice()
        let main = SiemensBlock(name: "Main", kind: .organizationBlock, number: 1, language: .lad,
                                title: SiemensOBEvent.programCycle.standardTitle)
        let tags = SiemensTagRules.systemAndClockTags(systemByte: device.systemMemoryByte, clockByte: device.clockMemoryByte)
        return SiemensProject(name: name, device: device,
                              tagTables: [SiemensTagTable(name: SiemensTagTable.defaultName, tags: tags)],
                              blocks: [main], watchTables: [], forceTable: [])
    }

    // MARK: Lookup

    func block(named name: String) -> SiemensBlock? {
        blocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func dataBlock(named name: String) -> SiemensDataBlock? {
        dataBlocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// "Show all tags": every tag with the table it is in.
    var allTags: [(table: String, tag: SiemensTag)] {
        tagTables.flatMap { table in table.tags.map { (table: table.name, tag: $0) } }
    }

    var allConstants: [(table: String, constant: SiemensUserConstant)] {
        tagTables.flatMap { table in table.constants.map { (table: table.name, constant: $0) } }
    }

    /// Names of every program block and data block (they share one namespace).
    var blockNames: [String] { blocks.map(\.name) + dataBlocks.map(\.name) }

    /// Problems the tag tables show.
    var tagIssues: [SiemensTagIssue] { SiemensTagRules.issues(in: tagTables) }

    /// Whether a bit-memory tag is retentive (the Retain column).
    func isRetain(_ tag: SiemensTag) -> Bool {
        SiemensTagRules.isRetain(tag, retentiveBytes: device.retentiveMarkerBytes)
    }

    // MARK: Numbers

    /// The next free number for a new block: FB/FC/DB count from 1, extra OBs from 123.
    func nextFreeNumber(for kind: SiemensBlockKind, event: SiemensOBEvent = .programCycle) -> Int {
        let used = Set(blocks.filter { $0.kind == kind }.map(\.number))
        var number: Int
        if kind == .organizationBlock {
            number = used.contains(event.standardNumber) ? 123 : event.standardNumber
        } else {
            number = 1
        }
        while used.contains(number) { number += 1 }
        return number
    }

    func nextFreeDataBlockNumber() -> Int {
        let used = Set(dataBlocks.map(\.number))
        var number = 1
        while used.contains(number) { number += 1 }
        return number
    }

    // MARK: Editing

    /// "Add new block" for an OB, FC or FB, with TIA's proposed name (Block_1…)
    /// and an automatic number.
    @discardableResult
    mutating func addBlock(_ kind: SiemensBlockKind, language: SiemensLanguage = .lad, event: SiemensOBEvent = .programCycle,
                           name: String? = nil) -> SiemensBlock {
        var proposed = name ?? "Block_1"
        if kind == .organizationBlock && name == nil && !blocks.contains(where: { $0.kind == .organizationBlock && $0.event == event }) {
            proposed = event.standardName
        }
        let unique = SiemensNaming.unique(proposed, among: blockNames, style: name == nil ? .counting : .underscore)
        let number = nextFreeNumber(for: kind, event: event)
        var title = ""
        if kind == .organizationBlock && number == event.standardNumber { title = event.standardTitle }
        let block = SiemensBlock(name: unique, kind: kind, number: number, language: language, event: event, title: title)
        blocks.append(block)
        return block
    }

    /// "Add new block" › Data block (global).
    @discardableResult
    mutating func addGlobalDataBlock(name: String? = nil) -> SiemensDataBlock {
        let unique = SiemensNaming.unique(name ?? "Data_block_1", among: blockNames, style: name == nil ? .counting : .underscore)
        let block = SiemensDataBlock(name: unique, number: nextFreeDataBlockNumber())
        dataBlocks.append(block)
        return block
    }

    /// An instance DB of a user FB, named "<FB>_DB" by default.
    @discardableResult
    mutating func addInstanceDataBlock(of functionBlock: String, name: String? = nil) -> SiemensDataBlock {
        let unique = SiemensNaming.unique(name ?? functionBlock + "_DB", among: blockNames, style: .underscore)
        let block = SiemensDataBlock(name: unique, number: nextFreeDataBlockNumber(), kind: .instance, instanceOf: functionBlock)
        dataBlocks.append(block)
        return block
    }

    /// "Call options" › Single instance for a timer, counter or R_TRIG/F_TRIG
    /// box: creates IEC_Timer_0_DB (then IEC_Timer_0_DB_1…), IEC_Counter_0_DB,
    /// R_TRIG_DB under Program resources and returns the operand to put above the box.
    mutating func createInstanceDataBlock(for instruction: S7Instruction, dataType: PLCDataType? = nil) -> String? {
        guard let base = instruction.instanceNameBase(multiInstance: false),
              let typeName = instruction.instanceTypeName(dataType: dataType)
        else { return nil }
        let unique = SiemensNaming.unique(base, among: blockNames, style: .underscore)
        let block = SiemensDataBlock(name: unique, number: nextFreeDataBlockNumber(), kind: .systemInstance, instanceOf: typeName,
                                     isRetain: instruction.isCounter, isCreatedAutomatically: true)
        dataBlocks.append(block)
        return "\"\(unique)\""
    }

    /// "Add new data type".
    @discardableResult
    mutating func addDataType(name: String? = nil) -> SiemensDataType {
        let unique = SiemensNaming.unique(name ?? "User data type_1", among: dataTypes.map(\.name), style: name == nil ? .counting : .underscore)
        let type = SiemensDataType(name: unique)
        dataTypes.append(type)
        return type
    }

    /// Adds a tag to a table (the first one by default). A taken name gets
    /// "(1)" appended, and the address is normalized ("i0.0" → "%I0.0").
    @discardableResult
    mutating func addTag(_ tag: SiemensTag, toTable index: Int = 0) -> SiemensTag {
        if tagTables.isEmpty { tagTables.append(SiemensTagTable(name: SiemensTagTable.defaultName)) }
        let table = tagTables.indices.contains(index) ? index : 0
        var added = tag
        added.name = SiemensTagRules.uniqueName(tag.name, in: tagTables)
        added.address = SiemensTagRules.normalizedAddress(tag.address)
        tagTables[table].tags.append(added)
        return added
    }

    /// A new row the way "<Add new>" fills it: Tag_1, Bool, the next address.
    @discardableResult
    mutating func addNewTag(toTable index: Int = 0, dataType: PLCDataType = .bool) -> SiemensTag {
        if tagTables.isEmpty { tagTables.append(SiemensTagTable(name: SiemensTagTable.defaultName)) }
        let table = tagTables.indices.contains(index) ? index : 0
        let previous = tagTables[table].tags.last
        let name = SiemensTagRules.uniqueName(previous.map { SiemensNaming.unique($0.name, among: [$0.name], style: .counting) } ?? "Tag_1",
                                              in: tagTables)
        let address = SiemensTagRules.proposedAddress(for: dataType, after: previous, in: tagTables)
        return addTag(SiemensTag(name, dataType, address), toTable: table)
    }

    @discardableResult
    mutating func addConstant(_ constant: SiemensUserConstant, toTable index: Int = 0) -> SiemensUserConstant {
        if tagTables.isEmpty { tagTables.append(SiemensTagTable(name: SiemensTagTable.defaultName)) }
        let table = tagTables.indices.contains(index) ? index : 0
        var added = constant
        added.name = SiemensTagRules.uniqueName(constant.name, in: tagTables)
        tagTables[table].constants.append(added)
        return added
    }

    /// Renames a tag or constant; a taken name gets "(1)" appended.
    mutating func rename(row id: UUID, to name: String) {
        let unique = SiemensTagRules.uniqueName(name, in: tagTables, excluding: id)
        for table in tagTables.indices {
            if let index = tagTables[table].tags.firstIndex(where: { $0.id == id }) { tagTables[table].tags[index].name = unique }
            if let index = tagTables[table].constants.firstIndex(where: { $0.id == id }) { tagTables[table].constants[index].name = unique }
        }
    }

    /// Ticks or clears a bit-memory tag's Retain box (moves the retentive range).
    mutating func setRetain(_ retain: Bool, forTag id: UUID) {
        guard let tag = tagTables.flatMap(\.tags).first(where: { $0.id == id }) else { return }
        device.retentiveMarkerBytes = SiemensTagRules.retentiveBytes(setting: retain, for: tag, current: device.retentiveMarkerBytes)
    }

    /// Enables or moves the system memory byte; the tags follow, as in TIA.
    mutating func setSystemMemory(enabled: Bool, byte: Int? = nil) {
        device.isSystemMemoryEnabled = enabled
        if let byte { device.systemMemoryByte = byte }
        replaceStandardTags(names: ["System_Byte", "FirstScan", "DiagStatusUpdate", "AlwaysTRUE", "AlwaysFALSE"],
                            with: enabled ? SiemensTagRules.systemAndClockTags(systemByte: device.systemMemoryByte, clockByte: nil) : [])
    }

    /// Enables or moves the clock memory byte; the tags follow, as in TIA.
    mutating func setClockMemory(enabled: Bool, byte: Int? = nil) {
        device.isClockMemoryEnabled = enabled
        if let byte { device.clockMemoryByte = byte }
        let names = ["Clock_Byte", "Clock_10Hz", "Clock_5Hz", "Clock_2.5Hz", "Clock_2Hz", "Clock_1.25Hz", "Clock_1Hz",
                     "Clock_0.625Hz", "Clock_0.5Hz"]
        replaceStandardTags(names: names,
                            with: enabled ? SiemensTagRules.systemAndClockTags(systemByte: nil, clockByte: device.clockMemoryByte) : [])
    }

    private mutating func replaceStandardTags(names: [String], with tags: [SiemensTag]) {
        let keys = Set(names.map { $0.lowercased() })
        for table in tagTables.indices {
            tagTables[table].tags.removeAll { keys.contains($0.name.lowercased()) }
        }
        if tagTables.isEmpty { tagTables.append(SiemensTagTable(name: SiemensTagTable.defaultName)) }
        tagTables[0].tags.append(contentsOf: tags)
    }
}
