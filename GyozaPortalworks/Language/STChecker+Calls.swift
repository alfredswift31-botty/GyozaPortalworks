import Foundation

/// What a call names.
nonisolated enum STCallTarget {
    case standard(STStandardFunction)
    case procedure(NativeProcedure)
    case function(BlockHandle)
    /// An FB instance, with the operation for generic IEC_TIMER / IEC_COUNTER instances.
    case functionBlock(STPlace, FunctionBlockType, BuiltInFunctionBlock?)
}

/// A compiled argument of an environment procedure: a value, or a place with its trace site.
nonisolated enum STProcedureArgument {
    case value(STEvaluator)
    case place(STLocator, Int)
}

/// An argument matched to its formal parameter.
nonisolated struct STBoundArgument {
    var parameter: CallParameter
    var argument: STArgument
}

/// InOut: copied in before the call and back afterwards.
nonisolated struct STInOutCode {
    var copyIn: (STRunState, DataNode) throws -> Place
    var copyBack: (STRunState, DataNode, Place) -> Void
}

/// The parameter transfers of a block call around its instance or parameter data.
nonisolated struct STParameterCode {
    var inputs: [(STRunState, DataNode) throws -> Void] = []
    var inOuts: [STInOutCode] = []
    var outputs: [(STRunState, DataNode) throws -> Void] = []

    /// Writes the inputs, copies InOuts in, calls, copies InOuts back and
    /// hands the outputs to their targets.
    func run(_ state: STRunState, _ data: DataNode, call: () throws -> Void) throws {
        for input in inputs {
            try input(state, data)
        }
        var locations: [Place] = []
        for inOut in inOuts {
            locations.append(try inOut.copyIn(state, data))
        }
        try call()
        for (inOut, location) in zip(inOuts, locations) {
            inOut.copyBack(state, data, location)
        }
        for output in outputs {
            try output(state, data)
        }
    }
}

