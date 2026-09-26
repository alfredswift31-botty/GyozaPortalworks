import Foundation

/// One compiled IF / ELSIF branch.
nonisolated private struct STCompiledBranch {
    var condition: STEvaluator
    var body: STExecutor
    var site: Int
    /// Marked as executed when the condition is evaluated (ELSIF headers).
    var lines: ClosedRange<Int>?
}

/// One step of an assignment chain: takes the incoming value, stores it
/// and returns the value now held by the target.
typealias STAssignmentStep = (STRunState, PLCValue) throws -> PLCValue

// Statements.
nonisolated extension STChecker {
    func compileBody(_ statements: [STStatement]) -> STExecutor {
        compileStatements(statements)
    }

    func compileStatements(_ statements: [STStatement]) -> STExecutor {
        Self.sequence(statements.compactMap(compileStatement))
    }

    static func sequence(_ executors: [STExecutor]) -> STExecutor {
        if executors.isEmpty { return { _ in .normal } }
        if executors.count == 1 { return executors[0] }
        return { state in
            for executor in executors {
                let flow = try executor(state)
                if flow != .normal { return flow }
            }
            return .normal
        }
    }

    private func compileStatement(_ statement: STStatement) -> STExecutor? {
        let body: STExecutor?
        switch statement.kind {
        case let .assignment(targets, value):
            body = compileAssignment(targets, value)
        case let .call(call):
            body = compileCallStatement(call)
        case let .ifThen(branches, elseBody, elseRange):
            body = compileIf(branches, elseBody: elseBody, elseRange: elseRange)
        case let .caseOf(selector, keywordRange, branches, elseBody, elseRange):
            body = compileCase(selector, keywordRange: keywordRange, branches: branches, elseBody: elseBody, elseRange: elseRange)
        case let .forLoop(loop):
            body = compileFor(loop)
        case let .whileLoop(keywordRange, condition, loopBody):
            body = compileWhile(keywordRange: keywordRange, condition: condition, body: loopBody)
        case let .repeatLoop(loopBody, untilRange, condition):
            body = compileRepeat(body: loopBody, untilRange: untilRange, condition: condition)
        case .exitLoop, .continueLoop:
            let isExit: Bool
            if case .exitLoop = statement.kind { isExit = true } else { isExit = false }
            guard loopDepth > 0 else {
                let word = isExit ? "EXIT" : "CONTINUE"
                switch dialect {
                case .siemens: error("\(word) is only permitted in a FOR, WHILE or REPEAT loop.", at: statement.range)
                case .melsec: error("\(word) can only be used inside FOR, WHILE or REPEAT.", at: statement.range)
                }
                return nil
            }
            let flow: STFlow = isExit ? .exitLoop : .continueLoop
            body = { _ in flow }
        case .returnBlock:
            body = { _ in .returnBlock }
        case .empty:
            body = { _ in .normal }
        case let .region(_, regionBody):
            if dialect == .melsec {
                error("REGION is not available in GX Works.", at: statement.headerRange)
                _ = compileStatements(regionBody)
                return nil
            }
            // A region only groups statements; its own line isn't a statement.
            return compileStatements(regionBody)
        }
        guard let body else { return nil }
        return located(body, lines: statement.headerRange.lines)
    }

    /// Marks the statement's lines as executed and says where a fault happened.
    private func located(_ body: @escaping STExecutor, lines: ClosedRange<Int>) -> STExecutor {
        let location = "Line \(lines.lowerBound)"
        return { state in
            state.trace?.markExecuted(lines)
            do {
                return try body(state)
            } catch let fault as RuntimeFault {
                throw STProgram.locate(fault, in: state.frame, location: location)
            } catch {
                throw RuntimeFault(.invalidOperation, "\(error)", block: state.frame.block.displayName, location: location)
            }
        }
    }

    // MARK: - Assignment

    private func compileAssignment(_ targets: [STAssignmentTarget], _ valueExpression: STExpression) -> STExecutor? {
        if dialect == .melsec, let offending = targets.first(where: { $0.operation != .assign }) ?? (targets.count > 1 ? targets[1] : nil) {
            if offending.operation != .assign {
                error("Compound assignment '\(offending.operation.symbol)' is not available in GX Works; write x := x + y.", at: offending.operatorRange)
            } else {
                error("Multiple assignment (a := b := c) is not available in GX Works.", at: offending.operatorRange)
            }
            _ = compileExpression(valueExpression, expected: nil)
            return nil
        }
        let places = targets.map { resolvePlace($0.operand) }
        if targets.count == 1, let place = places[0], place.type.elementary == nil, targets[0].operation == .assign {
            return compileAggregateAssignment(place, valueExpression)
        }
        var valid = !places.contains { $0 == nil }
        var types: [PLCDataType] = []
        for (target, place) in zip(targets, places) {
            guard let place else { continue }
            guard let type = place.type.elementary else {
                error(target.operation == .assign
                      ? "A structure, array or instance can only be assigned alone, not in a multiple assignment."
                      : "'\(target.operation.symbol)' needs an elementary data type, not \(typeName(place.type)).",
                      at: place.operand.range)
                valid = false
                continue
            }
            types.append(type)
        }
        let lastType = places.last.flatMap { $0?.type.elementary }
        let isPlainLast = targets.last?.operation == .assign
        let value = compileExpression(valueExpression, expected: lastType, target: isPlainLast ? lastType : nil)
        guard valid, let value, types.count == targets.count else { return nil }
        let checked = places.compactMap { $0 }
        for place in checked where !checkWritable(place) {
            valid = false
        }
        guard valid else { return nil }

        // The rightmost target takes the value first.
        let lastIndex = targets.count - 1
        let evaluateValue: STEvaluator
        var incoming: PLCDataType
        if targets[lastIndex].operation == .assign {
            guard let coerced = coerce(value, to: types[lastIndex], for: .assignment) else { return nil }
            evaluateValue = coerced.evaluate
            incoming = types[lastIndex]
        } else {
            let current = Self.constant(types[lastIndex].defaultValue, type: types[lastIndex], range: checked[lastIndex].operand.range)
            let adaptedValue = adaptPair(current, value, expected: types[lastIndex]).1
            evaluateValue = adaptedValue.evaluate
            incoming = adaptedValue.type
        }
        var steps: [STAssignmentStep] = []
        for index in stride(from: lastIndex, through: 0, by: -1) {
            guard let step = assignmentStep(checked[index], type: types[index], operation: targets[index].operation,
                                            incoming: incoming, operatorRange: targets[index].operatorRange,
                                            valueRange: index == lastIndex ? value.range : checked[index + 1].operand.range)
            else { return nil }
            steps.append(step)
            incoming = types[index]
        }
        for place in checked {
            markWritten(place)
        }
        return { state in
            var current = try evaluateValue(state)
            for step in steps {
                current = try step(state, current)
            }
            return .normal
        }
    }

    /// Stores into `place` (`:=`) or combines with it first (`+=` …).
    private func assignmentStep(_ place: STPlace, type: PLCDataType, operation: STAssignmentOperator, incoming: PLCDataType,
                                operatorRange: STSourceRange, valueRange: STSourceRange) -> STAssignmentStep? {
        let locate = place.locate
        guard let binary = operation.binary else {
            guard incoming == type || PLCTypeRules.canConvertImplicitly(from: incoming, to: type, dialect: dialect) else {
                reportConversion(from: incoming, to: type, at: valueRange, for: .assignment)
                return nil
            }
            let convert = conversion(from: incoming, to: type)
            let store = recordingStore(place, type: type)
            return { state, value in
                let location = try locate(state)
                return store(state, location, convert?(value) ?? value)
            }
        }
        checkTempRead(place)
        guard let plan = self.plan(binary, String(operation.symbol.dropLast()), type, incoming, range: operatorRange) else { return nil }
        guard plan.resultType == type || PLCTypeRules.canConvertImplicitly(from: plan.resultType, to: type, dialect: dialect) else {
            reportConversion(from: plan.resultType, to: type, at: operatorRange, for: .assignment)
            return nil
        }
        let convertCurrent = conversion(from: type, to: plan.leftType)
        let convertValue = conversion(from: incoming, to: plan.rightType)
        let convertResult = conversion(from: plan.resultType, to: type)
        let apply = plan.apply
        let store = recordingStore(place, type: type)
        return { state, value in
            let location = try locate(state)
            let current = location.read()
            let result = try apply(convertCurrent?(current) ?? current, convertValue?(value) ?? value)
            return store(state, location, convertResult?(result) ?? result)
        }
    }

    private func compileAggregateAssignment(_ place: STPlace, _ valueExpression: STExpression) -> STExecutor? {
        if case .instance = place.type {
            error("A function block instance cannot be assigned.", at: place.operand.range)
            return nil
        }
        guard checkWritable(place) else {
            _ = compileExpression(valueExpression, expected: nil)
            return nil
        }
        let destination = place.locate
        if let operand = valueExpression.operand {
            guard let source = resolvePlace(operand) else { return nil }
            guard Self.identical(source.type, place.type) else {
                reportAggregateMismatch(from: source.type, to: place.type, at: operand.range, for: .assignment)
                return nil
            }
            checkTempRead(source)
            markWritten(place)
            let origin = source.locate
            return { state in
                guard case let .node(from) = try origin(state), case let .node(to) = try destination(state) else {
                    throw STChecker.invalidAccess()
                }
                to.assign(from: from)
                return .normal
            }
        }
        if case let .call(call) = Self.unparenthesized(valueExpression) {
            guard let compiled = compileFunctionCall(call) else { return nil }
            let (block, code) = compiled
            guard let returned = block.returnValue, Self.identical(returned.member.type, place.type) else {
                let returnType = block.returnValue?.member.type
                if let returnType {
                    reportAggregateMismatch(from: returnType, to: place.type, at: call.range, for: .assignment)
                } else {
                    error("\(call.callee.text) has no return value.", at: call.range)
                }
                return nil
            }
            markWritten(place)
            let index = returned.index
            return { state in
                let area = try code(state)
                guard case let .node(to) = try destination(state), index < area.children.count else { throw STChecker.invalidAccess() }
                to.assign(from: area.children[index])
                return .normal
            }
        }
        _ = compileExpression(valueExpression, expected: nil)
        switch dialect {
        case .siemens:
            error("Data type \(typeName(place.type)) is not permitted here: assign a tag of the same data type.", at: valueExpression.range)
        case .melsec:
            error("Type mismatch: \(place.operand.text) can only be assigned from a label of the same data type.", at: valueExpression.range)
        }
        return nil
    }

    static func unparenthesized(_ expression: STExpression) -> STExpression {
        if case let .parenthesized(inner, _) = expression { return unparenthesized(inner) }
        return expression
    }

    // MARK: - IF and CASE

    private func compileIf(_ branches: [STConditionalBranch], elseBody: [STStatement]?, elseRange: STSourceRange?) -> STExecutor? {
        var compiled: [STCompiledBranch] = []
        var valid = true
        for (position, branch) in branches.enumerated() {
            let condition = compileCondition(branch.condition)
            let site = addSite(branch.keywordRange, text: branch.keyword, type: .bool)
            let body = compileStatements(branch.body)
            if let condition {
                compiled.append(STCompiledBranch(condition: condition.evaluate, body: body, site: site,
                                                 lines: position == 0 ? nil : branch.headerRange.lines))
            } else {
                valid = false
            }
        }
        let otherwise = elseBody.map(compileStatements)
        guard valid else { return nil }
        let elseLines = elseRange?.lines
        return { state in
            for branch in compiled {
                if let lines = branch.lines { state.trace?.markExecuted(lines) }
                let result = try branch.condition(state).boolValue
                state.trace?.record(branch.site, .bool(result))
                if result { return try branch.body(state) }
            }
            if let otherwise {
                if let elseLines { state.trace?.markExecuted(elseLines) }
                return try otherwise(state)
            }
            return .normal
        }
    }

    private func compileCase(_ selectorExpression: STExpression, keywordRange: STSourceRange, branches: [STCaseBranch],
                             elseBody: [STStatement]?, elseRange: STSourceRange?) -> STExecutor? {
        var selector = compileExpression(selectorExpression, expected: nil)
        if let value = selector, value.untyped != nil { selector = Self.typed(value) }
        if let value = selector, !value.type.isInteger {
            notPermitted(value.type, at: value.range, hint: "The CASE expression must be an integer or a bit string.")
            selector = nil
        }
        let type = selector?.type ?? .dint
        var single: [Int64: Int] = [:]
        var ranges: [(low: Int64, high: Int64, branch: Int)] = []
        var intervals: [(low: Int64, high: Int64)] = []
        var bodies: [STExecutor] = []
        var labelLines: [ClosedRange<Int>] = []
        var valid = selector != nil
        for (index, branch) in branches.enumerated() {
            for label in branch.labels {
                let low = caseLabelValue(label.low, type: type)
                let high = label.high.map { caseLabelValue($0, type: type) } ?? low
                guard let low, let high else {
                    valid = false
                    continue
                }
                guard low <= high else {
                    error("Invalid CASE range \(low)..\(high): the first value must not be greater than the second.", at: label.range)
                    valid = false
                    continue
                }
                if intervals.contains(where: { low <= $0.high && $0.low <= high }) {
                    let what = low == high ? "value \(low)" : "range \(low)..\(high)"
                    switch dialect {
                    case .siemens: error("The CASE \(what) is already used by another label.", at: label.range)
                    case .melsec: error("Duplicate CASE label: the \(what) is already used.", at: label.range)
                    }
                    valid = false
                    continue
                }
                intervals.append((low, high))
                if low == high {
                    single[low] = index
                } else {
                    ranges.append((low, high, index))
                }
            }
            bodies.append(compileStatements(branch.body))
            labelLines.append(branch.labelRange.lines)
        }
        let otherwise = elseBody.map(compileStatements)
        guard valid, let selector else { return nil }
        let evaluate = selector.evaluate
        let site = addSite(keywordRange, text: text(keywordRange), type: type)
        let elseLines = elseRange?.lines
        return { state in
            let value = try evaluate(state)
            state.trace?.record(site, value)
            let key = value.intValue
            var chosen = single[key]
            if chosen == nil {
                chosen = ranges.first { key >= $0.low && key <= $0.high }?.branch
            }
            if let chosen {
                state.trace?.markExecuted(labelLines[chosen])
                return try bodies[chosen](state)
            }
            if let otherwise {
                if let elseLines { state.trace?.markExecuted(elseLines) }
                return try otherwise(state)
            }
            return .normal
        }
    }

    /// A CASE label's value: a constant that fits the selector's data type.
    private func caseLabelValue(_ expression: STExpression, type: PLCDataType) -> Int64? {
        guard let value = compileExpression(expression, expected: type) else { return nil }
        guard value.constant != nil else {
            error("A CASE label must be a constant.", at: value.range)
            return nil
        }
        guard let coerced = coerce(value, to: type, for: .operand), let constant = coerced.constant else { return nil }
        return constant.intValue
    }

    // MARK: - Loops

    private func compileFor(_ loop: STForLoop) -> STExecutor? {
        let counter = resolvePlace(loop.variable)
        var type: PLCDataType?
        if let counter {
            if let elementary = counter.type.elementary, elementary.isSignedInteger || elementary.isUnsignedInteger {
                type = elementary
            } else {
                notPermitted(counter.type.elementary ?? .bool, at: counter.operand.range,
                             hint: "The FOR loop counter must be an integer (SInt, Int, DInt, USInt, UInt or UDInt).")
            }
        }
        let first = compileBound(loop.start, type: type)
        let last = compileBound(loop.end, type: type)
        let step = loop.step.map { compileBound($0, type: type) }
        let writable = counter.map(checkWritable) ?? false
        if let counter { markWritten(counter) }
        if let step, let increment = step?.constant, increment.intValue == 0 {
            error("The increment of a FOR loop must not be 0.", at: step?.range ?? loop.variable.range)
        }
        loopDepth += 1
        let identity = counter?.identity
        if let identity { forCounters.append(identity) }
        let body = compileStatements(loop.body)
        if identity != nil { forCounters.removeLast() }
        loopDepth -= 1
        guard let counter, let type, writable, let first, let last, let range = type.integerRange else { return nil }
        let stepValue: STValue
        if let step {
            guard let step else { return nil }
            guard step.constant?.intValue != 0 else { return nil }
            stepValue = step
        } else {
            stepValue = Self.constant(.int(1), type: type, range: loop.variable.range)
        }
        let locate = counter.locate
        let store = recordingStore(counter, type: type)
        let evaluateFirst = first.evaluate
        let evaluateLast = last.evaluate
        let evaluateStep = stepValue.evaluate
        return { state in
            let start = try evaluateFirst(state)
            let end = try evaluateLast(state).intValue
            let increment = try evaluateStep(state).intValue
            let location = try locate(state)
            var current = store(state, location, start).intValue
            while increment >= 0 ? current <= end : current >= end {
                try state.frame.context.countLoopIteration()
                let flow = try body(state)
                if flow == .exitLoop { break }
                if flow == .returnBlock { return .returnBlock }
                let next = location.read().intValue + increment
                // Stop instead of wrapping around when the counter's type is exhausted.
                guard range.contains(next) else { break }
                current = store(state, location, .int(next)).intValue
            }
            return .normal
        }
    }

    /// A FOR start, end or step value, converted to the counter's data type.
    private func compileBound(_ expression: STExpression, type: PLCDataType?) -> STValue? {
        guard let value = compileExpression(expression, expected: type, target: type) else { return nil }
        guard let type else { return nil }
        return coerce(value, to: type, for: .assignment)
    }

    private func compileWhile(keywordRange: STSourceRange, condition: STExpression, body: [STStatement]) -> STExecutor? {
        let test = compileCondition(condition)
        let site = addSite(keywordRange, text: text(keywordRange), type: .bool)
        loopDepth += 1
        let loopBody = compileStatements(body)
        loopDepth -= 1
        guard let test else { return nil }
        let evaluate = test.evaluate
        return { state in
            while true {
                let result = try evaluate(state).boolValue
                state.trace?.record(site, .bool(result))
                guard result else { break }
                try state.frame.context.countLoopIteration()
                let flow = try loopBody(state)
                if flow == .exitLoop { break }
                if flow == .returnBlock { return .returnBlock }
            }
            return .normal
        }
    }

    private func compileRepeat(body: [STStatement], untilRange: STSourceRange, condition: STExpression) -> STExecutor? {
        loopDepth += 1
        let loopBody = compileStatements(body)
        loopDepth -= 1
        let test = compileCondition(condition)
        let site = addSite(untilRange, text: text(untilRange), type: .bool)
        guard let test else { return nil }
        let evaluate = test.evaluate
        let untilLines = untilRange.lines
        return { state in
            while true {
                try state.frame.context.countLoopIteration()
                let flow = try loopBody(state)
                if flow == .exitLoop { break }
                if flow == .returnBlock { return .returnBlock }
                state.trace?.markExecuted(untilLines)
                let result = try evaluate(state).boolValue
                state.trace?.record(site, .bool(result))
                if result { break }
            }
            return .normal
        }
    }
}
