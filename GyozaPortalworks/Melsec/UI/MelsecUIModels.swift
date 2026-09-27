import Foundation

/// An editor that can be open in the centre tabs.
nonisolated enum MelsecEditorTabID: Hashable, Sendable {
    case program(UUID)
    case localLabels(UUID)
    case globalLabels
    case deviceComments
    case deviceMemory
    case cpuParameter

    /// A string id for the tab strip.
    var key: String {
        switch self {
        case let .program(id): return "program:\(id.uuidString)"
        case let .localLabels(id): return "local:\(id.uuidString)"
        case .globalLabels: return "globalLabels"
        case .deviceComments: return "deviceComments"
        case .deviceMemory: return "deviceMemory"
        case .cpuParameter: return "cpuParameter"
        }
    }

    init?(key: String) {
        switch key {
        case "globalLabels": self = .globalLabels
        case "deviceComments": self = .deviceComments
        case "deviceMemory": self = .deviceMemory
        case "cpuParameter": self = .cpuParameter
        default:
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
            switch parts[0] {
            case "program": self = .program(id)
            case "local": self = .localLabels(id)
            default: return nil
            }
        }
    }

    var programID: UUID? {
        switch self {
        case let .program(id), let .localLabels(id): return id
        default: return nil
        }
    }
}

/// The docking windows at the bottom.
nonisolated enum MelsecDockTab: Hashable, Sendable {
    case output
    case conversionResult
    case watch(Int)

    var title: String {
        switch self {
        case .output: return "Output"
        case .conversionResult: return "Conversion Result"
        case let .watch(index): return "Watch \(index + 1)"
        }
    }
}

/// One row of the Output window.
nonisolated struct MelsecOutputMessage: Identifiable, Hashable, Sendable {
    nonisolated enum Result: String, CaseIterable, Hashable, Sendable {
        case error = "Error"
        case warning = "Warning"
        case information = "Information"
    }

    /// No. column (1-based).
    var id: Int
    var result: Result
    /// Data Name: the program or label list.
    var dataName: String
    var category: String
    var content: String
    /// Error Code: blank, because the simulator doesn't invent codes.
    var errorCode: String = ""
    /// Where double-click jumps.
    var programID: UUID?
    var cell: MelsecCellRef?
    var line: Int?
    var column: Int?
}

/// A node of the Navigation window.
nonisolated struct MelsecNavigationNode: Identifiable, Hashable, Sendable {
    /// Text colour: converted (normal), unconverted (red), unused (light blue).
    nonisolated enum State: Hashable, Sendable {
        case normal, unconverted, unused
    }

    var id: String
    var title: String
    var systemImage: String
    var state: State = .normal
    /// What double-click opens.
    var tab: MelsecEditorTabID?
    /// The program a context-menu action applies to.
    var programID: UUID?
    var children: [MelsecNavigationNode]?

    /// GX Works3's Navigation tree for a project.
    static func tree(for project: MelsecProject, unconverted: Set<UUID>) -> [MelsecNavigationNode] {
        let files = Dictionary(grouping: project.programs, by: \.fileName)
        let fileNames = project.programs.map(\.fileName).reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        var scanChildren: [MelsecNavigationNode] = []
        for fileName in fileNames {
            let blocks = (files[fileName] ?? []).map { program -> MelsecNavigationNode in
                let state: State = unconverted.contains(program.id) ? .unconverted : .normal
                let language = program.language == .ladder ? "LD" : "ST"
                return MelsecNavigationNode(
                    id: "block:\(program.id.uuidString)", title: program.name, systemImage: "doc.text", state: state,
                    tab: .program(program.id), programID: program.id,
                    children: [
                        MelsecNavigationNode(id: "local:\(program.id.uuidString)", title: "Local Label", systemImage: "tag",
                                             tab: .localLabels(program.id), programID: program.id),
                        MelsecNavigationNode(id: "body:\(program.id.uuidString)", title: "ProgramBody [\(language)]",
                                             systemImage: program.language == .ladder ? "list.bullet.indent" : "text.alignleft",
                                             state: state, tab: .program(program.id), programID: program.id),
                    ])
            }
            let fileState: State = blocks.contains { $0.state == .unconverted } ? .unconverted : .normal
            scanChildren.append(MelsecNavigationNode(id: "file:\(fileName)", title: fileName, systemImage: "folder", state: fileState,
                                                     children: blocks))
        }
        func folder(_ id: String, _ title: String, _ children: [MelsecNavigationNode]? = nil, image: String = "folder") -> MelsecNavigationNode {
            MelsecNavigationNode(id: id, title: title, systemImage: image, children: children)
        }
        let program = folder("program", "Program", [
            folder("initial", "Initial", []),
            folder("scan", "Scan", scanChildren),
            folder("fixedScan", "Fixed Scan", []),
            folder("event", "Event", []),
            folder("standby", "Standby", []),
            folder("noExecution", "No Execution Type", []),
            folder("unregistered", "Unregistered Program", []),
        ])
        let label = folder("label", "Label", [
            folder("globalLabel", "Global Label", [
                MelsecNavigationNode(id: "global", title: "Global", systemImage: "tag", tab: .globalLabels),
            ]),
            MelsecNavigationNode(id: "structured", title: "Structured Data Types", systemImage: "square.stack.3d.up", state: .unused),
        ])
        let device = folder("device", "Device", [
            MelsecNavigationNode(id: "deviceComment", title: "Device Comment", systemImage: "text.bubble", tab: .deviceComments),
            MelsecNavigationNode(id: "deviceMemory", title: "Device Memory", systemImage: "memorychip", tab: .deviceMemory),
            MelsecNavigationNode(id: "deviceInitial", title: "Device Initial Value", systemImage: "number", state: .unused),
        ])
        let parameter = folder("parameter", "Parameter", [
            folder("cpuFolder", "\(project.profile.series)CPU", [
                MelsecNavigationNode(id: "cpuParameter", title: "CPU Parameter", systemImage: "gearshape", tab: .cpuParameter),
                MelsecNavigationNode(id: "moduleParameter", title: "Module Parameter", systemImage: "gearshape.2", state: .unused),
            ]),
        ])
        return [
            MelsecNavigationNode(id: "project", title: "Project", systemImage: "shippingbox", children: [
                MelsecNavigationNode(id: "module", title: "Module Configuration", systemImage: "cpu", tab: .cpuParameter),
                program,
                folder("fbfun", "FB/FUN", []),
                label,
                device,
                parameter,
            ]),
        ]
    }
}

