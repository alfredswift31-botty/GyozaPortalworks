import Foundation

/// Name lookup for MELSEC ST programs: local labels, then global labels,
/// then devices (X0, D100, K4M0, D0.3, TS0…). Also provides the GX Works3 ST
/// instruction functions (SET, RST, OUT_T, OUT_C, MOV, BCD, BIN…).
///
/// A plain timer or counter name (T0, C0) in ST means its contact; use TN0
/// / CN0 for the current value. Instruction functions take the execution
/// condition EN first, as in GX Works3: `OUT_T(X0, TC0, 50);`.
nonisolated final class MelsecSymbolResolver: SymbolResolver {
    let block: BlockHandle
    let labels: MelsecLabelStorage
    var dialect: LanguageDialect { .melsec }

    /// `labels` is the program's local label storage (with the globals as
    /// parent) or the global storage alone.
    init(block: BlockHandle, labels: MelsecLabelStorage) {
        self.block = block
        self.labels = labels
    }

    private var memory: MelsecDeviceMemory { labels.memory }

    func resolve(_ name: SymbolName) throws -> SymbolBinding? {
        let text = name.text.trimmingCharacters(in: .whitespaces)
        if let local = block.localBinding(text) {
            return local
        }
        let globals = labels.parent ?? labels
        if let binding = globals.binding(text) {
            switch binding {
            case let .constant(value, type):
                return .constant(name: text, value: value, type: type)
            case let .node(node, label):
                return .global(GlobalSymbol(displayName: label.name, place: .node(node), isWritable: true))
            case let .device(operand):
                return .global(GlobalSymbol(displayName: text, place: try place(operand, text: text), isWritable: isWritable(operand)))
            }
        }
        let operand: MelsecOperand
        do {
            operand = try MelsecOperandParser.parse(text, profile: memory.profile)
        } catch let error as MelsecOperandError {
            throw ResolveError(message: error.message)
        }
        switch operand {
        case .label, .pointer, .nesting, .unspecified:
            return nil
        case let .constant(constant):
            switch constant {
            case let .real(value):
                return .constant(name: text, value: .real(value), type: .real)
            case let .decimal(value), let .hexadecimal(value):
                return .constant(name: text, value: .int(value), type: PLCDataType.int.contains(value) ? .int : .dint)
            }
        default:
            return .global(GlobalSymbol(displayName: operand.text(memory.profile), place: try place(operand, text: text),
                                        isWritable: isWritable(operand)))
        }
    }

    private func place(_ operand: MelsecOperand, text: String) throws -> Place {
        var context = MelsecPlaceContext.natural
        if case let .device(device, _) = operand, device.kind.isTimerOrCounter, device.facet == .whole {
            context = .bit
        }
        do {
            return try memory.place(for: operand, context: context)
        } catch let error as MelsecOperandError {
            throw ResolveError(message: error.message)
        }
    }

    private func isWritable(_ operand: MelsecOperand) -> Bool {
        switch operand {
        case let .device(device, _), let .digit(_, device, _):
            return device.kind != .input
        case .constant:
            return false
        default:
            return true
        }
    }

    func userBlock(named name: String) -> BlockHandle? {
        nil
    }

    func procedure(named name: String) -> NativeProcedure? {
        MelsecSTFunctions.procedure(named: name, labels: labels)
    }
}

