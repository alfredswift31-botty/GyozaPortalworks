import Foundation

/// An editor tab in the work area.
nonisolated enum SiemensEditorTab: Hashable, Sendable {
    case block(UUID)
    case dataBlock(UUID)
    case dataType(UUID)
    case tagTable(UUID)
    case allTags
    case watchTable(UUID)
    case forceTable
    case deviceConfiguration
    case onlineDiagnostics

    var id: String {
        switch self {
        case let .block(id): return "block-" + id.uuidString
        case let .dataBlock(id): return "db-" + id.uuidString
        case let .dataType(id): return "udt-" + id.uuidString
        case let .tagTable(id): return "tags-" + id.uuidString
        case .allTags: return "all-tags"
        case let .watchTable(id): return "watch-" + id.uuidString
        case .forceTable: return "force"
        case .deviceConfiguration: return "device"
        case .onlineDiagnostics: return "diagnostics"
        }
    }
}

/// The "Add new block" dialog.
nonisolated struct SiemensNewBlockRequest: Hashable, Sendable {
    nonisolated enum Kind: String, CaseIterable, Hashable, Sendable {
        case organizationBlock = "Organization block"
        case functionBlock = "Function block"
        case function = "Function"
        case dataBlock = "Data block"

        /// The letters on the dialog's big buttons.
        var shortTitle: String {
            switch self {
            case .organizationBlock: return "OB"
            case .functionBlock: return "FB"
            case .function: return "FC"
            case .dataBlock: return "DB"
            }
        }

        var blockKind: SiemensBlockKind? {
            switch self {
            case .organizationBlock: return .organizationBlock
            case .functionBlock: return .functionBlock
            case .function: return .function
            case .dataBlock: return nil
            }
        }
    }

    static let globalDB = "Global DB"
    static let systemTypes = ["IEC_TIMER", "IEC_COUNTER", "IEC_DCOUNTER", "IEC_UCOUNTER", "TON_TIME", "TOF_TIME", "TP_TIME",
                              "TONR_TIME", "CTU_INT", "CTD_INT", "CTUD_INT", "R_TRIG", "F_TRIG"]

    var kind: Kind
    var name: String
    var language: SiemensLanguage
    var isNumberAutomatic = true
    var number: Int
    var event: SiemensOBEvent = .programCycle
    /// Data blocks: "Global DB", an FB name (instance DB) or a system type.
    var dataBlockType = SiemensNewBlockRequest.globalDB
    var openAfterAdding = true

    /// What the dialog shows when a block type is picked.
    static func defaults(_ kind: Kind, in project: SiemensProject) -> SiemensNewBlockRequest {
        let names = project.blockNames
        switch kind {
        case .dataBlock:
            return SiemensNewBlockRequest(kind: kind, name: SiemensNaming.unique("Data_block_1", among: names, style: .counting),
                                          language: .lad, number: project.nextFreeDataBlockNumber())
        default:
            let blockKind = kind.blockKind ?? .function
            return SiemensNewBlockRequest(kind: kind, name: SiemensNaming.unique("Block_1", among: names, style: .counting),
                                          language: .lad, number: project.nextFreeNumber(for: blockKind))
        }
    }

    /// The types in the DB dialog's Type list.
    static func dataBlockTypes(in project: SiemensProject) -> [String] {
        [globalDB] + project.blocks.filter { $0.kind == .functionBlock }.map(\.name) + systemTypes
    }

    /// Why "OK" is disabled, or nil.
    func problem(in project: SiemensProject) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return S7Messages.emptyName }
        if trimmed.contains("\"") { return S7Messages.quotesInName }
        if project.blockNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return S7Messages.nameUsedTwice(trimmed)
        }
        if !isNumberAutomatic {
            if kind == .dataBlock {
                if project.dataBlocks.contains(where: { $0.number == number }) { return "The number \(number) is already in use." }
            } else if let blockKind = kind.blockKind {
                if project.blocks.contains(where: { $0.kind == blockKind && $0.number == number }) {
                    return "The number \(number) is already in use."
                }
                if blockKind == .organizationBlock && !event.allows(number) {
                    return "OB number \(number) is not permitted for the event class \"\(event.rawValue)\"."
                }
            }
            if number < 1 || number > 59_999 { return "The number must be between 1 and 59999." }
        }
        return nil
    }

    /// Adds the block; returns the tab to open.
    func apply(to project: inout SiemensProject) -> SiemensEditorTab? {
        guard problem(in: project) == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if kind == .dataBlock {
            let number = isNumberAutomatic ? project.nextFreeDataBlockNumber() : self.number
            var dataBlock: SiemensDataBlock
            if dataBlockType == Self.globalDB {
                dataBlock = SiemensDataBlock(name: trimmed, number: number)
            } else if project.blocks.contains(where: { $0.kind == .functionBlock && $0.name == dataBlockType }) {
                dataBlock = SiemensDataBlock(name: trimmed, number: number, kind: .instance, instanceOf: dataBlockType)
            } else {
                let counter = dataBlockType.contains("COUNTER") || dataBlockType.hasPrefix("CT")
                dataBlock = SiemensDataBlock(name: trimmed, number: number, kind: .systemInstance, instanceOf: dataBlockType, isRetain: counter)
            }
            dataBlock.isNumberAutomatic = isNumberAutomatic
            project.dataBlocks.append(dataBlock)
            return .dataBlock(dataBlock.id)
        }
        guard let blockKind = kind.blockKind else { return nil }
        let number = isNumberAutomatic ? project.nextFreeNumber(for: blockKind, event: event) : self.number
        var title = ""
        if blockKind == .organizationBlock && number == event.standardNumber { title = event.standardTitle }
        let block = SiemensBlock(name: trimmed, kind: blockKind, number: number, language: language, event: event,
                                 isNumberAutomatic: isNumberAutomatic, title: title)
        project.blocks.append(block)
        return .block(block.id)
    }
}