/// A node of the Element Selection window.
nonisolated struct MelsecPaletteNode: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var mnemonic: String?
    var help: String
    var children: [MelsecPaletteNode]?

    /// Instructions grouped by their Element Selection path, filtered by
    /// `search` (mnemonic or help text, case-insensitive).
    static func tree(search: String = "") -> [MelsecPaletteNode] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var groups: [String: [String]] = [:]
        var items: [String: [MelsecPaletteNode]] = [:]
        for definition in MelsecInstructionSet.all {
            guard definition.palette.count >= 2 else { continue }
            if !query.isEmpty, !definition.mnemonic.lowercased().contains(query), !definition.help.lowercased().contains(query) {
                continue
            }
            let top = definition.palette[0]
            let sub = definition.palette[1]
            if groups[top] == nil {
                order.append(top)
                groups[top] = []
            }
            if groups[top]?.contains(sub) == false {
                groups[top]?.append(sub)
            }
            let key = top + "/" + sub
            items[key, default: []].append(MelsecPaletteNode(id: "item:\(definition.mnemonic)", title: definition.mnemonic,
                                                             mnemonic: definition.mnemonic, help: definition.help))
        }
        return order.map { top in
            MelsecPaletteNode(id: "group:\(top)", title: top, help: "", children: (groups[top] ?? []).map { sub in
                MelsecPaletteNode(id: "group:\(top)/\(sub)", title: sub, help: "", children: items[top + "/" + sub] ?? [])
            })
        }
    }

    /// The Ladder Input dialog a palette instruction opens: the symbol and
    /// the text with the mnemonic already typed.
    static func ladderInput(for mnemonic: String) -> (symbol: MelsecLadderSymbol, text: String)? {
        guard let definition = MelsecInstructionSet.definition(mnemonic) else { return nil }
        let hasOperands = definition.forms.contains { !$0.operands.isEmpty }
        let text = definition.mnemonic + (hasOperands ? " " : "")
        switch definition.kind {
        case .contact, .comparison, .operationResult:
            return (.openContact, text)
        case .output:
            return (.coil, text)
        default:
            return (.instruction, text)
        }
    }
}

/// Watch window display formats.
nonisolated enum MelsecDisplayFormat: String, CaseIterable, Hashable, Sendable {
    case decimal = "Decimal"
    case hexadecimal = "Hexadecimal"
    case binary = "Binary"

    /// Formats a value of `type` (bits always show TRUE/FALSE).
    func format(_ value: PLCValue, type: PLCDataType) -> String {
        switch type {
        case .bool:
            return value.boolValue ? "TRUE" : "FALSE"
        case .real, .lreal:
            return RealLiteral.format(value.doubleValue)
        case .time:
            return TimeLiteral.format(milliseconds: value.intValue)
        default:
            let bits = type.bitWidth
            let raw = UInt64(bitPattern: value.intValue) & (bits >= 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1)
            switch self {
            case .decimal:
                return String(value.intValue)
            case .hexadecimal:
                let text = String(raw, radix: 16, uppercase: true)
                return String(repeating: "0", count: max(0, bits / 4 - text.count)) + text + "H"
            case .binary:
                let text = String(raw, radix: 2)
                return String(repeating: "0", count: max(0, bits - text.count)) + text
            }
        }
    }

    /// GX Works3's data type names for the Data Type column.
    static func typeName(_ type: PLCDataType) -> String {
        switch type {
        case .bool: return "Bit"
        case .int: return "Word [Signed]"
        case .dint: return "Double Word [Signed]"
        case .uint, .word: return "Word [Unsigned]/Bit String [16-bit]"
        case .udint, .dword: return "Double Word [Unsigned]/Bit String [32-bit]"
        case .real: return "FLOAT [Single Precision]"
        case .lreal: return "FLOAT [Double Precision]"
        case .time: return "Time"
        default: return type.rawValue
        }
    }
}