/// GX Works3 ST forms of ladder instructions. Instructions that need edge
/// memory per call site (the P forms, PLS, PLF) are not provided.
nonisolated enum MelsecSTFunctions {
    static let names = ["SET", "RST", "OUT_T", "OUTH_T", "OUTHS_T", "OUT_C", "MOV", "DMOV", "EMOV", "BCD", "BIN", "INC", "DEC"]

    static func procedure(named rawName: String, labels: MelsecLabelStorage) -> NativeProcedure? {
        let name = rawName.uppercased()
        let enable = NativeProcedure.Parameter(name: "EN", type: .bool, isOutput: false)
        func output(_ parameter: String) -> NativeProcedure.Parameter {
            NativeProcedure.Parameter(name: parameter, type: nil, isOutput: true)
        }
        func input(_ parameter: String, _ type: PLCDataType? = nil) -> NativeProcedure.Parameter {
            NativeProcedure.Parameter(name: parameter, type: type, isOutput: false)
        }
        switch name {
        case "SET", "RST":
            return NativeProcedure(name: name, parameters: [enable, output("d")], returnType: .bool) { arguments, frame in
                let condition = try boolArgument(arguments, 0)
                if condition {
                    let target = try placeArgument(arguments, 1, name)
                    if name == "SET" {
                        target.write(.bool(true))
                    } else if let node = target.node, let item = labels.timerCounter(for: node) {
                        item.resetCurrent(at: frame.context.clock)
                    } else {
                        target.write((target.elementaryType ?? .bool).defaultValue)
                    }
                }
                return .bool(condition)
            }
        case "OUT_T", "OUTH_T", "OUTHS_T", "OUT_C":
            let resolution: Int64 = name == "OUTH_T" ? 10 : (name == "OUTHS_T" ? 1 : 100)
            return NativeProcedure(name: name, parameters: [enable, output("d1"), input("d2")], returnType: .bool) { arguments, frame in
                let condition = try boolArgument(arguments, 0)
                let target = try placeArgument(arguments, 1, name)
                guard let node = target.node, let item = labels.timerCounter(for: node) else {
                    throw RuntimeFault(.invalidOperation, "\(name): d1 must be a \(name == "OUT_C" ? "counter" : "timer") (e.g. \(name == "OUT_C" ? "CC0" : "TC0") or a Timer label).")
                }
                guard item.kind.isTimer == (name != "OUT_C") else {
                    throw RuntimeFault(.invalidOperation, "\(name): d1 must be a \(name == "OUT_C" ? "counter" : "timer").")
                }
                let setValue: Int64
                do {
                    setValue = try MelsecTimerLogic.checkedSetValue(try valueArgument(arguments, 2, name).intValue, for: item)
                } catch let error as MelsecOperationError {
                    throw RuntimeFault(.invalidOperation, "\(name): \(error.message)")
                }
                if item.kind.isTimer {
                    MelsecTimerLogic.driveTimer(item, coil: condition, setValue: setValue, resolution: resolution, clock: frame.context.clock)
                } else {
                    MelsecTimerLogic.driveCounter(item, coil: condition, setValue: setValue)
                }
                return .bool(condition)
            }
        case "MOV", "DMOV", "EMOV":
            let type: PLCDataType = name == "MOV" ? .int : (name == "DMOV" ? .dint : .real)
            return NativeProcedure(name: name, parameters: [enable, input("s"), output("d")], returnType: .bool) { arguments, _ in
                let condition = try boolArgument(arguments, 0)
                if condition {
                    let value = try valueArgument(arguments, 1, name).converted(to: type)
                    try placeArgument(arguments, 2, name).write(value)
                }
                return .bool(condition)
            }
        case "INC", "DEC":
            return NativeProcedure(name: name, parameters: [enable, output("d")], returnType: .bool) { arguments, _ in
                let condition = try boolArgument(arguments, 0)
                if condition {
                    let target = try placeArgument(arguments, 1, name)
                    let type = target.elementaryType ?? .int
                    target.write(.int(type.wrap(target.read().intValue + (name == "INC" ? 1 : -1))))
                }
                return .bool(condition)
            }
        case "BCD", "BIN":
            return NativeProcedure(name: name, parameters: [enable, input("s"), output("d")], returnType: .bool) { arguments, _ in
                let condition = try boolArgument(arguments, 0)
                if condition {
                    let value = try valueArgument(arguments, 1, name).intValue
                    let result = try name == "BCD" ? toBCD(value) : fromBCD(value)
                    try placeArgument(arguments, 2, name).write(.int(result))
                }
                return .bool(condition)
            }
        default:
            return nil
        }
    }

    private static func boolArgument(_ arguments: [NativeProcedure.Argument], _ index: Int) throws -> Bool {
        guard arguments.indices.contains(index) else {
            throw RuntimeFault(.invalidOperation, "The execution condition (EN) is missing.")
        }
        switch arguments[index] {
        case let .value(value): return value.boolValue
        case let .place(place): return place.read().boolValue
        }
    }

    private static func valueArgument(_ arguments: [NativeProcedure.Argument], _ index: Int, _ name: String) throws -> PLCValue {
        guard arguments.indices.contains(index) else {
            throw RuntimeFault(.invalidOperation, "\(name): an argument is missing.")
        }
        switch arguments[index] {
        case let .value(value): return value
        case let .place(place): return place.read()
        }
    }

    private static func placeArgument(_ arguments: [NativeProcedure.Argument], _ index: Int, _ name: String) throws -> Place {
        guard arguments.indices.contains(index), case let .place(place) = arguments[index] else {
            throw RuntimeFault(.invalidOperation, "\(name): the destination must be a device or label.")
        }
        return place
    }

    /// 16-bit BIN → BCD (0 to 9999).
    static func toBCD(_ value: Int64) throws -> Int64 {
        guard value >= 0, value <= 9999 else {
            throw RuntimeFault(.invalidOperation, "BCD conversion error: \(value) is outside 0 to 9999.")
        }
        var remaining = value
        var result: Int64 = 0
        var shift: Int64 = 0
        while remaining > 0 {
            result |= (remaining % 10) << shift
            remaining /= 10
            shift += 4
        }
        return Int64(Int16(truncatingIfNeeded: result))
    }

    /// 16-bit BCD → BIN.
    static func fromBCD(_ value: Int64) throws -> Int64 {
        let raw = value & 0xFFFF
        var result: Int64 = 0
        var multiplier: Int64 = 1
        for shift in stride(from: Int64(0), to: 16, by: 4) {
            let digit = (raw >> shift) & 0xF
            guard digit <= 9 else {
                throw RuntimeFault(.invalidOperation, "BCD conversion error: H\(String(raw, radix: 16, uppercase: true)) is not a BCD value.")
            }
            result += digit * multiplier
            multiplier *= 10
        }
        return result
    }
}
