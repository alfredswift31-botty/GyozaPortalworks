import Foundation

/// An operation error: the CPU stops (STOP, ERROR LED) and logs `message`.
nonisolated struct MelsecOperationError: Error, Hashable, Sendable {
    var message: String
}

/// What a label name stands for at run time.
nonisolated enum MelsecLabelBinding {
    /// A label assigned to a device (Device column of the global label editor).
    case device(MelsecOperand)
    /// Label storage: elementary, array or Timer/Counter structure.
    case node(DataNode, MelsecLabel)
    /// VAR_GLOBAL_CONSTANT / VAR_CONSTANT.
    case constant(PLCValue, PLCDataType)
}

/// The storage behind one label scope: the global labels, or one program's
/// local labels (with the globals as parent).
nonisolated final class MelsecLabelStorage {
    let memory: MelsecDeviceMemory
    let parent: MelsecLabelStorage?
    let labels: [MelsecLabel]
    private var bindings: [String: MelsecLabelBinding] = [:]
    private var owners: [ObjectIdentifier: MelsecTimerCounter] = [:]
    /// Timer/Counter labels of this scope, for STOP→RUN and RESET handling.
    private(set) var timerCounters: [MelsecTimerCounter] = []
    private var nodes: [DataNode] = []

    /// `instance`, when given, holds the labels as members (a program block's
    /// instance area, shared with its ST code); otherwise each label gets a
    /// node of its own.
    init(labels: [MelsecLabel], memory: MelsecDeviceMemory, parent: MelsecLabelStorage? = nil, instance: DataNode? = nil) {
        self.memory = memory
        self.parent = parent
        self.labels = labels
        for label in labels {
            let key = label.name.lowercased()
            if label.labelClass.isConstant {
                let type = label.dataType.elementaryType ?? .int
                bindings[key] = .constant(label.startValue ?? type.defaultValue, type)
                continue
            }
            if label.hasDevice, let operand = try? MelsecOperandParser.parse(label.device, profile: memory.profile) {
                bindings[key] = .device(operand)
                continue
            }
            let node = instance?.member(label.name)
                ?? DataNode(type: label.dataType.plcType, initialValue: label.dataType.elementaryType == nil ? nil : label.startValue)
            nodes.append(node)
            bindings[key] = .node(node, label)
            if let kind = label.dataType.element.timerCounterKind {
                let structures = label.dataType.isArray ? node.children : [node]
                for structure in structures {
                    guard let item = MelsecTimerCounter(kind: kind, label: structure) else { continue }
                    timerCounters.append(item)
                    for part in [structure, item.contact, item.coil, item.value] {
                        owners[ObjectIdentifier(part)] = item
                    }
                }
            }
        }
    }

    func binding(_ name: String) -> MelsecLabelBinding? {
        bindings[name.lowercased()] ?? parent?.binding(name)
    }

    /// The timer or counter (device or label) a node belongs to.
    func timerCounter(for node: DataNode) -> MelsecTimerCounter? {
        memory.owner(of: node) ?? owners[ObjectIdentifier(node)] ?? parent?.timerCounter(for: node)
    }

    /// RESET: labels return to their initial values.
    func reset() {
        for node in nodes {
            node.reset()
        }
        for item in timerCounters {
            item.clear()
        }
    }

    /// The run-time target of a label operand ("lbl", "tm.S").
    func target(forLabel name: String) throws -> MelsecTarget {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let base = parts.first, let binding = binding(base) else {
            throw MelsecOperandError(message: "The label '\(name)' is not declared.")
        }
        let member = parts.count > 1 ? parts[1].uppercased() : nil
        switch binding {
        case let .device(operand):
            guard member == nil else { throw MelsecOperandError(message: "'\(name)': \(base) has no members.") }
            return try MelsecTarget.bind(operand, storage: self)
        case let .constant(value, type):
            guard member == nil else { throw MelsecOperandError(message: "'\(name)': \(base) has no members.") }
            return .value(value.converted(to: type))
        case let .node(node, label):
            if label.dataType.element.timerCounterKind != nil, !label.dataType.isArray {
                guard let item = timerCounter(for: node) else {
                    throw MelsecOperandError(message: "'\(name)' is not a timer or counter.")
                }
                switch member {
                case nil: return .timerCounter(item, .whole)
                case "S": return .timerCounter(item, .contact)
                case "C": return .timerCounter(item, .coil)
                case "N": return .timerCounter(item, .value)
                default: throw MelsecOperandError(message: "'\(name)': \(label.dataType.text) has no member '\(parts[1])'.")
                }
            }
            guard member == nil, let type = label.dataType.elementaryType else {
                throw MelsecOperandError(message: "'\(name)' cannot be used here: use an element or member of it.")
            }
            return .place(.node(node), type)
        }
    }

    /// The place and type of a label for watch windows and ST.
    func place(forLabel name: String) throws -> (place: Place, type: PLCDataType) {
        switch try target(forLabel: name) {
        case let .place(place, type):
            return (place, type)
        case let .timerCounter(item, facet):
            switch facet {
            case .contact, .whole: return (.node(item.contact), .bool)
            case .coil: return (.node(item.coil), .bool)
            case .value: return (.node(item.value), item.isLong ? .udint : .int)
            }
        case let .value(value):
            let type: PLCDataType
            switch value {
            case .bool: type = .bool
            case .real: type = .real
            case .time: type = .time
            case .int: type = .dint
            }
            return (.cell(Cell.constant(value, type: type)), type)
        case let .operand(operand):
            let place = try memory.place(for: operand)
            return (place, place.elementaryType ?? .int)
        case .pointer, .nesting:
            throw MelsecOperandError(message: "'\(name)' is not a value.")
        }
    }
}