/// Data types offered by the Modify Value dialog.
nonisolated enum MelsecModifyType: String, CaseIterable, Hashable, Sendable {
    case bit = "Bit"
    case word = "Word [Signed]"
    case doubleWord = "Double Word [Signed]"
    case float = "FLOAT [Single Precision]"

    var context: MelsecPlaceContext {
        switch self {
        case .bit: return .bit
        case .word: return .word
        case .doubleWord: return .doubleWord
        case .float: return .real
        }
    }
}

/// One row of the Device/Buffer Memory Batch Monitor: 16 bits.
nonisolated struct MelsecBatchRow: Identifiable, Hashable, Sendable {
    var id: String { device }
    var device: String
    /// Bits F…0 as displayed (index 0 = bit F).
    var bits: [Bool]
    var value: Int64
    /// Two ASCII characters (low byte first), "." for non-printables.
    var string: String
    var comment: String
    /// The device each bit cell toggles, index 0 = bit F.
    var bitDevices: [String]

    /// Rows starting at `start` (e.g. "D0", "M0", "X0"); nil when the text is
    /// not a word or bit device.
    static func rows(start text: String, count: Int = 16, memory: MelsecDeviceMemory,
                     comments: (String) -> String?) -> [MelsecBatchRow]? {
        let profile = memory.profile
        guard case let .device(device, nil)? = try? MelsecOperandParser.parse(text, profile: profile) else { return nil }
        var rows: [MelsecBatchRow] = []
        if device.kind.isWordDevice || device.kind.isTimerOrCounter {
            for offset in 0..<count {
                let current = MelsecDevice(device.kind, device.number + offset, facet: device.kind.isTimerOrCounter ? .value : .whole)
                guard profile.contains(current.kind, current.number) else { break }
                let operand = MelsecOperand.device(current, index: nil)
                let value = (try? memory.readInteger(operand, width: .word)) ?? 0
                let raw = UInt16(truncatingIfNeeded: value)
                let name = current.text(profile)
                let bitDevices = (0..<16).reversed().map { bit in
                    current.kind.allowsBitSpecification ? "\(name).\(String(bit, radix: 16, uppercase: true))" : ""
                }
                rows.append(MelsecBatchRow(device: name, bits: (0..<16).reversed().map { (raw >> UInt16($0)) & 1 == 1 },
                                           value: value, string: ascii(raw), comment: comments(name) ?? "", bitDevices: bitDevices))
            }
        } else if device.kind.isBitDevice {
            let base = device.number - device.number % 16
            for offset in 0..<count {
                let start = MelsecDevice(device.kind, base + offset * 16)
                guard profile.contains(start.kind, start.number) else { break }
                var bits: [Bool] = []
                var names: [String] = []
                var raw: UInt16 = 0
                for bit in (0..<16).reversed() {
                    let current = start.advanced(by: bit)
                    let inRange = profile.contains(current.kind, current.number)
                    let isOn = inRange && memory.bit(current.kind, current.number)
                    bits.append(isOn)
                    names.append(inRange ? current.text(profile) : "")
                    if isOn { raw |= UInt16(1) << UInt16(bit) }
                }
                let name = start.text(profile)
                rows.append(MelsecBatchRow(device: name, bits: bits, value: Int64(Int16(bitPattern: raw)), string: ascii(raw),
                                           comment: comments(name) ?? "", bitDevices: names))
            }
        } else {
            return nil
        }
        return rows
    }

    private static func ascii(_ raw: UInt16) -> String {
        [UInt8(raw & 0xFF), UInt8(raw >> 8)].map { byte in
            (32..<127).contains(byte) ? String(UnicodeScalar(byte)) : "."
        }.joined()
    }
}

/// The Program Check dialog's settings.
nonisolated struct MelsecProgramCheckOptions: Hashable, Sendable {
    var categories: Set<MelsecCheckFinding.Category> = Set(MelsecCheckFinding.Category.allCases)
}

/// What the Online Data Operation dialog is doing.
nonisolated enum MelsecOnlineOperation: Hashable, Sendable {
    /// The write that Start Simulation performs.
    case startSimulation
    /// Online › Write to PLC.
    case writeToPLC
    /// Online › Read from PLC.
    case readFromPLC

    var title: String { "Online Data Operation" }
}
