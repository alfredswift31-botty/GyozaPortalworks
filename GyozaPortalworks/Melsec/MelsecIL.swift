import Foundation

/// A cell of the ladder grid: row (0-based, in the whole ladder) and column
/// (0…10 contacts, 11 the coil/instruction column).
nonisolated struct MelsecCellRef: Hashable, Comparable, Codable, Sendable {
    var row: Int
    var column: Int

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    static func < (lhs: MelsecCellRef, rhs: MelsecCellRef) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// One instruction of the instruction list, with parsed operands.
nonisolated struct MelsecInstruction: Hashable, Sendable {
    var definition: MelsecInstructionDefinition
    var operands: [MelsecOperand]
    /// The ladder cell it was converted from.
    var cell: MelsecCellRef?

    init(_ definition: MelsecInstructionDefinition, _ operands: [MelsecOperand] = [], cell: MelsecCellRef? = nil) {
        self.definition = definition
        self.operands = operands
        self.cell = cell
    }

    var mnemonic: String { definition.mnemonic }
    var steps: Int { MelsecInstructionSet.steps(definition, operands: operands) }

    /// "OUT T0 K50", "LD>= D0 K10", "P0".
    func text(_ profile: MelsecCPUProfile) -> String {
        if definition.kind == .pointerLabel {
            return operands.first?.text(profile) ?? "P?"
        }
        return ([mnemonic] + operands.map { $0.text(profile) }).joined(separator: " ")
    }
}

/// One line of the Conversion Result window / instruction list.
nonisolated struct MelsecListingLine: Hashable, Sendable {
    var step: Int
    var code: String
}

/// A program as a list of instructions, ending with END.
nonisolated struct MelsecILProgram: Hashable, Sendable {
    var instructions: [MelsecInstruction]

    init(_ instructions: [MelsecInstruction] = []) {
        self.instructions = instructions
    }

    /// The step number of each instruction, and of the position after the last.
    var stepNumbers: [Int] {
        var numbers: [Int] = []
        numbers.reserveCapacity(instructions.count + 1)
        var step = 0
        for instruction in instructions {
            numbers.append(step)
            step += instruction.steps
        }
        numbers.append(step)
        return numbers
    }

    /// Total program size in steps.
    var stepCount: Int { stepNumbers.last ?? 0 }

    /// Step | Code, as the Conversion Result window shows it.
    func listing(_ profile: MelsecCPUProfile) -> [MelsecListingLine] {
        let steps = stepNumbers
        return instructions.enumerated().map { index, instruction in
            MelsecListingLine(step: steps[index], code: instruction.text(profile))
        }
    }
}

/// How an operand looks to the type checker.
nonisolated enum MelsecOperandShape: Hashable, Sendable {
    case bitDevice(MelsecDeviceKind)
    case wordDevice(MelsecDeviceKind)
    case longIndex
    case timerCounter(MelsecDeviceKind, MelsecDeviceFacet)
    case digit(count: Int, MelsecDeviceKind)
    case wordBit
    case integerConstant(Int64)
    case realConstant
    /// A label with an elementary type (or a Timer/Counter member).
    case elementaryLabel(PLCDataType, isConstant: Bool)
    /// A whole Timer/Counter label.
    case timerCounterLabel(MelsecDeviceKind)
    /// A label that is an array or has no ladder meaning.
    case otherLabel
    case pointer
    case nesting
    case unspecified
}

/// Parses operands and checks them against what an instruction expects.
nonisolated enum MelsecOperandChecker {
    /// Parses one operand of `definition`. Throws MelsecOperandError with a
    /// GX Works3-like message.
    static func parse(_ text: String, profile: MelsecCPUProfile) throws -> MelsecOperand {
        try MelsecOperandParser.parse(text, profile: profile)
    }

    /// The operand behind a label: its device assignment or constant value;
    /// the label itself otherwise. Throws for labels that aren't declared.
    static func shape(of operand: MelsecOperand, scope: MelsecLabelScope, profile: MelsecCPUProfile) throws -> MelsecOperandShape {
        switch operand {
        case let .device(device, _):
            if device.kind.isBitDevice { return .bitDevice(device.kind) }
            if device.kind.isWordDevice { return .wordDevice(device.kind) }
            if device.kind == .longIndexRegister { return .longIndex }
            return .timerCounter(device.kind, device.facet)
        case let .digit(count, start, _):
            return .digit(count: count, start.kind)
        case .wordBit:
            return .wordBit
        case let .constant(constant):
            switch constant {
            case let .decimal(value), let .hexadecimal(value): return .integerConstant(value)
            case .real: return .realConstant
            }
        case .pointer:
            return .pointer
        case .nesting:
            return .nesting
        case .unspecified:
            return .unspecified
        case let .label(name):
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let base = parts.first, let label = scope.label(named: base) else {
                throw MelsecOperandError(message: "The label '\(name)' is not declared.")
            }
            let member = parts.count > 1 ? parts[1] : nil
            if label.hasDevice, member == nil {
                let device = try MelsecOperandParser.parse(label.device, profile: profile)
                return try shape(of: device, scope: MelsecLabelScope(), profile: profile)
            }
            if let kind = label.dataType.element.timerCounterKind, !label.dataType.isArray {
                guard let member else { return .timerCounterLabel(kind) }
                switch member.uppercased() {
                case "S", "C": return .elementaryLabel(.bool, isConstant: false)
                case "N": return .elementaryLabel(kind == .longCounter ? .udint : .int, isConstant: false)
                default: throw MelsecOperandError(message: "'\(name)': \(label.dataType.text) has no member '\(member)' (S, C, N).")
                }
            }
            guard member == nil else {
                throw MelsecOperandError(message: "'\(name)': \(label.name) is not a structure.")
            }
            guard let type = label.dataType.elementaryType else { return .otherLabel }
            return .elementaryLabel(type, isConstant: label.labelClass.isConstant)
        }
    }

    /// Why `operand` can't be used as `role` of `mnemonic`; nil when it can.
    static func problem(_ operand: MelsecOperand, role: MelsecOperandRole, mnemonic: String,
                        scope: MelsecLabelScope, profile: MelsecCPUProfile) -> String? {
        let shape: MelsecOperandShape
        do {
            shape = try self.shape(of: operand, scope: scope, profile: profile)
        } catch let error as MelsecOperandError {
            return error.message
        } catch {
            return "'\(operand.text(profile))' cannot be used."
        }
        let text = operand.text(profile)
        let mismatch = "'\(text)' cannot be used as an operand of \(mnemonic) (operand type mismatch)."
        if shape == .unspecified {
            return "An operand of \(mnemonic) has not been entered ('?')."
        }
        switch role {
        case .bitSource:
            switch shape {
            case .bitDevice, .wordBit, .timerCounterLabel: return nil
            case let .timerCounter(_, facet): return facet == .value ? mismatch : nil
            case let .elementaryLabel(type, _): return type == .bool ? nil : mismatch
            default: return mismatch
            }
        case .bitDestination:
            switch shape {
            case let .bitDevice(kind):
                return kind == .input ? "'\(text)': X (input) cannot be used as an output of \(mnemonic)." : nil
            case .wordBit: return nil
            case let .elementaryLabel(type, isConstant):
                if isConstant { return "'\(text)' is a constant and cannot be written." }
                return type == .bool ? nil : mismatch
            default: return mismatch
            }
        case let .value(width, write):
            return valueProblem(operand, shape: shape, width: width, write: write, text: text, mismatch: mismatch, profile: profile)
        case let .wideDestination(words):
            guard case let .device(device, _) = operand, device.kind.isWordDevice else {
                return "'\(text)': \(mnemonic) needs a word device here (the result takes \(words) words)."
            }
            if !profile.contains(device.kind, device.number + words - 1) {
                return "'\(text)': the \(words)-word result would reach beyond \(profile.rangeText(device.kind))."
            }
            return nil
        case .count:
            switch shape {
            case let .integerConstant(value):
                return value >= 0 && value <= 65535 ? nil : "'\(text)' is out of range for \(mnemonic)."
            case .wordDevice: return nil
            case let .elementaryLabel(type, _): return type == .int || type == .uint ? nil : mismatch
            default: return mismatch
            }
        case .resetTarget:
            switch shape {
            case let .bitDevice(kind): return kind == .input ? "'\(text)': X (input) cannot be reset." : nil
            case .wordBit, .wordDevice, .longIndex, .timerCounterLabel: return nil
            case let .timerCounter(_, facet): return facet == .whole || facet == .value ? nil : mismatch
            case let .elementaryLabel(_, isConstant): return isConstant ? "'\(text)' is a constant and cannot be written." : nil
            default: return mismatch
            }
        case .rangeDevice:
            switch shape {
            case let .bitDevice(kind): return kind == .input ? "'\(text)': X (input) cannot be reset." : nil
            case .wordDevice: return nil
            case let .timerCounter(_, facet): return facet == .whole ? nil : mismatch
            default: return mismatch
            }
        case .pointer:
            return shape == .pointer ? nil : "\(mnemonic) needs a pointer (P0-P\(profile.pointerCount - 1)), not '\(text)'."
        case .nesting:
            return shape == .nesting ? nil : "\(mnemonic) needs a nesting number (N0-N\(profile.nestingLevels - 1)), not '\(text)'."
        case .timerOrCounterCoil:
            let timerOnly = mnemonic == "OUTH" || mnemonic == "OUTHS"
            let kind: MelsecDeviceKind
            switch shape {
            case let .timerCounter(deviceKind, .whole): kind = deviceKind
            case let .timerCounterLabel(labelKind): kind = labelKind
            default: return timerOnly ? "\(mnemonic) needs a timer (T or ST), not '\(text)'." : mismatch
            }
            if timerOnly, !kind.isTimer {
                return "\(mnemonic) needs a timer (T or ST), not '\(text)'."
            }
            return nil
        case .setValue:
            switch shape {
            case let .integerConstant(value):
                return value >= 0 && value <= 4_294_967_295 ? nil : "The set value '\(text)' is out of range."
            case .wordDevice: return nil
            case let .elementaryLabel(type, _): return type.isInteger ? nil : mismatch
            default: return "The set value must be a decimal constant (K) or a word device, not '\(text)'."
            }
        case let .bitArray(write):
            guard case let .bitDevice(kind) = shape else {
                return "'\(text)': \(mnemonic) needs a bit device here."
            }
            return write && kind == .input ? "'\(text)': X (input) cannot be written by \(mnemonic)." : nil
        }
    }

    private static func valueProblem(_ operand: MelsecOperand, shape: MelsecOperandShape, width: MelsecValueWidth, write: Bool,
                                     text: String, mismatch: String, profile: MelsecCPUProfile) -> String? {
        switch shape {
        case let .integerConstant(value):
            if write { return "The constant '\(text)' cannot be a destination." }
            switch width {
            case .word:
                return (-32768...65535).contains(value) ? nil : "'\(text)' is out of the 16-bit range (K-32768 to K32767)."
            case .doubleWord:
                return (-2_147_483_648...4_294_967_295).contains(value) ? nil : "'\(text)' is out of the 32-bit range."
            case .real:
                return nil
            }
        case .realConstant:
            if write { return "The constant '\(text)' cannot be a destination." }
            return width == .real ? nil : mismatch
        case let .wordDevice(kind):
            if width != .word, case let .device(device, nil) = operand, !profile.contains(kind, device.number + 1) {
                return "'\(text)' is the last \(kind.rawValue) device: a 32-bit value needs two words."
            }
            return nil
        case .longIndex:
            return width == .doubleWord ? nil : mismatch
        case let .timerCounter(kind, facet):
            guard facet == .whole || facet == .value else { return mismatch }
            switch width {
            case .word: return kind == .longCounter ? mismatch : nil
            case .doubleWord: return nil
            case .real: return mismatch
            }
        case let .digit(count, kind):
            if write, kind == .input { return "'\(text)': X (input) cannot be a destination." }
            switch width {
            case .word: return count <= 4 ? nil : "'\(text)': a 16-bit operand takes K1 to K4."
            case .doubleWord: return nil
            case .real: return mismatch
            }
        case let .elementaryLabel(type, isConstant):
            if write, isConstant { return "'\(text)' is a constant and cannot be written." }
            switch width {
            case .word: return type == .int || type == .uint || type == .word ? nil : mismatch
            case .doubleWord: return type == .dint || type == .udint || type == .dword || type == .time ? nil : mismatch
            case .real: return type == .real ? nil : mismatch
            }
        default:
            return mismatch
        }
    }

    /// Parses and checks the operand texts of one instruction. Returns the
    /// operands, or the problems (one per bad operand, or one for a wrong
    /// operand count).
    static func operands(for definition: MelsecInstructionDefinition, texts: [String], scope: MelsecLabelScope,
                         profile: MelsecCPUProfile) -> (operands: [MelsecOperand], problems: [String]) {
        let mnemonic = definition.mnemonic
        var operands: [MelsecOperand] = []
        var problems: [String] = []
        for text in texts {
            do {
                operands.append(try parse(text, profile: profile))
            } catch let error as MelsecOperandError {
                problems.append(error.message)
                operands.append(.unspecified)
            } catch {
                problems.append("'\(text)' cannot be used.")
                operands.append(.unspecified)
            }
        }
        guard problems.isEmpty else { return (operands, problems) }
        guard var form = definition.form(operandCount: operands.count) else {
            let counts = definition.operandCounts.map(String.init).joined(separator: " or ")
            return (operands, ["\(mnemonic) takes \(counts) operand\(counts == "1" ? "" : "s"), not \(operands.count)."])
        }
        // OUT: one operand for a coil, two for a timer or counter with its set value.
        if definition.kind == .output, let first = operands.first {
            let shape = try? self.shape(of: first, scope: scope, profile: profile)
            var isTimerCounter = false
            if case .timerCounter(_, .whole)? = shape { isTimerCounter = true }
            if case .timerCounterLabel? = shape { isTimerCounter = true }
            if isTimerCounter, operands.count == 1 {
                return (operands, ["'\(first.text(profile))': enter the set value after the timer/counter (e.g. OUT \(first.text(profile)) K10)."])
            }
            if let other = definition.forms.first(where: { $0.operands.count == operands.count }) {
                form = other
            }
        }
        for (operand, spec) in zip(operands, form.operands) {
            if let problem = problem(operand, role: spec.role, mnemonic: mnemonic, scope: scope, profile: profile) {
                problems.append(problem)
            }
        }
        return (operands, problems)
    }
}

/// A problem found while reading instruction-list text.
nonisolated struct MelsecILError: Hashable, Sendable {
    /// 1-based line of the text.
    var line: Int
    var message: String
}

/// Reads instruction-list text: one instruction per line or several per
/// line ("LD X0   OR Y0   ANI X1   OUT Y0"), optional leading step numbers,
/// pointer labels ("P0") at the start of a line, and `;` comments.
nonisolated enum MelsecILParser {
    static func parse(_ text: String, scope: MelsecLabelScope = MelsecLabelScope(),
                      profile: MelsecCPUProfile = .fx5u) -> (program: MelsecILProgram, errors: [MelsecILError]) {
        var instructions: [MelsecInstruction] = []
        var errors: [MelsecILError] = []

        var pending: MelsecPendingInstruction?

        func flush() {
            guard let current = pending else { return }
            pending = nil
            if current.definition.kind == .pointerLabel {
                if let operand = try? MelsecOperandParser.parse(current.operands.first ?? "", profile: profile) {
                    instructions.append(MelsecInstruction(current.definition, [operand]))
                }
                return
            }
            let result = MelsecOperandChecker.operands(for: current.definition, texts: current.operands, scope: scope, profile: profile)
            for problem in result.problems {
                errors.append(MelsecILError(line: current.line, message: problem))
            }
            instructions.append(MelsecInstruction(current.definition, result.operands))
        }

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let content = rawLine.components(separatedBy: ";").first ?? ""
            let tokens = content.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            var skipped = 0
            if let first = tokens.first, first.allSatisfy({ $0.isASCII && $0.isNumber }) {
                skipped = 1
            }
            for (position, token) in tokens.enumerated() where position >= skipped {
                let atLineStart = position == skipped
                if let definition = MelsecInstructionSet.definition(token) {
                    flush()
                    pending = MelsecPendingInstruction(definition: definition, operands: [], line: lineNumber)
                    continue
                }
                if atLineStart, case .pointer? = try? MelsecOperandParser.parse(token, profile: profile) {
                    flush()
                    pending = MelsecPendingInstruction(definition: MelsecInstructionSet.pointerLabel, operands: [token], line: lineNumber)
                    continue
                }
                guard pending != nil else {
                    errors.append(MelsecILError(line: lineNumber, message: "'\(token)' is not an instruction."))
                    continue
                }
                pending?.operands.append(token)
            }
        }
        flush()

        if let endIndex = instructions.firstIndex(where: { $0.definition.kind == .end }) {
            if endIndex != instructions.count - 1 {
                errors.append(MelsecILError(line: 0, message: "Instructions after END are never executed."))
                instructions.removeSubrange((endIndex + 1)...)
            }
        } else if let end = MelsecInstructionSet.definition("END") {
            instructions.append(MelsecInstruction(end))
        }
        return (MelsecILProgram(instructions), errors)
    }
}

/// An instruction whose operands are still being collected by MelsecILParser.
nonisolated private struct MelsecPendingInstruction {
    var definition: MelsecInstructionDefinition
    var operands: [String]
    var line: Int
}