/// An operand bound to storage, ready for the interpreter.
nonisolated enum MelsecTarget {
    /// A device, digit specification, bit of a word or constant, read and
    /// written through device memory (index modification is applied there).
    case operand(MelsecOperand)
    case timerCounter(MelsecTimerCounter, MelsecDeviceFacet)
    /// A label's storage.
    case place(Place, PLCDataType)
    /// A constant label.
    case value(PLCValue)
    case pointer(Int)
    case nesting(Int)

    static func bind(_ operand: MelsecOperand, storage: MelsecLabelStorage) throws -> MelsecTarget {
        switch operand {
        case let .label(name):
            return try storage.target(forLabel: name)
        case let .pointer(number):
            return .pointer(number)
        case let .nesting(number):
            return .nesting(number)
        case .unspecified:
            throw MelsecOperandError(message: "An operand has not been entered ('?').")
        case let .device(device, nil) where device.kind.isTimerOrCounter:
            guard let item = storage.memory.timerCounter(device.kind, device.number) else {
                throw MelsecOperandError(message: "'\(operand.text(storage.memory.profile))' is out of range.")
            }
            return .timerCounter(item, device.facet)
        default:
            return .operand(operand)
        }
    }
}

/// Reads and writes bound operands.
nonisolated struct MelsecAccess {
    let memory: MelsecDeviceMemory

    func readBit(_ target: MelsecTarget) throws -> Bool {
        switch target {
        case let .operand(operand):
            return try memory.readBit(operand)
        case let .timerCounter(item, facet):
            switch facet {
            case .whole, .contact: return item.contactState
            case .coil: return item.coilState
            case .value: return item.current != 0
            }
        case let .place(place, _):
            return place.read().boolValue
        case let .value(value):
            return value.boolValue
        case .pointer, .nesting:
            throw MelsecOperationError(message: "A pointer or nesting number is not a bit.")
        }
    }

    func writeBit(_ target: MelsecTarget, _ value: Bool) throws {
        switch target {
        case let .operand(operand):
            try memory.writeBit(operand, value)
        case let .timerCounter(item, facet):
            switch facet {
            case .whole, .contact: item.contact.write(.bool(value))
            case .coil: item.coil.write(.bool(value))
            case .value: item.value.write(.int(value ? 1 : 0))
            }
        case let .place(place, _):
            place.write(.bool(value))
        case .value, .pointer, .nesting:
            throw MelsecOperationError(message: "A constant cannot be written.")
        }
    }

    func readInteger(_ target: MelsecTarget, width: MelsecIntegerWidth) throws -> Int64 {
        switch target {
        case let .operand(operand):
            return try memory.readInteger(operand, width: width)
        case let .timerCounter(item, facet):
            switch facet {
            case .contact: return item.contactState ? 1 : 0
            case .coil: return item.coilState ? 1 : 0
            case .whole, .value: return width.wrap(item.current)
            }
        case let .place(place, _):
            return width.wrap(place.read().intValue)
        case let .value(value):
            return width.wrap(value.intValue)
        case .pointer, .nesting:
            throw MelsecOperationError(message: "A pointer or nesting number is not a value.")
        }
    }

    func writeInteger(_ target: MelsecTarget, width: MelsecIntegerWidth, _ value: Int64) throws {
        switch target {
        case let .operand(operand):
            try memory.writeInteger(operand, width: width, value)
        case let .timerCounter(item, _):
            item.value.write(.int(item.isLong ? Int64(UInt32(truncatingIfNeeded: value)) : Int64(Int16(truncatingIfNeeded: value))))
        case let .place(place, _):
            place.write(.int(width.wrap(value)))
        case .value, .pointer, .nesting:
            throw MelsecOperationError(message: "A constant cannot be written.")
        }
    }

    func readReal(_ target: MelsecTarget) throws -> Double {
        switch target {
        case let .operand(operand):
            return try memory.readReal(operand)
        case let .place(place, _):
            return place.read().doubleValue
        case let .value(value):
            return value.doubleValue
        default:
            return Double(try readInteger(target, width: .doubleWord))
        }
    }

    func writeReal(_ target: MelsecTarget, _ value: Double) throws {
        switch target {
        case let .operand(operand):
            try memory.writeReal(operand, value)
        case let .place(place, _):
            place.write(.real(value))
        default:
            throw MelsecOperationError(message: "A FLOAT value cannot be stored there.")
        }
    }

    func timerCounter(_ target: MelsecTarget) throws -> MelsecTimerCounter {
        switch target {
        case let .timerCounter(item, _):
            return item
        case let .operand(operand):
            if case let .device(device, _) = try memory.resolved(operand), let item = memory.timerCounter(device.kind, device.number) {
                return item
            }
        default:
            break
        }
        throw MelsecOperationError(message: "The operand is not a timer or counter.")
    }

    /// RST: bit OFF, word 0, timer/counter current value and contact cleared.
    func reset(_ target: MelsecTarget, clock: Int64) throws {
        switch target {
        case let .timerCounter(item, facet):
            if facet == .contact || facet == .coil {
                try writeBit(target, false)
            } else {
                item.resetCurrent(at: clock)
            }
        case let .operand(operand):
            switch try memory.resolved(operand) {
            case let .device(device, _):
                if device.kind.isBitDevice {
                    try memory.writeBit(operand, false)
                } else if let item = memory.timerCounter(device.kind, device.number) {
                    item.resetCurrent(at: clock)
                } else {
                    try memory.writeInteger(operand, width: device.kind == .longIndexRegister ? .doubleWord : .word, 0)
                }
            case .wordBit:
                try memory.writeBit(operand, false)
            default:
                try memory.writeInteger(operand, width: .doubleWord, 0)
            }
        case let .place(place, type):
            place.write(type.defaultValue)
        default:
            throw MelsecOperationError(message: "The operand cannot be reset.")
        }
    }
}

