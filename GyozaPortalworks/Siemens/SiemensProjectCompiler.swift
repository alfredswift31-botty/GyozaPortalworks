import Foundation

/// A line of Info › Compile, the way TIA lists them: device, folder, block,
/// then the block's messages, ending with "Compiling finished (…)".
nonisolated struct SiemensCompileMessage: Hashable, Identifiable, Sendable {
    var id = UUID()
    var severity: Diagnostic.Severity
    /// "PLC_1", "Program blocks", "Main (OB1)"… (the Path column).
    var path: String
    /// The Description column.
    var text: String
    /// Indentation in the list: 0 device, 1 folder, 2 block, 3 message.
    var level: Int
    /// Where "Go to" leads.
    var blockID: UUID?
    var network: Int?
    var line: Int?
    var column: Int?
}

/// The outcome of compiling a project.
nonisolated struct SiemensCompileResult {
    /// The project after TIA's automatic work: numbers assigned, unused
    /// system instance DBs removed.
    var project: SiemensProject
    var messages: [SiemensCompileMessage]
    /// Errors and warnings with their block ("Main [OB1]") filled in.
    var diagnostics: [Diagnostic]
    /// What can be downloaded; nil when there are errors.
    var image: SiemensCPUImage?

    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
    var succeeded: Bool { errorCount == 0 }
    /// "Compiling finished (errors: 0; warnings: 0)".
    var summary: String { S7Messages.compilingFinished(errors: errorCount, warnings: warningCount) }
}

