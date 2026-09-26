import Foundation

/// Where a contact sits in the logic: starting a block, in series or in
/// parallel. Decides LD/AND/OR in the instruction list.
nonisolated enum MelsecLogicPosition: String, Hashable, Sendable {
    case load = "LD"
    case and = "AND"
    case or = "OR"
}

/// The contact symbols of the ladder editor.
nonisolated enum MelsecContactKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// Open contact (F5): LD / AND / OR.
    case normallyOpen
    /// Close contact (F6): LDI / ANI / ORI.
    case normallyClosed
    /// Rising pulse (Shift+F7): LDP / ANDP / ORP.
    case risingEdge
    /// Falling pulse (Shift+F8): LDF / ANDF / ORF.
    case fallingEdge
    /// Rising pulse close: LDPI / ANDPI / ORPI.
    case risingEdgeNegated
    /// Falling pulse close: LDFI / ANDFI / ORFI.
    case fallingEdgeNegated

    func mnemonic(_ position: MelsecLogicPosition) -> String {
        let suffix: String
        switch self {
        case .normallyOpen: suffix = ""
        case .normallyClosed: suffix = "I"
        case .risingEdge: suffix = "P"
        case .fallingEdge: suffix = "F"
        case .risingEdgeNegated: suffix = "PI"
        case .fallingEdgeNegated: suffix = "FI"
        }
        if self == .normallyClosed && position == .and { return "ANI" }
        return position.rawValue + suffix
    }

    var isPulse: Bool { self != .normallyOpen && self != .normallyClosed }
}

/// INV, MEP and MEF: they act on the operation result so far.
nonisolated enum MelsecOperationResultKind: String, Codable, CaseIterable, Hashable, Sendable {
    case invert = "INV"
    case risingPulse = "MEP"
    case fallingPulse = "MEF"
}

/// Operand size for comparisons and data instructions: none (16-bit),
/// D (32-bit) or E (FLOAT [Single Precision]).
nonisolated enum MelsecValueWidth: Hashable, Sendable {
    case word
    case doubleWord
    case real

    /// The mnemonic prefix: "", "D", "E".
    var prefix: String {
        switch self {
        case .word: return ""
        case .doubleWord: return "D"
        case .real: return "E"
        }
    }

    var integerWidth: MelsecIntegerWidth? {
        switch self {
        case .word: return .word
        case .doubleWord: return .doubleWord
        case .real: return nil
        }
    }
}

/// What an application instruction computes.
nonisolated enum MelsecDataOperation: Hashable, Sendable {
    case move(MelsecValueWidth)
    case blockMove
    case fillMove
    case zoneReset
    /// `+ - * /` and ADD/SUB/MUL/DIV; `*` and `/` write a double-size result.
    case arithmetic(ArithmeticOperator, MelsecValueWidth)
    case increment(MelsecIntegerWidth)
    case decrement(MelsecIntegerWidth)
    case negate(MelsecIntegerWidth)
    case toBCD(MelsecIntegerWidth)
    case fromBCD(MelsecIntegerWidth)
    /// INT2FLT / DINT2FLT.
    case integerToFloat(MelsecIntegerWidth)
    /// FLT2INT / FLT2DINT.
    case floatToInteger(MelsecIntegerWidth)
    case logic(BitLogicOperator, MelsecIntegerWidth)
    case rotate(left: Bool, throughCarry: Bool, MelsecIntegerWidth)
    /// SFTL (left) / SFTR (right): n1-bit array shifted by n2 bits.
    case shiftBits(left: Bool)
    /// SFT: one-bit shift from the device before (d) into (d).
    case shiftOne
    case compare(MelsecValueWidth)
    case zoneCompare(MelsecValueWidth)
}