/// Timer and counter coils, shared by the ladder (OUT T, OUT C) and the ST
/// functions (OUT_T, OUT_C).
nonisolated enum MelsecTimerLogic {
    /// OUT T / OUTH / OUTHS / OUT ST: while the coil is ON the current value
    /// counts elapsed time in units of `resolution` ms up to the set value;
    /// the contact turns ON when it is reached. Turning the coil OFF clears a
    /// T timer; an ST (retentive) timer keeps its value until RST.
    static func driveTimer(_ timer: MelsecTimerCounter, coil: Bool, setValue: Int64, resolution: Int64, clock: Int64) {
        let wasOn = timer.coilState
        timer.coil.write(.bool(coil))
        guard coil else {
            if !timer.isRetentive {
                timer.value.write(.int(0))
                timer.contact.write(.bool(false))
                timer.residual = 0
            }
            timer.lastUpdate = clock
            return
        }
        if wasOn {
            let elapsed = max(0, clock - timer.lastUpdate)
            timer.residual += elapsed
            let units = timer.residual / max(1, resolution)
            timer.residual %= max(1, resolution)
            let current = timer.current
            if current < setValue {
                timer.value.write(.int(min(current + units, setValue)))
            }
        }
        timer.lastUpdate = clock
        timer.contact.write(.bool(timer.current >= setValue))
    }

    /// OUT C / OUT LC: counts each OFF→ON of the coil up to the set value;
    /// the contact is ON once the count reaches it.
    static func driveCounter(_ counter: MelsecTimerCounter, coil: Bool, setValue: Int64) {
        let wasOn = counter.coilState
        counter.coil.write(.bool(coil))
        let current = counter.current
        if coil, !wasOn, current < setValue {
            counter.value.write(.int(current + 1))
        }
        counter.contact.write(.bool(counter.current >= setValue))
    }

    /// Checks a set value against the device's range.
    static func checkedSetValue(_ value: Int64, for item: MelsecTimerCounter) throws -> Int64 {
        let limit: Int64 = item.isLong ? 4_294_967_295 : 32767
        guard value >= 0, value <= limit else {
            throw MelsecOperationError(message: "The set value \(value) is outside 0 to \(limit).")
        }
        return value
    }
}

/// One bound instruction of a ladder program.
nonisolated struct MelsecBoundInstruction {
    let instruction: MelsecInstruction
    let targets: [MelsecTarget]
    /// An LD that starts a new rung (instead of opening a block for ANB/ORB).
    let startsRung: Bool
    /// CJ / CALL: index of the pointer label.
    let jumpTarget: Int?
}

/// Execution state of one scan of a ladder program.
nonisolated private struct MelsecScanState {
    var accumulator = false
    var blocks: [Bool] = []
    var stack: [Bool] = []
    var masterControl: [Bool?]
    var power = true
    var calls: [(returnIndex: Int, accumulator: Bool, blocks: [Bool], stack: [Bool])] = []

    init(nestingLevels: Int) {
        masterControl = Array(repeating: nil, count: nestingLevels)
    }

    mutating func updatePower() {
        power = masterControl.allSatisfy { $0 ?? true }
    }
}

