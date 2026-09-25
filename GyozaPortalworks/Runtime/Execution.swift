import Foundation

// The contract between the languages (SCL/ST, LAD/FBD, ladder) and the
// simulated CPU. A compiler turns a block's source into an ExecutableBody,
// resolving names through a SymbolResolver; the CPU runs bodies in Frames.

/// Which vendor's language rules a program follows.
nonisolated enum LanguageDialect: String, Codable, CaseIterable, Hashable, Sendable {
    /// TIA Portal (S7-1200): SCL, LAD, FBD.
    case siemens
    /// GX Works (MELSEC): ST, ladder.
    case melsec
}

/// A compiler message.
nonisolated struct Diagnostic: Hashable, Sendable, Identifiable {
    nonisolated enum Severity: String, Hashable, Sendable {
        case error, warning, information
    }

    var id = UUID()
    var severity: Severity
    var message: String
    /// 1-based position in text source.
    var line: Int?
    var column: Int?
    /// 1-based network (LAD/FBD) or ladder block.
    var network: Int?
    /// The block it belongs to ("Main [OB1]"); the project compiler fills it in.
    var block: String?

    static func error(_ message: String, line: Int? = nil, column: Int? = nil, network: Int? = nil) -> Diagnostic {
        Diagnostic(severity: .error, message: message, line: line, column: column, network: network)
    }

    static func warning(_ message: String, line: Int? = nil, column: Int? = nil, network: Int? = nil) -> Diagnostic {
        Diagnostic(severity: .warning, message: message, line: line, column: column, network: network)
    }
}

/// A name as written in source, before resolution.
nonisolated enum SymbolName: Hashable, Sendable {
    /// `#Start`: the block's own interface (TIA).
    case local(String)
    /// `"Start"`: a PLC tag, data block or other global name (TIA).
    case global(String)
    /// `%I0.0`, `%MW10` (TIA), text including the `%`.
    case absolute(String)
    /// No prefix: `Start`, `X0`, `D100`. TIA looks in the block interface,
    /// then the global tags; GX Works looks up labels, then devices.
    case plain(String)

    var text: String {
        switch self {
        case let .local(name), let .global(name), let .absolute(name), let .plain(name): return name
        }
    }
}

/// Where a block's own variables live while it runs.
nonisolated enum FrameArea: Hashable, Sendable {
    /// Instance data (FB), parameters (FC) or persistent locals (OB, GX
    /// program): Input, Output, InOut, Static and Return.
    case instance
    /// Temp: fresh for every call.
    case temp
}

/// What a name refers to.
nonisolated enum SymbolBinding {
    /// A variable of the block's own interface, at `frame.node(area, index)`.
    case local(area: FrameArea, index: Int, member: PLCMember)
    /// A named constant: a local Constant, a TIA user constant or a GX Works
    /// global constant.
    case constant(name: String, value: PLCValue, type: PLCDataType)
    /// Global storage, fixed for the program's life: a PLC tag, a global data
    /// block, a global label, or an absolute operand (%MW10, D100, X0).
    case global(GlobalSymbol)
}

nonisolated struct GlobalSymbol {
    /// How the editor shows it: "Motor_On", %I0.0, X0, bStart.
    var displayName: String
    var place: Place
    /// False for operands a program may not write (GX Works X inputs).
    var isWritable: Bool

    init(displayName: String, place: Place, isWritable: Bool = true) {
        self.displayName = displayName
        self.place = place
        self.isWritable = isWritable
    }
}

/// A name that is recognizably wrong, e.g. "%I0.8" (bit numbers stop at 7).
nonisolated struct ResolveError: Error, Hashable, Sendable {
    var message: String
}

/// The compile-time view of everything a block's code can name. The project
/// compiler provides one per block; tests can provide their own.
nonisolated protocol SymbolResolver: AnyObject {
    var dialect: LanguageDialect { get }
    /// The block being compiled.
    var block: BlockHandle { get }
    /// Looks up a variable, constant or operand. nil when it isn't declared;
    /// throws ResolveError when it is malformed.
    func resolve(_ name: SymbolName) throws -> SymbolBinding?
    /// A user function (TIA FC, GX Works FUN) or function block, by name.
    func userBlock(named name: String) -> BlockHandle?
    /// An environment instruction callable like a function (GX Works: SET,
    /// RST, OUT_T…); nil if there is none by that name.
    func procedure(named name: String) -> NativeProcedure?
}

