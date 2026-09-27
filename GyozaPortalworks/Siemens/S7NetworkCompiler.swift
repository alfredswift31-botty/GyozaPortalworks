import Foundation

/// Compiles LAD/FBD networks into executable code, checking TIA's placement
/// rules and operands on the way. Every problem becomes a Diagnostic tagged
/// with its network number; code is only produced when there are none.
nonisolated final class S7NetworkCompiler {
    let resolver: SymbolResolver
    let operands: S7OperandCompiler
    private(set) var diagnostics: [Diagnostic] = []
    /// Global names used as instances (IEC_Timer_0_DB, Motor_DB), for the
    /// project compiler's clean-up of unused instance DBs.
    private(set) var usedInstances: Set<String> = []
    private var networkNumber = 0

    init(resolver: SymbolResolver) {
        self.resolver = resolver
        self.operands = S7OperandCompiler(resolver: resolver)
    }

    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// Compiles a block's networks; nil when there are errors.
    func compile(_ networks: [S7Network], monitor: S7BlockMonitor = S7BlockMonitor()) -> S7NetworkBody? {
        var compiled: [S7CompiledNetwork] = []
        for (index, network) in networks.enumerated() {
            networkNumber = index + 1
            let rungs = network.rungs.filter { !$0.items.isEmpty }
            let flows = rungs.map {
                compilePath($0, S7PathContext(startsAtRail: true, mustTerminate: true, contactsOnly: false))
            }
            compiled.append(S7CompiledNetwork(number: networkNumber, rungs: flows))
        }
        return hasErrors ? nil : S7NetworkBody(networks: compiled, monitor: monitor)
    }

    // MARK: - Structure

    private func error(_ message: String) {
        diagnostics.append(.error(message, network: networkNumber))
    }

    private func warning(_ message: String) {
        diagnostics.append(.warning(message, network: networkNumber))
    }

    private static let passThrough: S7Flow = { _, power in power }

    private func compilePath(_ path: S7Path, _ context: S7PathContext) -> S7Flow {
        var flows: [S7Flow] = []
        for (position, node) in path.items.enumerated() {
            let atRail = context.startsAtRail && position == 0
            let isLast = position == path.items.count - 1
            switch node {
            case let .contact(contact):
                if context.contactsOnly && contact.kind == .invert {
                    error(S7Messages.onlyContactsInBranch)
                }
                flows.append(compileContact(contact))
            case let .coil(coil):
                if context.contactsOnly {
                    error(S7Messages.onlyContactsInBranch)
                }
                if coil.kind.mustBeLast && !isLast {
                    error(S7Messages.mustBeLast(coil.kind.rawValue))
                }
                let needsLogic = coil.kind.timerOperation != nil || coil.kind == .positiveEdge || coil.kind == .negativeEdge
                if needsLogic && atRail {
                    error(S7Messages.requiresPrecedingLogic)
                }
                flows.append(compileCoil(coil))
            case let .box(box):
                if context.contactsOnly && box.instruction != .inRange && box.instruction != .outOfRange {
                    error(S7Messages.onlyContactsInBranch)
                }
                if box.instruction.requiresPrecedingLogic && atRail {
                    error(S7Messages.requiresPrecedingLogic)
                }
                flows.append(compileBox(box))
            case let .parallel(group):
                flows.append(compileParallel(group, atRail: atRail, context: context))
            case let .fanOut(group):
                if !isLast { error(S7Messages.networkIncomplete) }
                if context.contactsOnly { error(S7Messages.onlyContactsInBranch) }
                flows.append(compileFanOut(group, atRail: atRail))
            }
        }
        if context.mustTerminate { checkTermination(path) }
        switch flows.count {
        case 0: return Self.passThrough
        case 1: return flows[0]
        default:
            return { run, power in
                var current = power
                for flow in flows {
                    current = try flow(run, current)
                }
                return current
            }
        }
    }

    private func checkTermination(_ path: S7Path) {
        guard let last = path.items.last else {
            error(S7Messages.networkIncomplete)
            return
        }
        switch last {
        case .coil, .fanOut:
            break
        case let .box(box):
            if !box.instruction.canTerminate { error(S7Messages.cannotTerminate(box.instruction.boxTitle)) }
        case let .contact(contact):
            if contact.kind == .compare {
                error(S7Messages.cannotTerminate(contact.comparison.label))
            } else {
                error(S7Messages.networkIncomplete)
            }
        case let .parallel(group):
            let terminated = group.branches.allSatisfy { branch in
                switch branch.items.last {
                case .some(.coil), .some(.fanOut): return true
                case let .box(box)?: return box.instruction.canTerminate
                default: return false
                }
            }
            if !terminated { error(S7Messages.networkIncomplete) }
        }
    }

    private func compileParallel(_ group: S7Branches, atRail: Bool, context: S7PathContext) -> S7Flow {
        if group.branches.contains(where: { $0.items.isEmpty }) {
            error(S7Messages.shortCircuit)
        }
        let branchContext = S7PathContext(startsAtRail: atRail, mustTerminate: false, contactsOnly: context.contactsOnly || !atRail)
        let branches = group.branches.filter { !$0.items.isEmpty }.map { compilePath($0, branchContext) }
        let id = group.id
        return { run, power in
            var result = false
            for branch in branches {
                if try branch(run, power) { result = true }
            }
            run.note(id, input: power, output: result)
            return result
        }
    }

    private func compileFanOut(_ group: S7Branches, atRail: Bool) -> S7Flow {
        let branchContext = S7PathContext(startsAtRail: atRail, mustTerminate: true, contactsOnly: false)
        let branches = group.branches.map { compilePath($0, branchContext) }
        let id = group.id
        return { run, power in
            for branch in branches {
                _ = try branch(run, power)
            }
            run.note(id, input: power, output: power)
            return power
        }
    }

    // MARK: - Operands

    /// Compiles an operand, reporting problems; nil on error.
    private func operand(_ text: String, expected: PLCDataType?, usage: S7OperandUsage) -> S7Operand? {
        do {
            return try operands.compile(text, expected: expected, usage: usage)
        } catch let problem as ResolveError {
            error(problem.message)
        } catch {
            self.error(error.localizedDescription)
        }
        return nil
    }

    /// A Bool operand of a contact or coil.
    private func bitOperand(_ text: String, usage: S7OperandUsage, allowConstant: Bool = false) -> S7Operand? {
        if !allowConstant && S7OperandParser.isLiteral(text.trimmingCharacters(in: .whitespaces)) && usage == .read {
            error(S7Messages.constantAtContact)
            return nil
        }
        guard let compiled = operand(text, expected: .bool, usage: usage) else { return nil }
        guard compiled.elementary == .bool else {
            error(S7Messages.dataTypeNotPermitted(compiled.type.displayName))
            return nil
        }
        return compiled
    }

    /// An edge memory bit: Bool, read and written, and not in Temp.
    private func edgeBit(_ text: String) -> S7Operand? {
        guard let bit = bitOperand(text, usage: .readWrite) else { return nil }
        if bit.isTemporary {
            error("The edge memory bit \(bit.text) must be located in a data block, in the Static section of an FB or in bit memory.")
        }
        return bit
    }

    private func recordInstance(_ operand: S7Operand) {
        if let root = operand.globalRoot { usedInstances.insert(root.lowercased()) }
    }

    // MARK: - Contacts

    private func compileContact(_ contact: S7Contact) -> S7Flow {
        let id = contact.id
        switch contact.kind {
        case .normallyOpen, .normallyClosed:
            guard let bit = bitOperand(contact.operand, usage: .read) else { return Self.passThrough }
            let closed = contact.kind == .normallyOpen
            return { run, power in
                let value = try bit.read(run.frame).boolValue
                let conducts = value == closed
                let output = power && conducts
                run.note(id, input: power, output: output, state: conducts)
                return output
            }
        case .invert:
            return { run, power in
                run.note(id, input: power, output: !power, state: !power)
                return !power
            }
        case .positiveEdge, .negativeEdge:
            guard let bit = bitOperand(contact.operand, usage: .read, allowConstant: true),
                  let memory = edgeBit(contact.secondOperand)
            else { return Self.passThrough }
            let rising = contact.kind == .positiveEdge
            return { run, power in
                let value = try bit.read(run.frame).boolValue
                let previous = try memory.read(run.frame).boolValue
                let edge = rising ? value && !previous : !value && previous
                try memory.write(run.frame, .bool(value))
                let output = power && edge
                run.note(id, input: power, output: output, state: edge)
                return output
            }
        case .compare:
            return compileComparator(contact)
        }
    }

    private func compileComparator(_ contact: S7Contact) -> S7Flow {
        guard let type = resolveType(contact.dataType, candidates: [contact.operand, contact.secondOperand], allowed: nil) else {
            return Self.passThrough
        }
        if type == .bool && contact.comparison != .equal && contact.comparison != .notEqual {
            error(S7Messages.dataTypeNotPermitted(type.rawValue))
            return Self.passThrough
        }
        guard let left = valueOperand(contact.operand, type: type), let right = valueOperand(contact.secondOperand, type: type) else {
            return Self.passThrough
        }
        let op = contact.comparison.runtimeOperator
        let id = contact.id
        return { run, power in
            let a = try left.read(run.frame).converted(to: type)
            let b = try right.read(run.frame).converted(to: type)
            let result = PLCOperations.compare(op, a, b)
            let output = power && result
            run.note(id, input: power, output: output, state: result, values: ["IN1": a, "IN2": b])
            return output
        }
    }

    /// A value operand that must convert implicitly into `type`.
    private func valueOperand(_ text: String, type: PLCDataType, parameter: Bool = false) -> S7Operand? {
        guard let compiled = operand(text, expected: type, usage: .read) else { return nil }
        guard let actual = compiled.elementary, PLCTypeRules.canConvertImplicitly(from: actual, to: type, dialect: .siemens) else {
            error(parameter ? S7Messages.parameterTypeMismatch(actual: compiled.type.displayName, formal: type.rawValue)
                            : S7Messages.dataTypeNotPermitted(compiled.type.displayName))
            return nil
        }
        return compiled
    }

    /// A target operand that `type` converts implicitly into.
    private func targetOperand(_ text: String, type: PLCDataType, usage: S7OperandUsage = .write, parameter: Bool = false) -> S7Operand? {
        guard let compiled = operand(text, expected: type, usage: usage) else { return nil }
        let fits: Bool
        if let actual = compiled.elementary {
            fits = usage == .readWrite ? actual == type : PLCTypeRules.canConvertImplicitly(from: type, to: actual, dialect: .siemens)
        } else {
            fits = false
        }
        guard fits else {
            error(parameter ? S7Messages.parameterTypeMismatch(actual: compiled.type.displayName, formal: type.rawValue)
                            : S7Messages.dataTypeNotPermitted(compiled.type.displayName))
            return nil
        }
        return compiled
    }

    /// The type of a comparator or box: the chosen one, or (Auto) the common
    /// type of the symbolic operands. Reports "Please select a data type." when
    /// nothing decides it.
    private func resolveType(_ chosen: PLCDataType?, candidates: [String], allowed: [PLCDataType]?) -> PLCDataType? {
        var type = chosen
        if type == nil {
            for text in candidates {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !S7Placeholder.isPlaceholder(trimmed), !S7OperandParser.isLiteral(trimmed),
                      let found = (try? operands.compile(trimmed, expected: nil, usage: .read))?.elementary
                else { continue }
                if let current = type {
                    type = PLCTypeRules.commonType(current, found, dialect: .siemens) ?? current
                } else {
                    type = found
                }
            }
        }
        if type == nil {
            // Typed literals (INT#5, T#5S, TRUE) decide the type too.
            for text in candidates {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard S7OperandParser.isLiteral(trimmed) else { continue }
                let upper = trimmed.uppercased()
                var typed = upper == "TRUE" || upper == "FALSE" || upper.hasPrefix("T#") || upper.hasPrefix("TIME#")
                if let hash = upper.firstIndex(of: "#"), PLCDataType.named(String(upper[..<hash])) != nil { typed = true }
                if typed, let inferred = S7OperandCompiler.inferredType(of: trimmed) {
                    type = inferred
                    break
                }
            }
        }
        guard let type else {
            error(S7Messages.selectDataType)
            return nil
        }
        if let allowed, !allowed.contains(type) {
            error(S7Messages.dataTypeNotPermitted(type.rawValue))
            return nil
        }
        return type
    }

    // MARK: - Coils

    private func compileCoil(_ coil: S7Coil) -> S7Flow {
        let id = coil.id
        switch coil.kind {
        case .assign, .negate:
            guard let bit = bitOperand(coil.operand, usage: .write) else { return Self.passThrough }
            let negate = coil.kind == .negate
            return { run, power in
                let value = negate ? !power : power
                try bit.write(run.frame, .bool(value))
                run.note(id, input: power, output: power, state: value)
                return power
            }
        case .set, .reset:
            guard let bit = bitOperand(coil.operand, usage: .write) else { return Self.passThrough }
            let setting = coil.kind == .set
            return { run, power in
                if power { try bit.write(run.frame, .bool(setting)) }
                let state = try bit.read(run.frame).boolValue
                run.note(id, input: power, output: power, state: state)
                return power
            }
        case .setBitField, .resetBitField:
            return compileBitField(coil)
        case .positiveEdge, .negativeEdge:
            guard let bit = bitOperand(coil.operand, usage: .write), let memory = edgeBit(coil.secondOperand) else {
                return Self.passThrough
            }
            let rising = coil.kind == .positiveEdge
            return { run, power in
                let previous = try memory.read(run.frame).boolValue
                let edge = rising ? power && !previous : !power && previous
                try memory.write(run.frame, .bool(power))
                try bit.write(run.frame, .bool(edge))
                run.note(id, input: power, output: power, state: edge)
                return power
            }
        case .pulseTimer, .onDelayTimer, .offDelayTimer, .accumulatingTimer, .resetTimer, .presetTimer:
            return compileTimerCoil(coil)
        }
    }

    private func compileBitField(_ coil: S7Coil) -> S7Flow {
        let id = coil.id
        let setting = coil.kind == .setBitField
        guard let count = valueOperand(coil.secondOperand, type: .uint) else { return Self.passThrough }
        let text = coil.operand.trimmingCharacters(in: .whitespaces)
        if S7Placeholder.isPlaceholder(text) {
            error(S7Messages.operandMissing)
            return Self.passThrough
        }
        guard let path = try? S7OperandParser.parse(text) else {
            _ = bitOperand(text, usage: .write)
            return Self.passThrough
        }
        // An absolute address or a tag on one: walk the following bits.
        if let addressing = resolver as? S7AddressResolving, let found = addressing.address(of: path.root), path.accessors.isEmpty {
            guard found.type == .bool, found.address.width == .bit else {
                error(S7Messages.dataTypeNotPermitted(found.type.rawValue))
                return Self.passThrough
            }
            _ = bitOperand(text, usage: .write)
            let start = found.address
            return { run, power in
                if power {
                    let total = try Int(count.read(run.frame).intValue)
                    let first = start.byteOffset * 8 + start.bitNumber
                    for offset in 0..<max(0, total) {
                        let position = first + offset
                        guard position / 8 < start.area.size,
                              let cell = addressing.cell(for: .bit(start.area, position / 8, position % 8), type: .bool)
                        else { break }
                        cell.write(.bool(setting))
                    }
                }
                run.note(id, input: power, output: power)
                return power
            }
        }
        // An element of a Bool array: set the following elements.
        if case let .index(.constant(first))? = path.accessors.last {
            var arrayPath = path
            arrayPath.accessors.removeLast()
            guard let element = bitOperand(text, usage: .write),
                  let array = operand(arrayPath.text, expected: nil, usage: .write),
                  element.elementary == .bool
            else { return Self.passThrough }
            return { run, power in
                if power {
                    let total = try Int(count.read(run.frame).intValue)
                    let place = try array.locate(run.frame)
                    for offset in 0..<max(0, total) {
                        guard let target = place.element(first + offset) else { break }
                        target.write(.bool(setting))
                    }
                }
                run.note(id, input: power, output: power)
                return power
            }
        }
        error(S7Messages.dataTypeNotPermitted(coil.operand))
        return Self.passThrough
    }

    private func compileTimerCoil(_ coil: S7Coil) -> S7Flow {
        let id = coil.id
        guard let instance = operand(coil.operand, expected: nil, usage: .readWrite) else { return Self.passThrough }
        recordInstance(instance)
        guard case let .instance(type) = instance.type, let builtIn = type.builtIn, builtIn.isTimer else {
            error(S7Messages.dataTypeNotPermitted(instance.type.displayName))
            return Self.passThrough
        }
        if let operation = coil.kind.timerOperation, builtIn != .iecTimer, builtIn != operation {
            error(S7Messages.dataTypeNotPermitted(type.name))
            return Self.passThrough
        }
        var duration: S7Operand?
        if coil.kind.hasSecondOperand {
            guard let value = valueOperand(coil.secondOperand, type: .time) else { return Self.passThrough }
            duration = value
        }
        let kind = coil.kind
        return { run, power in
            guard let node = try instance.locate(run.frame).node else { return power }
            switch kind {
            case .resetTimer:
                if power {
                    node.memory?.reset()
                    node.member("Q")?.write(.bool(false))
                    node.member("ET")?.write(.time(0))
                }
            case .presetTimer:
                if power, let duration {
                    let preset = try duration.read(run.frame)
                    node.member("PT")?.write(preset)
                }
            default:
                if let duration {
                    let preset = try duration.read(run.frame)
                    node.member("PT")?.write(preset)
                }
                node.member("IN")?.write(.bool(power))
                FunctionBlockLibrary.execute(type, operation: kind.timerOperation, instance: node, now: run.clock)
            }
            let q = node.member("Q")?.read() ?? .bool(false)
            run.note(id, input: power, output: power, state: q.boolValue,
                     values: ["ET": node.member("ET")?.read() ?? .time(0)])
            return power
        }
    }

    // MARK: - Boxes

    /// The spec of a pin, including added ones (IN3 of an ADD, OUT2 of a MOVE).
    private func pinSpec(_ name: String, in spec: S7InstructionSpec, input: Bool) -> S7PinSpec? {
        let list = input ? spec.inputs : spec.outputs
        if let found = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return found }
        let upper = name.uppercased()
        if input, spec.expandableInputs, upper.hasPrefix("IN"), Int(upper.dropFirst(2)) != nil {
            return S7PinSpec(name: name, type: .first, isRequired: true)
        }
        if !input, spec.expandableOutputs, upper.hasPrefix("OUT"), Int(upper.dropFirst(3)) != nil {
            return S7PinSpec(name: name, type: .any, isRequired: true)
        }
        return nil
    }

    private func pinType(_ type: S7PinType, first: PLCDataType?, second: PLCDataType?) -> PLCDataType? {
        switch type {
        case .bool: return .bool
        case .time: return .time
        case .first: return first
        case .second: return second
        case .anyInteger, .any: return nil
        }
    }

    /// Compiles a box input pin. `nil` when compilation failed.
    private func compileInput(_ pin: S7Pin?, spec pinSpec: S7PinSpec, type: PLCDataType?, parameter: Bool = false) -> S7InputSource? {
        guard let pin else {
            if pinSpec.isRequired { error(S7Messages.operandMissing) }
            return pinSpec.isRequired ? nil : .open
        }
        switch pin.source {
        case let .branch(path):
            guard type == .bool else {
                error(S7Messages.dataTypeNotPermitted("Bool"))
                return nil
            }
            return .flow(compilePath(path, S7PathContext(startsAtRail: true, mustTerminate: false, contactsOnly: false)))
        case let .operand(text):
            if S7Placeholder.isPlaceholder(text) {
                if pinSpec.isRequired {
                    error(S7Messages.operandMissing)
                    return nil
                }
                return .open
            }
            if pinSpec.isInOut, let type {
                return targetOperand(text, type: type, usage: .readWrite, parameter: parameter).map { .operand($0) }
            }
            switch pinSpec.type {
            case .anyInteger:
                guard let compiled = operand(text, expected: .uint, usage: .read) else { return nil }
                guard let actual = compiled.elementary, actual.isInteger else {
                    error(S7Messages.dataTypeNotPermitted(compiled.type.displayName))
                    return nil
                }
                return .operand(compiled)
            default:
                guard let type else { return nil }
                if type == .bool, S7OperandParser.isLiteral(text.trimmingCharacters(in: .whitespaces)) {
                    return operand(text, expected: .bool, usage: .read).map { .operand($0) }
                }
                return valueOperand(text, type: type, parameter: parameter).map { .operand($0) }
            }
        }
    }

    private func compileOutput(_ pin: S7Pin?, spec pinSpec: S7PinSpec, type: PLCDataType?, parameter: Bool = false) -> S7OutputTarget? {
        guard let pin else {
            if pinSpec.isRequired { error(S7Messages.operandMissing) }
            return pinSpec.isRequired ? nil : .open
        }
        switch pin.source {
        case let .branch(path):
            guard type == .bool else {
                error(S7Messages.dataTypeNotPermitted("Bool"))
                return nil
            }
            return .flow(compilePath(path, S7PathContext(startsAtRail: false, mustTerminate: true, contactsOnly: false)))
        case let .operand(text):
            if S7Placeholder.isPlaceholder(text) {
                if pinSpec.isRequired {
                    error(S7Messages.operandMissing)
                    return nil
                }
                return .open
            }
            guard let type else { return nil }
            return targetOperand(text, type: type, parameter: parameter).map { .operand($0) }
        }
    }

    private func compileBox(_ box: S7Box) -> S7Flow {
        switch box.instruction {
        case .empty:
            error(S7Messages.selectInstruction)
            return Self.passThrough
        case .call:
            return compileCall(box)
        case .pulseTimer, .onDelayTimer, .offDelayTimer, .accumulatingTimer, .countUp, .countDown, .countUpDown,
             .risingEdgeTrigger, .fallingEdgeTrigger:
            return compileInstanceBox(box)
        case .positiveEdgeBox, .negativeEdgeBox:
            guard let memory = edgeBit(box.operand) else { return Self.passThrough }
            let rising = box.instruction == .positiveEdgeBox
            let id = box.id
            return { run, power in
                let previous = try memory.read(run.frame).boolValue
                let edge = rising ? power && !previous : !power && previous
                try memory.write(run.frame, .bool(power))
                run.note(id, input: power, output: edge, state: edge)
                return edge
            }
        case .setReset, .resetSet:
            return compileFlipFlop(box)
        case .move:
            return compileMove(box)
        default:
            return compileFunctionBox(box)
        }
    }

    private func compileFlipFlop(_ box: S7Box) -> S7Flow {
        let spec = box.instruction.spec
        guard let bit = bitOperand(box.operand, usage: .readWrite),
              let second = spec.inputs.first,
              let other = compileInput(box.input(second.name), spec: second, type: .bool)
        else { return Self.passThrough }
        let resetDominant = box.instruction == .setReset
        let id = box.id
        return { run, power in
            let otherValue = try other.value(run, default: .bool(false)).boolValue
            var q = try bit.read(run.frame).boolValue
            if resetDominant {
                if power { q = true }
                if otherValue { q = false }
            } else {
                if power { q = false }
                if otherValue { q = true }
            }
            try bit.write(run.frame, .bool(q))
            run.note(id, input: power, output: q, state: q)
            return q
        }
    }

    /// Timers, counters and R_TRIG/F_TRIG: boxes on an instance.
    private func compileInstanceBox(_ box: S7Box) -> S7Flow {
        let instruction = box.instruction
        let spec = instruction.spec
        let text = box.instance.trimmingCharacters(in: .whitespaces)
        if S7Placeholder.isPlaceholder(text) {
            error(S7Messages.missingInstanceDB)
            return Self.passThrough
        }
        var valueType: PLCDataType?
        if instruction.isCounter {
            guard let type = resolveType(box.dataType, candidates: [box.input("PV")?.source.operandText ?? "",
                                                                   box.output("CV")?.source.operandText ?? ""],
                                         allowed: S7Instruction.integerTypes)
            else { return Self.passThrough }
            valueType = type
        }
        guard let instance = operand(text, expected: nil, usage: .readWrite) else { return Self.passThrough }
        recordInstance(instance)
        guard case let .instance(type) = instance.type, instruction.accepts(instanceType: type, dataType: valueType) else {
            error(S7Messages.dataTypeNotPermitted(instance.type.displayName))
            return Self.passThrough
        }
        var inputs: [(String, S7InputSource)] = []
        var outputs: [(String, S7OutputTarget)] = []
        var failed = false
        for pinSpec in spec.inputs {
            let source = compileInput(box.input(pinSpec.name), spec: pinSpec, type: pinType(pinSpec.type, first: valueType, second: nil))
            if let source { inputs.append((pinSpec.name, source)) } else { failed = true }
        }
        for pinSpec in spec.outputs {
            let target = compileOutput(box.output(pinSpec.name), spec: pinSpec, type: pinType(pinSpec.type, first: valueType, second: nil))
            if let target { outputs.append((pinSpec.name, target)) } else { failed = true }
        }
        if failed { return Self.passThrough }
        let operation = instruction.builtInOperation
        let powerInput = spec.powerInput
        let powerOutput = spec.powerOutput
        let hasEnable = powerInput == "EN"
        let id = box.id
        let parameters = FunctionBlockLibrary.callParameters(of: type, operation: operation)
        func member(_ node: DataNode, _ name: String) -> DataNode? {
            guard let parameter = parameters.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return node.member(name)
            }
            return node.children[parameter.memberIndex]
        }
        return { run, power in
            guard let node = try instance.locate(run.frame).node else { return false }
            var values: [String: PLCValue] = [:]
            if hasEnable && !power {
                run.note(id, input: power, output: false, state: false)
                return false
            }
            if !hasEnable { member(node, powerInput)?.write(.bool(power)) }
            for (name, source) in inputs {
                if case .open = source { continue }
                let value = try source.value(run, default: .bool(false))
                member(node, name)?.write(value)
                values[name] = value
            }
            FunctionBlockLibrary.execute(type, operation: operation, instance: node, now: run.clock)
            for (name, target) in outputs {
                let value = member(node, name)?.read() ?? .bool(false)
                try target.deliver(value, run)
                values[name] = value
            }
            let output: Bool
            if hasEnable {
                output = true
                if let q = member(node, "Q")?.read() { values["Q"] = q }
            } else {
                output = member(node, powerOutput)?.read().boolValue ?? false
            }
            run.note(id, input: power, output: output, state: output, values: values)
            return output
        }
    }

    private func compileMove(_ box: S7Box) -> S7Flow {
        guard let inputText = box.input("IN")?.source.operandText, !S7Placeholder.isPlaceholder(inputText) else {
            error(S7Messages.operandMissing)
            return Self.passThrough
        }
        let outputTexts = box.outputs.map { ($0.name, $0.source.operandText ?? "") }
        if outputTexts.isEmpty || outputTexts.contains(where: { S7Placeholder.isPlaceholder($0.1) }) {
            error(S7Messages.operandMissing)
            return Self.passThrough
        }
        // The first symbolic target types a literal source.
        let literalSource = S7OperandParser.isLiteral(inputText.trimmingCharacters(in: .whitespaces))
        var targets: [S7Operand] = []
        for (_, text) in outputTexts {
            guard let target = operand(text, expected: nil, usage: .write) else { return Self.passThrough }
            targets.append(target)
        }
        let sourceType = literalSource ? targets.first?.elementary : nil
        guard let source = operand(inputText, expected: sourceType, usage: .read) else { return Self.passThrough }
        for target in targets {
            if let from = source.elementary, let to = target.elementary {
                if !PLCTypeRules.canConvertImplicitly(from: from, to: to, dialect: .siemens) {
                    error(S7Messages.dataTypeNotPermitted(target.type.displayName))
                    return Self.passThrough
                }
            } else if source.type != target.type {
                error(S7Messages.dataTypeNotPermitted(target.type.displayName))
                return Self.passThrough
            }
        }
        let id = box.id
        return { run, power in
            guard power else {
                run.note(id, input: false, output: false, state: false)
                return false
            }
            if source.elementary != nil {
                let value = try source.read(run.frame)
                for target in targets { try target.write(run.frame, value) }
                run.note(id, input: true, output: true, state: true, values: ["IN": value])
            } else {
                let from = try source.locate(run.frame)
                for target in targets {
                    if let targetNode = try target.locate(run.frame).node, let sourceNode = from.node {
                        targetNode.assign(from: sourceNode)
                    }
                }
                run.note(id, input: true, output: true, state: true)
            }
            return true
        }
    }

    /// Boxes with EN/ENO that compute outputs from inputs: math, conversion,
    /// word logic, shifts, CALCULATE, and the IN_RANGE/OUT_RANGE comparators.
    private func compileFunctionBox(_ box: S7Box) -> S7Flow {
        let instruction = box.instruction
        let spec = instruction.spec
        var first: PLCDataType?
        var second: PLCDataType?
        switch spec.typing {
        case .none:
            break
        case let .single(allowed):
            let candidates = (box.inputs + box.outputs).filter { pin in
                let found = pinSpec(pin.name, in: spec, input: box.inputs.contains(pin)) ?? pinSpec(pin.name, in: spec, input: false)
                return found?.type == .first
            }.compactMap(\.source.operandText)
            guard let type = resolveType(box.dataType, candidates: candidates, allowed: allowed) else { return Self.passThrough }
            first = type
        case let .pair(firstAllowed, secondAllowed):
            let firstCandidates = box.inputs.filter { pinSpec($0.name, in: spec, input: true)?.type == .first }.compactMap(\.source.operandText)
            let secondCandidates = (box.inputs + box.outputs).filter { pin in
                (pinSpec(pin.name, in: spec, input: true) ?? pinSpec(pin.name, in: spec, input: false))?.type == .second
            }.compactMap(\.source.operandText)
            guard let type = resolveType(box.dataType, candidates: firstCandidates, allowed: firstAllowed),
                  let target = resolveType(box.secondDataType, candidates: secondCandidates, allowed: secondAllowed)
            else { return Self.passThrough }
            first = type
            second = target
        }

        if instruction == .calculate {
            return compileCalculate(box, type: first ?? .int)
        }

        var inputs: [S7InputSource] = []
        var inputNames: [String] = []
        var failed = false
        var inputPins = spec.inputs.map { spec in (spec, box.input(spec.name)) }
        if spec.expandableInputs {
            for pin in box.inputs where !spec.inputs.contains(where: { $0.name.caseInsensitiveCompare(pin.name) == .orderedSame }) {
                if let extra = pinSpec(pin.name, in: spec, input: true) { inputPins.append((extra, pin)) }
            }
        }
        for (pinSpec, pin) in inputPins {
            if let source = compileInput(pin, spec: pinSpec, type: pinType(pinSpec.type, first: first, second: second)) {
                inputs.append(source)
                inputNames.append(pinSpec.name)
            } else {
                failed = true
            }
        }
        var outputs: [S7OutputTarget] = []
        for pinSpec in spec.outputs {
            if let target = compileOutput(box.output(pinSpec.name), spec: pinSpec, type: pinType(pinSpec.type, first: first, second: second)) {
                outputs.append(target)
            } else {
                failed = true
            }
        }
        if failed { return Self.passThrough }
        let resultType = spec.outputs.first.map { $0.type == .second ? second : first } ?? first
        guard let compute = operation(for: instruction, first: first ?? .int, second: second ?? resultType ?? .int) else {
            error(S7Messages.selectInstruction)
            return Self.passThrough
        }
        let id = box.id
        let isRangeCheck = instruction == .inRange || instruction == .outOfRange
        return { run, power in
            if !isRangeCheck && !power {
                run.note(id, input: false, output: false, state: false)
                return false
            }
            var values: [PLCValue] = []
            var shown: [String: PLCValue] = [:]
            for (index, source) in inputs.enumerated() {
                let value = try source.value(run, default: (first ?? .int).defaultValue)
                values.append(value)
                shown[inputNames[index]] = value
            }
            let result = compute(values)
            if isRangeCheck {
                let output = power && result.value.boolValue
                run.note(id, input: power, output: output, state: result.value.boolValue, values: shown)
                return output
            }
            if instruction == .increment || instruction == .decrement, case let .operand(target)? = inputs.first {
                try target.write(run.frame, result.value)
            }
            for target in outputs {
                try target.deliver(result.value, run)
            }
            shown["OUT"] = result.value
            run.note(id, input: power, output: result.isValid, state: result.isValid, values: shown)
            return result.isValid
        }
    }

    /// The computation of a function box on its input values.
    private func operation(for instruction: S7Instruction, first: PLCDataType, second: PLCDataType) -> (([PLCValue]) -> OperationResult)? {
        func fold(_ op: ArithmeticOperator) -> ([PLCValue]) -> OperationResult {
            { values in
                var result = OperationResult(value: (values.first ?? first.defaultValue).converted(to: first), isValid: true)
                for value in values.dropFirst() {
                    let next = PLCOperations.arithmetic(op, result.value, value.converted(to: first), as: first)
                    result = OperationResult(value: next.value, isValid: result.isValid && next.isValid)
                }
                return result
            }
        }
        func logic(_ op: BitLogicOperator) -> ([PLCValue]) -> OperationResult {
            { values in
                var result = (values.first ?? first.defaultValue).converted(to: first)
                for value in values.dropFirst() {
                    result = PLCOperations.bitLogic(op, result, value.converted(to: first), as: first)
                }
                return OperationResult(value: result, isValid: true)
            }
        }
        func value(_ values: [PLCValue], _ index: Int) -> PLCValue {
            index < values.count ? values[index] : first.defaultValue
        }
        func rounding(_ rule: FloatingPointRoundingRule) -> ([PLCValue]) -> OperationResult {
            { values in
                let input = value(values, 0)
                if second.isReal {
                    let rounded = input.doubleValue.rounded(rule)
                    let stored = second == .real ? Double(Float(rounded)) : rounded
                    return OperationResult(value: .real(stored), isValid: stored.isFinite)
                }
                return PLCOperations.convert(input, from: first, to: second, rounding: rule)
            }
        }
        switch instruction {
        case .add: return fold(.add)
        case .multiply: return fold(.multiply)
        case .subtract: return fold(.subtract)
        case .divide: return fold(.divide)
        case .modulo: return fold(.modulo)
        case .power:
            return { values in
                PLCOperations.arithmetic(.power, value(values, 0).converted(to: first), .real(value(values, 1).doubleValue), as: first)
            }
        case .negate:
            return { values in PLCOperations.arithmetic(.subtract, PLCOperations.integer(0, as: first), value(values, 0), as: first) }
        case .absolute:
            return { values in S7Math.function("ABS", value(values, 0), as: first) }
        case .increment:
            return { values in PLCOperations.arithmetic(.add, value(values, 0), .int(1), as: first) }
        case .decrement:
            return { values in PLCOperations.arithmetic(.subtract, value(values, 0), .int(1), as: first) }
        case .minimum:
            return { values in
                OperationResult(value: (PLCOperations.minimum(values.map { $0.converted(to: first) }) ?? first.defaultValue), isValid: true)
            }
        case .maximum:
            return { values in
                OperationResult(value: (PLCOperations.maximum(values.map { $0.converted(to: first) }) ?? first.defaultValue), isValid: true)
            }
        case .limit:
            return { values in
                PLCOperations.limit(value(values, 1).converted(to: first), min: value(values, 0).converted(to: first),
                                    max: value(values, 2).converted(to: first))
            }
        case .square, .squareRoot, .naturalLogarithm, .exponential, .sine, .cosine, .tangent, .arcSine, .arcCosine,
             .arcTangent, .fraction:
            let name = instruction.rawValue
            return { values in S7Math.function(name, value(values, 0), as: first) }
        case .convert:
            return { values in PLCOperations.convert(value(values, 0).converted(to: first), from: first, to: second) }
        case .round: return rounding(.toNearestOrEven)
        case .truncate: return rounding(.towardZero)
        case .ceiling: return rounding(.up)
        case .floor: return rounding(.down)
        case .scale:
            return { values in
                let minimum = value(values, 0)
                let maximum = value(values, 2)
                let input = value(values, 1)
                let result = PLCOperations.scale(input, min: minimum, max: maximum, as: second)
                let ordered = PLCOperations.compare(.less, minimum, maximum)
                return OperationResult(value: result.value, isValid: result.isValid && ordered && !input.doubleValue.isNaN)
            }
        case .normalize:
            return { values in
                let minimum = value(values, 0)
                let maximum = value(values, 2)
                let result = PLCOperations.normalize(value(values, 1), min: minimum, max: maximum, as: second)
                return OperationResult(value: result.value, isValid: result.isValid && PLCOperations.compare(.less, minimum, maximum))
            }
        case .inRange:
            return { values in
                let inside = PLCOperations.compare(.lessOrEqual, value(values, 0), value(values, 1))
                    && PLCOperations.compare(.lessOrEqual, value(values, 1), value(values, 2))
                return OperationResult(value: .bool(inside), isValid: true)
            }
        case .outOfRange:
            return { values in
                let outside = PLCOperations.compare(.less, value(values, 1), value(values, 0))
                    || PLCOperations.compare(.greater, value(values, 1), value(values, 2))
                return OperationResult(value: .bool(outside), isValid: true)
            }
        case .wordAnd: return logic(.and)
        case .wordOr: return logic(.or)
        case .wordXor: return logic(.xor)
        case .invert:
            return { values in OperationResult(value: PLCOperations.invert(value(values, 0), as: first), isValid: true) }
        case .shiftLeft:
            return { values in OperationResult(value: PLCOperations.shiftLeft(value(values, 0), by: value(values, 1).intValue, as: first), isValid: true) }
        case .shiftRight:
            return { values in OperationResult(value: PLCOperations.shiftRight(value(values, 0), by: value(values, 1).intValue, as: first), isValid: true) }
        case .rotateLeft:
            return { values in OperationResult(value: PLCOperations.rotate(value(values, 0), by: value(values, 1).intValue, left: true, as: first), isValid: true) }
        case .rotateRight:
            return { values in OperationResult(value: PLCOperations.rotate(value(values, 0), by: value(values, 1).intValue, left: false, as: first), isValid: true) }
        default:
            return nil
        }
    }

    private func compileCalculate(_ box: S7Box, type: PLCDataType) -> S7Flow {
        let expression: S7Expression
        do {
            expression = try S7Expression.parse(box.expression)
            try expression.validate(as: type)
        } catch let problem as ResolveError {
            error(problem.message)
            return Self.passThrough
        } catch {
            self.error(error.localizedDescription)
            return Self.passThrough
        }
        let count = max(2, box.inputs.count)
        if expression.highestInput > count {
            error(S7Messages.invalidExpression("IN\(expression.highestInput) is not an input of the box."))
            return Self.passThrough
        }
        var sources: [S7InputSource] = []
        var failed = false
        for index in 0..<count {
            let name = "IN\(index + 1)"
            let spec = S7PinSpec(name: name, type: .first, isRequired: true)
            if let source = compileInput(box.input(name), spec: spec, type: type) { sources.append(source) } else { failed = true }
        }
        let outputSpec = S7PinSpec(name: "OUT", type: .first, isRequired: true)
        guard !failed, let output = compileOutput(box.output("OUT"), spec: outputSpec, type: type) else { return Self.passThrough }
        let id = box.id
        return { run, power in
            guard power else {
                run.note(id, input: false, output: false, state: false)
                return false
            }
            var values: [PLCValue] = []
            for source in sources {
                let value = try source.value(run, default: type.defaultValue)
                values.append(value)
            }
            let result = expression.evaluate(values, as: type)
            try output.deliver(result.value, run)
            run.note(id, input: true, output: result.isValid, state: result.isValid, values: ["OUT": result.value])
            return result.isValid
        }
    }

    // MARK: - Calls

    private func compileCall(_ box: S7Box) -> S7Flow {
        let name = box.calledBlock.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !name.isEmpty else {
            error(S7Messages.selectInstruction)
            return Self.passThrough
        }
        guard let handle = resolver.userBlock(named: name), handle.kind != .organizationBlock else {
            error(S7Messages.blockNotDefined(name))
            return Self.passThrough
        }
        let isFunction = handle.kind == .function
        var instance: S7Operand?
        if !isFunction {
            let text = box.instance.trimmingCharacters(in: .whitespaces)
            if S7Placeholder.isPlaceholder(text) {
                error(S7Messages.missingInstanceDB)
                return Self.passThrough
            }
            guard let compiled = operand(text, expected: nil, usage: .readWrite) else { return Self.passThrough }
            recordInstance(compiled)
            guard case let .instance(type) = compiled.type, type.builtIn == nil,
                  type.name.caseInsensitiveCompare(handle.name) == .orderedSame
            else {
                error(S7Messages.parameterTypeMismatch(actual: compiled.type.displayName, formal: "\"\(handle.name)\""))
                return Self.passThrough
            }
            instance = compiled
        }
        var bindings: [S7CallBinding] = []
        var failed = false
        for parameter in handle.callParameters {
            let required = isFunction
            switch parameter.section {
            case .input:
                if let elementary = parameter.type.elementary {
                    let spec = S7PinSpec(name: parameter.name, type: elementary == .bool ? .bool : .first, isRequired: required)
                    if let source = compileInput(box.input(parameter.name), spec: spec, type: elementary, parameter: true) {
                        bindings.append(S7CallBinding(parameter: parameter, input: source))
                    } else { failed = true }
                } else if let structured = structuredOperand(box.input(parameter.name), parameter: parameter, required: required, usage: .read) {
                    bindings.append(S7CallBinding(parameter: parameter, inOut: structured.operand))
                } else { failed = true }
            case .output:
                if let elementary = parameter.type.elementary {
                    let spec = S7PinSpec(name: parameter.name, type: elementary == .bool ? .bool : .first, isRequired: required)
                    if let target = compileOutput(box.output(parameter.name), spec: spec, type: elementary, parameter: true) {
                        bindings.append(S7CallBinding(parameter: parameter, output: target))
                    } else { failed = true }
                } else if let structured = structuredOperand(box.output(parameter.name), parameter: parameter, required: required, usage: .write) {
                    bindings.append(S7CallBinding(parameter: parameter, output: structured.operand.map { .operand($0) } ?? .open))
                } else { failed = true }
            default:
                if let structured = structuredOperand(box.input(parameter.name) ?? box.output(parameter.name), parameter: parameter,
                                                      required: required, usage: .readWrite) {
                    bindings.append(S7CallBinding(parameter: parameter, inOut: structured.operand))
                } else { failed = true }
            }
        }
        var returnTarget: S7OutputTarget = .open
        if let returnValue = handle.returnValue, let type = returnValue.member.type.elementary {
            let spec = S7PinSpec(name: "Ret_Val", type: type == .bool ? .bool : .first, isRequired: true)
            if let target = compileOutput(box.output("Ret_Val") ?? box.output(handle.name), spec: spec, type: type, parameter: true) {
                returnTarget = target
            } else { failed = true }
        }
        if failed { return Self.passThrough }
        let returnIndex = handle.returnValue?.index
        let id = box.id
        return { run, power in
            guard power else {
                run.note(id, input: false, output: false, state: false)
                return false
            }
            let area: DataNode
            if let instance {
                guard let node = try instance.locate(run.frame).node else { return false }
                area = node
            } else {
                area = handle.makeInstanceArea()
            }
            for binding in bindings {
                let target = area.children[binding.parameter.memberIndex]
                if let input = binding.input {
                    if case .open = input { continue }
                    let value = try input.value(run, default: .bool(false))
                    target.write(value)
                } else if let operand = binding.inOut, binding.parameter.section != .output {
                    if let node = try operand.locate(run.frame).node {
                        target.assign(from: node)
                    } else {
                        target.write(try operand.read(run.frame))
                    }
                }
            }
            try run.frame.context.run(handle, instance: area)
            for binding in bindings {
                let source = area.children[binding.parameter.memberIndex]
                if let output = binding.output {
                    if source.type.elementary != nil {
                        try output.deliver(source.read(), run)
                    } else if case let .operand(operand) = output, let node = try operand.locate(run.frame).node {
                        node.assign(from: source)
                    }
                } else if let operand = binding.inOut, binding.parameter.section == .inOut {
                    let place = try operand.locate(run.frame)
                    if let node = place.node, source.type.elementary == nil {
                        node.assign(from: source)
                    } else {
                        place.write(source.read())
                    }
                }
            }
            if let returnIndex {
                try returnTarget.deliver(area.children[returnIndex].read(), run)
            }
            let enableOutput = (handle.body as? S7TrackedBody)?.lastEnableOutput ?? true
            run.note(id, input: true, output: enableOutput, state: enableOutput)
            return enableOutput
        }
    }

    /// A structured or InOut call parameter: the operand must have exactly the parameter's type.
    private func structuredOperand(_ pin: S7Pin?, parameter: CallParameter, required: Bool,
                                   usage: S7OperandUsage) -> (operand: S7Operand?, ok: Bool)? {
        guard let text = pin?.source.operandText, !S7Placeholder.isPlaceholder(text) else {
            if required || parameter.section == .inOut {
                error(S7Messages.operandMissing)
                return nil
            }
            return (nil, true)
        }
        let expected = parameter.type.elementary
        guard let compiled = operand(text, expected: expected, usage: usage) else { return nil }
        guard compiled.type == parameter.type else {
            error(S7Messages.parameterTypeMismatch(actual: compiled.type.displayName, formal: parameter.type.displayName))
            return nil
        }
        return (compiled, true)
    }
}

