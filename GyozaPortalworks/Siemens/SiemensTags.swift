import Foundation

/// A row of a PLC tag table.
nonisolated struct SiemensTag: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var dataType: PLCDataType
    /// The Address column as typed: "%I0.0", "%MW10". TIA adds the "%".
    var address: String
    var comment: String

    init(_ name: String, _ dataType: PLCDataType, _ address: String, comment: String = "", id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.address = address
        self.comment = comment
    }

    enum CodingKeys: String, CodingKey {
        case id, name, dataType, address, comment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "Tag_1")
        dataType = try container.s7Value(.dataType, default: .bool)
        address = try container.s7Value(.address, default: "%M0.0")
        comment = try container.s7Value(.comment, default: "")
    }

    /// The parsed address, or nil when it is malformed.
    var parsedAddress: S7Address? { try? S7Address.parse(address) }
}

/// A row of a tag table's "User constants" tab.
nonisolated struct SiemensUserConstant: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var dataType: PLCDataType
    var value: String
    var comment: String

    init(_ name: String, _ dataType: PLCDataType, _ value: String, comment: String = "", id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.dataType = dataType
        self.value = value
        self.comment = comment
    }

    enum CodingKeys: String, CodingKey {
        case id, name, dataType, value, comment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "Constant_1")
        dataType = try container.s7Value(.dataType, default: .int)
        value = try container.s7Value(.value, default: "0")
        comment = try container.s7Value(.comment, default: "")
    }

    var parsedValue: PLCValue? { ValueParser.parse(value, as: dataType) }
}

/// A PLC tag table: "Default tag table" or one the user added.
nonisolated struct SiemensTagTable: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var tags: [SiemensTag]
    var constants: [SiemensUserConstant]

    init(name: String, tags: [SiemensTag] = [], constants: [SiemensUserConstant] = [], id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.tags = tags
        self.constants = constants
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tags, constants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.s7Value(.id, default: UUID())
        name = try container.s7Value(.name, default: "Default tag table")
        tags = try container.s7Value(.tags, default: [])
        constants = try container.s7Value(.constants, default: [])
    }

    static let defaultName = "Default tag table"
}

/// A problem the tag table editor marks on a cell.
nonisolated struct SiemensTagIssue: Hashable, Sendable {
    nonisolated enum Column: String, Hashable, Sendable {
        case name = "Name"
        case dataType = "Data type"
        case address = "Address"
        case value = "Value"
    }

    /// The tag or user constant.
    var rowID: UUID
    var column: Column
    var message: String
}

