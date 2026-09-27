import Foundation

/// The CPU's absolute memory: the process images (I, Q), bit memory (M) and
/// the board side of the I/O they exchange with every cycle.
///
/// Everything is big-endian and byte-addressed, as on the real CPU: %MW10 is
/// %MB10 (high byte) followed by %MB11, and %M10.0 is bit 0 of %MB10 — the
/// *high* byte of %MW10. Writing %MW10 := 16#0102 therefore gives %MB10 = 1,
/// %MB11 = 2, and %M11.1 = TRUE.
nonisolated final class S7Memory {
    /// Process image input (PII), %I.
    private(set) var inputs: [UInt8]
    /// Process image output (PIQ), %Q.
    private(set) var outputs: [UInt8]
    /// Bit memory, %M.
    private(set) var markers: [UInt8]
    /// Board side of the inputs: what the switches and analog sources present.
    private(set) var boardInputs: [UInt8]
    /// Board side of the outputs, before forcing: what the CPU drives.
    private(set) var boardOutputs: [UInt8]
    /// Force jobs on the I/O (%I0.0:P, %QW80:P): masked bits override the board side.
    private(set) var inputForceMask: [UInt8]
    private(set) var inputForceValue: [UInt8]
    private(set) var outputForceMask: [UInt8]
    private(set) var outputForceValue: [UInt8]

    init() {
        inputs = Array(repeating: 0, count: S7Area.input.size)
        outputs = Array(repeating: 0, count: S7Area.output.size)
        markers = Array(repeating: 0, count: S7Area.memory.size)
        boardInputs = Array(repeating: 0, count: S7Area.input.size)
        boardOutputs = Array(repeating: 0, count: S7Area.output.size)
        inputForceMask = Array(repeating: 0, count: S7Area.input.size)
        inputForceValue = Array(repeating: 0, count: S7Area.input.size)
        outputForceMask = Array(repeating: 0, count: S7Area.output.size)
        outputForceValue = Array(repeating: 0, count: S7Area.output.size)
    }

    /// Takes over every byte of another memory: used when a new program is
    /// downloaded, so bit memory, I/O and force jobs survive the download.
    func copyContents(from other: S7Memory) {
        inputs = other.inputs
        outputs = other.outputs
        markers = other.markers
        boardInputs = other.boardInputs
        boardOutputs = other.boardOutputs
        inputForceMask = other.inputForceMask
        inputForceValue = other.inputForceValue
        outputForceMask = other.outputForceMask
        outputForceValue = other.outputForceValue
    }

    // MARK: Process image and bit memory

    /// Reads `count` bytes (1…8) as a big-endian number.
    func readRaw(_ area: S7Area, offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in offset..<(offset + count) {
            value = (value << 8) | UInt64(byte(area, index))
        }
        return value
    }

    /// Writes the low `count` bytes of `value` big-endian.
    func writeRaw(_ area: S7Area, offset: Int, count: Int, _ value: UInt64) {
        for position in 0..<count {
            let shift = UInt64(8 * (count - 1 - position))
            setByte(area, offset + position, UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    func readBit(_ area: S7Area, byte index: Int, bit: Int) -> Bool {
        (byte(area, index) >> UInt8(bit)) & 1 == 1
    }

    func writeBit(_ area: S7Area, byte index: Int, bit: Int, _ value: Bool) {
        let mask = UInt8(1) << UInt8(bit)
        let current = byte(area, index)
        setByte(area, index, value ? current | mask : current & ~mask)
    }

    func byte(_ area: S7Area, _ index: Int) -> UInt8 {
        guard index >= 0, index < area.size else { return 0 }
        switch area {
        case .input: return inputs[index]
        case .output: return outputs[index]
        case .memory: return markers[index]
        }
    }

    func setByte(_ area: S7Area, _ index: Int, _ value: UInt8) {
        guard index >= 0, index < area.size else { return }
        switch area {
        case .input: inputs[index] = value
        case .output: outputs[index] = value
        case .memory: markers[index] = value
        }
    }

    // MARK: Typed access

    /// Reads an operand as `type` (its width's default type when nil).
    /// Peripheral inputs read the board, with force jobs applied.
    func read(_ address: S7Address, as type: PLCDataType? = nil) -> PLCValue {
        let dataType = type ?? address.width.defaultType
        if address.width == .bit && dataType != .lreal {
            if address.isPeripheral {
                let byteValue = address.area == .input
                    ? effectiveBoardInput(address.byteOffset)
                    : effectiveBoardOutput(address.byteOffset)
                return .bool((byteValue >> UInt8(address.bitNumber)) & 1 == 1)
            }
            return .bool(readBit(address.area, byte: address.byteOffset, bit: address.bitNumber))
        }
        let count = S7Memory.byteCount(of: dataType)
        var raw: UInt64 = 0
        if address.isPeripheral {
            for index in address.byteOffset..<(address.byteOffset + count) {
                let byteValue = address.area == .input ? effectiveBoardInput(index) : effectiveBoardOutput(index)
                raw = (raw << 8) | UInt64(byteValue)
            }
        } else {
            raw = readRaw(address.area, offset: address.byteOffset, count: count)
        }
        return S7Memory.decode(raw, as: dataType)
    }

    /// Writes an operand as `type`. A peripheral output write drives the
    /// board immediately and also updates the process image output (the
    /// address is in the process image); peripheral inputs can't be written.
    func write(_ address: S7Address, as type: PLCDataType? = nil, _ value: PLCValue) {
        let dataType = type ?? address.width.defaultType
        if address.isPeripheral && address.area == .input { return }
        if address.width == .bit && dataType != .lreal {
            let bit = value.boolValue
            writeBit(address.area, byte: address.byteOffset, bit: address.bitNumber, bit)
            if address.isPeripheral {
                let mask = UInt8(1) << UInt8(address.bitNumber)
                let current = boardOutputs[address.byteOffset]
                boardOutputs[address.byteOffset] = bit ? current | mask : current & ~mask
            }
            return
        }
        let count = S7Memory.byteCount(of: dataType)
        let raw = S7Memory.encode(value, as: dataType)
        writeRaw(address.area, offset: address.byteOffset, count: count, raw)
        if address.isPeripheral {
            for position in 0..<count {
                let shift = UInt64(8 * (count - 1 - position))
                boardOutputs[address.byteOffset + position] = UInt8(truncatingIfNeeded: raw >> shift)
            }
        }
    }

    /// A storage cell for an operand, typed as `type` (or its width's default).
    func cell(for address: S7Address, type: PLCDataType? = nil) -> Cell {
        let dataType = type ?? address.width.defaultType
        return Cell(type: dataType, read: {
            self.read(address, as: dataType)
        }, write: { value in
            self.write(address, as: dataType, value)
        })
    }

    /// Bytes a value of `type` occupies in absolute memory.
    static func byteCount(of type: PLCDataType) -> Int {
        switch type {
        case .bool, .byte, .sint, .usint: return 1
        case .word, .int, .uint: return 2
        case .dword, .dint, .udint, .real, .time: return 4
        case .lreal: return 8
        }
    }

    /// Interprets raw big-endian bits as a value of `type`.
    static func decode(_ raw: UInt64, as type: PLCDataType) -> PLCValue {
        switch type {
        case .bool: return .bool(raw & 1 == 1)
        case .byte, .usint: return .int(Int64(UInt8(truncatingIfNeeded: raw)))
        case .sint: return .int(Int64(Int8(truncatingIfNeeded: raw)))
        case .word, .uint: return .int(Int64(UInt16(truncatingIfNeeded: raw)))
        case .int: return .int(Int64(Int16(truncatingIfNeeded: raw)))
        case .dword, .udint: return .int(Int64(UInt32(truncatingIfNeeded: raw)))
        case .dint: return .int(Int64(Int32(truncatingIfNeeded: raw)))
        case .time: return .time(Int64(Int32(truncatingIfNeeded: raw)))
        case .real: return .real(Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))))
        case .lreal: return .real(Double(bitPattern: raw))
        }
    }

    /// The raw bits a value of `type` is stored as.
    static func encode(_ value: PLCValue, as type: PLCDataType) -> UInt64 {
        let stored = value.converted(to: type)
        switch type {
        case .bool: return stored.boolValue ? 1 : 0
        case .real: return UInt64(Float(stored.doubleValue).bitPattern)
        case .lreal: return stored.doubleValue.bitPattern
        default: return UInt64(truncatingIfNeeded: stored.intValue)
        }
    }

    // MARK: Board side and cycle transfers

    /// A board input byte as the CPU sees it: the board's value with force
    /// jobs applied.
    func effectiveBoardInput(_ index: Int) -> UInt8 {
        guard index >= 0, index < S7Area.input.size else { return 0 }
        let mask = inputForceMask[index]
        return (boardInputs[index] & ~mask) | (inputForceValue[index] & mask)
    }

    /// A board output byte as the terminals show it: forced bits win.
    func effectiveBoardOutput(_ index: Int) -> UInt8 {
        guard index >= 0, index < S7Area.output.size else { return 0 }
        let mask = outputForceMask[index]
        return (boardOutputs[index] & ~mask) | (outputForceValue[index] & mask)
    }

    func setBoardInputBit(byte index: Int, bit: Int, _ value: Bool) {
        guard index >= 0, index < S7Area.input.size else { return }
        let mask = UInt8(1) << UInt8(bit)
        boardInputs[index] = value ? boardInputs[index] | mask : boardInputs[index] & ~mask
    }

    func boardInputBit(byte index: Int, bit: Int) -> Bool {
        guard index >= 0, index < S7Area.input.size else { return false }
        return (boardInputs[index] >> UInt8(bit)) & 1 == 1
    }

    /// Stores a 16-bit analog input value (big-endian) on the board side.
    func setBoardInputWord(byte index: Int, _ value: Int) {
        guard index >= 0, index + 1 < S7Area.input.size else { return }
        let raw = UInt16(truncatingIfNeeded: value)
        boardInputs[index] = UInt8(truncatingIfNeeded: raw >> 8)
        boardInputs[index + 1] = UInt8(truncatingIfNeeded: raw)
    }

    func boardInputWord(byte index: Int) -> Int {
        guard index >= 0, index + 1 < S7Area.input.size else { return 0 }
        return Int(Int16(bitPattern: UInt16(boardInputs[index]) << 8 | UInt16(boardInputs[index + 1])))
    }

    /// An output terminal as it currently is (forced bits win).
    func effectiveBoardOutputBit(byte index: Int, bit: Int) -> Bool {
        (effectiveBoardOutput(index) >> UInt8(bit)) & 1 == 1
    }

    /// A 16-bit analog output as the terminals show it.
    func effectiveBoardOutputWord(byte index: Int) -> Int {
        guard index >= 0, index + 1 < S7Area.output.size else { return 0 }
        let raw = UInt16(effectiveBoardOutput(index)) << 8 | UInt16(effectiveBoardOutput(index + 1))
        return Int(Int16(bitPattern: raw))
    }

    /// Start of cycle: copies the configured input bytes from the board into
    /// the process image input, with force jobs applied.
    func transferInputs(_ ranges: [Range<Int>]) {
        for range in ranges {
            for index in range where index >= 0 && index < S7Area.input.size {
                inputs[index] = effectiveBoardInput(index)
            }
        }
    }

    /// End of cycle: copies the configured process image output bytes to the board.
    func transferOutputs(_ ranges: [Range<Int>]) {
        for range in ranges {
            for index in range where index >= 0 && index < S7Area.output.size {
                boardOutputs[index] = outputs[index]
            }
        }
    }

    /// STOP: the output terminals switch off (substitute value 0). Forced
    /// outputs keep their force values.
    func switchOffBoardOutputs() {
        for index in boardOutputs.indices { boardOutputs[index] = 0 }
    }

    // MARK: Startup and memory reset

    /// Warm restart: clears both process images and the non-retentive bit
    /// memory; bytes MB0…MB(retainedBytes-1) keep their values.
    func warmRestart(retainedMarkerBytes: Int) {
        for index in inputs.indices { inputs[index] = 0 }
        for index in outputs.indices { outputs[index] = 0 }
        let kept = max(0, min(retainedMarkerBytes, markers.count))
        for index in kept..<markers.count { markers[index] = 0 }
    }

    /// Memory reset (MRES): clears I, Q and all bit memory, retentive or not.
    /// The board side and force jobs are kept, as on the real CPU.
    func memoryReset() {
        warmRestart(retainedMarkerBytes: 0)
    }

    // MARK: Force jobs

    /// Forces an I/O address (%I0.0:P, %IW64:P, %Q0.0:P, %QW80:P) to `value`
    /// read as `type`. Forced inputs are what the program sees; forced
    /// outputs are what the terminals show.
    func force(_ address: S7Address, type: PLCDataType, _ value: PLCValue) {
        guard address.area != .memory else { return }
        if address.width == .bit && type != .lreal {
            let mask = UInt8(1) << UInt8(address.bitNumber)
            setForce(area: address.area, index: address.byteOffset, mask: mask, bits: value.boolValue ? mask : 0)
            return
        }
        let count = S7Memory.byteCount(of: type)
        let raw = S7Memory.encode(value, as: type)
        for position in 0..<count {
            let shift = UInt64(8 * (count - 1 - position))
            setForce(area: address.area, index: address.byteOffset + position, mask: 0xFF, bits: UInt8(truncatingIfNeeded: raw >> shift))
        }
    }

    /// Removes the force job on an address.
    func unforce(_ address: S7Address, type: PLCDataType) {
        guard address.area != .memory else { return }
        if address.width == .bit && type != .lreal {
            let mask = UInt8(1) << UInt8(address.bitNumber)
            clearForce(area: address.area, index: address.byteOffset, mask: mask)
            return
        }
        for index in address.byteOffset..<(address.byteOffset + S7Memory.byteCount(of: type)) {
            clearForce(area: address.area, index: index, mask: 0xFF)
        }
    }

    /// "Stop forcing": removes every force job.
    func clearForces() {
        for index in inputForceMask.indices {
            inputForceMask[index] = 0
            inputForceValue[index] = 0
        }
        for index in outputForceMask.indices {
            outputForceMask[index] = 0
            outputForceValue[index] = 0
        }
    }

    /// Whether any force job is active (TIA lights the MAINT LED).
    var hasForceJobs: Bool {
        inputForceMask.contains { $0 != 0 } || outputForceMask.contains { $0 != 0 }
    }

    /// Whether any bit of the address is forced.
    func isForced(_ address: S7Address, type: PLCDataType) -> Bool {
        let masks = address.area == .input ? inputForceMask : outputForceMask
        guard address.area != .memory else { return false }
        if address.width == .bit && type != .lreal {
            return (masks[address.byteOffset] >> UInt8(address.bitNumber)) & 1 == 1
        }
        let range = address.byteOffset..<min(address.byteOffset + S7Memory.byteCount(of: type), masks.count)
        return range.contains { masks[$0] != 0 }
    }

    private func setForce(area: S7Area, index: Int, mask: UInt8, bits: UInt8) {
        switch area {
        case .input:
            guard index < inputForceMask.count else { return }
            inputForceMask[index] |= mask
            inputForceValue[index] = (inputForceValue[index] & ~mask) | (bits & mask)
        case .output:
            guard index < outputForceMask.count else { return }
            outputForceMask[index] |= mask
            outputForceValue[index] = (outputForceValue[index] & ~mask) | (bits & mask)
        case .memory:
            break
        }
    }

    private func clearForce(area: S7Area, index: Int, mask: UInt8) {
        switch area {
        case .input:
            guard index < inputForceMask.count else { return }
            inputForceMask[index] &= ~mask
            inputForceValue[index] &= ~mask
        case .output:
            guard index < outputForceMask.count else { return }
            outputForceMask[index] &= ~mask
            outputForceValue[index] &= ~mask
        case .memory:
            break
        }
    }

    // MARK: System and clock memory

    /// Clock memory byte: bit n toggles at 10, 5, 2.5, 2, 1.25, 1, 0.625 and
    /// 0.5 Hz with a 1:1 duty cycle, each low for the first half of its period.
    func updateClockMemory(byte index: Int, clock: Int64) {
        let periods: [Int64] = [100, 200, 400, 500, 800, 1_000, 1_600, 2_000]
        var value: UInt8 = 0
        for (bit, period) in periods.enumerated() {
            let phase = ((clock % period) + period) % period
            if phase >= period / 2 { value |= UInt8(1) << UInt8(bit) }
        }
        setByte(.memory, index, value)
    }

    /// System memory byte: bit 0 FirstScan, bit 1 DiagStatusUpdate, bit 2
    /// AlwaysTRUE, bit 3 AlwaysFALSE; bits 4…7 are reserved (0).
    func updateSystemMemory(byte index: Int, firstScan: Bool, diagnosticStatusChanged: Bool) {
        var value: UInt8 = 0b0000_0100
        if firstScan { value |= 0b0000_0001 }
        if diagnosticStatusChanged { value |= 0b0000_0010 }
        setByte(.memory, index, value)
    }
}
