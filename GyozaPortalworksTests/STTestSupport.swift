import Foundation
import Testing
@testable import GyozaPortalworks

/// A symbol table for tests: the block interface, global tags and data
/// blocks, absolute operands / devices, constants, user blocks and procedures.
final class STTestResolver: SymbolResolver {
    let dialect: LanguageDialect
    let block: BlockHandle
    var globals: [String: GlobalSymbol] = [:]
    var constants: [String: (value: PLCValue, type: PLCDataType)] = [:]
    var absolutes: [String: GlobalSymbol] = [:]
    var blocks: [String: BlockHandle] = [:]
    var procedures: [String: NativeProcedure] = [:]

    init(dialect: LanguageDialect, block: BlockHandle) {
        self.dialect = dialect
        self.block = block
    }

    /// A global tag or data block.
    @discardableResult
    func addGlobal(_ name: String, _ type: PLCType, initialValue: PLCValue? = nil, isWritable: Bool = true) -> DataNode {
        let node = DataNode(type: type, initialValue: initialValue)
        globals[name.lowercased()] = GlobalSymbol(displayName: name, place: .node(node), isWritable: isWritable)
        return node
    }

    /// An absolute operand (`%MW10`) or GX Works device (`D0`, `X0`).
    @discardableResult
    func addAbsolute(_ name: String, _ type: PLCDataType, isWritable: Bool = true) -> DataNode {
        let node = DataNode(type: .elementary(type))
        absolutes[name.uppercased()] = GlobalSymbol(displayName: name, place: .node(node), isWritable: isWritable)
        return node
    }

    func resolve(_ name: SymbolName) throws -> SymbolBinding? {
        switch name {
        case let .local(text):
            return block.localBinding(text)
        case let .global(text):
            return global(text)
        case let .absolute(text):
            if let symbol = absolutes[text.uppercased()] { return .global(symbol) }
            throw ResolveError(message: "\(text) is not a valid address.")
        case let .plain(text):
            if let local = block.localBinding(text) { return local }
            if let binding = global(text) { return binding }
            return absolutes[text.uppercased()].map { .global($0) }
        }
    }

    private func global(_ text: String) -> SymbolBinding? {
        if let constant = constants.first(where: { $0.key.caseInsensitiveCompare(text) == .orderedSame }) {
            return .constant(name: constant.key, value: constant.value.value, type: constant.value.type)
        }
        return globals[text.lowercased()].map { .global($0) }
    }

    func userBlock(named name: String) -> BlockHandle? {
        blocks[name.lowercased()]
    }

    func procedure(named name: String) -> NativeProcedure? {
        procedures[name.uppercased()]
    }
}

/// A block compiled from ST source, loaded in a CPU context, ready to scan.
final class STRun {
    let resolver: STTestResolver
    let block: BlockHandle
    let context: ExecutionContext
    let instance: DataNode
    let program: STProgram
    let diagnostics: [Diagnostic]

    private init(resolver: STTestResolver, block: BlockHandle, context: ExecutionContext, instance: DataNode,
                 program: STProgram, diagnostics: [Diagnostic]) {
        self.resolver = resolver
        self.block = block
        self.context = context
        self.instance = instance
        self.program = program
        self.diagnostics = diagnostics
    }

    /// Compiles `source` as the body of "Main [OB1]" (or `kind`); records an
    /// issue and returns nil when it doesn't compile.
    static func make(_ source: String, _ members: [PLCMember] = [], dialect: LanguageDialect = .siemens,
                     kind: BlockHandle.Kind = .organizationBlock, name: String = "Main",
                     configure: (STTestResolver) -> Void = { _ in },
                     sourceLocation: SourceLocation = #_sourceLocation) -> STRun? {
        let block = BlockHandle(name: name, kind: kind, number: 1, members: members)
        let resolver = STTestResolver(dialect: dialect, block: block)
        configure(resolver)
        let result = STCompiler.compile(source, resolver: resolver)
        guard let program = result.program else {
            let messages = result.diagnostics.map { "\($0.line ?? 0):\($0.column ?? 0) \($0.message)" }
            Issue.record("Compile failed: \(messages)", sourceLocation: sourceLocation)
            return nil
        }
        block.body = program
        let context = ExecutionContext(dialect: dialect, blocks: [block] + Array(resolver.blocks.values))
        let instance: DataNode
        if let type = block.functionBlockType {
            instance = DataNode(type: .instance(type))
        } else {
            instance = block.makeInstanceArea()
        }
        return STRun(resolver: resolver, block: block, context: context, instance: instance, program: program,
                     diagnostics: result.diagnostics)
    }