nonisolated enum MelsecInstructionKind: Hashable, Sendable {
    case contact(MelsecContactKind, MelsecLogicPosition)
    case comparison(ComparisonOperator, MelsecValueWidth, MelsecLogicPosition)
    case blockAnd
    case blockOr
    case push
    case read
    case pop
    case operationResult(MelsecOperationResultKind)
    /// OUT: a bit coil, a timer (100 ms) or a counter.
    case output
    /// OUTH (10 ms) and OUTHS (1 ms) timers.
    case timerOutput(resolution: Int64)
    case set
    case reset
    case pulseRising
    case pulseFalling
    case flipFlop
    /// ALT (every scan) / ALTP (once per rising edge, `isPulse`).
    case alternate
    case masterControl
    case masterControlReset
    case jump
    case call
    case subroutineReturn
    case mainProgramEnd
    case end
    case noOperation
    /// A pointer label (P0) in front of a ladder block.
    case pointerLabel
    case data(MelsecDataOperation)
}

/// How an operand is used; decides which devices, constants and labels fit.
nonisolated enum MelsecOperandRole: Hashable, Sendable {
    /// A contact's device.
    case bitSource
    /// A coil's device (not X).
    case bitDestination
    /// A 16/32-bit or real value, read or written.
    case value(MelsecValueWidth, write: Bool)
    /// A result that takes `words` consecutive words: `/` (quotient and
    /// remainder), `D*` and `D/`.
    case wideDestination(words: Int)
    /// n, n1, n2: a count (constant or 16-bit value).
    case count
    /// RST: a bit, a word, a timer or a counter.
    case resetTarget
    /// ZRST's first and last device.
    case rangeDevice
    case pointer
    case nesting
    /// OUT/OUTH/OUTHS T0 or ST0 (or a Timer label); OUT C0/LC0 (or a Counter label).
    case timerOrCounterCoil
    /// The set value after a timer or counter coil: K or a word device.
    case setValue
    /// Start of a bit array: SFTL/SFTR source and destination, CMP's three
    /// result bits, SFT.
    case bitArray(write: Bool)
}

nonisolated struct MelsecOperandSpec: Hashable, Sendable {
    /// The manual's name: s, d, s1, n1…
    var name: String
    var role: MelsecOperandRole
}

/// One operand list an instruction accepts, with its step count.
nonisolated struct MelsecOperandForm: Hashable, Sendable {
    var operands: [MelsecOperandSpec]
    /// Program steps (FX3 step counts, used as an approximation for the
    /// FX5; see MelsecInstructionSet).
    var steps: Int
}

/// One instruction as the Element Selection window and F1 help describe it.
nonisolated struct MelsecInstructionDefinition: Hashable, Sendable {
    var mnemonic: String
    var kind: MelsecInstructionKind
    var forms: [MelsecOperandForm]
    /// P form of an application instruction: runs once per rising edge.
    var isPulse: Bool
    /// Runs without an execution condition and is drawn straight from the
    /// left bus (MCR, FEND, RET, END, NOP).
    var isUnconditional: Bool
    /// Element Selection path, e.g. ["Basic Instructions", "Data Transfer Instructions"].
    var palette: [String]
    /// One line for F1 help.
    var help: String

    func form(operandCount: Int) -> MelsecOperandForm? {
        forms.first { $0.operands.count == operandCount }
    }

    /// Whether the ladder draws it in the coil/instruction column.
    var isOutput: Bool {
        switch kind {
        case .contact, .comparison, .blockAnd, .blockOr, .push, .read, .pop, .operationResult, .pointerLabel:
            return false
        default:
            return true
        }
    }

    var operandCounts: [Int] { forms.map { $0.operands.count } }
}