/// Where a path starts and what it may contain.
nonisolated private struct S7PathContext {
    /// The path begins at the left power rail.
    var startsAtRail: Bool
    /// The path must end in a coil or box.
    var mustTerminate: Bool
    /// Only contacts may appear (a simultaneous branch with preceding logic).
    var contactsOnly: Bool
}

/// A box input at run time.
nonisolated private enum S7InputSource {
    case operand(S7Operand)
    case flow(S7Flow)
    /// Open optional input: leaves the instance value alone.
    case open

    func value(_ run: S7Run, default fallback: PLCValue) throws -> PLCValue {
        switch self {
        case let .operand(operand): return try operand.read(run.frame)
        case let .flow(flow): return .bool(try flow(run, true))
        case .open: return fallback
        }
    }
}

/// A box output at run time.
nonisolated private enum S7OutputTarget {
    case operand(S7Operand)
    case flow(S7Flow)
    case open

    func deliver(_ value: PLCValue, _ run: S7Run) throws {
        switch self {
        case let .operand(operand): try operand.write(run.frame, value)
        case let .flow(flow): _ = try flow(run, value.boolValue)
        case .open: break
        }
    }
}

/// How one parameter of an FC/FB call is supplied.
nonisolated private struct S7CallBinding {
    var parameter: CallParameter
    var input: S7InputSource?
    var output: S7OutputTarget?
    var inOut: S7Operand?
}