    /// One CPU cycle at `clock`.
    func scan(clock: Int64 = 0) throws {
        context.beginScan(clock: clock)
        try context.run(block, instance: instance)
    }

    func monitor() {
        context.monitoredBlocks.insert(ObjectIdentifier(block))
    }

    /// An interface variable by path: `x`, `s.a`, `values[2]`.
    subscript(_ path: String) -> PLCValue? {
        node(path)?.read()
    }

    func node(_ path: String) -> DataNode? {
        STRun.node(path, in: instance)
    }

    func write(_ path: String, _ value: PLCValue) {
        node(path)?.write(value)
    }

    static func node(_ path: String, in root: DataNode) -> DataNode? {
        var current: DataNode? = root
        for part in path.split(separator: ".") {
            var name = Substring(part)
            var index: Int?
            if let open = part.firstIndex(of: "["), let close = part.firstIndex(of: "]") {
                name = part[..<open]
                index = Int(part[part.index(after: open)..<close])
            }
            current = current?.member(String(name))
            if let index { current = current?.element(index) }
        }
        return current
    }
}

/// Compile-only helpers.
enum ST {
    static func compile(_ source: String, _ members: [PLCMember] = [], dialect: LanguageDialect = .siemens,
                        kind: BlockHandle.Kind = .organizationBlock,
                        configure: (STTestResolver) -> Void = { _ in }) -> (program: STProgram?, diagnostics: [Diagnostic]) {
        let block = BlockHandle(name: "Main", kind: kind, number: 1, members: members)
        let resolver = STTestResolver(dialect: dialect, block: block)
        configure(resolver)
        return STCompiler.compile(source, resolver: resolver)
    }

    /// The error messages of a compile.
    static func errors(_ source: String, _ members: [PLCMember] = [], dialect: LanguageDialect = .siemens,
                       configure: (STTestResolver) -> Void = { _ in }) -> [String] {
        compile(source, members, dialect: dialect, configure: configure).diagnostics.filter { $0.severity == .error }.map(\.message)
    }

    /// Runs `r := <expression>;` once and returns r.
    static func evaluate(_ expression: String, as type: PLCDataType, dialect: LanguageDialect = .siemens,
                         _ members: [PLCMember] = [], sourceLocation: SourceLocation = #_sourceLocation) -> PLCValue? {
        guard let run = STRun.make("r := \(expression);", [PLCMember("r", .elementary(type))] + members, dialect: dialect,
                                   sourceLocation: sourceLocation)
        else { return nil }
        do {
            try run.scan()
        } catch {
            Issue.record("Run failed: \(error)", sourceLocation: sourceLocation)
            return nil
        }
        return run["r"]
    }

    static func member(_ name: String, _ type: PLCDataType, _ section: VariableSection = .staticVar,
                       _ initialValue: PLCValue? = nil) -> PLCMember {
        PLCMember(name, .elementary(type), section: section, initialValue: initialValue)
    }

    /// A user block compiled from source against its own interface.
    static func userBlock(_ name: String, kind: BlockHandle.Kind, number: Int = 2, members: [PLCMember], source: String,
                          dialect: LanguageDialect = .siemens, sourceLocation: SourceLocation = #_sourceLocation) -> BlockHandle {
        let block = BlockHandle(name: name, kind: kind, number: number, members: members)
        let resolver = STTestResolver(dialect: dialect, block: block)
        let result = STCompiler.compile(source, resolver: resolver)
        if result.program == nil {
            Issue.record("Block \(name) failed to compile: \(result.diagnostics.map(\.message))", sourceLocation: sourceLocation)
        }
        block.body = result.program
        return block
    }
}