/// Compiled code for one block.
nonisolated protocol ExecutableBody: AnyObject {
    func execute(_ frame: Frame) throws
}

/// A block the CPU can call: OB/FC/FB in TIA; program/FUN/FB in GX Works.
nonisolated final class BlockHandle {
    nonisolated enum Kind: String, Hashable, Sendable {
        case organizationBlock = "OB"
        case function = "FC"
        case functionBlock = "FB"
    }

    let name: String
    let kind: Kind
    let number: Int
    /// The whole interface in declaration order.
    let members: [PLCMember]
    /// Frame area `.instance`: Input, Output, InOut, Static and Return.
    let instanceMembers: [PLCMember]
    /// Frame area `.temp`.
    let tempMembers: [PLCMember]
    /// The compiled code; nil until the block compiles without errors.
    var body: ExecutableBody?

    init(name: String, kind: Kind, number: Int, members: [PLCMember]) {
        self.name = name
        self.kind = kind
        self.number = number
        self.members = members
        self.instanceMembers = members.filter { $0.section.frameArea == .instance }
        self.tempMembers = members.filter { $0.section == .temp }
    }

    /// TIA's label for the block: "Main [OB1]", "Motor [FB1]".
    var displayName: String { "\(name) [\(kind.rawValue)\(number)]" }

    /// The instance type of an FB: what its instance DBs and multi-instances hold.
    var functionBlockType: FunctionBlockType? {
        guard kind == .functionBlock else { return nil }
        return FunctionBlockType(name: name, members: instanceMembers, builtIn: nil)
    }

    /// An FC's return value (TIA names it after the block; SCL assigns it
    /// with `#Name := …`).
    var returnValue: (index: Int, member: PLCMember)? {
        guard let index = instanceMembers.firstIndex(where: { $0.section == .returnValue }) else { return nil }
        return (index, instanceMembers[index])
    }

    /// Input, InOut and Output parameters, as a call assigns them.
    var callParameters: [CallParameter] {
        var parameters: [CallParameter] = []
        for (index, member) in instanceMembers.enumerated() where member.section.isParameter {
            parameters.append(CallParameter(name: member.name, section: member.section, type: member.type, memberIndex: index))
        }
        return parameters
    }

    /// Fresh instance-area storage: an FC's parameters for one call, or an OB's
    /// persistent locals. (FB instances are `DataNode(type: .instance(functionBlockType))`.)
    func makeInstanceArea() -> DataNode {
        DataNode(type: .structure(name: nil, members: instanceMembers))
    }

    func makeTemps() -> DataNode {
        DataNode(type: .structure(name: nil, members: tempMembers))
    }

    /// The binding for a name declared in this block's interface.
    func localBinding(_ name: String) -> SymbolBinding? {
        if let index = instanceMembers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return .local(area: .instance, index: index, member: instanceMembers[index])
        }
        if let index = tempMembers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return .local(area: .temp, index: index, member: tempMembers[index])
        }
        if let constant = members.first(where: { $0.section == .constant && $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           let type = constant.type.elementary {
            return .constant(name: constant.name, value: (constant.initialValue ?? type.defaultValue).converted(to: type), type: type)
        }
        return nil
    }
}

/// One running call of a block.
nonisolated final class Frame {
    unowned let context: ExecutionContext
    let block: BlockHandle
    /// Instance data (FB), parameters (FC) or persistent locals (OB).
    let instance: DataNode
    let temps: DataNode
    /// TIA's ENO for this call (SCL `ENO := FALSE;`).
    var enableOutput = true

    init(context: ExecutionContext, block: BlockHandle, instance: DataNode, temps: DataNode) {
        self.context = context
        self.block = block
        self.instance = instance
        self.temps = temps
    }

    func node(_ area: FrameArea, _ index: Int) -> DataNode {
        switch area {
        case .instance: return instance.children[index]
        case .temp: return temps.children[index]
        }
    }

    /// Whether an editor is monitoring this block, so its code should record
    /// what it did this scan.
    var isMonitored: Bool {
        context.monitoredBlocks.contains(ObjectIdentifier(block))
    }
}

