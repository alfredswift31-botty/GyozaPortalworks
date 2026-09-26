import Foundation

/// 16- or 32-bit integer access to an operand.
nonisolated enum MelsecIntegerWidth: Hashable, Sendable {
    case word
    case doubleWord

    var bitCount: Int { self == .word ? 16 : 32 }
    var dataType: PLCDataType { self == .word ? .int : .dint }

    /// Two's-complement wrap into the width: 32768 → -32768 for a word.
    func wrap(_ value: Int64) -> Int64 {
        self == .word ? Int64(Int16(truncatingIfNeeded: value)) : Int64(Int32(truncatingIfNeeded: value))
    }
}

/// How an operand is viewed when it becomes a `Place` (ST, watch windows).
nonisolated enum MelsecPlaceContext: Hashable, Sendable {
    /// Bits as Bool, registers as Word [Signed], timers and counters as their
    /// current value, digit specifications of more than 4 digits as 32-bit.
    case natural
    case bit
    case word
    case doubleWord
    case real
}

/// One timer or counter: contact, coil and current value (GX Works3's
/// Timer/Counter structure with members S, C and N), plus the measurement
/// state the CPU keeps between executions of its OUT instruction.
nonisolated final class MelsecTimerCounter {
    /// T, ST, C or LC.
    let kind: MelsecDeviceKind
    /// The device number; nil for a Timer/Counter label.
    let number: Int?
    let contact: DataNode
    let coil: DataNode
    let value: DataNode
    /// CPU clock of the last OUT execution while the coil was on.
    var lastUpdate: Int64 = 0
    /// Measured milliseconds not yet counted as a whole time unit.
    var residual: Int64 = 0

    init(kind: MelsecDeviceKind, number: Int) {
        self.kind = kind
        self.number = number
        contact = DataNode(type: .elementary(.bool))
        coil = DataNode(type: .elementary(.bool))
        value = DataNode(type: .elementary(kind == .longCounter ? .udint : .int))
    }

    /// Wraps the storage of a Timer/Counter label (members S, C, N).
    init?(kind: MelsecDeviceKind, label node: DataNode) {
        guard let contact = node.member("S"), let coil = node.member("C"), let value = node.member("N") else { return nil }
        self.kind = kind
        self.number = nil
        self.contact = contact
        self.coil = coil
        self.value = value
    }

    var isRetentive: Bool { kind == .retentiveTimer }
    var isLong: Bool { kind == .longCounter }
    var current: Int64 { value.read().intValue }
    var contactState: Bool { contact.read().boolValue }
    var coilState: Bool { coil.read().boolValue }

    /// RST: clears the current value and the contact. The coil keeps its
    /// state, so a count input that is still ON does not count again.
    func resetCurrent(at clock: Int64) {
        value.write(.int(0))
        contact.write(.bool(false))
        residual = 0
        lastUpdate = clock
    }

    /// Everything off, as after RESET or latch clear.
    func clear() {
        resetCurrent(at: 0)
        coil.write(.bool(false))
    }
}