/// A ladder program loaded into the CPU: bound instructions, per-instruction
/// edge memory for pulse contacts and P instructions, and monitor state.
nonisolated final class MelsecLadderRuntime {
    /// Instructions a scan may execute before the watchdog stops the CPU.
    static let instructionBudget = 2_000_000
    static let maximumStackDepth = 16
    static let maximumCallDepth = 16

    let name: String
    let program: MelsecILProgram
    let stepNumbers: [Int]
    private let instructions: [MelsecBoundInstruction]
    private let memory: MelsecDeviceMemory
    private var edges: [Bool]
    /// Per instruction: contact conducting / instruction executed with its
    /// condition ON, in the last scan. Filled only while monitoring.
    private(set) var energized: [Bool]

    init(name: String, program: MelsecILProgram, storage: MelsecLabelStorage) throws {
        self.name = name
        self.program = program
        self.memory = storage.memory
        stepNumbers = program.stepNumbers
        var pointers: [Int: Int] = [:]
        for (index, instruction) in program.instructions.enumerated() where instruction.definition.kind == .pointerLabel {
            guard case let .pointer(number)? = instruction.operands.first else { continue }
            if pointers[number] != nil {
                throw MelsecOperationError(message: "\(name): the pointer P\(number) is used more than once.")
            }
            pointers[number] = index
        }
        var bound: [MelsecBoundInstruction] = []
        var previousIsLogic = false
        for (index, instruction) in program.instructions.enumerated() {
            var targets: [MelsecTarget] = []
            for operand in instruction.operands {
                do {
                    targets.append(try MelsecTarget.bind(operand, storage: storage))
                } catch let error as MelsecOperandError {
                    throw MelsecOperationError(message: "\(name), step \(stepNumbers[index]) (\(instruction.text(storage.memory.profile))): \(error.message)")
                }
            }
            var jump: Int?
            if instruction.definition.kind == .jump || instruction.definition.kind == .call {
                guard case let .pointer(number)? = instruction.operands.first, let target = pointers[number] else {
                    throw MelsecOperationError(message: "\(name), step \(stepNumbers[index]): the jump destination \(instruction.operands.first?.text(storage.memory.profile) ?? "P?") does not exist.")
                }
                jump = target
            }
            let isLoad: Bool
            let isLogic: Bool
            switch instruction.definition.kind {
            case let .contact(_, position), let .comparison(_, _, position):
                isLoad = position == .load
                isLogic = true
            case .blockAnd, .blockOr, .push, .read, .pop, .operationResult:
                isLoad = false
                isLogic = true
            default:
                isLoad = false
                isLogic = false
            }
            bound.append(MelsecBoundInstruction(instruction: instruction, targets: targets,
                                                startsRung: isLoad && !previousIsLogic, jumpTarget: jump))
            previousIsLogic = isLogic
        }
        instructions = bound
        edges = Array(repeating: false, count: bound.count)
        energized = Array(repeating: false, count: bound.count)
    }

    /// Forgets pulse history (STOP→RUN, RESET).
    func resetEdges() {
        for index in edges.indices {
            edges[index] = false
        }
    }

    /// Runs the program once. Throws MelsecOperationError for operation
    /// errors; the message names the program, step and instruction.
    func execute(clock: Int64, monitoring: Bool) throws {
        let access = MelsecAccess(memory: memory)
        var state = MelsecScanState(nestingLevels: memory.profile.nestingLevels)
        var budget = MelsecLadderRuntime.instructionBudget
        if monitoring {
            for index in energized.indices { energized[index] = false }
        }
        var index = 0
        while index < instructions.count {
            budget -= 1
            if budget < 0 {
                throw MelsecOperationError(message: "Watchdog timer error in \(name): the scan did not reach END (does a CJ jump backwards forever?).")
            }
            let bound = instructions[index]
            do {
                guard let next = try step(index, bound, &state, access: access, clock: clock, monitoring: monitoring) else {
                    return
                }
                index = next
            } catch let error as MelsecOperationError {
                throw MelsecOperationError(message: describe(index, bound, error.message))
            } catch let error as MelsecOperandError {
                throw MelsecOperationError(message: describe(index, bound, error.message))
            }
        }
    }

    private func describe(_ index: Int, _ bound: MelsecBoundInstruction, _ message: String) -> String {
        "Operation error in \(name) at step \(stepNumbers[index]) (\(bound.instruction.text(memory.profile))): \(message)"
    }

    /// Executes one instruction; returns the next index, or nil at END/FEND.
    private func step(_ index: Int, _ bound: MelsecBoundInstruction, _ state: inout MelsecScanState,
                      access: MelsecAccess, clock: Int64, monitoring: Bool) throws -> Int? {
        let definition = bound.instruction.definition
        let targets = bound.targets
        var next = index + 1

        func combine(_ position: MelsecLogicPosition, _ value: Bool) {
            switch position {
            case .load:
                if bound.startsRung {
                    state.blocks.removeAll()
                } else {
                    state.blocks.append(state.accumulator)
                }
                state.accumulator = state.power && value
            case .and:
                state.accumulator = state.accumulator && value
            case .or:
                state.accumulator = state.accumulator || (state.power && value)
            }
        }

        /// The condition of an output: ON while the operation result is ON,
        /// or only on its rising edge for pulse (P) instructions.
        func fires() -> Bool {
            let condition = state.accumulator
            guard definition.isPulse else { return condition }
            let fired = condition && !edges[index]
            edges[index] = condition
            return fired
        }

        let first = targets.first ?? .value(.bool(false))

        switch definition.kind {
        case let .contact(kind, position):
            let raw = try access.readBit(first)
            let conducts: Bool
            switch kind {
            case .normallyOpen:
                conducts = raw
            case .normallyClosed:
                conducts = !raw
            case .risingEdge:
                conducts = raw && !edges[index]
                edges[index] = raw
            case .fallingEdge:
                conducts = !raw && edges[index]
                edges[index] = raw
            case .risingEdgeNegated:
                conducts = !(raw && !edges[index])
                edges[index] = raw
            case .fallingEdgeNegated:
                conducts = !(!raw && edges[index])
                edges[index] = raw
            }
            combine(position, conducts)
            if monitoring { energized[index] = conducts }
            return next

        case let .comparison(op, width, position):
            guard targets.count == 2 else { throw MelsecOperationError(message: "Two operands are needed.") }
            let result: Bool
            if let integerWidth = width.integerWidth {
                result = PLCOperations.compare(op, .int(try access.readInteger(targets[0], width: integerWidth)),
                                               .int(try access.readInteger(targets[1], width: integerWidth)))
            } else {
                result = PLCOperations.compare(op, .real(try access.readReal(targets[0])), .real(try access.readReal(targets[1])))
            }
            combine(position, result)
            if monitoring { energized[index] = result }
            return next

        case .blockAnd, .blockOr:
            guard let block = state.blocks.popLast() else {
                throw MelsecOperationError(message: "\(definition.mnemonic) has no ladder block to connect.")
            }
            state.accumulator = definition.kind == .blockAnd ? block && state.accumulator : block || state.accumulator
        case .push:
            guard state.stack.count < MelsecLadderRuntime.maximumStackDepth else {
                throw MelsecOperationError(message: "MPS is nested more than \(MelsecLadderRuntime.maximumStackDepth) levels.")
            }
            state.stack.append(state.accumulator)
        case .read:
            guard let top = state.stack.last else { throw MelsecOperationError(message: "MRD without MPS.") }
            state.accumulator = top
        case .pop:
            guard let top = state.stack.popLast() else { throw MelsecOperationError(message: "MPP without MPS.") }
            state.accumulator = top
        case let .operationResult(kind):
            switch kind {
            case .invert:
                state.accumulator = !state.accumulator && state.power
            case .risingPulse:
                let pulse = state.accumulator && !edges[index]
                edges[index] = state.accumulator
                state.accumulator = pulse
            case .fallingPulse:
                let pulse = !state.accumulator && edges[index]
                edges[index] = state.accumulator
                state.accumulator = pulse && state.power
            }

        case .output:
            if targets.count == 2 {
                let item = try access.timerCounter(first)
                let setValue = try MelsecTimerLogic.checkedSetValue(
                    try access.readInteger(targets[1], width: item.isLong ? .doubleWord : .word), for: item)
                if item.kind.isTimer {
                    MelsecTimerLogic.driveTimer(item, coil: state.accumulator, setValue: setValue, resolution: 100, clock: clock)
                } else {
                    MelsecTimerLogic.driveCounter(item, coil: state.accumulator, setValue: setValue)
                }
            } else {
                try access.writeBit(first, state.accumulator)
            }
        case let .timerOutput(resolution):
            guard targets.count == 2 else { throw MelsecOperationError(message: "The set value is missing.") }
            let item = try access.timerCounter(first)
            let setValue = try MelsecTimerLogic.checkedSetValue(try access.readInteger(targets[1], width: .word), for: item)
            MelsecTimerLogic.driveTimer(item, coil: state.accumulator, setValue: setValue, resolution: resolution, clock: clock)
        case .set:
            if state.accumulator { try access.writeBit(first, true) }
        case .reset:
            if state.accumulator { try access.reset(first, clock: clock) }
        case .pulseRising:
            try access.writeBit(first, state.accumulator && !edges[index])
            edges[index] = state.accumulator
        case .pulseFalling:
            try access.writeBit(first, !state.accumulator && edges[index])
            edges[index] = state.accumulator
        case .flipFlop:
            if state.accumulator && !edges[index] {
                try access.writeBit(first, !(try access.readBit(first)))
            }
            edges[index] = state.accumulator
        case .alternate:
            if fires() {
                try access.writeBit(first, !(try access.readBit(first)))
            }
        case .masterControl:
            guard case let .nesting(level) = first, state.masterControl.indices.contains(level), targets.count == 2 else {
                throw MelsecOperationError(message: "MC needs a nesting number and a coil.")
            }
            try access.writeBit(targets[1], state.accumulator)
            state.masterControl[level] = state.accumulator
            state.updatePower()
        case .masterControlReset:
            guard case let .nesting(level) = first, state.masterControl.indices.contains(level) else {
                throw MelsecOperationError(message: "MCR needs a nesting number.")
            }
            for nested in level..<state.masterControl.count {
                state.masterControl[nested] = nil
            }
            state.updatePower()
        case .jump:
            if state.accumulator, let target = bound.jumpTarget {
                next = target
            }
        case .call:
            if fires(), let target = bound.jumpTarget {
                guard state.calls.count < MelsecLadderRuntime.maximumCallDepth else {
                    throw MelsecOperationError(message: "Subroutine calls are nested more than \(MelsecLadderRuntime.maximumCallDepth) levels.")
                }
                state.calls.append((index + 1, state.accumulator, state.blocks, state.stack))
                state.blocks = []
                state.stack = []
                next = target
            }
        case .subroutineReturn:
            guard let frame = state.calls.popLast() else {
                throw MelsecOperationError(message: "RET was executed without CALL (is FEND missing before the subroutine?).")
            }
            state.accumulator = frame.accumulator
            state.blocks = frame.blocks
            state.stack = frame.stack
            next = frame.returnIndex
        case .mainProgramEnd:
            if !state.calls.isEmpty {
                throw MelsecOperationError(message: "FEND was reached inside a subroutine: RET is missing.")
            }
            return nil
        case .end:
            if !state.calls.isEmpty {
                throw MelsecOperationError(message: "END was reached inside a subroutine: RET is missing.")
            }
            return nil
        case .noOperation, .pointerLabel:
            break
        case let .data(operation):
            if fires() {
                try MelsecDataExecutor(access: access, clock: clock).execute(operation, bound.instruction, targets)
            }
        }
        if monitoring, definition.isOutput {
            energized[index] = state.accumulator || definition.isUnconditional
        }
        return next
    }
}