/// The "Call options" dialog TIA opens when a timer, counter, R_TRIG/F_TRIG
/// or FB box is placed: single instance (an instance DB) or multi-instance
/// (a Static of the calling FB).
nonisolated struct SiemensCallOptions: Hashable, Sendable {
    nonisolated enum Mode: String, Hashable, Sendable {
        case singleInstance = "Single instance"
        case multiInstance = "Multi instance"
    }

    var blockID: UUID
    var network: UUID
    var element: UUID
    var instruction: S7Instruction
    /// The FB for a call box.
    var calledBlock: String
    var dataType: PLCDataType?
    var mode: Mode
    var name: String
    var isNumberAutomatic = true
    var number: Int
    /// Only function blocks can hold multi-instances.
    var allowsMultiInstance: Bool

    /// The dialog for a box just placed, or nil when it needs no instance.
    static func proposal(for box: S7Box, in block: SiemensBlock, network: UUID, project: SiemensProject) -> SiemensCallOptions? {
        let needsInstance = box.instruction.needsInstance
            || (box.instruction == .call && project.block(named: box.calledBlock)?.kind == .functionBlock)
        guard needsInstance else { return nil }
        var options = SiemensCallOptions(blockID: block.id, network: network, element: box.id, instruction: box.instruction,
                                         calledBlock: box.calledBlock, dataType: box.dataType, mode: .singleInstance, name: "",
                                         number: project.nextFreeDataBlockNumber(), allowsMultiInstance: block.kind == .functionBlock)
        options.name = options.proposedName(for: .singleInstance, block: block, project: project)
        return options
    }

    /// IEC_Timer_0_DB, IEC_Timer_0_DB_1…; Motor_DB; multi-instances end in "_Instance".
    func proposedName(for mode: Mode, block: SiemensBlock, project: SiemensProject) -> String {
        let multi = mode == .multiInstance
        let base = instruction == .call
            ? calledBlock + (multi ? "_Instance" : "_DB")
            : (instruction.instanceNameBase(multiInstance: multi) ?? "Instance")
        let existing = multi ? block.interface.allNames : project.blockNames
        return SiemensNaming.unique(base, among: existing, style: .underscore)
    }

    mutating func switchMode(to newMode: Mode, block: SiemensBlock, project: SiemensProject) {
        guard newMode == .singleInstance || allowsMultiInstance else { return }
        mode = newMode
        name = proposedName(for: newMode, block: block, project: project)
    }

    /// Why OK is disabled, or nil.
    func problem(in project: SiemensProject, block: SiemensBlock) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return S7Messages.emptyName }
        if trimmed.contains("\"") { return S7Messages.quotesInName }
        let taken = mode == .multiInstance ? block.interface.allNames : project.blockNames
        if taken.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return S7Messages.nameUsedTwice(trimmed) }
        if mode == .singleInstance, !isNumberAutomatic, project.dataBlocks.contains(where: { $0.number == number }) {
            return "The number \(number) is already in use."
        }
        return nil
    }

    /// Creates the instance and writes it above the box. Returns the operand.
    @discardableResult
    func apply(to project: inout SiemensProject) -> String? {
        guard let blockIndex = project.blocks.firstIndex(where: { $0.id == blockID }),
              problem(in: project, block: project.blocks[blockIndex]) == nil
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let operand: String
        switch mode {
        case .singleInstance:
            let number = isNumberAutomatic ? project.nextFreeDataBlockNumber() : self.number
            var dataBlock: SiemensDataBlock
            if instruction == .call {
                dataBlock = SiemensDataBlock(name: trimmed, number: number, kind: .instance, instanceOf: calledBlock)
            } else {
                dataBlock = SiemensDataBlock(name: trimmed, number: number, kind: .systemInstance,
                                             instanceOf: instruction.instanceTypeName(dataType: dataType) ?? "IEC_TIMER",
                                             isRetain: instruction.isCounter, isCreatedAutomatically: true)
            }
            dataBlock.isNumberAutomatic = isNumberAutomatic
            project.dataBlocks.append(dataBlock)
            operand = "\"\(trimmed)\""
        case .multiInstance:
            let type = instruction == .call ? "\"\(calledBlock)\"" : (instruction.multiInstanceTypeName(dataType: dataType) ?? "TON_TIME")
            project.blocks[blockIndex].interface.staticVariables.append(
                SiemensVariable(trimmed, type, retain: instruction.isCounter ? .retain : .nonRetain))
            operand = "#" + trimmed
        }
        if let networkIndex = project.blocks[blockIndex].networks.firstIndex(where: { $0.id == network }) {
            project.blocks[blockIndex].networks[networkIndex].setOperand(operand, of: element, slot: .instance)
        }
        return operand
    }
}

