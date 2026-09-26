import Foundation

/// Everything global a Siemens program can name: PLC tags, user constants,
/// data blocks, absolute operands and user blocks, bound to one CPU memory.
nonisolated final class SiemensSymbolTable {
    let memory: S7Memory
    private var tags: [String: (tag: SiemensTag, address: S7Address)] = [:]
    private var constants: [String: (name: String, value: PLCValue, type: PLCDataType)] = [:]
    private var dataBlocks: [String: (name: String, node: DataNode)] = [:]
    private var blocks: [String: BlockHandle] = [:]

    init(memory: S7Memory) {
        self.memory = memory
    }

    /// Adds a tag; tags with malformed addresses or clashing names are skipped
    /// (the tag table editor reports them).
    func add(_ tag: SiemensTag) {
        let key = tag.name.lowercased()
        guard tags[key] == nil, let address = try? SiemensTagRules.parseTagAddress(tag.address), address.accepts(tag.dataType) else {
            return
        }
        tags[key] = (tag, address)
    }

    func add(_ constant: SiemensUserConstant) {
        let key = constant.name.lowercased()
        guard constants[key] == nil, let value = constant.parsedValue else { return }
        constants[key] = (constant.name, value.converted(to: constant.dataType), constant.dataType)
    }

    func addDataBlock(named name: String, node: DataNode) {
        let key = name.lowercased()
        guard dataBlocks[key] == nil else { return }
        dataBlocks[key] = (name, node)
    }

    func add(_ block: BlockHandle) {
        blocks[block.name.lowercased()] = block
    }

    /// A data block's storage by name.
    func dataBlock(named name: String) -> DataNode? {
        dataBlocks[name.lowercased()]?.node
    }

    func block(named name: String) -> BlockHandle? {
        blocks[name.lowercased()]
    }

    /// A tag and its parsed address.
    func tag(named name: String) -> (tag: SiemensTag, address: S7Address)? {
        tags[name.lowercased()]
    }

    /// Every tag, for "Show all tags" style listings of what the CPU knows.
    var allTags: [SiemensTag] { tags.values.map(\.tag).sorted { $0.name < $1.name } }

    /// A tag, data block or user constant.
    func globalBinding(_ name: String) -> SymbolBinding? {
        let key = name.lowercased()
        if let entry = tags[key] {
            let cell = memory.cell(for: entry.address, type: entry.tag.dataType)
            return .global(GlobalSymbol(displayName: "\"\(entry.tag.name)\"", place: .cell(cell)))
        }
        if let entry = dataBlocks[key] {
            return .global(GlobalSymbol(displayName: "\"\(entry.name)\"", place: .node(entry.node)))
        }
        if let entry = constants[key] {
            return .constant(name: entry.name, value: entry.value, type: entry.type)
        }
        return nil
    }

    /// An absolute operand: "%I0.0", "%MW10", "%QW80:P". Throws TIA-style
    /// errors for malformed or impossible addresses (%I0.8, %DB1.DBX0.0).
    func absoluteBinding(_ text: String) throws -> SymbolBinding {
        let address = try S7Address.parse(text)
        let cell = memory.cell(for: address)
        let writable = !(address.isPeripheral && address.area == .input)
        return .global(GlobalSymbol(displayName: address.description, place: .cell(cell), isWritable: writable))
    }
}

/// The SymbolResolver for one Siemens block: `#x` looks in the block
/// interface, `"x"` in tags, data blocks and user constants, `%…` is an
/// absolute address, and a plain name tries the interface, then the globals.
nonisolated final class SiemensSymbolResolver: SymbolResolver, S7AddressResolving {
    let dialect: LanguageDialect = .siemens
    let block: BlockHandle
    let table: SiemensSymbolTable

    init(block: BlockHandle, table: SiemensSymbolTable) {
        self.block = block
        self.table = table
    }

    func resolve(_ name: SymbolName) throws -> SymbolBinding? {
        switch name {
        case let .local(text):
            return block.localBinding(text)
        case let .global(text):
            return table.globalBinding(text)
        case let .absolute(text):
            return try table.absoluteBinding(text)
        case let .plain(text):
            if let local = block.localBinding(text) { return local }
            if let global = table.globalBinding(text) { return global }
            if S7Address.looksLikeAddress(text) { return try table.absoluteBinding(text) }
            return nil
        }
    }

    func userBlock(named name: String) -> BlockHandle? {
        guard let found = table.block(named: name), found.kind != .organizationBlock else { return nil }
        return found
    }

    func procedure(named name: String) -> NativeProcedure? {
        nil
    }

    func address(of name: SymbolName) -> (address: S7Address, type: PLCDataType)? {
        switch name {
        case .local:
            return nil
        case let .global(text):
            return table.tag(named: text).map { ($0.address, $0.tag.dataType) }
        case let .absolute(text):
            return (try? S7Address.parse(text)).map { ($0, $0.width.defaultType) }
        case let .plain(text):
            if block.localBinding(text) != nil { return nil }
            if let tag = table.tag(named: text) { return (tag.address, tag.tag.dataType) }
            guard S7Address.looksLikeAddress(text) else { return nil }
            return (try? S7Address.parse(text)).map { ($0, $0.width.defaultType) }
        }
    }

    func resolvePeripheral(_ name: SymbolName) throws -> GlobalSymbol? {
        let tagName: String
        switch name {
        case let .global(text): tagName = text
        case let .plain(text):
            if block.localBinding(text) != nil { throw ResolveError(message: S7Messages.peripheralOnlyForIO) }
            tagName = text
        default: return nil
        }
        guard let entry = table.tag(named: tagName) else { return nil }
        guard entry.address.area != .memory else { throw ResolveError(message: S7Messages.peripheralOnlyForIO) }
        var address = entry.address
        address.isPeripheral = true
        let cell = table.memory.cell(for: address, type: entry.tag.dataType)
        return GlobalSymbol(displayName: "\"\(entry.tag.name)\":P", place: .cell(cell), isWritable: address.area == .output)
    }

    func cell(for address: S7Address, type: PLCDataType) -> Cell? {
        table.memory.cell(for: address, type: type)
    }
}