/// The FX5U instruction set the simulator supports.
///
/// Step counts are the FX3 programming manual's (1 for basic contacts and
/// coils, 2 for pulse contacts, 5 for MOV, 7 for three-operand arithmetic…),
/// used as an approximation: the FX5's own step counts differ for some
/// instructions. They only affect the step numbers shown in the ladder and
/// the Conversion Result list.
nonisolated enum MelsecInstructionSet {
    /// Every instruction in Element Selection order.
    static let all: [MelsecInstructionDefinition] = build()

    private static let table: [String: MelsecInstructionDefinition] = {
        var table: [String: MelsecInstructionDefinition] = [:]
        for definition in all where table[definition.mnemonic] == nil {
            table[definition.mnemonic] = definition
        }
        return table
    }()

    static func definition(_ mnemonic: String) -> MelsecInstructionDefinition? {
        table[mnemonic.uppercased()]
    }

    /// Steps for an instruction with these operands: timer/counter coils,
    /// SET/RST and special-relay coils differ from the base form.
    static func steps(_ definition: MelsecInstructionDefinition, operands: [MelsecOperand]) -> Int {
        let base = definition.form(operandCount: operands.count)?.steps ?? definition.forms.first?.steps ?? 1
        let device = operands.first?.device
        let modifier = operands.contains { operand in
            switch operand {
            case let .device(_, index): return index != nil
            case let .digit(_, _, index): return index != nil
            case .wordBit: return true
            default: return false
            }
        } ? 1 : 0
        switch definition.kind {
        case .contact:
            return base + modifier
        case .output:
            if operands.count == 2 {
                return device?.kind == .longCounter ? 5 : 3
            }
            return (device?.kind == .specialRelay || device?.kind == .stepRelay ? 2 : 1) + modifier
        case .set:
            return (device?.kind == .specialRelay || device?.kind == .stepRelay ? 2 : 1) + modifier
        case .reset:
            guard let device else { return 1 }
            if device.kind.isTimerOrCounter { return 2 }
            if device.kind.isWordDevice || device.kind == .longIndexRegister { return 3 }
            return (device.kind == .specialRelay || device.kind == .stepRelay ? 2 : 1) + modifier
        default:
            return base
        }
    }

    // MARK: Table

    private static func build() -> [MelsecInstructionDefinition] {
        var list: [MelsecInstructionDefinition] = []

        func add(_ mnemonic: String, _ kind: MelsecInstructionKind, _ forms: [MelsecOperandForm],
                 palette: [String], help: String, pulse: Bool = false, unconditional: Bool = false) {
            list.append(MelsecInstructionDefinition(mnemonic: mnemonic, kind: kind, forms: forms, isPulse: pulse,
                                                    isUnconditional: unconditional, palette: palette, help: help))
        }

        /// A data instruction and its P form.
        func data(_ mnemonic: String, _ operation: MelsecDataOperation, _ forms: [MelsecOperandForm],
                  palette: [String], help: String) {
            add(mnemonic, .data(operation), forms, palette: palette, help: help)
            add(mnemonic + "P", .data(operation), forms, palette: palette,
                help: help + " Pulse form: runs once when the execution condition turns on.", pulse: true)
        }

        func spec(_ name: String, _ role: MelsecOperandRole) -> MelsecOperandSpec {
            MelsecOperandSpec(name: name, role: role)
        }

        func form(_ steps: Int, _ operands: MelsecOperandSpec...) -> MelsecOperandForm {
            MelsecOperandForm(operands: operands, steps: steps)
        }

        let word = MelsecOperandRole.value(.word, write: false)
        let wordOut = MelsecOperandRole.value(.word, write: true)
        let double = MelsecOperandRole.value(.doubleWord, write: false)
        let doubleOut = MelsecOperandRole.value(.doubleWord, write: true)
        let real = MelsecOperandRole.value(.real, write: false)
        let realOut = MelsecOperandRole.value(.real, write: true)

        // Contacts
        let contactPalette = ["Sequence Instructions", "Contact Instructions"]
        let contactHelp: [MelsecContactKind: String] = [
            .normallyOpen: "open contact: conducts while the device is ON.",
            .normallyClosed: "close contact: conducts while the device is OFF.",
            .risingEdge: "rising pulse: conducts for one scan when the device turns ON.",
            .fallingEdge: "falling pulse: conducts for one scan when the device turns OFF.",
            .risingEdgeNegated: "rising pulse close: conducts except for the scan in which the device turns ON.",
            .fallingEdgeNegated: "falling pulse close: conducts except for the scan in which the device turns OFF.",
        ]
        for position in [MelsecLogicPosition.load, .and, .or] {
            for kind in MelsecContactKind.allCases {
                let steps = kind.isPulse ? 2 : 1
                let placement: String
                switch position {
                case .load: placement = "Operation start,"
                case .and: placement = "Series connection,"
                case .or: placement = "Parallel connection,"
                }
                add(kind.mnemonic(position), .contact(kind, position), [form(steps, spec("s", .bitSource))],
                    palette: contactPalette, help: "\(placement) \(contactHelp[kind] ?? "")")
            }
        }

        // Association instructions
        let association = ["Sequence Instructions", "Association Instructions"]
        add("ANB", .blockAnd, [form(1)], palette: association, help: "Connects two ladder blocks in series (AND).")
        add("ORB", .blockOr, [form(1)], palette: association, help: "Connects two ladder blocks in parallel (OR).")
        add("MPS", .push, [form(1)], palette: association, help: "Stores the operation result (memory push).")
        add("MRD", .read, [form(1)], palette: association, help: "Reads the result stored by MPS.")
        add("MPP", .pop, [form(1)], palette: association, help: "Reads and clears the result stored by MPS (memory pop).")
        add("INV", .operationResult(.invert), [form(1)], palette: association, help: "Inverts the operation result so far.")
        add("MEP", .operationResult(.risingPulse), [form(1)], palette: association,
            help: "Turns the operation result so far into a one-scan pulse at its rising edge.")
        add("MEF", .operationResult(.fallingPulse), [form(1)], palette: association,
            help: "Turns the operation result so far into a one-scan pulse at its falling edge.")

        // Output instructions
        let output = ["Sequence Instructions", "Output Instructions"]
        add("OUT", .output, [form(1, spec("d", .bitDestination)), form(3, spec("d", .timerOrCounterCoil), spec("K/D", .setValue))],
            palette: output, help: "Outputs the operation result to a coil; OUT T0 K50 drives a 100 ms timer, OUT C0 K10 a counter.")
        add("OUTH", .timerOutput(resolution: 10), [form(3, spec("d", .timerOrCounterCoil), spec("K/D", .setValue))],
            palette: output, help: "Drives a high-speed (10 ms) timer: OUTH T0 K500 = 5.00 s.")
        add("OUTHS", .timerOutput(resolution: 1), [form(3, spec("d", .timerOrCounterCoil), spec("K/D", .setValue))],
            palette: output, help: "Drives an ultra-high-speed (1 ms) timer: OUTHS T0 K5000 = 5.000 s.")
        add("SET", .set, [form(1, spec("d", .bitDestination))], palette: output, help: "Turns the device ON and keeps it ON.")
        add("RST", .reset, [form(1, spec("d", .resetTarget))], palette: output,
            help: "Turns a bit OFF, clears a word to 0, or resets a timer/counter's current value and contact.")
        add("PLS", .pulseRising, [form(2, spec("d", .bitDestination))], palette: output,
            help: "Turns the device ON for one scan when the execution condition turns ON.")
        add("PLF", .pulseFalling, [form(2, spec("d", .bitDestination))], palette: output,
            help: "Turns the device ON for one scan when the execution condition turns OFF.")
        add("FF", .flipFlop, [form(2, spec("d", .bitDestination))], palette: output,
            help: "Inverts the device each time the execution condition turns ON.")
        add("ALT", .alternate, [form(3, spec("d", .bitDestination))], palette: output,
            help: "Inverts the device on every scan the execution condition is ON (use ALTP for push-on/push-off).")
        add("ALTP", .alternate, [form(3, spec("d", .bitDestination))], palette: output,
            help: "Inverts the device each time the execution condition turns ON.", pulse: true)
        add("SFT", .data(.shiftOne), [form(3, spec("d", .bitArray(write: true)))], palette: ["Sequence Instructions", "Shift Instructions"],
            help: "Shifts the device before (d) into (d) and turns the device before (d) OFF.")
        add("SFTP", .data(.shiftOne), [form(3, spec("d", .bitArray(write: true)))], palette: ["Sequence Instructions", "Shift Instructions"],
            help: "SFT once per rising edge of the execution condition.", pulse: true)

        // Master control, termination, branch
        let master = ["Sequence Instructions", "Master Control Instructions"]
        add("MC", .masterControl, [form(3, spec("n", .nesting), spec("d", .bitDestination))], palette: master,
            help: "Starts a master control zone: while OFF, coils in the zone drop and timers reset.")
        add("MCR", .masterControlReset, [form(2, spec("n", .nesting))], palette: master,
            help: "Ends the master control zone of nesting n.", unconditional: true)
        let termination = ["Sequence Instructions", "Termination Instructions"]
        add("FEND", .mainProgramEnd, [form(1)], palette: termination,
            help: "Ends the main routine; subroutines (P labels called by CALL) follow it.", unconditional: true)
        add("END", .end, [form(1)], palette: termination, help: "Ends the program.", unconditional: true)
        add("NOP", .noOperation, [form(1)], palette: ["Sequence Instructions", "No Operation Instructions"],
            help: "No operation.", unconditional: true)
        let branch = ["Application Instructions", "Program Branch Instructions"]
        add("CJ", .jump, [form(3, spec("P", .pointer))], palette: branch,
            help: "Jumps to pointer P while the execution condition is ON; the skipped instructions don't run.")
        let subroutine = ["Application Instructions", "Subroutine Program Call Instructions"]
        add("CALL", .call, [form(3, spec("P", .pointer))], palette: subroutine,
            help: "Calls the subroutine at pointer P (after FEND) while the execution condition is ON.")
        add("CALLP", .call, [form(3, spec("P", .pointer))], palette: subroutine,
            help: "Calls the subroutine at pointer P once per rising edge.", pulse: true)
        add("RET", .subroutineReturn, [form(1)], palette: subroutine,
            help: "Returns from a subroutine.", unconditional: true)
        add("SRET", .subroutineReturn, [form(1)], palette: subroutine,
            help: "FX3 name of RET: returns from a subroutine.", unconditional: true)

        // Comparison contacts
        let comparisonPalette = ["Basic Instructions", "Comparison Operation Instructions"]
        for width in [MelsecValueWidth.word, .doubleWord, .real] {
            let source: MelsecOperandRole = .value(width, write: false)
            let steps = width == .word ? 5 : 9
            let size = width == .word ? "16-bit" : (width == .doubleWord ? "32-bit" : "FLOAT")
            for position in [MelsecLogicPosition.load, .and, .or] {
                for op in [ComparisonOperator.equal, .notEqual, .greater, .less, .greaterOrEqual, .lessOrEqual] {
                    add(position.rawValue + width.prefix + op.rawValue, .comparison(op, width, position),
                        [form(steps, spec("s1", source), spec("s2", source))], palette: comparisonPalette,
                        help: "Conducts while s1 \(op.rawValue) s2 (\(size) comparison).")
                }
            }
        }

        // Arithmetic
        let arithmetic = ["Basic Instructions", "Arithmetic Operation Instructions"]
        for (symbol, op, name) in [("+", ArithmeticOperator.add, "Addition"), ("-", ArithmeticOperator.subtract, "Subtraction")] {
            data(symbol, .arithmetic(op, .word), [form(5, spec("s", word), spec("d", wordOut)), form(7, spec("s1", word), spec("s2", word), spec("d", wordOut))],
                 palette: arithmetic, help: "BIN 16-bit \(name.lowercased()): d \(symbol)= s, or d = s1 \(symbol) s2.")
            data("D" + symbol, .arithmetic(op, .doubleWord), [form(9, spec("s", double), spec("d", doubleOut)), form(13, spec("s1", double), spec("s2", double), spec("d", doubleOut))],
                 palette: arithmetic, help: "BIN 32-bit \(name.lowercased()).")
            data("E" + symbol, .arithmetic(op, .real), [form(9, spec("s", real), spec("d", realOut)), form(13, spec("s1", real), spec("s2", real), spec("d", realOut))],
                 palette: arithmetic, help: "FLOAT \(name.lowercased()).")
        }
        data("*", .arithmetic(.multiply, .word), [form(7, spec("s1", word), spec("s2", word), spec("d", doubleOut))], palette: arithmetic,
             help: "BIN 16-bit multiplication: the 32-bit product goes to d and d+1.")
        data("/", .arithmetic(.divide, .word), [form(7, spec("s1", word), spec("s2", word), spec("d", .wideDestination(words: 2)))], palette: arithmetic,
             help: "BIN 16-bit division: quotient to d, remainder to d+1.")
        data("D*", .arithmetic(.multiply, .doubleWord), [form(13, spec("s1", double), spec("s2", double), spec("d", .wideDestination(words: 4)))], palette: arithmetic,
             help: "BIN 32-bit multiplication: the 64-bit product goes to d…d+3.")
        data("D/", .arithmetic(.divide, .doubleWord), [form(13, spec("s1", double), spec("s2", double), spec("d", .wideDestination(words: 4)))], palette: arithmetic,
             help: "BIN 32-bit division: quotient to d/d+1, remainder to d+2/d+3.")
        data("E*", .arithmetic(.multiply, .real), [form(13, spec("s1", real), spec("s2", real), spec("d", realOut))], palette: arithmetic, help: "FLOAT multiplication.")
        data("E/", .arithmetic(.divide, .real), [form(13, spec("s1", real), spec("s2", real), spec("d", realOut))], palette: arithmetic, help: "FLOAT division.")
        data("ADD", .arithmetic(.add, .word), [form(7, spec("s1", word), spec("s2", word), spec("d", wordOut))], palette: arithmetic, help: "BIN 16-bit addition d = s1 + s2 (FX3-compatible name).")
        data("SUB", .arithmetic(.subtract, .word), [form(7, spec("s1", word), spec("s2", word), spec("d", wordOut))], palette: arithmetic, help: "BIN 16-bit subtraction d = s1 - s2 (FX3-compatible name).")
        data("MUL", .arithmetic(.multiply, .word), [form(7, spec("s1", word), spec("s2", word), spec("d", doubleOut))], palette: arithmetic, help: "BIN 16-bit multiplication into d, d+1 (FX3-compatible name).")
        data("DIV", .arithmetic(.divide, .word), [form(7, spec("s1", word), spec("s2", word), spec("d", .wideDestination(words: 2)))], palette: arithmetic, help: "BIN 16-bit division: quotient d, remainder d+1 (FX3-compatible name).")
        data("DADD", .arithmetic(.add, .doubleWord), [form(13, spec("s1", double), spec("s2", double), spec("d", doubleOut))], palette: arithmetic, help: "BIN 32-bit addition (FX3-compatible name).")
        data("DSUB", .arithmetic(.subtract, .doubleWord), [form(13, spec("s1", double), spec("s2", double), spec("d", doubleOut))], palette: arithmetic, help: "BIN 32-bit subtraction (FX3-compatible name).")
        data("DMUL", .arithmetic(.multiply, .doubleWord), [form(13, spec("s1", double), spec("s2", double), spec("d", .wideDestination(words: 4)))], palette: arithmetic, help: "BIN 32-bit multiplication (FX3-compatible name).")
        data("DDIV", .arithmetic(.divide, .doubleWord), [form(13, spec("s1", double), spec("s2", double), spec("d", .wideDestination(words: 4)))], palette: arithmetic, help: "BIN 32-bit division (FX3-compatible name).")
        data("INC", .increment(.word), [form(3, spec("d", wordOut))], palette: arithmetic, help: "Adds 1 to d (32767 + 1 → -32768).")
        data("DEC", .decrement(.word), [form(3, spec("d", wordOut))], palette: arithmetic, help: "Subtracts 1 from d (-32768 - 1 → 32767).")
        data("DINC", .increment(.doubleWord), [form(5, spec("d", doubleOut))], palette: arithmetic, help: "Adds 1 to the 32-bit d.")
        data("DDEC", .decrement(.doubleWord), [form(5, spec("d", doubleOut))], palette: arithmetic, help: "Subtracts 1 from the 32-bit d.")

        // Logic
        let logic = ["Basic Instructions", "Logical Operation Instructions"]
        for (name, op) in [("AND", BitLogicOperator.and), ("OR", BitLogicOperator.or), ("XOR", BitLogicOperator.xor)] {
            data("W" + name, .logic(op, .word), [form(5, spec("s", word), spec("d", wordOut)), form(7, spec("s1", word), spec("s2", word), spec("d", wordOut))],
                 palette: logic, help: "16-bit logical \(name): d = d \(name) s, or d = s1 \(name) s2.")
            data("D" + name, .logic(op, .doubleWord), [form(9, spec("s", double), spec("d", doubleOut)), form(13, spec("s1", double), spec("s2", double), spec("d", doubleOut))],
                 palette: logic, help: "32-bit logical \(name).")
        }

        // Data conversion
        let conversion = ["Basic Instructions", "Data Conversion Instructions"]
        data("BCD", .toBCD(.word), [form(5, spec("s", word), spec("d", wordOut))], palette: conversion, help: "BIN → BCD (0 to 9999).")
        data("DBCD", .toBCD(.doubleWord), [form(9, spec("s", double), spec("d", doubleOut))], palette: conversion, help: "32-bit BIN → BCD (0 to 99999999).")
        data("BIN", .fromBCD(.word), [form(5, spec("s", word), spec("d", wordOut))], palette: conversion, help: "BCD → BIN (each digit 0 to 9).")
        data("DBIN", .fromBCD(.doubleWord), [form(9, spec("s", double), spec("d", doubleOut))], palette: conversion, help: "32-bit BCD → BIN.")
        data("INT2FLT", .integerToFloat(.word), [form(5, spec("s", word), spec("d", realOut))], palette: conversion, help: "Signed 16-bit BIN → FLOAT.")
        data("DINT2FLT", .integerToFloat(.doubleWord), [form(9, spec("s", double), spec("d", realOut))], palette: conversion, help: "Signed 32-bit BIN → FLOAT.")
        data("FLT2INT", .floatToInteger(.word), [form(5, spec("s", real), spec("d", wordOut))], palette: conversion, help: "FLOAT → signed 16-bit BIN, rounded to the nearest integer.")
        data("FLT2DINT", .floatToInteger(.doubleWord), [form(9, spec("s", real), spec("d", doubleOut))], palette: conversion, help: "FLOAT → signed 32-bit BIN, rounded to the nearest integer.")
        data("NEG", .negate(.word), [form(3, spec("d", wordOut))], palette: conversion, help: "Two's complement: d = -d.")
        data("DNEG", .negate(.doubleWord), [form(5, spec("d", doubleOut))], palette: conversion, help: "32-bit two's complement: d = -d.")

        // Data transfer
        let transfer = ["Basic Instructions", "Data Transfer Instructions"]
        data("MOV", .move(.word), [form(5, spec("s", word), spec("d", wordOut))], palette: transfer, help: "Transfers 16-bit data from s to d.")
        data("DMOV", .move(.doubleWord), [form(9, spec("s", double), spec("d", doubleOut))], palette: transfer, help: "Transfers 32-bit data from s to d.")
        data("EMOV", .move(.real), [form(9, spec("s", real), spec("d", realOut))], palette: transfer, help: "Transfers FLOAT data from s to d.")
        data("BMOV", .blockMove, [form(7, spec("s", word), spec("d", wordOut), spec("n", .count))], palette: transfer, help: "Transfers n words from s… to d….")
        data("FMOV", .fillMove, [form(7, spec("s", word), spec("d", wordOut), spec("n", .count))], palette: transfer, help: "Writes s to the n words d….")

        // Shift and rotation
        let shift = ["Basic Instructions", "Data Shift Instructions"]
        data("ROR", .rotate(left: false, throughCarry: false, .word), [form(5, spec("d", wordOut), spec("n", .count))], palette: shift, help: "Rotates 16-bit d right by n bits (carry: SM700).")
        data("ROL", .rotate(left: true, throughCarry: false, .word), [form(5, spec("d", wordOut), spec("n", .count))], palette: shift, help: "Rotates 16-bit d left by n bits (carry: SM700).")
        data("RCR", .rotate(left: false, throughCarry: true, .word), [form(5, spec("d", wordOut), spec("n", .count))], palette: shift, help: "Rotates 16-bit d right by n bits through the carry flag SM700.")
        data("RCL", .rotate(left: true, throughCarry: true, .word), [form(5, spec("d", wordOut), spec("n", .count))], palette: shift, help: "Rotates 16-bit d left by n bits through the carry flag SM700.")
        data("DROR", .rotate(left: false, throughCarry: false, .doubleWord), [form(9, spec("d", doubleOut), spec("n", .count))], palette: shift, help: "Rotates 32-bit d right by n bits.")
        data("DROL", .rotate(left: true, throughCarry: false, .doubleWord), [form(9, spec("d", doubleOut), spec("n", .count))], palette: shift, help: "Rotates 32-bit d left by n bits.")
        data("SFTR", .shiftBits(left: false), [form(9, spec("s", .bitArray(write: false)), spec("d", .bitArray(write: true)), spec("n1", .count), spec("n2", .count))],
             palette: shift, help: "Shifts the n1-bit array d… right by n2 bits; n2 bits from s… enter at the top.")
        data("SFTL", .shiftBits(left: true), [form(9, spec("s", .bitArray(write: false)), spec("d", .bitArray(write: true)), spec("n1", .count), spec("n2", .count))],
             palette: shift, help: "Shifts the n1-bit array d… left by n2 bits; n2 bits from s… enter at the bottom.")

        // Comparison output and data processing
        let compareOut = ["Basic Instructions", "Comparison Operation Instructions"]
        data("CMP", .compare(.word), [form(7, spec("s1", word), spec("s2", word), spec("d", .bitArray(write: true)))], palette: compareOut,
             help: "Compares s1 with s2: d is ON if s1 > s2, d+1 if equal, d+2 if s1 < s2.")
        data("DCMP", .compare(.doubleWord), [form(13, spec("s1", double), spec("s2", double), spec("d", .bitArray(write: true)))], palette: compareOut, help: "32-bit CMP.")
        data("ECMP", .compare(.real), [form(13, spec("s1", real), spec("s2", real), spec("d", .bitArray(write: true)))], palette: compareOut, help: "FLOAT CMP.")
        data("ZCP", .zoneCompare(.word), [form(9, spec("s1", word), spec("s2", word), spec("s", word), spec("d", .bitArray(write: true)))], palette: compareOut,
             help: "Zone compare: d ON if s < s1, d+1 if s1 ≤ s ≤ s2, d+2 if s > s2.")
        data("DZCP", .zoneCompare(.doubleWord), [form(17, spec("s1", double), spec("s2", double), spec("s", double), spec("d", .bitArray(write: true)))], palette: compareOut, help: "32-bit ZCP.")
        data("EZCP", .zoneCompare(.real), [form(17, spec("s1", real), spec("s2", real), spec("s", real), spec("d", .bitArray(write: true)))], palette: compareOut, help: "FLOAT ZCP.")
        data("ZRST", .zoneReset, [form(5, spec("d1", .rangeDevice), spec("d2", .rangeDevice))], palette: ["Application Instructions", "Data Processing Instructions"],
             help: "Resets every device from d1 to d2 (same device type).")

        return list
    }
}