/// Application instructions: transfer, arithmetic, conversion, logic,
/// rotation, shift and comparison output.
nonisolated private struct MelsecDataExecutor {
    let access: MelsecAccess
    let clock: Int64

    private var memory: MelsecDeviceMemory { access.memory }

    func execute(_ operation: MelsecDataOperation, _ instruction: MelsecInstruction, _ targets: [MelsecTarget]) throws {
        func target(_ position: Int) throws -> MelsecTarget {
            guard targets.indices.contains(position) else {
                throw MelsecOperationError(message: "An operand is missing.")
            }
            return targets[position]
        }
        switch operation {
        case let .move(width):
            if let integerWidth = width.integerWidth {
                try access.writeInteger(try target(1), width: integerWidth, try access.readInteger(try target(0), width: integerWidth))
            } else {
                try access.writeReal(try target(1), try access.readReal(try target(0)))
            }
        case .blockMove:
            try blockMove(instruction, fill: false, targets)
        case .fillMove:
            try blockMove(instruction, fill: true, targets)
        case .zoneReset:
            try zoneReset(instruction)
        case let .arithmetic(op, width):
            try arithmetic(op, width, instruction, targets)
        case let .increment(width), let .decrement(width):
            let delta: Int64
            if case .increment = operation { delta = 1 } else { delta = -1 }
            let value = try access.readInteger(try target(0), width: width)
            try access.writeInteger(try target(0), width: width, width.wrap(value + delta))
        case let .negate(width):
            let value = try access.readInteger(try target(0), width: width)
            try access.writeInteger(try target(0), width: width, width.wrap(-value))
        case let .toBCD(width):
            let value = try access.readInteger(try target(0), width: width)
            let limit: Int64 = width == .word ? 9999 : 99_999_999
            guard value >= 0, value <= limit else {
                throw MelsecOperationError(message: "BCD conversion error: \(value) is outside 0 to \(limit).")
            }
            var remaining = value
            var result: Int64 = 0
            var shift: Int64 = 0
            while remaining > 0 {
                result |= (remaining % 10) << shift
                remaining /= 10
                shift += 4
            }
            try access.writeInteger(try target(1), width: width, width.wrap(result))
        case let .fromBCD(width):
            let raw = try access.readInteger(try target(0), width: width) & (width == .word ? 0xFFFF : 0xFFFF_FFFF)
            var result: Int64 = 0
            var multiplier: Int64 = 1
            var remaining = raw
            for _ in 0..<(width.bitCount / 4) {
                let digit = remaining & 0xF
                guard digit <= 9 else {
                    let digits = width == .word ? 4 : 8
                    let text = String(raw, radix: 16, uppercase: true)
                    throw MelsecOperationError(message: "BCD conversion error: H\(String(repeating: "0", count: max(0, digits - text.count)) + text) is not a BCD value (each digit must be 0 to 9).")
                }
                result += digit * multiplier
                multiplier *= 10
                remaining >>= 4
            }
            try access.writeInteger(try target(1), width: width, result)
        case let .integerToFloat(width):
            try access.writeReal(try target(1), Double(try access.readInteger(try target(0), width: width)))
        case let .floatToInteger(width):
            let value = try access.readReal(try target(0))
            let rounded = value.rounded(.toNearestOrAwayFromZero)
            let range: ClosedRange<Double> = width == .word ? -32768...32767 : -2_147_483_648...2_147_483_647
            guard rounded.isFinite, range.contains(rounded) else {
                throw MelsecOperationError(message: "\(RealLiteral.format(value)) is outside the \(width.bitCount)-bit integer range.")
            }
            try access.writeInteger(try target(1), width: width, Int64(rounded))
        case let .logic(op, width):
            let type = width.dataType
            let lhs: Int64
            let rhs: Int64
            let destination: MelsecTarget
            if targets.count == 2 {
                lhs = try access.readInteger(try target(1), width: width)
                rhs = try access.readInteger(try target(0), width: width)
                destination = try target(1)
            } else {
                lhs = try access.readInteger(try target(0), width: width)
                rhs = try access.readInteger(try target(1), width: width)
                destination = try target(2)
            }
            let result = PLCOperations.bitLogic(op, .int(lhs), .int(rhs), as: type)
            try access.writeInteger(destination, width: width, width.wrap(result.intValue))
        case let .rotate(left, throughCarry, width):
            try rotate(left: left, throughCarry: throughCarry, width: width, targets)
        case let .shiftBits(left):
            try shiftBits(left: left, instruction)
        case .shiftOne:
            guard case let .device(device, index)? = instruction.operands.first, device.number > 0 else {
                throw MelsecOperationError(message: "SFT needs a bit device after the first one (e.g. M1).")
            }
            let previous = MelsecOperand.device(device.advanced(by: -1), index: index)
            try memory.writeBit(.device(device, index: index), try memory.readBit(previous))
            try memory.writeBit(previous, false)
        case let .compare(width):
            let order = try compare(width, try target(0), try target(1))
            try writeBits(instruction, operandIndex: 2, [order > 0, order == 0, order < 0])
        case let .zoneCompare(width):
            let low = try compare(width, try target(0), try target(1))
            guard low <= 0 else {
                throw MelsecOperationError(message: "The lower limit s1 is greater than the upper limit s2.")
            }
            let below = try compare(width, try target(2), try target(0)) < 0
            let above = try compare(width, try target(2), try target(1)) > 0
            try writeBits(instruction, operandIndex: 3, [below, !below && !above, above])
        }
    }

    /// -1, 0 or 1 comparing a with b.
    private func compare(_ width: MelsecValueWidth, _ a: MelsecTarget, _ b: MelsecTarget) throws -> Int {
        if let integerWidth = width.integerWidth {
            let lhs = try access.readInteger(a, width: integerWidth)
            let rhs = try access.readInteger(b, width: integerWidth)
            return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        }
        let lhs = try access.readReal(a)
        let rhs = try access.readReal(b)
        return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
    }

    private func writeBits(_ instruction: MelsecInstruction, operandIndex: Int, _ values: [Bool]) throws {
        guard instruction.operands.indices.contains(operandIndex) else { throw MelsecOperationError(message: "An operand is missing.") }
        let start = instruction.operands[operandIndex]
        for (offset, value) in values.enumerated() {
            guard let operand = start.advanced(bits: offset) else {
                throw MelsecOperationError(message: "\(start.text(memory.profile)) has no following devices.")
            }
            try checkInRange(operand)
            try memory.writeBit(operand, value)
        }
    }

    private func checkInRange(_ operand: MelsecOperand) throws {
        if case let .device(device, nil) = operand, !memory.profile.contains(device.kind, device.number) {
            throw MelsecOperationError(message: "\(device.kind.rawValue)\(memory.profile.format(device.number, for: device.kind)) is outside the device range (\(memory.profile.rangeText(device.kind))).")
        }
        if case let .wordBit(device, _) = operand, !memory.profile.contains(device.kind, device.number) {
            throw MelsecOperationError(message: "The bit is outside the device range (\(memory.profile.rangeText(device.kind))).")
        }
    }

    private func arithmetic(_ op: ArithmeticOperator, _ width: MelsecValueWidth, _ instruction: MelsecInstruction, _ targets: [MelsecTarget]) throws {
        let lhsTarget: MelsecTarget
        let rhsTarget: MelsecTarget
        let destination: MelsecTarget
        if targets.count == 2 {
            lhsTarget = targets[1]
            rhsTarget = targets[0]
            destination = targets[1]
        } else if targets.count == 3 {
            lhsTarget = targets[0]
            rhsTarget = targets[1]
            destination = targets[2]
        } else {
            throw MelsecOperationError(message: "Wrong number of operands.")
        }
        guard let integerWidth = width.integerWidth else {
            let result = PLCOperations.arithmetic(op, .real(try access.readReal(lhsTarget)), .real(try access.readReal(rhsTarget)), as: .real)
            if op == .divide, try access.readReal(rhsTarget) == 0 {
                throw MelsecOperationError(message: "Division by 0.")
            }
            guard result.isValid else {
                throw MelsecOperationError(message: "The result is outside the FLOAT range.")
            }
            try access.writeReal(destination, result.value.doubleValue)
            return
        }
        let lhs = try access.readInteger(lhsTarget, width: integerWidth)
        let rhs = try access.readInteger(rhsTarget, width: integerWidth)
        switch op {
        case .add, .subtract:
            let result = PLCOperations.arithmetic(op, .int(lhs), .int(rhs), as: integerWidth.dataType)
            try access.writeInteger(destination, width: integerWidth, result.value.intValue)
        case .multiply:
            // 16 × 16 → 32 bits in d, d+1; 32 × 32 → 64 bits in d … d+3.
            let product = lhs * rhs
            if integerWidth == .word {
                try access.writeInteger(destination, width: .doubleWord, product)
            } else {
                try writeWide(instruction, destination, [product & 0xFFFF_FFFF, product >> 32])
            }
        case .divide:
            guard rhs != 0 else { throw MelsecOperationError(message: "Division by 0.") }
            let quotient = integerWidth.wrap(lhs / rhs)
            let remainder = integerWidth.wrap(lhs % rhs)
            if integerWidth == .word {
                try writeWideWords(instruction, destination, [quotient, remainder], width: .word)
            } else {
                try writeWide(instruction, destination, [quotient, remainder])
            }
        case .modulo, .power:
            throw MelsecOperationError(message: "Unsupported operation.")
        }
    }

    /// Writes 32-bit values to d, d+2, … (D* and D/ results).
    private func writeWide(_ instruction: MelsecInstruction, _ destination: MelsecTarget, _ values: [Int64]) throws {
        try writeWideWords(instruction, destination, values, width: .doubleWord)
    }

    private func writeWideWords(_ instruction: MelsecInstruction, _ destination: MelsecTarget, _ values: [Int64], width: MelsecIntegerWidth) throws {
        guard case let .operand(operand) = destination else {
            throw MelsecOperationError(message: "The result needs consecutive word devices.")
        }
        let step = width == .word ? 1 : 2
        for (offset, value) in values.enumerated() {
            guard let part = operand.advanced(words: offset * step) else {
                throw MelsecOperationError(message: "The result needs consecutive word devices.")
            }
            try checkInRange(part)
            try memory.writeInteger(part, width: width, value)
        }
    }

    private func blockMove(_ instruction: MelsecInstruction, fill: Bool, _ targets: [MelsecTarget]) throws {
        guard targets.count == 3, instruction.operands.count == 3 else { throw MelsecOperationError(message: "Wrong number of operands.") }
        let count = try access.readInteger(targets[2], width: .word)
        guard count >= 0 else { throw MelsecOperationError(message: "The number of words n (\(count)) is negative.") }
        guard count > 0 else { return }
        let source = try memory.resolved(instruction.operands[0])
        let destination = try memory.resolved(instruction.operands[1])
        func item(_ operand: MelsecOperand, _ offset: Int) throws -> MelsecOperand {
            guard let moved = operand.advanced(words: offset) else {
                throw MelsecOperationError(message: "\(instruction.mnemonic) needs device operands.")
            }
            try checkInRange(moved)
            return moved
        }
        let total = Int(count)
        _ = try item(destination, total - 1)
        if fill {
            let value = try access.readInteger(targets[0], width: .word)
            for offset in 0..<total {
                try memory.writeInteger(try item(destination, offset), width: .word, value)
            }
            return
        }
        _ = try item(source, total - 1)
        var values: [Int64] = []
        for offset in 0..<total {
            values.append(try memory.readInteger(try item(source, offset), width: .word))
        }
        for offset in 0..<total {
            try memory.writeInteger(try item(destination, offset), width: .word, values[offset])
        }
    }

    private func zoneReset(_ instruction: MelsecInstruction) throws {
        guard instruction.operands.count == 2,
              case let .device(first, _) = try memory.resolved(instruction.operands[0]),
              case let .device(last, _) = try memory.resolved(instruction.operands[1]) else {
            throw MelsecOperationError(message: "ZRST needs two devices.")
        }
        guard first.kind == last.kind, first.facet == last.facet else {
            throw MelsecOperationError(message: "ZRST needs two devices of the same type.")
        }
        // As on the FX3: when d1 > d2 only d1 is reset.
        let end = max(first.number, last.number) == first.number ? first.number : last.number
        for number in first.number...end {
            let device = MelsecDevice(first.kind, number, facet: first.facet)
            if first.kind.isBitDevice {
                memory.setBit(first.kind, number, false)
            } else if let item = memory.timerCounter(first.kind, number) {
                item.resetCurrent(at: clock)
            } else {
                try memory.writeInteger(.device(device, index: nil), width: .word, 0)
            }
        }
    }

    private func rotate(left: Bool, throughCarry: Bool, width: MelsecIntegerWidth, _ targets: [MelsecTarget]) throws {
        guard targets.count == 2 else { throw MelsecOperationError(message: "Wrong number of operands.") }
        let count = try access.readInteger(targets[1], width: .word)
        guard count >= 0 else { throw MelsecOperationError(message: "The number of bits n (\(count)) is negative.") }
        let bits = Int64(width.bitCount)
        let mask: Int64 = width == .word ? 0xFFFF : 0xFFFF_FFFF
        var value = try access.readInteger(targets[0], width: width) & mask
        var carry = memory.bit(.specialRelay, MelsecSpecialDevices.carryFlag)
        if throughCarry {
            let size = bits + 1
            let steps = count % size
            guard steps > 0 else { return }
            var combined = value | ((carry ? 1 : 0) << bits)
            let fullMask = (Int64(1) << size) - 1
            combined = left
                ? ((combined << steps) | (combined >> (size - steps))) & fullMask
                : ((combined >> steps) | (combined << (size - steps))) & fullMask
            value = combined & mask
            carry = (combined >> bits) & 1 == 1
        } else {
            let steps = count % bits
            guard steps > 0 else { return }
            value = left
                ? ((value << steps) | (value >> (bits - steps))) & mask
                : ((value >> steps) | (value << (bits - steps))) & mask
            carry = left ? value & 1 == 1 : (value >> (bits - 1)) & 1 == 1
        }
        try access.writeInteger(targets[0], width: width, width.wrap(value))
        memory.setBit(.specialRelay, MelsecSpecialDevices.carryFlag, carry)
    }

    private func shiftBits(left: Bool, _ instruction: MelsecInstruction) throws {
        guard instruction.operands.count == 4 else { throw MelsecOperationError(message: "Wrong number of operands.") }
        let length = Int(try memory.readInteger(instruction.operands[2], width: .word))
        let shift = Int(try memory.readInteger(instruction.operands[3], width: .word))
        guard length > 0, shift >= 0, shift <= length else {
            throw MelsecOperationError(message: "n2 (\(shift)) must be between 0 and n1 (\(length)), and n1 must be at least 1.")
        }
        guard shift > 0 else { return }
        let source = try memory.resolved(instruction.operands[0])
        let destination = try memory.resolved(instruction.operands[1])
        func bit(_ operand: MelsecOperand, _ offset: Int) throws -> MelsecOperand {
            guard let moved = operand.advanced(bits: offset) else {
                throw MelsecOperationError(message: "\(instruction.mnemonic) needs bit devices.")
            }
            try checkInRange(moved)
            return moved
        }
        var old: [Bool] = []
        for offset in 0..<length {
            old.append(try memory.readBit(try bit(destination, offset)))
        }
        var incoming: [Bool] = []
        for offset in 0..<shift {
            incoming.append(try memory.readBit(try bit(source, offset)))
        }
        var result = old
        for position in 0..<length {
            if left {
                result[position] = position >= shift ? old[position - shift] : incoming[position]
            } else {
                result[position] = position < length - shift ? old[position + shift] : incoming[position - (length - shift)]
            }
        }
        for (offset, value) in result.enumerated() {
            try memory.writeBit(try bit(destination, offset), value)
        }
    }
}