/// Tag table rules: names, addresses, retentivity and proposals.
nonisolated enum SiemensTagRules {
    /// Every problem in the tag tables. Names are unique across all tag
    /// tables and user constants; two tags on the same address are both marked.
    static func issues(in tables: [SiemensTagTable]) -> [SiemensTagIssue] {
        var issues: [SiemensTagIssue] = []
        var names: [String: [UUID]] = [:]
        var addresses: [String: [UUID]] = [:]
        for table in tables {
            for tag in table.tags {
                issues += nameIssues(tag.name, row: tag.id)
                names[tag.name.lowercased(), default: []].append(tag.id)
                do {
                    let address = try parseTagAddress(tag.address)
                    if !address.accepts(tag.dataType) {
                        issues.append(SiemensTagIssue(rowID: tag.id, column: .address,
                                                      message: S7Messages.addressDoesNotFit(address.description, tag.dataType.rawValue)))
                    } else {
                        addresses["\(address.description)|\(tag.dataType.bitWidth)", default: []].append(tag.id)
                    }
                } catch let error as ResolveError {
                    issues.append(SiemensTagIssue(rowID: tag.id, column: .address, message: error.message))
                } catch {
                    issues.append(SiemensTagIssue(rowID: tag.id, column: .address, message: error.localizedDescription))
                }
            }
            for constant in table.constants {
                issues += nameIssues(constant.name, row: constant.id)
                names[constant.name.lowercased(), default: []].append(constant.id)
                if constant.parsedValue == nil {
                    issues.append(SiemensTagIssue(rowID: constant.id, column: .value,
                                                  message: S7Messages.invalidConstant(constant.value, constant.dataType.rawValue)))
                }
            }
        }
        var shownNames: [UUID: String] = [:]
        for table in tables {
            for tag in table.tags { shownNames[tag.id] = tag.name }
            for constant in table.constants { shownNames[constant.id] = constant.name }
        }
        for (_, rows) in names where rows.count > 1 {
            let name = shownNames[rows[0]] ?? ""
            issues += rows.map { SiemensTagIssue(rowID: $0, column: .name, message: S7Messages.nameUsedTwice(name)) }
        }
        for (key, rows) in addresses where rows.count > 1 {
            let address = String(key.prefix { $0 != "|" })
            issues += rows.map { SiemensTagIssue(rowID: $0, column: .address, message: S7Messages.addressUsedTwice(address)) }
        }
        return issues
    }

    private static func nameIssues(_ name: String, row: UUID) -> [SiemensTagIssue] {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return [SiemensTagIssue(rowID: row, column: .name, message: S7Messages.emptyName)]
        }
        if name.contains("\"") {
            return [SiemensTagIssue(rowID: row, column: .name, message: S7Messages.quotesInName)]
        }
        return []
    }

    /// Parses a tag's address: I, Q or M, without ":P".
    static func parseTagAddress(_ text: String) throws -> S7Address {
        let address = try S7Address.parse(text)
        if address.isPeripheral { throw ResolveError(message: S7Messages.peripheralInTagTable) }
        return address
    }

    /// TIA's normalized form of a typed address: "i0.0" → "%I0.0". Unparseable text is kept.
    static func normalizedAddress(_ text: String) -> String {
        (try? S7Address.parse(text).description) ?? text
    }

    /// A free name for a new or renamed row: "Tag_1" → "Tag_1(1)" when taken.
    static func uniqueName(_ proposed: String, in tables: [SiemensTagTable], excluding row: UUID? = nil) -> String {
        let existing = tables.flatMap { table in
            table.tags.filter { $0.id != row }.map(\.name) + table.constants.filter { $0.id != row }.map(\.name)
        }
        return SiemensNaming.unique(proposed, among: existing, style: .parenthesis)
    }

    /// The address TIA proposes for a new tag of `type`: the next free
    /// address after `previous` in its area, or %I0.0 / %IW0-style in bit
    /// memory when there is no previous tag.
    static func proposedAddress(for type: PLCDataType, after previous: SiemensTag?, in tables: [SiemensTagTable]) -> String {
        let used = Set(tables.flatMap(\.tags).compactMap { $0.parsedAddress?.description })
        let area = previous?.parsedAddress?.area ?? (type == .bool ? .input : .memory)
        guard let width = S7AccessWidth.holding(type) ?? (type == .lreal ? .bit : nil) else { return "" }
        let step = type == .lreal ? 8 : width.byteCount
        var candidate: S7Address
        if let previous, let previousAddress = previous.parsedAddress, previousAddress.area == area {
            let end = previousAddress.byteRange(for: previous.dataType).upperBound
            if width == .bit && type != .lreal && previousAddress.width == .bit && previous.dataType == .bool {
                let next = previousAddress.byteOffset * 8 + previousAddress.bitNumber + 1
                candidate = .bit(area, next / 8, next % 8)
            } else {
                candidate = S7Address(area: area, width: width, byteOffset: end)
            }
        } else {
            candidate = S7Address(area: area, width: width, byteOffset: 0)
        }
        var attempts = 0
        while used.contains(candidate.description), attempts < 65_536 {
            attempts += 1
            if width == .bit && type != .lreal {
                let next = candidate.byteOffset * 8 + candidate.bitNumber + 1
                candidate = .bit(area, next / 8, next % 8)
            } else {
                candidate = S7Address(area: area, width: width, byteOffset: candidate.byteOffset + step)
            }
        }
        guard candidate.byteOffset + step <= area.size else { return "" }
        return candidate.description
    }

    /// Whether a bit-memory tag lies inside the retentive range MB0…MB(n-1).
    static func isRetain(_ tag: SiemensTag, retentiveBytes: Int) -> Bool {
        guard let address = tag.parsedAddress, address.area == .memory else { return false }
        return address.byteRange(for: tag.dataType).upperBound <= retentiveBytes
    }

    /// The retentive byte count after ticking or clearing a tag's Retain box:
    /// ticking extends the range to cover the tag, clearing ends it before the tag.
    static func retentiveBytes(setting retain: Bool, for tag: SiemensTag, current: Int) -> Int {
        guard let address = tag.parsedAddress, address.area == .memory else { return current }
        if retain { return max(current, address.byteRange(for: tag.dataType).upperBound) }
        return min(current, address.byteOffset)
    }

    /// The tags TIA adds for enabled system and clock memory bytes.
    static func systemAndClockTags(systemByte: Int?, clockByte: Int?) -> [SiemensTag] {
        var tags: [SiemensTag] = []
        if let systemByte {
            tags += [
                SiemensTag("System_Byte", .byte, "%MB\(systemByte)"),
                SiemensTag("FirstScan", .bool, "%M\(systemByte).0"),
                SiemensTag("DiagStatusUpdate", .bool, "%M\(systemByte).1"),
                SiemensTag("AlwaysTRUE", .bool, "%M\(systemByte).2"),
                SiemensTag("AlwaysFALSE", .bool, "%M\(systemByte).3"),
            ]
        }
        if let clockByte {
            tags.append(SiemensTag("Clock_Byte", .byte, "%MB\(clockByte)"))
            let names = ["Clock_10Hz", "Clock_5Hz", "Clock_2.5Hz", "Clock_2Hz", "Clock_1.25Hz", "Clock_1Hz", "Clock_0.625Hz", "Clock_0.5Hz"]
            for (bit, name) in names.enumerated() {
                tags.append(SiemensTag(name, .bool, "%M\(clockByte).\(bit)"))
            }
        }
        return tags
    }
}
