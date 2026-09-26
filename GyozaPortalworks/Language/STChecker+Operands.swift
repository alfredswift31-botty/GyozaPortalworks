import Foundation

// Names, access paths and the storage they locate.
nonisolated extension STChecker {
    /// Resolves an operand and its access path (or only its first
    /// `stepCount` steps). Reports and returns nil when any part is wrong.
    func resolvePlace(_ operand: STOperand, stepCount: Int? = nil) -> STPlace? {
        guard var place = rootPlace(operand) else { return nil }
        for step in operand.steps.prefix(stepCount ?? operand.steps.count) {
            guard let next = apply(step, to: place, operand: operand) else { return nil }
            place = next
        }
        return place
    }

    /// Applies one access step of `operand` to `place`.
    func resolveStep(_ index: Int, of operand: STOperand, on place: STPlace) -> STPlace? {
        apply(operand.steps[index], to: place, operand: operand)
    }

    func rootPlace(_ operand: STOperand) -> STPlace? {
        let name = operand.root
        if dialect == .siemens, isENO(name) {
            return enoPlace(operand)
        }
        let binding: SymbolBinding?
        do {
            binding = try resolver.resolve(name)
        } catch let problem as ResolveError {
            error(problem.message, at: operand.rootRange)
            return nil
        } catch let other {
            error("\(other)", at: operand.rootRange)
            return nil
        }
        guard let binding else {
            if isENO(name) { return enoPlace(operand) }
            reportUndefined(name, at: operand.rootRange)
            return nil
        }
        switch binding {
        case let .local(area, index, member):
            let locate: STLocator = { state in .node(state.frame.node(area, index)) }
            return STPlace(type: member.type, locate: locate, isWritable: true, constantValue: nil, fixed: nil,
                           tempIndex: area == .temp ? index : nil,
                           identity: (area == .temp ? "temp:" : "instance:") + String(index), operand: operand)
        case let .constant(_, value, type):
            let stored = value.converted(to: type)
            let cell = Place.cell(Cell.constant(stored, type: type))
            return STPlace(type: .elementary(type), locate: { _ in cell }, isWritable: false, constantValue: stored,
                           fixed: cell, tempIndex: nil, identity: nil, operand: operand)
        case let .global(symbol):
            let place = symbol.place
            return STPlace(type: place.type, locate: { _ in place }, isWritable: symbol.isWritable, constantValue: nil,
                           fixed: place, tempIndex: nil, identity: "global:" + symbol.displayName.lowercased(), operand: operand)
        }
    }

    private func isENO(_ name: SymbolName) -> Bool {
        guard case let .plain(text) = name else { return false }
        return text.caseInsensitiveCompare("ENO") == .orderedSame
    }

    /// `ENO`: the block's enable output (`ENO := FALSE;`).
    private func enoPlace(_ operand: STOperand) -> STPlace {
        let locate: STLocator = { state in
            let frame = state.frame
            return .cell(Cell(type: .bool, read: { .bool(frame.enableOutput) }, write: { frame.enableOutput = $0.boolValue }))
        }
        return STPlace(type: .elementary(.bool), locate: locate, isWritable: true, constantValue: nil, fixed: nil,
                       tempIndex: nil, identity: "ENO", operand: operand)
    }

    /// TIA's instruction placeholders: `_bool_in_`, `_time_in_`, `_int_out_`.
    static func isPlaceholder(_ name: String) -> Bool {
        for suffix in ["_in_", "_out_", "_inout_"] where name.hasPrefix("_") && name.hasSuffix(suffix) {
            let middle = name.dropFirst().dropLast(suffix.count)
            if !middle.isEmpty && middle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                return true
            }
        }
        return false
    }

    func reportUndefined(_ name: SymbolName, at range: STSourceRange) {
        if Self.isPlaceholder(name.text) {
            error("Placeholder \(name.text) must be replaced with an operand.", at: range)
            return
        }
        switch dialect {
        case .siemens:
            switch name {
            case let .local(text): error("Tag #\(text) not defined.", at: range)
            case let .global(text), let .plain(text): error("Tag \"\(text)\" not defined.", at: range)
            case let .absolute(text): error("Operand \(text) not defined.", at: range)
            }
        case .melsec:
            error("Label or device \"\(name.text)\" is not defined.", at: range)
        }
    }

    private func reportUndefinedMember(_ operand: STOperand, through step: STSourceRange) {
        let path = text(STSourceRange(start: operand.range.start, end: step.end))
        switch dialect {
        case .siemens: error("Tag \(path) not defined.", at: step)
        case .melsec: error("Label or device \"\(path)\" is not defined.", at: step)
        }
    }

    // MARK: - Access steps

    private func apply(_ step: STAccessStep, to place: STPlace, operand: STOperand) -> STPlace? {
        if place.constantValue != nil {
            notPermitted(place.type.elementary ?? .int, at: step.range, hint: "A constant has no members, elements or bits.")
            return nil
        }
        switch step {
        case let .member(name, range):
            return member(name, of: place, at: range, operand: operand)
        case let .index(expressions, range):
            var result = place
            for expression in expressions {
                guard let next = element(expression, of: result, at: range, operand: operand) else { return nil }
                result = next
            }
            return result
        case let .slice(text, range):
            guard dialect == .siemens else {
                error("Slice access such as .%X3 is not available in GX Works; write the bit number, e.g. D0.3.", at: range)
                return nil
            }
            return slice(text, of: place, at: range, operand: operand)
        case let .bitNumber(digits, range):
            guard dialect == .melsec else {
                error("Bit access is written .%X\(digits) in SCL.", at: range)
                return nil
            }
            guard digits.count == 1, let bit = Int(digits) else {
                error("Invalid bit number '\(digits)': use one hexadecimal digit, 0 to F.", at: range)
                return nil
            }
            return bitOfWord(bit, of: place, at: range, operand: operand)
        }
    }

    private func member(_ name: String, of place: STPlace, at range: STSourceRange, operand: STOperand) -> STPlace? {
        let members: [PLCMember]
        switch place.type {
        case let .structure(_, list):
            members = list
        case let .instance(block):
            members = block.members
        case let .elementary(type):
            if dialect == .melsec, type.isInteger, name.count == 1, let bit = Int(name, radix: 16) {
                return bitOfWord(bit, of: place, at: range, operand: operand)
            }
            reportUndefinedMember(operand, through: range)
            return nil
        case .array:
            reportUndefinedMember(operand, through: range)
            return nil
        }
        guard let index = members.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            reportUndefinedMember(operand, through: range)
            return nil
        }
        var result = place
        result.type = members[index].type
        result.identity = place.identity.map { "\($0).\(index)" }
        if let fixed = place.fixed {
            guard case let .node(node) = fixed, index < node.children.count else {
                reportUndefinedMember(operand, through: range)
                return nil
            }
            let child = Place.node(node.children[index])
            result.fixed = child
            result.locate = { _ in child }
        } else {
            let base = place.locate
            result.locate = { state in
                guard case let .node(node) = try base(state), index < node.children.count else { throw STChecker.invalidAccess() }
                return .node(node.children[index])
            }
        }
        return result
    }

    private func element(_ expression: STExpression, of place: STPlace, at range: STSourceRange, operand: STOperand) -> STPlace? {
        guard case let .array(lower, upper, elementType) = place.type else {
            let path = text(STSourceRange(start: operand.range.start, end: range.start))
            error("\(path) is not an array.", at: range)
            return nil
        }
        guard let value = compileExpression(expression, expected: .dint) else { return nil }
        let index: STValue
        if let literal = value.untyped {
            guard case let .integer(number) = literal else {
                notPermitted(value.type, at: value.range, hint: "An array index must be an integer.")
                return nil
            }
            index = Self.constant(.int(number), type: .dint, range: value.range)
        } else {
            let type = value.type
            guard type.isSignedInteger || type.isUnsignedInteger || (dialect == .siemens && type.isBitString) else {
                notPermitted(type, at: value.range, hint: "An array index must be an integer.")
                return nil
            }
            index = value
        }
        var result = place
        result.type = elementType
        if let constant = index.constant {
            let number = constant.intValue
            guard number >= Int64(lower) && number <= Int64(upper) else {
                error("Index \(number) is outside the array limits [\(lower)..\(upper)].", at: value.range)
                return nil
            }
            let position = Int(number) - lower
            result.identity = place.identity.map { "\($0)[\(number)]" }
            if let fixed = place.fixed {
                guard case let .node(node) = fixed, position < node.children.count else { return nil }
                let child = Place.node(node.children[position])
                result.fixed = child
                result.locate = { _ in child }
            } else {
                let base = place.locate
                result.locate = { state in
                    guard case let .node(node) = try base(state), position < node.children.count else { throw STChecker.invalidAccess() }
                    return .node(node.children[position])
                }
            }
            return result
        }
        let base = place.locate
        let evaluate = index.evaluate
        let path = text(STSourceRange(start: operand.range.start, end: range.start))
        result.fixed = nil
        result.identity = nil
        result.locate = { state in
            let container = try base(state)
            let number = try evaluate(state).intValue
            guard case let .node(node) = container, let child = node.element(Int(number)) else {
                throw RuntimeFault(.indexOutOfRange, "Array index \(number) is outside the limits [\(lower)..\(upper)] of \(path).")
            }
            return .node(child)
        }
        return result
    }

    /// TIA slice access: `.%X3`, `.%B1`, `.%W0`, `.%D0`.
    private func slice(_ text: String, of place: STPlace, at range: STSourceRange, operand: STOperand) -> STPlace? {
        let upper = text.uppercased()
        let widths: [Character: Int] = ["X": 1, "B": 8, "W": 16, "D": 32]
        guard upper.count >= 3, upper.hasPrefix("%"),
              let letter = upper.dropFirst().first, let width = widths[letter],
              let position = Int(upper.dropFirst(2)), upper.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            error("Invalid slice access '.\(text)': use .%X<bit>, .%B<byte>, .%W<word> or .%D<double word>.", at: range)
            return nil
        }
        guard case let .elementary(type) = place.type, type.isInteger else {
            notPermitted(place.type.elementary ?? .bool, at: range, hint: "Slice access needs a bit string or an integer.")
            return nil
        }
        guard width < type.bitWidth, (position + 1) * width <= type.bitWidth else {
            error("The slice .\(text) is outside the \(type.bitWidth) bits of \(typeName(type)).", at: range)
            return nil
        }
        return sliced(place, width: width, index: position)
    }

    /// GX Works bit-of-word: `D0.3`, `D0.F`.
    private func bitOfWord(_ bit: Int, of place: STPlace, at range: STSourceRange, operand: STOperand) -> STPlace? {
        guard case let .elementary(type) = place.type, type.isInteger else {
            notPermitted(place.type.elementary ?? .bool, at: range, hint: "A bit number needs a word device or an integer label.")
            return nil
        }
        guard bit < type.bitWidth else {
            error("Bit \(String(bit, radix: 16, uppercase: true)) is outside the \(type.bitWidth) bits of \(typeName(type)).", at: range)
            return nil
        }
        return sliced(place, width: 1, index: bit)
    }

    private func sliced(_ place: STPlace, width: Int, index: Int) -> STPlace? {
        var result = place
        let sliceType: PLCDataType = width == 1 ? .bool : (Self.bitString(width: width) ?? .dword)
        result.type = .elementary(sliceType)
        result.identity = place.identity.map { "\($0).%\(width):\(index)" }
        if let fixed = place.fixed {
            guard let piece = fixed.slice(width: width, index: index) else { return nil }
            result.fixed = piece
            result.locate = { _ in piece }
        } else {
            let base = place.locate
            result.locate = { state in
                guard let piece = try base(state).slice(width: width, index: index) else { throw STChecker.invalidAccess() }
                return piece
            }
        }
        return result
    }

    // MARK: - Reading and writing

    /// Reads an elementary place, recording its value for the monitor.
    func readValue(_ place: STPlace) -> STValue? {
        guard case let .elementary(type) = place.type else {
            switch dialect {
            case .siemens:
                error("Data type \(typeName(place.type)) is not permitted here.", at: place.operand.range)
            case .melsec:
                error("Type mismatch: \(place.operand.text) (\(typeName(place.type))) cannot be used in an expression.", at: place.operand.range)
            }
            return nil
        }
        checkTempRead(place)
        let site = addSite(place.operand.range, text: place.operand.text, type: type)
        if let constant = place.constantValue {
            return STValue(type: type, untyped: nil, constant: constant, evaluate: { state in
                state.trace?.record(site, constant)
                return constant
            }, range: place.operand.range)
        }
        let locate = place.locate
        return STValue(type: type, untyped: nil, constant: nil, evaluate: { state in
            let value = try locate(state).read()
            state.trace?.record(site, value)
            return value
        }, range: place.operand.range)
    }

    /// Reports writes to read-only operands, constants and running FOR counters.
    func checkWritable(_ place: STPlace) -> Bool {
        if !place.isWritable {
            switch dialect {
            case .siemens:
                error("The tag is read-only.", at: place.operand.range)
            case .melsec:
                let what = place.constantValue != nil ? "the constant" : "the read-only operand"
                error("Cannot write \(what) \(place.operand.text).", at: place.operand.range)
            }
            return false
        }
        if let identity = place.identity, forCounters.contains(identity) {
            error("The FOR loop counter \(place.operand.text) cannot be changed inside the loop.", at: place.operand.range)
            return false
        }
        return true
    }

    /// Temp variables have no defined value until written (TIA warns on this).
    func checkTempRead(_ place: STPlace) {
        guard dialect == .siemens, let index = place.tempIndex,
              !writtenTemps.contains(index), !warnedTemps.contains(index)
        else { return }
        warnedTemps.insert(index)
        warning("The temporary tag \(text(place.operand.rootRange)) is read before it is written; its value is undefined.",
                at: place.operand.rootRange)
    }

    func markWritten(_ place: STPlace) {
        if let index = place.tempIndex {
            writtenTemps.insert(index)
        }
    }

    /// Records a place's value after it was written, for the monitor.
    func recordingStore(_ place: STPlace, type: PLCDataType) -> (STRunState, Place, PLCValue) -> PLCValue {
        let site = addSite(place.operand.range, text: place.operand.text, type: type)
        return { state, location, value in
            location.write(value)
            let stored = location.read()
            state.trace?.record(site, stored)
            return stored
        }
    }
}