/// A confirmation TIA asks for before acting.
nonisolated enum SiemensConfirmation: Hashable, Sendable {
    case startCPU
    case stopCPU
    case memoryReset
    case forceAll

    var title: String {
        switch self {
        case .startCPU: return "Start module"
        case .stopCPU: return "Stop module"
        case .memoryReset: return "Memory reset"
        case .forceAll: return "Force"
        }
    }

    var message: String {
        switch self {
        case .startCPU: return "Do you really want to start the module PLC_1?"
        case .stopCPU: return "Do you really want to stop the module PLC_1?"
        case .memoryReset: return "Do you really want to perform a memory reset on PLC_1? The CPU goes to STOP."
        case .forceAll:
            return "DANGER: Forcing changes the process. Unexpected machine motion can cause death, severe injury or damage. Do you want to force the selected addresses?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .forceAll: return "Force"
        default: return "OK"
        }
    }
}

/// The steps of TIA's download: Extended download → Load preview → Load results.
nonisolated enum SiemensLoadStep: Hashable, Sendable {
    /// "Extended download to device": pick the PG/PC interface and search.
    case extendedDownload(searched: Bool)
    /// "Load preview": what will happen, with "Stop modules" when the CPU runs.
    case loadPreview(stopModules: Bool)
    /// "Load results", with "Start all".
    case loadResults(startAll: Bool)
}

/// How the online program compares with the project.
nonisolated enum SiemensOnlineStatus: Hashable, Sendable {
    /// Green: online and offline are identical.
    case identical
    /// Orange: they differ.
    case different
    /// Only in the project.
    case offlineOnly
}