/// Everything a download puts into the CPU: memory, data blocks and code.
nonisolated final class SiemensCPUImage {
    let device: SiemensDevice
    let memory: S7Memory
    let context: ExecutionContext
    let symbols: SiemensSymbolTable
    /// Every OB, FC and FB, by number within kind.
    let blocks: [BlockHandle]
    /// Program cycle OBs in number order.
    let cycleBlocks: [BlockHandle]
    /// Startup OBs in number order.
    let startupBlocks: [BlockHandle]
    /// Data blocks: name, layout and storage.
    let dataBlocks: [(name: String, type: PLCType, node: DataNode)]
    private let organizationLocals: [ObjectIdentifier: DataNode]
    /// Whether any retentive data is configured (the OBs' Remanence input).
    let hasRetentiveData: Bool

    init(device: SiemensDevice, memory: S7Memory, symbols: SiemensSymbolTable, blocks: [BlockHandle],
         startupNumbers: Set<Int>, dataBlocks: [(name: String, type: PLCType, node: DataNode)]) {
        self.device = device
        self.memory = memory
        self.symbols = symbols
        self.blocks = blocks
        self.context = ExecutionContext(dialect: .siemens, blocks: blocks)
        let organizationBlocks = blocks.filter { $0.kind == .organizationBlock }.sorted { $0.number < $1.number }
        startupBlocks = organizationBlocks.filter { startupNumbers.contains($0.number) }
        cycleBlocks = organizationBlocks.filter { !startupNumbers.contains($0.number) }
        self.dataBlocks = dataBlocks
        var locals: [ObjectIdentifier: DataNode] = [:]
        for block in organizationBlocks {
            locals[ObjectIdentifier(block)] = block.makeInstanceArea()
        }
        organizationLocals = locals
        var retentive = device.retentiveMarkerBytes > 0
        for entry in dataBlocks where !retentive {
            retentive = entry.node.leaves().contains { leaf in leaf.node.isRetain }
        }
        hasRetentiveData = retentive
    }

    func block(named name: String) -> BlockHandle? {
        blocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// An OB's persistent locals (its Input section: Initial_Call, Remanence…).
    func locals(of block: BlockHandle) -> DataNode {
        organizationLocals[ObjectIdentifier(block)] ?? block.makeInstanceArea()
    }

    func dataBlock(named name: String) -> DataNode? {
        dataBlocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.node
    }

    /// The LAD/FBD monitor of a block; nil for SCL blocks.
    func monitor(ofBlock name: String) -> S7BlockMonitor? {
        (block(named: name)?.body as? S7TrackedBody)?.monitor
    }
}

/// Compiles a whole project the way "Compile › Software (only changes)" does,
/// and builds the image to download.
nonisolated struct SiemensProjectCompiler {
    /// Compiles SCL source; provided by the ST/SCL engine. Without it SCL
    /// blocks report "The SCL compiler is not available."
    var compileSCL: ((String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]))?

    init(compileSCL: ((String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]))? = nil) {
        self.compileSCL = compileSCL
    }

    func compile(_ original: SiemensProject) -> SiemensCompileResult {
        var project = original
        var messages: [SiemensCompileMessage] = []
        var diagnostics: [Diagnostic] = []
        let deviceName = project.device.name

        func report(_ diagnostic: Diagnostic, owner: String, blockID: UUID? = nil) {
            var tagged = diagnostic
            tagged.block = owner
            diagnostics.append(tagged)
            messages.append(SiemensCompileMessage(severity: diagnostic.severity, path: owner, text: diagnostic.message, level: 3,
                                                  blockID: blockID, network: diagnostic.network, line: diagnostic.line,
                                                  column: diagnostic.column))
        }

        messages.append(SiemensCompileMessage(severity: .information, path: deviceName, text: "", level: 0))

        // Consistency work TIA does before compiling.
        let usedNames = Self.referencedGlobalNames(in: project)
        project.dataBlocks.removeAll { $0.kind == .systemInstance && $0.isCreatedAutomatically && !usedNames.contains($0.name.lowercased()) }
        Self.assignNumbers(&project)

        // PLC tags.
        let tagIssues = project.tagIssues
        if !tagIssues.isEmpty {
            messages.append(SiemensCompileMessage(severity: .information, path: "PLC tags", text: "", level: 1))
            for table in project.tagTables {
                let ids = Set(table.tags.map(\.id) + table.constants.map(\.id))
                for issue in tagIssues where ids.contains(issue.rowID) {
                    report(.error(issue.message), owner: table.name)
                }
            }
        }

        // PLC data types.
        let environment = SiemensTypeEnvironment(dataTypes: project.dataTypes, blocks: project.blocks)
        var typeMessages: [(String, Diagnostic)] = []
        for udt in project.dataTypes {
            do {
                _ = try environment.dataType(named: udt.name)
            } catch let problem as ResolveError {
                typeMessages.append((udt.name, .error(problem.message)))
            } catch {
                typeMessages.append((udt.name, .error(error.localizedDescription)))
            }
        }
        if !typeMessages.isEmpty {
            messages.append(SiemensCompileMessage(severity: .information, path: "PLC data types", text: "", level: 1))
            for (name, diagnostic) in typeMessages { report(diagnostic, owner: name) }
        }

        // Duplicate names and numbers.
        var structural: [UUID: [Diagnostic]] = [:]
        var seenNames: [String: UUID] = [:]
        for block in project.blocks {
            if seenNames[block.name.lowercased()] != nil { structural[block.id, default: []].append(.error(S7Messages.nameUsedTwice(block.name))) }
            seenNames[block.name.lowercased()] = block.id
            if block.kind == .organizationBlock && !block.event.allows(block.number) {
                structural[block.id, default: []].append(.error("OB number \(block.number) is not permitted for the event class \"\(block.event.rawValue)\"."))
            }
            if project.blocks.contains(where: { $0.id != block.id && $0.kind == block.kind && $0.number == block.number }) {
                structural[block.id, default: []].append(.error(S7Messages.numberUsedTwice(block.displayName)))
            }
        }
        for block in project.dataBlocks {
            if seenNames[block.name.lowercased()] != nil { structural[block.id, default: []].append(.error(S7Messages.nameUsedTwice(block.name))) }
            seenNames[block.name.lowercased()] = block.id
            if project.dataBlocks.contains(where: { $0.id != block.id && $0.number == block.number }) {
                structural[block.id, default: []].append(.error(S7Messages.numberUsedTwice(block.displayName)))
            }
        }

        // Storage and symbols.
        let memory = S7Memory()
        let table = SiemensSymbolTable(memory: memory)
        for entry in project.allTags { table.add(entry.tag) }
        for entry in project.allConstants { table.add(entry.constant) }

        var handles: [UUID: BlockHandle] = [:]
        var interfaceErrors: [UUID: [Diagnostic]] = [:]
        for block in project.blocks {
            let interface = environment.interfaceMembers(of: block)
            for problem in interface.errors {
                interfaceErrors[block.id, default: []].append(.error("\(problem.row): \(problem.message)"))
            }
            let handle = BlockHandle(name: block.name, kind: block.kind.handleKind, number: block.number, members: interface.members)
            handles[block.id] = handle
            table.add(handle)
        }

        var dataBlockNodes: [(name: String, type: PLCType, node: DataNode)] = []
        var dataBlockErrors: [UUID: [Diagnostic]] = [:]
        for dataBlock in project.dataBlocks {
            do {
                let (type, node) = try Self.storage(for: dataBlock, project: project, environment: environment)
                table.addDataBlock(named: dataBlock.name, node: node)
                dataBlockNodes.append((dataBlock.name, type, node))
            } catch let problem as ResolveError {
                dataBlockErrors[dataBlock.id, default: []].append(.error(problem.message))
            } catch {
                dataBlockErrors[dataBlock.id, default: []].append(.error(error.localizedDescription))
            }
        }

        // Program blocks.
        messages.append(SiemensCompileMessage(severity: .information, path: "Program blocks", text: "", level: 1))
        let ordered = project.blocks.sorted { lhs, rhs in
            let order: [SiemensBlockKind] = [.organizationBlock, .functionBlock, .function]
            let left = order.firstIndex(of: lhs.kind) ?? 0
            let right = order.firstIndex(of: rhs.kind) ?? 0
            return left != right ? left < right : lhs.number < rhs.number
        }
        for block in ordered {
            guard let handle = handles[block.id] else { continue }
            messages.append(SiemensCompileMessage(severity: .information, path: block.treeLabel, text: "", level: 2, blockID: block.id))
            var blockDiagnostics = (structural[block.id] ?? []) + (interfaceErrors[block.id] ?? [])
            let resolver = SiemensSymbolResolver(block: handle, table: table)
            var body: ExecutableBody?
            if block.language.usesNetworks {
                let compiler = S7NetworkCompiler(resolver: resolver)
                body = compiler.compile(block.networks)
                blockDiagnostics += compiler.diagnostics
                let unconfigured = compiler.operands.usedAddresses.contains { !project.device.isConfigured($0.address, type: $0.type) }
                if unconfigured { blockDiagnostics.append(.warning(S7Messages.ioNotConfigured)) }
            } else if let compileSCL {
                let (compiled, sclDiagnostics) = compileSCL(block.source, resolver)
                body = compiled
                blockDiagnostics += sclDiagnostics
            } else {
                blockDiagnostics.append(.error(S7Messages.sclNotAvailable))
            }
            if !blockDiagnostics.contains(where: { $0.severity == .error }), let body {
                handle.body = S7TrackedBody(body)
            }
            for diagnostic in blockDiagnostics {
                report(diagnostic, owner: block.displayName, blockID: block.id)
            }
            if !blockDiagnostics.contains(where: { $0.severity == .error }) {
                messages.append(SiemensCompileMessage(severity: .information, path: block.treeLabel, text: S7Messages.blockCompiled,
                                                      level: 3, blockID: block.id))
            }
        }
        for dataBlock in project.dataBlocks.sorted(by: { $0.number < $1.number }) {
            let problems = (structural[dataBlock.id] ?? []) + (dataBlockErrors[dataBlock.id] ?? [])
            let label = "\(dataBlock.name) (DB\(dataBlock.number))"
            messages.append(SiemensCompileMessage(severity: .information, path: label, text: "", level: 2, blockID: dataBlock.id))
            for diagnostic in problems {
                report(diagnostic, owner: dataBlock.displayName, blockID: dataBlock.id)
            }
            if problems.isEmpty {
                messages.append(SiemensCompileMessage(severity: .information, path: label, text: S7Messages.blockCompiled, level: 3,
                                                      blockID: dataBlock.id))
            }
        }
        if !project.blocks.contains(where: { $0.kind == .organizationBlock && $0.event == .programCycle }) {
            report(.warning("The program has no program cycle OB; the CPU will not go to RUN."), owner: deviceName)
        }

        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.filter { $0.severity == .warning }.count
        messages.append(SiemensCompileMessage(severity: errors > 0 ? .error : (warnings > 0 ? .warning : .information),
                                              path: deviceName, text: S7Messages.compilingFinished(errors: errors, warnings: warnings), level: 0))

        var image: SiemensCPUImage?
        if errors == 0 {
            let startupNumbers = Set(project.blocks.filter { $0.kind == .organizationBlock && $0.event == .startup }.map(\.number))
            let allHandles = project.blocks.compactMap { handles[$0.id] }
            image = SiemensCPUImage(device: project.device, memory: memory, symbols: table, blocks: allHandles,
                                    startupNumbers: startupNumbers, dataBlocks: dataBlockNodes)
        }
        return SiemensCompileResult(project: project, messages: messages, diagnostics: diagnostics, image: image)
    }

    // MARK: - Helpers

    /// The layout and storage of a data block.
    static func storage(for dataBlock: SiemensDataBlock, project: SiemensProject,
                        environment: SiemensTypeEnvironment) throws -> (PLCType, DataNode) {
        switch dataBlock.kind {
        case .global:
            var members: [PLCMember] = []
            var seen: Set<String> = []
            for variable in dataBlock.members {
                guard seen.insert(variable.name.lowercased()).inserted else {
                    throw ResolveError(message: S7Messages.nameUsedTwice(variable.name))
                }
                let type = try environment.type(of: variable)
                members.append(PLCMember(variable.name, type, section: .staticVar,
                                         initialValue: try environment.startValue(variable.startValue, for: type),
                                         isRetain: variable.retain == .retain))
            }
            let type = PLCType.structure(name: nil, members: members)
            return (type, DataNode(type: type))
        case .instance:
            guard let functionBlock = try environment.functionBlockType(named: dataBlock.instanceOf) else {
                throw ResolveError(message: S7Messages.blockNotDefined(dataBlock.instanceOf))
            }
            // Members declared "Set in IDB" take the instance DB's retentivity.
            let setInIDB = Set((project.block(named: dataBlock.instanceOf)?.interface).map { interface in
                (interface.input + interface.output + interface.inOut + interface.staticVariables)
                    .filter { $0.retain == .setInIDB }.map { $0.name.lowercased() }
            } ?? [])
            var members = functionBlock.members
            for index in members.indices where setInIDB.contains(members[index].name.lowercased()) {
                members[index].isRetain = dataBlock.isRetain
            }
            let type = PLCType.instance(FunctionBlockType(name: functionBlock.name, members: members, builtIn: nil))
            return (type, DataNode(type: type))
        case .systemInstance:
            guard let system = FunctionBlockLibrary.type(named: dataBlock.instanceOf, dialect: .siemens) else {
                throw ResolveError(message: S7Messages.dataTypeNotDefined(dataBlock.instanceOf))
            }
            let type = PLCType.instance(system)
            return (type, DataNode(type: type, isRetain: dataBlock.isRetain))
        }
    }

    /// Gives blocks with automatic numbering the next free number when theirs is taken.
    static func assignNumbers(_ project: inout SiemensProject) {
        for index in project.blocks.indices where project.blocks[index].isNumberAutomatic {
            let block = project.blocks[index]
            // The later of two automatically numbered blocks moves; a manual number always wins.
            let clash = project.blocks.indices.contains { other in
                other != index && project.blocks[other].kind == block.kind && project.blocks[other].number == block.number
                    && (other < index || !project.blocks[other].isNumberAutomatic)
            }
            let invalid = block.kind == .organizationBlock && !block.event.allows(block.number)
            guard clash || invalid else { continue }
            var candidate = project.blocks
            candidate.remove(at: index)
            var copy = project
            copy.blocks = candidate
            project.blocks[index].number = copy.nextFreeNumber(for: block.kind, event: block.event)
        }
        for index in project.dataBlocks.indices where project.dataBlocks[index].isNumberAutomatic {
            let number = project.dataBlocks[index].number
            let clash = project.dataBlocks.indices.contains { other in
                other != index && project.dataBlocks[other].number == number
                    && (other < index || !project.dataBlocks[other].isNumberAutomatic)
            }
            guard clash else { continue }
            var copy = project
            copy.dataBlocks.remove(at: index)
            project.dataBlocks[index].number = copy.nextFreeDataBlockNumber()
        }
    }

    /// Global names (lowercased) that LAD/FBD operands and SCL sources mention,
    /// to find system instance DBs nothing uses any more.
    static func referencedGlobalNames(in project: SiemensProject) -> Set<String> {
        var names: Set<String> = []
        func note(_ text: String) {
            guard let path = try? S7OperandParser.parse(text) else { return }
            switch path.root {
            case let .global(name), let .plain(name): names.insert(name.lowercased())
            default: break
            }
        }
        func walk(_ path: S7Path) {
            for node in path.items {
                switch node {
                case let .contact(contact):
                    note(contact.operand)
                    note(contact.secondOperand)
                case let .coil(coil):
                    note(coil.operand)
                    note(coil.secondOperand)
                case let .box(box):
                    note(box.instance)
                    note(box.operand)
                    for pin in box.inputs + box.outputs {
                        switch pin.source {
                        case let .operand(text): note(text)
                        case let .branch(branch): walk(branch)
                        }
                    }
                case let .parallel(group), let .fanOut(group):
                    group.branches.forEach(walk)
                }
            }
        }
        for block in project.blocks {
            block.networks.forEach { $0.rungs.forEach(walk) }
            var remaining = Substring(block.source)
            while let open = remaining.firstIndex(of: "\"") {
                let rest = remaining[remaining.index(after: open)...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                names.insert(rest[..<close].lowercased())
                remaining = rest[rest.index(after: close)...]
            }
        }
        return names
    }
}