// Calls of function blocks, functions and environment procedures.
nonisolated extension STChecker {
    func compileCallStatement(_ call: STCall) -> STExecutor? {
        guard let target = callTarget(call) else { return nil }
        switch target {
        case let .standard(function):
            guard let value = compileStandardCall(function, call, expected: nil, target: nil) else { return nil }
            let evaluate = value.evaluate
            return { state in
                _ = try evaluate(state)
                return .normal
            }
        case let .procedure(procedure):
            guard let code = compileProcedureCall(procedure, call) else { return nil }
            return { state in
                _ = try code(state)
                return .normal
            }
        case let .function(block):
            guard let code = compileFunctionCall(block, call) else { return nil }
            return { state in
                _ = try code(state)
                return .normal
            }
        case let .functionBlock(place, type, operation):
            return compileFunctionBlockCall(call, place: place, type: type, operation: operation)
        }
    }

    func compileCallExpression(_ call: STCall, expected: PLCDataType?, target: PLCDataType?) -> STValue? {
        guard let callTarget = callTarget(call) else { return nil }
        switch callTarget {
        case let .standard(function):
            return compileStandardCall(function, call, expected: expected, target: target)
        case let .procedure(procedure):
            guard let returnType = procedure.returnType else {
                error("\(procedure.name) has no return value and cannot be used in an expression.", at: call.range)
                return nil
            }
            guard let code = compileProcedureCall(procedure, call) else { return nil }
            return STValue(type: returnType, untyped: nil, constant: nil, evaluate: { state in
                (try code(state))?.converted(to: returnType) ?? returnType.defaultValue
            }, range: call.range)
        case let .function(block):
            guard let returned = block.returnValue else {
                switch dialect {
                case .siemens: error("\(call.callee.text) has no return value (Void) and cannot be used in an expression.", at: call.range)
                case .melsec: error("\(call.callee.text) has no return value and cannot be used in an expression.", at: call.range)
                }
                return nil
            }
            guard let returnType = returned.member.type.elementary else {
                notPermitted(.int, at: call.range, hint: "A function returning \(typeName(returned.member.type)) can only be assigned to a tag of that type.")
                return nil
            }
            guard let code = compileFunctionCall(block, call) else { return nil }
            let index = returned.index
            return STValue(type: returnType, untyped: nil, constant: nil, evaluate: { state in
                let area = try code(state)
                guard index < area.children.count else { throw STChecker.invalidAccess() }
                return area.children[index].read()
            }, range: call.range)
        case .functionBlock:
            error("A function block call cannot be used in an expression; call it as a statement and read its outputs.", at: call.range)
            return nil
        }
    }

    /// A function call whose return value is used whole (structures, arrays).
    func compileFunctionCall(_ call: STCall) -> (BlockHandle, (STRunState) throws -> DataNode)? {
        guard let target = callTarget(call) else { return nil }
        guard case let .function(block) = target else {
            error("\(call.callee.text) does not return a value of this data type.", at: call.range)
            return nil
        }
        guard let code = compileFunctionCall(block, call) else { return nil }
        return (block, code)
    }

    // MARK: - Finding the callee

    func callTarget(_ call: STCall) -> STCallTarget? {
        let callee = call.callee
        let count = callee.steps.count
        if count == 0 {
            switch callee.root {
            case let .plain(name):
                if let procedure = resolver.procedure(named: name) { return .procedure(procedure) }
                if let function = STStandardLibrary.function(named: name) { return .standard(function) }
                if let block = resolver.userBlock(named: name) { return blockTarget(block, callee) }
            case let .global(name):
                if let block = resolver.userBlock(named: name) { return blockTarget(block, callee) }
            case .local:
                break
            case let .absolute(text):
                error("\(text) cannot be called.", at: callee.range)
                return nil
            }
            if isUndefinedCallee(callee.root) {
                if Self.isPlaceholder(callee.root.text) {
                    reportUndefined(callee.root, at: callee.rootRange)
                    return nil
                }
                switch dialect {
                case .siemens:
                    error("Block or instruction \"\(callee.root.text)\" not defined.", at: callee.rootRange)
                case .melsec:
                    error("Function or function block \"\(callee.root.text)\" is not defined.", at: callee.rootRange)
                }
                return nil
            }
        }
        if count > 0, case let .member(name, range) = callee.steps[count - 1] {
            guard let base = resolvePlace(callee, stepCount: count - 1) else { return nil }
            if case let .instance(type) = base.type, let builtIn = type.builtIn, !builtIn.operations.isEmpty {
                guard let operation = builtIn.operations.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) else {
                    let names = builtIn.operations.map(\.rawValue).joined(separator: ", ")
                    error("\(name) is not an operation of \(type.name); use \(names).", at: range)
                    return nil
                }
                return .functionBlock(base, type, operation)
            }
            guard let place = resolveStep(count - 1, of: callee, on: base) else { return nil }
            return instanceTarget(place)
        }
        guard let place = resolvePlace(callee) else { return nil }
        return instanceTarget(place)
    }

    /// A plain or quoted callee name that names nothing at all.
    private func isUndefinedCallee(_ name: SymbolName) -> Bool {
        if case .local = name { return false }
        do {
            return try resolver.resolve(name) == nil
        } catch {
            return false
        }
    }

    private func blockTarget(_ block: BlockHandle, _ callee: STOperand) -> STCallTarget? {
        switch block.kind {
        case .function:
            return .function(block)
        case .functionBlock:
            switch dialect {
            case .siemens:
                error("The function block \"\(block.name)\" needs an instance: call its instance data block or a multi-instance, e.g. #\(block.name)_Instance(…).", at: callee.range)
            case .melsec:
                error("The function block \(block.name) must be called through an instance label.", at: callee.range)
            }
            return nil
        case .organizationBlock:
            error("The organization block \"\(block.name)\" cannot be called.", at: callee.range)
            return nil
        }
    }

    private func instanceTarget(_ place: STPlace) -> STCallTarget? {
        let text = place.operand.text
        guard case let .instance(type) = place.type else {
            error("\(text) is not a function block instance and cannot be called.", at: place.operand.range)
            return nil
        }
        if let builtIn = type.builtIn, let first = builtIn.operations.first {
            error("The \(type.name) instance \(text) needs an operation, e.g. \(text).\(first.rawValue)(…).", at: place.operand.range)
            return nil
        }
        return .functionBlock(place, type, nil)
    }

    // MARK: - Blocks

    private func compileFunctionBlockCall(_ call: STCall, place: STPlace, type: FunctionBlockType,
                                          operation: BuiltInFunctionBlock?) -> STExecutor? {
        let parameters = FunctionBlockLibrary.callParameters(of: type, operation: operation)
        guard let code = compileParameters(call, parameters: parameters, isFunction: false) else { return nil }
        let locate = place.locate
        return { state in
            guard case let .node(instance) = try locate(state) else { throw STChecker.invalidAccess() }
            try code.run(state, instance) {
                try state.frame.context.callFunctionBlock(type, instance: instance, operation: operation)
            }
            return .normal
        }
    }

    /// An FC call: parameters in a fresh area, run, then outputs out. Returns the area (for the return value).
    func compileFunctionCall(_ block: BlockHandle, _ call: STCall) -> ((STRunState) throws -> DataNode)? {
        guard let code = compileParameters(call, parameters: block.callParameters, isFunction: true) else { return nil }
        let name = block.displayName
        return { [weak block] state in
            guard let block else { throw RuntimeFault(.blockNotLoaded, "\(name) is not loaded in the CPU.") }
            let area = block.makeInstanceArea()
            try code.run(state, area) {
                try state.frame.context.run(block, instance: area)
            }
            return area
        }
    }

    /// Matches named arguments to parameters and checks directions and completeness.
    private func bindArguments(_ call: STCall, parameters: [CallParameter], isFunction: Bool) -> [STBoundArgument]? {
        let callee = call.callee.text
        var bound: [STBoundArgument] = []
        var assigned: Set<String> = []
        var valid = true
        for argument in call.arguments {
            guard let name = argument.name else {
                error("Parameters of \(callee) must be named, e.g. IN := …; positional arguments are only possible for standard functions.",
                      at: argument.range)
                valid = false
                continue
            }
            let nameRange = argument.nameRange ?? argument.range
            if name.caseInsensitiveCompare("EN") == .orderedSame || name.caseInsensitiveCompare("ENO") == .orderedSame {
                error("\(name.uppercased()) of block calls is not supported in this simulator.", at: nameRange)
                valid = false
                continue
            }
            guard let parameter = parameters.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                switch dialect {
                case .siemens: error("Parameter \(name) not defined for \(callee).", at: nameRange)
                case .melsec: error("\(callee) has no argument named \(name).", at: nameRange)
                }
                valid = false
                continue
            }
            guard assigned.insert(parameter.name.lowercased()).inserted else {
                error("Parameter \(parameter.name) is assigned more than once.", at: nameRange)
                valid = false
                continue
            }
            switch parameter.section {
            case .input where argument.isOutput:
                error("The input parameter \(parameter.name) must be assigned with ':='.", at: nameRange)
                valid = false
            case .inOut where argument.isOutput:
                error("The in/out parameter \(parameter.name) must be assigned with ':='.", at: nameRange)
                valid = false
            case .output where !argument.isOutput && dialect == .siemens:
                error("The output parameter \(parameter.name) must be assigned with '=>'.", at: nameRange)
                valid = false
            default:
                break
            }
            bound.append(STBoundArgument(parameter: parameter, argument: argument))
        }
        for parameter in parameters where !assigned.contains(parameter.name.lowercased()) {
            let required: Bool
            switch parameter.section {
            case .inOut: required = true
            case .input: required = isFunction
            case .output: required = isFunction && dialect == .siemens
            default: required = false
            }
            guard required else { continue }
            let kind = parameter.section == .inOut ? "in/out parameter" : (parameter.section == .output ? "output parameter" : "input parameter")
            error("The \(kind) \(parameter.name) of \(callee) must be supplied.", at: call.callee.range)
            valid = false
        }
        return valid ? bound : nil
    }

    private func parameterMismatch(actual: PLCType, formal: PLCType, at range: STSourceRange) {
        switch dialect {
        case .siemens:
            error("The data type \(typeName(actual)) of the actual parameter does not match the data type \(typeName(formal)) of the formal parameter.", at: range)
        case .melsec:
            error("Type mismatch: the argument is \(typeName(actual)) but the parameter needs \(typeName(formal)).", at: range)
        }
    }

    /// The operand an output or in/out parameter writes to.
    private func parameterTarget(_ bound: STBoundArgument) -> STPlace? {
        guard let operand = bound.argument.value.operand else {
            let kind = bound.parameter.section == .output ? "output" : "in/out"
            error("The \(kind) parameter \(bound.parameter.name) needs a tag, not an expression.", at: bound.argument.value.range)
            _ = compileExpression(bound.argument.value, expected: nil)
            return nil
        }
        guard let place = resolvePlace(operand), checkWritable(place) else { return nil }
        return place
    }

    private func compileParameters(_ call: STCall, parameters: [CallParameter], isFunction: Bool) -> STParameterCode? {
        guard let bindings = bindArguments(call, parameters: parameters, isFunction: isFunction) else {
            for argument in call.arguments where argument.name == nil || !argument.isOutput {
                _ = compileExpression(argument.value, expected: nil)
            }
            return nil
        }
        var code = STParameterCode()
        var valid = true
        for bound in bindings {
            let child = bound.parameter.memberIndex
            let formal = bound.parameter.type
            switch bound.parameter.section {
            case .output:
                guard let target = parameterTarget(bound) else {
                    valid = false
                    continue
                }
                let locate = target.locate
                if let type = formal.elementary {
                    guard let targetType = target.type.elementary,
                          type == targetType || PLCTypeRules.canConvertImplicitly(from: type, to: targetType, dialect: dialect)
                    else {
                        parameterMismatch(actual: target.type, formal: formal, at: target.operand.range)
                        valid = false
                        continue
                    }
                    let convert = conversion(from: type, to: targetType)
                    let store = recordingStore(target, type: targetType)
                    code.outputs.append { state, data in
                        let value = data.children[child].read()
                        _ = store(state, try locate(state), convert?(value) ?? value)
                    }
                } else {
                    guard Self.identical(target.type, formal) else {
                        parameterMismatch(actual: target.type, formal: formal, at: target.operand.range)
                        valid = false
                        continue
                    }
                    code.outputs.append { state, data in
                        guard case let .node(node) = try locate(state) else { throw STChecker.invalidAccess() }
                        node.assign(from: data.children[child])
                    }
                }
                markWritten(target)
            case .inOut:
                guard let target = parameterTarget(bound) else {
                    valid = false
                    continue
                }
                guard Self.identical(target.type, formal) else {
                    parameterMismatch(actual: target.type, formal: formal, at: target.operand.range)
                    valid = false
                    continue
                }
                checkTempRead(target)
                markWritten(target)
                let locate = target.locate
                if let type = formal.elementary {
                    let site = addSite(target.operand.range, text: target.operand.text, type: type)
                    code.inOuts.append(STInOutCode(copyIn: { state, data in
                        let location = try locate(state)
                        data.children[child].write(location.read())
                        return location
                    }, copyBack: { state, data, location in
                        location.write(data.children[child].read())
                        state.trace?.record(site, location.read())
                    }))
                } else {
                    code.inOuts.append(STInOutCode(copyIn: { state, data in
                        let location = try locate(state)
                        guard case let .node(node) = location else { throw STChecker.invalidAccess() }
                        data.children[child].assign(from: node)
                        return location
                    }, copyBack: { _, data, location in
                        if case let .node(node) = location {
                            node.assign(from: data.children[child])
                        }
                    }))
                }
            default:
                if let type = formal.elementary {
                    guard let value = compileExpression(bound.argument.value, expected: type, target: type),
                          let coerced = coerce(value, to: type, for: .parameter)
                    else {
                        valid = false
                        continue
                    }
                    let evaluate = coerced.evaluate
                    code.inputs.append { state, data in
                        data.children[child].write(try evaluate(state))
                    }
                } else {
                    guard let operand = bound.argument.value.operand else {
                        error("The parameter \(bound.parameter.name) of data type \(typeName(formal)) needs a tag of that data type.",
                              at: bound.argument.value.range)
                        valid = false
                        continue
                    }
                    guard let source = resolvePlace(operand) else {
                        valid = false
                        continue
                    }
                    guard Self.identical(source.type, formal) else {
                        parameterMismatch(actual: source.type, formal: formal, at: operand.range)
                        valid = false
                        continue
                    }
                    checkTempRead(source)
                    let locate = source.locate
                    code.inputs.append { state, data in
                        guard case let .node(node) = try locate(state) else { throw STChecker.invalidAccess() }
                        data.children[child].assign(from: node)
                    }
                }
            }
        }
        return valid ? code : nil
    }

    // MARK: - Environment procedures

    /// A call of an environment instruction (GX Works SET, RST, OUT_T…) with
    /// positional arguments (or all named).
    func compileProcedureCall(_ procedure: NativeProcedure, _ call: STCall) -> ((STRunState) throws -> PLCValue?)? {
        let parameters = procedure.parameters
        var ordered: [STArgument?] = Array(repeating: nil, count: parameters.count)
        let named = call.arguments.filter { $0.name != nil }
        if named.isEmpty {
            guard call.arguments.count == parameters.count else {
                let list = parameters.map(\.name).joined(separator: ", ")
                error("\(procedure.name) needs \(parameters.count) argument\(parameters.count == 1 ? "" : "s") (\(list)), not \(call.arguments.count).",
                      at: call.range)
                return nil
            }
            ordered = call.arguments.map { Optional($0) }
        } else {
            guard named.count == call.arguments.count else {
                error("Use either named or positional arguments for \(procedure.name), not both.", at: call.range)
                return nil
            }
            for argument in call.arguments {
                guard let name = argument.name,
                      let index = parameters.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                else {
                    error("\(procedure.name) has no argument named \(argument.name ?? "").", at: argument.nameRange ?? argument.range)
                    return nil
                }
                guard ordered[index] == nil else {
                    error("Argument \(parameters[index].name) is assigned more than once.", at: argument.nameRange ?? argument.range)
                    return nil
                }
                ordered[index] = argument
            }
            if let missing = ordered.firstIndex(where: { $0 == nil }) {
                error("Argument \(parameters[missing].name) of \(procedure.name) must be supplied.", at: call.range)
                return nil
            }
        }
        var compiled: [STProcedureArgument] = []
        var valid = true
        for (parameter, slot) in zip(parameters, ordered) {
            guard let argument = slot else { continue }
            if parameter.isOutput {
                guard let operand = argument.value.operand else {
                    error("Argument \(parameter.name) of \(procedure.name) needs a tag to write to.", at: argument.value.range)
                    valid = false
                    continue
                }
                guard let place = resolvePlace(operand), checkWritable(place) else {
                    valid = false
                    continue
                }
                guard let placeType = place.type.elementary else {
                    notPermitted(.bool, at: operand.range, hint: "Argument \(parameter.name) needs an elementary operand.")
                    valid = false
                    continue
                }
                if let type = parameter.type, type != placeType, !PLCTypeRules.canConvertImplicitly(from: type, to: placeType, dialect: dialect) {
                    parameterMismatch(actual: place.type, formal: .elementary(type), at: operand.range)
                    valid = false
                    continue
                }
                markWritten(place)
                compiled.append(.place(place.locate, addSite(operand.range, text: operand.text, type: placeType)))
            } else {
                guard let value = compileExpression(argument.value, expected: parameter.type, target: parameter.type) else {
                    valid = false
                    continue
                }
                if let type = parameter.type {
                    guard let coerced = coerce(value, to: type, for: .parameter) else {
                        valid = false
                        continue
                    }
                    compiled.append(.value(coerced.evaluate))
                } else {
                    compiled.append(.value(Self.typed(value).evaluate))
                }
            }
        }
        guard valid else { return nil }
        let run = procedure.run
        return { state in
            var arguments: [NativeProcedure.Argument] = []
            arguments.reserveCapacity(compiled.count)
            for item in compiled {
                switch item {
                case let .value(evaluate): arguments.append(.value(try evaluate(state)))
                case let .place(locate, _): arguments.append(.place(try locate(state)))
                }
            }
            let result = try run(arguments, state.frame)
            if let trace = state.trace {
                for (item, argument) in zip(compiled, arguments) {
                    if case let .place(_, site) = item, case let .place(location) = argument {
                        trace.record(site, location.read())
                    }
                }
            }
            return result
        }
    }
}