/// A run-time error that stops the block: the CPU logs it in the diagnostic
/// buffer and reacts as the vendor's CPU would.
nonisolated struct RuntimeFault: Error, Hashable, Sendable {
    nonisolated enum Kind: String, Hashable, Sendable {
        case indexOutOfRange
        case divisionByZero
        case blockNotLoaded
        case callDepthExceeded
        case cycleTimeExceeded
        case invalidOperation
    }

    var kind: Kind
    var message: String
    /// Where it happened ("Motor [FB1]", "Line 12" / "Network 3"); the
    /// innermost block fills these in.
    var block: String?
    var location: String?

    init(_ kind: Kind, _ message: String, block: String? = nil, location: String? = nil) {
        self.kind = kind
        self.message = message
        self.block = block
        self.location = location
    }
}

/// An environment instruction callable from ST like a function: GX Works'
/// SET/RST/OUT_T and similar.
nonisolated struct NativeProcedure {
    nonisolated enum Argument {
        case value(PLCValue)
        case place(Place)
    }

    nonisolated struct Parameter {
        var name: String
        /// nil = any elementary type.
        var type: PLCDataType?
        /// Needs a writable operand (it is written); otherwise any expression.
        var isOutput: Bool
    }

    var name: String
    var parameters: [Parameter]
    var returnType: PLCDataType?
    var run: ([Argument], Frame) throws -> PLCValue?
}

/// CPU-wide state shared by every block while it runs: the clock, block
/// lookup, call nesting and the loop watchdog.
nonisolated final class ExecutionContext {
    /// S7-1200 allows 16 nested calls from a program cycle OB; leave headroom.
    static let maximumCallDepth = 24
    /// Loop iterations allowed per scan before the watchdog trips, standing in
    /// for the CPU's maximum cycle time (150 ms on an S7-1200).
    static let loopIterationLimit = 1_000_000

    let dialect: LanguageDialect
    /// CPU time in milliseconds since the switch to RUN; timers read it.
    private(set) var clock: Int64 = 0
    private(set) var scanCount: Int64 = 0
    /// Blocks whose code records monitoring information.
    var monitoredBlocks: Set<ObjectIdentifier> = []
    private var blocks: [String: BlockHandle] = [:]
    private var callDepth = 0
    private var loopBudget = ExecutionContext.loopIterationLimit

    init(dialect: LanguageDialect, blocks: [BlockHandle] = []) {
        self.dialect = dialect
        for block in blocks {
            register(block)
        }
    }

    func register(_ block: BlockHandle) {
        blocks[block.name.lowercased()] = block
    }

    func block(named name: String) -> BlockHandle? {
        blocks[name.lowercased()]
    }

    /// Called by the CPU before each cycle.
    func beginScan(clock: Int64) {
        self.clock = clock
        scanCount += 1
        loopBudget = Self.loopIterationLimit
        callDepth = 0
    }

    /// Runs a block with prepared data: the caller writes inputs before and
    /// reads outputs after.
    func run(_ block: BlockHandle, instance: DataNode, temps: DataNode? = nil) throws {
        guard let body = block.body else {
            throw RuntimeFault(.blockNotLoaded, "\(block.displayName) is not loaded in the CPU.", block: block.displayName)
        }
        guard callDepth < Self.maximumCallDepth else {
            throw RuntimeFault(.callDepthExceeded, "Too many nested block calls (is a block calling itself?).", block: block.displayName)
        }
        callDepth += 1
        defer { callDepth -= 1 }
        try body.execute(Frame(context: self, block: block, instance: instance, temps: temps ?? block.makeTemps()))
    }

    /// Calls a function block, built-in or user, on an instance. For generic
    /// IEC_TIMER / IEC_COUNTER instances pass the operation (TON, CTU…).
    func callFunctionBlock(_ type: FunctionBlockType, instance: DataNode, operation: BuiltInFunctionBlock? = nil) throws {
        if type.builtIn != nil {
            FunctionBlockLibrary.execute(type, operation: operation, instance: instance, now: clock)
            return
        }
        guard let block = block(named: type.name) else {
            throw RuntimeFault(.blockNotLoaded, "Function block \"\(type.name)\" is not loaded in the CPU.")
        }
        try run(block, instance: instance)
    }

    /// Counts one loop iteration (FOR, WHILE, REPEAT, backward jumps). Throws
    /// once a scan has looped so long that a real CPU's cycle watchdog fires.
    func countLoopIteration() throws {
        loopBudget -= 1
        if loopBudget < 0 {
            throw RuntimeFault(.cycleTimeExceeded, "Maximum cycle time exceeded: the program looped too long in one scan.")
        }
    }
}