/// The CPU's device memory: bit devices, 16-bit registers, timers and
/// counters. 32-bit values occupy two consecutive words, low word first;
/// FLOAT [Single Precision] values are IEEE 754 bit patterns in two words.
nonisolated final class MelsecDeviceMemory {
    let profile: MelsecCPUProfile
    let timers: [MelsecTimerCounter]
    let retentiveTimers: [MelsecTimerCounter]
    let counters: [MelsecTimerCounter]
    let longCounters: [MelsecTimerCounter]
    private var bitStore: [[Bool]]
    private var wordStore: [[UInt16]]
    private var longIndexStore: [UInt32]
    private var deviceOwners: [ObjectIdentifier: MelsecTimerCounter] = [:]
    private var labelOwners: [ObjectIdentifier: MelsecTimerCounter] = [:]

    private static let bitKinds: [MelsecDeviceKind] = [
        .input, .output, .internalRelay, .latchRelay, .linkRelay, .annunciator, .linkSpecialRelay, .stepRelay, .specialRelay,
    ]
    private static let wordKinds: [MelsecDeviceKind] = [
        .dataRegister, .linkRegister, .linkSpecialRegister, .specialRegister, .fileRegister, .indexRegister,
    ]

    init(profile: MelsecCPUProfile = .fx5u) {
        self.profile = profile
        bitStore = MelsecDeviceMemory.bitKinds.map { Array(repeating: false, count: profile.count($0)) }
        wordStore = MelsecDeviceMemory.wordKinds.map { Array(repeating: 0, count: profile.count($0)) }
        longIndexStore = Array(repeating: 0, count: profile.count(.longIndexRegister))
        timers = (0..<profile.count(.timer)).map { MelsecTimerCounter(kind: .timer, number: $0) }
        retentiveTimers = (0..<profile.count(.retentiveTimer)).map { MelsecTimerCounter(kind: .retentiveTimer, number: $0) }
        counters = (0..<profile.count(.counter)).map { MelsecTimerCounter(kind: .counter, number: $0) }
        longCounters = (0..<profile.count(.longCounter)).map { MelsecTimerCounter(kind: .longCounter, number: $0) }
        for group in [timers, retentiveTimers, counters, longCounters] {
            for item in group {
                for node in [item.contact, item.coil, item.value] {
                    deviceOwners[ObjectIdentifier(node)] = item
                }
            }
        }
    }

    private static func bitSlot(_ kind: MelsecDeviceKind) -> Int? {
        switch kind {
        case .input: return 0
        case .output: return 1
        case .internalRelay: return 2
        case .latchRelay: return 3
        case .linkRelay: return 4
        case .annunciator: return 5
        case .linkSpecialRelay: return 6
        case .stepRelay: return 7
        case .specialRelay: return 8
        default: return nil
        }
    }

    private static func wordSlot(_ kind: MelsecDeviceKind) -> Int? {
        switch kind {
        case .dataRegister: return 0
        case .linkRegister: return 1
        case .linkSpecialRegister: return 2
        case .specialRegister: return 3
        case .fileRegister: return 4
        case .indexRegister: return 5
        default: return nil
        }
    }

    // MARK: Raw access

    func bit(_ kind: MelsecDeviceKind, _ number: Int) -> Bool {
        guard let slot = MelsecDeviceMemory.bitSlot(kind), bitStore[slot].indices.contains(number) else { return false }
        return bitStore[slot][number]
    }

    func setBit(_ kind: MelsecDeviceKind, _ number: Int, _ value: Bool) {
        guard let slot = MelsecDeviceMemory.bitSlot(kind), bitStore[slot].indices.contains(number) else { return }
        bitStore[slot][number] = value
    }

    /// A 16-bit register (the low word of LZ).
    func word(_ kind: MelsecDeviceKind, _ number: Int) -> UInt16 {
        if kind == .longIndexRegister {
            return UInt16(truncatingIfNeeded: longIndexRegister(number))
        }
        guard let slot = MelsecDeviceMemory.wordSlot(kind), wordStore[slot].indices.contains(number) else { return 0 }
        return wordStore[slot][number]
    }

    func setWord(_ kind: MelsecDeviceKind, _ number: Int, _ value: UInt16) {
        if kind == .longIndexRegister {
            let high = longIndexRegister(number) & 0xFFFF_0000
            setLongIndexRegister(number, high | UInt32(value))
            return
        }
        guard let slot = MelsecDeviceMemory.wordSlot(kind), wordStore[slot].indices.contains(number) else { return }
        wordStore[slot][number] = value
    }

    func longIndexRegister(_ number: Int) -> UInt32 {
        longIndexStore.indices.contains(number) ? longIndexStore[number] : 0
    }

    func setLongIndexRegister(_ number: Int, _ value: UInt32) {
        guard longIndexStore.indices.contains(number) else { return }
        longIndexStore[number] = value
    }

    func timerCounter(_ kind: MelsecDeviceKind, _ number: Int) -> MelsecTimerCounter? {
        let group: [MelsecTimerCounter]
        switch kind {
        case .timer: group = timers
        case .retentiveTimer: group = retentiveTimers
        case .counter: group = counters
        case .longCounter: group = longCounters
        default: return nil
        }
        return group.indices.contains(number) ? group[number] : nil
    }

    /// The timer or counter a contact, coil or value node belongs to, for
    /// ST instructions such as OUT_T that receive one of them.
    func owner(of node: DataNode) -> MelsecTimerCounter? {
        let key = ObjectIdentifier(node)
        return deviceOwners[key] ?? labelOwners[key]
    }

    /// Makes a Timer/Counter label's nodes (and its structure node) known to
    /// `owner(of:)`.
    func registerLabelTimerCounter(_ item: MelsecTimerCounter, structure: DataNode?) {
        for node in [item.contact, item.coil, item.value] {
            labelOwners[ObjectIdentifier(node)] = item
        }
        if let structure {
            labelOwners[ObjectIdentifier(structure)] = item
        }
    }

    /// Forgets the label timers of a previously loaded program.
    func removeLabelTimerCounters() {
        labelOwners.removeAll()
    }

    /// The value of index register Zn as a signed offset.
    func indexOffset(_ register: Int) -> Int {
        Int(Int16(bitPattern: word(.indexRegister, register)))
    }

    // MARK: Operand access

    /// Applies index modification: D0Z1 with Z1 = 5 is D5. Throws when the
    /// modified device leaves the device range (an operation error).
    func resolved(_ operand: MelsecOperand) throws -> MelsecOperand {
        switch operand {
        case let .device(device, index?):
            let target = device.advanced(by: indexOffset(index))
            guard profile.contains(target.kind, target.number) else {
                throw MelsecOperandError(message: "\(operand.text(profile)) points outside the device range (\(profile.rangeText(device.kind))).")
            }
            return .device(target, index: nil)
        case let .digit(count, start, index?):
            let target = start.advanced(by: indexOffset(index))
            guard profile.contains(target.kind, target.number), profile.contains(target.kind, target.number + count * 4 - 1) else {
                throw MelsecOperandError(message: "\(operand.text(profile)) points outside the device range (\(profile.rangeText(start.kind))).")
            }
            return .digit(count: count, start: target, index: nil)
        default:
            return operand
        }
    }

    func readBit(_ operand: MelsecOperand) throws -> Bool {
        switch try resolved(operand) {
        case let .device(device, _):
            if device.kind.isBitDevice {
                return bit(device.kind, device.number)
            }
            if let item = timerCounter(device.kind, device.number) {
                switch device.facet {
                case .whole, .contact: return item.contactState
                case .coil: return item.coilState
                case .value: break
                }
            }
        case let .wordBit(device, bit):
            return (Int(rawWord(device)) >> bit) & 1 == 1
        default:
            break
        }
        throw MelsecOperandError(message: "'\(operand.text(profile))' is not a bit operand.")
    }

    func writeBit(_ operand: MelsecOperand, _ value: Bool) throws {
        switch try resolved(operand) {
        case let .device(device, _):
            if device.kind.isBitDevice {
                setBit(device.kind, device.number, value)
                return
            }
            if let item = timerCounter(device.kind, device.number) {
                switch device.facet {
                case .whole, .contact:
                    item.contact.write(.bool(value))
                    return
                case .coil:
                    item.coil.write(.bool(value))
                    return
                case .value:
                    break
                }
            }
        case let .wordBit(device, bit):
            let mask = UInt16(1) << UInt16(bit)
            let raw = rawWord(device)
            setRawWord(device, value ? raw | mask : raw & ~mask)
            return
        default:
            break
        }
        throw MelsecOperandError(message: "'\(operand.text(profile))' cannot be written as a bit.")
    }

    func readInteger(_ operand: MelsecOperand, width: MelsecIntegerWidth) throws -> Int64 {
        let target = try resolved(operand)
        switch target {
        case let .constant(constant):
            switch constant {
            case let .decimal(value), let .hexadecimal(value): return width.wrap(value)
            case let .real(value): return width.wrap(PLCValue.real(value).intValue)
            }
        case let .digit(count, start, _):
            let bits = min(count * 4, width.bitCount)
            var raw: Int64 = 0
            for offset in 0..<bits where bit(start.kind, start.number + offset) {
                raw |= Int64(1) << Int64(offset)
            }
            return bits == width.bitCount ? width.wrap(raw) : raw
        case let .wordBit(device, bit):
            return (Int64(rawWord(device)) >> Int64(bit)) & 1
        case let .device(device, _):
            if device.kind.isWordDevice {
                if width == .word {
                    return Int64(Int16(bitPattern: word(device.kind, device.number)))
                }
                try requireSecondWord(device, operand: operand)
                let low = UInt32(word(device.kind, device.number))
                let high = UInt32(word(device.kind, device.number + 1))
                return Int64(Int32(bitPattern: low | (high << 16)))
            }
            if device.kind == .longIndexRegister {
                let raw = longIndexRegister(device.number)
                return width == .word ? Int64(Int16(truncatingIfNeeded: raw)) : Int64(Int32(bitPattern: raw))
            }
            if let item = timerCounter(device.kind, device.number), device.facet == .whole || device.facet == .value {
                if width == .word {
                    return Int64(Int16(truncatingIfNeeded: item.current))
                }
                if item.isLong {
                    return Int64(Int32(truncatingIfNeeded: item.current))
                }
                guard let next = timerCounter(device.kind, device.number + 1) else {
                    throw MelsecOperandError(message: "\(operand.text(profile)) has no following device for a 32-bit value.")
                }
                let low = UInt32(truncatingIfNeeded: item.current) & 0xFFFF
                let high = UInt32(truncatingIfNeeded: next.current) & 0xFFFF
                return Int64(Int32(bitPattern: low | (high << 16)))
            }
        default:
            break
        }
        throw MelsecOperandError(message: "'\(operand.text(profile))' is not a word operand.")
    }

    func writeInteger(_ operand: MelsecOperand, width: MelsecIntegerWidth, _ value: Int64) throws {
        let target = try resolved(operand)
        switch target {
        case let .digit(count, start, _):
            let bits = min(count * 4, width.bitCount)
            for offset in 0..<bits {
                setBit(start.kind, start.number + offset, (value >> Int64(offset)) & 1 == 1)
            }
            return
        case let .wordBit(device, bit):
            try writeBit(.wordBit(device, bit: bit), value & 1 == 1)
            return
        case let .device(device, _):
            if device.kind.isWordDevice {
                if width == .word {
                    setWord(device.kind, device.number, UInt16(truncatingIfNeeded: value))
                    return
                }
                try requireSecondWord(device, operand: operand)
                let raw = UInt32(truncatingIfNeeded: value)
                setWord(device.kind, device.number, UInt16(truncatingIfNeeded: raw))
                setWord(device.kind, device.number + 1, UInt16(truncatingIfNeeded: raw >> 16))
                return
            }
            if device.kind == .longIndexRegister {
                if width == .word {
                    setWord(.longIndexRegister, device.number, UInt16(truncatingIfNeeded: value))
                } else {
                    setLongIndexRegister(device.number, UInt32(truncatingIfNeeded: value))
                }
                return
            }
            if let item = timerCounter(device.kind, device.number), device.facet == .whole || device.facet == .value {
                if item.isLong {
                    item.value.write(.int(Int64(UInt32(truncatingIfNeeded: value))))
                    return
                }
                if width == .word {
                    item.value.write(.int(Int64(Int16(truncatingIfNeeded: value))))
                    return
                }
                guard let next = timerCounter(device.kind, device.number + 1) else {
                    throw MelsecOperandError(message: "\(operand.text(profile)) has no following device for a 32-bit value.")
                }
                let raw = UInt32(truncatingIfNeeded: value)
                item.value.write(.int(Int64(Int16(truncatingIfNeeded: raw))))
                next.value.write(.int(Int64(Int16(truncatingIfNeeded: raw >> 16))))
                return
            }
        default:
            break
        }
        throw MelsecOperandError(message: "'\(operand.text(profile))' cannot be written as a word.")
    }

    /// FLOAT [Single Precision] in two words (E constants and K constants
    /// read as their value).
    func readReal(_ operand: MelsecOperand) throws -> Double {
        let target = try resolved(operand)
        if case let .constant(constant) = target {
            switch constant {
            case let .real(value): return value
            case let .decimal(value), let .hexadecimal(value): return Double(value)
            }
        }
        let raw = try readInteger(target, width: .doubleWord)
        return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
    }

    func writeReal(_ operand: MelsecOperand, _ value: Double) throws {
        let pattern = Float(value).bitPattern
        try writeInteger(operand, width: .doubleWord, Int64(Int32(bitPattern: pattern)))
    }

    private func requireSecondWord(_ device: MelsecDevice, operand: MelsecOperand) throws {
        guard profile.contains(device.kind, device.number + 1) else {
            throw MelsecOperandError(message: "\(operand.text(profile)) is the last \(device.kind.rawValue) device: a 32-bit value needs two words.")
        }
    }

    /// The 16 raw bits of a word device or a timer/counter current value.
    private func rawWord(_ device: MelsecDevice) -> UInt16 {
        if let item = timerCounter(device.kind, device.number) {
            return UInt16(truncatingIfNeeded: item.current)
        }
        return word(device.kind, device.number)
    }

    private func setRawWord(_ device: MelsecDevice, _ value: UInt16) {
        if let item = timerCounter(device.kind, device.number) {
            item.value.write(.int(item.isLong ? Int64(value) : Int64(Int16(bitPattern: value))))
            return
        }
        setWord(device.kind, device.number, value)
    }

    // MARK: Places for ST and watch windows

    /// A storage location for any device operand: what the ST resolver binds
    /// names to and what watch windows read. Timer and counter parts are
    /// their structure nodes, so ST instructions can find the timer again.
    func place(for operand: MelsecOperand, context: MelsecPlaceContext = .natural) throws -> Place {
        switch operand {
        case let .device(device, nil) where device.kind.isTimerOrCounter:
            guard let item = timerCounter(device.kind, device.number) else { break }
            switch device.facet {
            case .contact: return .node(item.contact)
            case .coil: return .node(item.coil)
            case .value: return .node(item.value)
            case .whole: return context == .bit ? .node(item.contact) : .node(item.value)
            }
        case let .constant(constant):
            switch constant {
            case let .real(value):
                return .cell(Cell.constant(.real(value), type: .real))
            case let .decimal(value), let .hexadecimal(value):
                let type: PLCDataType = context == .doubleWord || !PLCDataType.int.contains(value) ? .dint : .int
                return .cell(Cell.constant(.int(value), type: type))
            }
        case .label, .pointer, .nesting, .unspecified:
            throw MelsecOperandError(message: "'\(operand.text(profile))' is not a device.")
        default:
            break
        }
        let type = try placeType(for: operand, context: context)
        let memory = self
        switch type {
        case .bool:
            return .cell(Cell(type: .bool, read: {
                .bool((try? memory.readBit(operand)) ?? false)
            }, write: { value in
                _ = try? memory.writeBit(operand, value.boolValue)
            }))
        case .real:
            return .cell(Cell(type: .real, read: {
                .real((try? memory.readReal(operand)) ?? 0)
            }, write: { value in
                _ = try? memory.writeReal(operand, value.doubleValue)
            }))
        default:
            let width: MelsecIntegerWidth = type == .int ? .word : .doubleWord
            return .cell(Cell(type: type, read: {
                .int((try? memory.readInteger(operand, width: width)) ?? 0)
            }, write: { value in
                _ = try? memory.writeInteger(operand, width: width, value.intValue)
            }))
        }
    }

    /// The data type an operand has in `context`.
    func placeType(for operand: MelsecOperand, context: MelsecPlaceContext) throws -> PLCDataType {
        let isBitOperand: Bool
        switch operand {
        case .wordBit:
            isBitOperand = true
        case let .device(device, _):
            isBitOperand = device.kind.isBitDevice || device.facet == .contact || device.facet == .coil
        default:
            isBitOperand = false
        }
        switch context {
        case .bit:
            guard isBitOperand || operand.device?.kind.isTimerOrCounter == true else {
                throw MelsecOperandError(message: "'\(operand.text(profile))' is not a bit operand.")
            }
            return .bool
        case .word, .doubleWord, .real:
            if case let .device(device, _) = operand, device.kind.isBitDevice {
                throw MelsecOperandError(message: "'\(operand.text(profile))' is a bit device: use digit specification (e.g. K4\(device.text(profile))).")
            }
            if isBitOperand {
                throw MelsecOperandError(message: "'\(operand.text(profile))' is not a word operand.")
            }
            switch context {
            case .word: return .int
            case .doubleWord: return .dint
            default: return .real
            }
        case .natural:
            if isBitOperand { return .bool }
            switch operand {
            case let .digit(count, _, _):
                return count > 4 ? .dint : .int
            case let .device(device, _):
                if device.kind == .longIndexRegister { return .dint }
                if device.kind == .longCounter { return .udint }
                return .int
            default:
                return .int
            }
        }
    }

    // MARK: Clearing

    /// RESET / power-on: clears every device outside the latched ranges.
    /// SM and SD are cleared too; the CPU re-initialises its special relays.
    func clearNonLatched() {
        clear(includingLatched: false, includingSystem: true)
    }

    /// Latch clear: clears every device, latched ones included, except the
    /// special relays and registers.
    func clearAll() {
        clear(includingLatched: true, includingSystem: false)
    }

    private func clear(includingLatched: Bool, includingSystem: Bool) {
        for (slot, kind) in MelsecDeviceMemory.bitKinds.enumerated() {
            if kind == .specialRelay && !includingSystem { continue }
            for number in bitStore[slot].indices where includingLatched || !profile.isLatched(kind, number) {
                bitStore[slot][number] = false
            }
        }
        for (slot, kind) in MelsecDeviceMemory.wordKinds.enumerated() {
            if kind == .specialRegister && !includingSystem { continue }
            for number in wordStore[slot].indices where includingLatched || !profile.isLatched(kind, number) {
                wordStore[slot][number] = 0
            }
        }
        for number in longIndexStore.indices where includingLatched || !profile.isLatched(.longIndexRegister, number) {
            longIndexStore[number] = 0
        }
        for group in [timers, retentiveTimers, counters, longCounters] {
            for item in group {
                if includingLatched || !profile.isLatched(item.kind, item.number ?? 0) {
                    item.clear()
                }
            }
        }
    }
}
