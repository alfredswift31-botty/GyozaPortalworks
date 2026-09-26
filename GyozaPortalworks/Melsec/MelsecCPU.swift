import Foundation

/// The code of one program in the CPU.
nonisolated enum MelsecProgramCode {
    case ladder(MelsecLadderRuntime)
    /// Compiled ST (from the injected ST compiler).
    case structuredText(ExecutableBody)
}

/// One program of the scan list, loaded into the CPU.
nonisolated final class MelsecProgramImage {
    let name: String
    /// The program block; ST code runs through it, and its instance area
    /// holds the local labels.
    let block: BlockHandle
    let instance: DataNode
    let labels: MelsecLabelStorage
    let code: MelsecProgramCode

    init(name: String, block: BlockHandle, instance: DataNode, labels: MelsecLabelStorage, code: MelsecProgramCode) {
        self.name = name
        self.block = block
        self.instance = instance
        self.labels = labels
        self.code = code
    }

    var ladder: MelsecLadderRuntime? {
        if case let .ladder(runtime) = code { return runtime }
        return nil
    }
}

/// What Write to PLC transfers: device memory, global labels and the
/// programs in scan order.
nonisolated final class MelsecCPUImage {
    let memory: MelsecDeviceMemory
    let globals: MelsecLabelStorage
    let programs: [MelsecProgramImage]
    let context: ExecutionContext

    init(memory: MelsecDeviceMemory, globals: MelsecLabelStorage, programs: [MelsecProgramImage]) {
        self.memory = memory
        self.globals = globals
        self.programs = programs
        context = ExecutionContext(dialect: .melsec, blocks: programs.map(\.block))
    }

    /// Every Timer/Counter label, global and local.
    var labelTimerCounters: [MelsecTimerCounter] {
        globals.timerCounters + programs.flatMap { $0.labels.timerCounters }
    }
}

/// A simulated FX5U CPU (GX Simulator3's role).
///
/// Scan: input refresh (X from the board, analog inputs into SD6020/SD6060),
/// special relay update, the programs in order, then END processing
/// (Y to the board, SD6180 to the analog output, scan time into SD520…).
/// Devices keep their values through STOP; the outputs go OFF.
nonisolated final class MelsecCPU: SimulatedCPU {
    let profile: MelsecCPUProfile
    private(set) var memory: MelsecDeviceMemory
    private(set) var image: MelsecCPUImage?
    private(set) var mode: CPUMode = .stop
    private(set) var clock: Int64 = 0
    private(set) var diagnostics: [DiagnosticEvent] = []
    /// The stop error, shown until RESET or the next RUN.
    private(set) var errorMessage: String?
    private(set) var scanCount: Int64 = 0
    /// Monitor mode: ladder programs record per-instruction state.
    var isMonitoring = false
    /// Forced inputs (X device number → value) override the board.
    private(set) var forcedInputs: [Int: Bool] = [:]
    /// Forced outputs (Y device number → value) override the program.
    private(set) var forcedOutputs: [Int: Bool] = [:]

    private var boardInputs: [Bool]
    private var analogInputs: [Int]
    private var outputImage: [Bool]
    private var analogOutputImage: [Int]
    private var startupPending = false
    private var runStart: Int64 = 0
    private var lastScanClock: Int64?
    private var minimumScanTime: Int64?
    private var maximumScanTime: Int64 = 0

    init(profile: MelsecCPUProfile = .fx5u) {
        self.profile = profile
        memory = MelsecDeviceMemory(profile: profile)
        boardInputs = Array(repeating: false, count: profile.digitalInputCount)
        outputImage = Array(repeating: false, count: profile.digitalOutputCount)
        analogInputs = Array(repeating: 0, count: profile.analogInputRegisters.count)
        analogOutputImage = Array(repeating: 0, count: profile.analogOutputRegisters.count)
    }

    // MARK: Loading and modes

    /// Write to PLC. Loading while in RUN restarts (SM402 pulses again).
    func load(_ image: MelsecCPUImage) {
        self.image = image
        memory = image.memory
        for program in image.programs {
            program.ladder?.resetEdges()
        }
        if mode == .run {
            startupPending = true
        }
    }

    func setMode(_ newMode: CPUMode) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .run:
            errorMessage = nil
            startupPending = true
        case .stop:
            turnOutputsOff()
        }
    }

    /// The RESET switch: STOP, clear the error, clear non-latched devices
    /// and restore label initial values.
    func reset() {
        mode = .stop
        errorMessage = nil
        turnOutputsOff()
        memory.clearNonLatched()
        image?.globals.reset()
        for program in image?.programs ?? [] {
            program.labels.reset()
            program.ladder?.resetEdges()
        }
        scanCount = 0
        diagnostics.append(DiagnosticEvent(time: clock, message: "CPU reset.", isError: false))
    }

    /// Latch clear (only in STOP): clears latched devices too.
    func latchClear() {
        guard mode == .stop else { return }
        memory.clearAll()
        image?.globals.reset()
        for program in image?.programs ?? [] {
            program.labels.reset()
        }
    }

    // MARK: Scan

    func scan(clock newClock: Int64) {
        clock = newClock
        guard mode == .run else { return }
        if startupPending {
            startup()
        }
        let firstScan = scanCount == 0

        // Input refresh.
        for index in boardInputs.indices {
            memory.setBit(.input, index, forcedInputs[index] ?? boardInputs[index])
        }
        for (number, value) in forcedInputs where number >= boardInputs.count {
            memory.setBit(.input, number, value)
        }
        for (channel, register) in profile.analogInputRegisters.enumerated() where analogInputs.indices.contains(channel) {
            memory.setWord(.specialRegister, register, UInt16(truncatingIfNeeded: analogInputs[channel]))
        }
        updateSpecialRelays(firstScan: firstScan)

        // Programs.
        if let image {
            image.context.beginScan(clock: clock)
            for program in image.programs {
                do {
                    switch program.code {
                    case let .ladder(runtime):
                        try runtime.execute(clock: clock, monitoring: isMonitoring)
                    case .structuredText:
                        try image.context.run(program.block, instance: program.instance)
                    }
                } catch let error as MelsecOperationError {
                    stopWithError(error.message)
                    return
                } catch let fault as RuntimeFault {
                    stopWithError("Operation error in \(program.name)\(fault.location.map { " (\($0))" } ?? ""): \(fault.message)")
                    return
                } catch {
                    stopWithError("Operation error in \(program.name): \(error.localizedDescription)")
                    return
                }
            }
        }

        // END processing.
        setSpecial(MelsecSpecialDevices.firstScanOn, false)
        setSpecial(MelsecSpecialDevices.initialPulseOn, false)
        setSpecial(MelsecSpecialDevices.firstScanOff, true)
        setSpecial(MelsecSpecialDevices.initialPulseOff, true)
        updateScanTime()
        refreshOutputs()
        scanCount += 1
    }

    private func startup() {
        startupPending = false
        runStart = clock
        scanCount = 0
        lastScanClock = nil
        minimumScanTime = nil
        maximumScanTime = 0
        for item in memory.timers + memory.retentiveTimers + (image?.labelTimerCounters ?? []) {
            item.lastUpdate = clock
        }
        for program in image?.programs ?? [] {
            program.ladder?.resetEdges()
        }
    }

    private func setSpecial(_ number: Int, _ value: Bool) {
        memory.setBit(.specialRelay, number, value)
    }

    private func updateSpecialRelays(firstScan: Bool) {
        setSpecial(MelsecSpecialDevices.alwaysOn, true)
        setSpecial(MelsecSpecialDevices.alwaysOff, false)
        setSpecial(MelsecSpecialDevices.runMonitorOn, true)
        setSpecial(MelsecSpecialDevices.runMonitorOff, false)
        setSpecial(MelsecSpecialDevices.firstScanOn, firstScan)
        setSpecial(MelsecSpecialDevices.initialPulseOn, firstScan)
        setSpecial(MelsecSpecialDevices.firstScanOff, !firstScan)
        setSpecial(MelsecSpecialDevices.initialPulseOff, !firstScan)
        // Clocks: OFF for the first half of each period after RUN, ON for the second.
        let elapsed = max(0, clock - runStart)
        for (relay, period) in MelsecSpecialDevices.clocks + MelsecSpecialDevices.compatibleClocks {
            setSpecial(relay, elapsed % period >= period / 2)
        }
    }

    /// SD520/SD521 current, SD522/SD523 minimum, SD524/SD525 maximum scan
    /// time (ms, µs); SD8010–SD8012 the same in 0.1 ms. The simulated scan
    /// time is the clock step between scans.
    private func updateScanTime() {
        let current = lastScanClock.map { max(0, clock - $0) } ?? 0
        lastScanClock = clock
        let minimum = min(minimumScanTime ?? current, current)
        minimumScanTime = minimum
        maximumScanTime = max(maximumScanTime, current)
        let base = MelsecSpecialDevices.scanTimeRegisters
        for (offset, value) in [current, minimum, maximumScanTime].enumerated() {
            memory.setWord(.specialRegister, base + offset * 2, UInt16(truncatingIfNeeded: value))
            memory.setWord(.specialRegister, base + offset * 2 + 1, 0)
            memory.setWord(.specialRegister, MelsecSpecialDevices.compatibleScanTimeRegisters + offset,
                           UInt16(truncatingIfNeeded: min(value * 10, 32767)))
        }
    }

    private func refreshOutputs() {
        for index in outputImage.indices {
            outputImage[index] = forcedOutputs[index] ?? memory.bit(.output, index)
        }
        for (channel, register) in profile.analogOutputRegisters.enumerated() where analogOutputImage.indices.contains(channel) {
            let raw = Int(Int16(bitPattern: memory.word(.specialRegister, register)))
            analogOutputImage[channel] = min(max(raw, profile.analogRange.lowerBound), profile.analogRange.upperBound)
        }
    }

    private func turnOutputsOff() {
        for index in outputImage.indices {
            outputImage[index] = false
        }
        for index in analogOutputImage.indices {
            analogOutputImage[index] = 0
        }
    }

    private func stopWithError(_ message: String) {
        mode = .stop
        errorMessage = message
        setSpecial(MelsecSpecialDevices.latestErrorRelay, true)
        setSpecial(MelsecSpecialDevices.latestErrorRelayNoAnnunciator, true)
        setSpecial(MelsecSpecialDevices.operationErrorRelay, true)
        diagnostics.append(DiagnosticEvent(time: clock, message: message, isError: true))
        turnOutputsOff()
    }

    // MARK: Monitoring and modifying

    /// Per-instruction monitor state of a ladder program (see
    /// `MelsecLadderRuntime.energized`); nil for unknown or ST programs.
    func monitorState(program name: String) -> [Bool]? {
        image?.programs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.ladder?.energized
    }

    /// Where a watch-window text points: "X0", "D100", "T0", "K4M0",
    /// "D0.3", "Label", "tm.N", or "ProgPou.localLabel".
    func place(for rawText: String, context: MelsecPlaceContext = .natural) throws -> (place: Place, type: PLCDataType) {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        if let image {
            let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, let program = image.programs.first(where: { $0.name.caseInsensitiveCompare(parts[0]) == .orderedSame }),
               program.labels.binding(parts[1]) != nil {
                return try program.labels.place(forLabel: parts[1])
            }
        }
        let operand = try MelsecOperandParser.parse(text, profile: profile)
        if case let .label(name) = operand {
            guard let image, image.globals.binding(String(name.split(separator: ".").first ?? "")) != nil else {
                throw MelsecOperandError(message: "'\(text)' is not a device or a global label.")
            }
            return try image.globals.place(forLabel: name)
        }
        if case .unspecified = operand {
            throw MelsecOperandError(message: "Enter a device or label.")
        }
        let place = try memory.place(for: operand, context: context)
        return (place, try memory.placeType(for: operand, context: context))
    }

    func readOperand(_ text: String) -> PLCValue? {
        guard let resolved = try? place(for: text) else { return nil }
        return resolved.place.read()
    }

    /// Modify Value: writes `valueText` (K10, H1F, 1.5, TRUE…) to an operand.
    func writeOperand(_ text: String, value valueText: String) throws {
        let resolved = try place(for: text)
        guard let value = ValueParser.parse(valueText, as: resolved.type) else {
            throw MelsecOperandError(message: "'\(valueText)' is not a valid \(resolved.type.rawValue) value.")
        }
        if let input = boardInput(text) {
            setDigitalInput(input, value.boolValue)
        }
        resolved.place.write(value)
    }

    /// Shift+Enter in monitor mode: inverts a bit device or label. X points
    /// wired to the board switch the board input.
    func toggleBit(_ text: String) throws {
        let resolved = try place(for: text, context: .bit)
        guard resolved.type == .bool else {
            throw MelsecOperandError(message: "'\(text)' is not a bit.")
        }
        let value = !resolved.place.read().boolValue
        if let input = boardInput(text) {
            setDigitalInput(input, value)
        }
        resolved.place.write(.bool(value))
    }

    private func boardInput(_ text: String) -> Int? {
        guard case let .device(device, nil)? = try? MelsecOperandParser.parse(text, profile: profile),
              device.kind == .input, boardInputs.indices.contains(device.number) else { return nil }
        return device.number
    }

    /// Registers (value) or cancels (nil) a forced input on X device `number`.
    func forceInput(_ number: Int, _ value: Bool?) {
        forcedInputs[number] = value
    }

    /// Registers (value) or cancels (nil) a forced output on Y device `number`.
    func forceOutput(_ number: Int, _ value: Bool?) {
        forcedOutputs[number] = value
        if mode == .run, outputImage.indices.contains(number) {
            outputImage[number] = value ?? memory.bit(.output, number)
        }
    }

    // MARK: ProcessIO

    var digitalInputCount: Int { BoardAddressing.melsecCounts.digitalInputs }
    var digitalOutputCount: Int { BoardAddressing.melsecCounts.digitalOutputs }
    var analogInputCount: Int { BoardAddressing.melsecCounts.analogInputs }
    var analogOutputCount: Int { BoardAddressing.melsecCounts.analogOutputs }
    var analogRange: ClosedRange<Int> { profile.analogRange }

    func setDigitalInput(_ index: Int, _ value: Bool) {
        guard boardInputs.indices.contains(index) else { return }
        boardInputs[index] = value
    }

    func digitalInput(_ index: Int) -> Bool {
        boardInputs.indices.contains(index) ? boardInputs[index] : false
    }

    func digitalOutput(_ index: Int) -> Bool {
        outputImage.indices.contains(index) ? outputImage[index] : false
    }

    func setAnalogInput(_ channel: Int, _ value: Int) {
        guard analogInputs.indices.contains(channel) else { return }
        analogInputs[channel] = min(max(value, analogRange.lowerBound), analogRange.upperBound)
    }

    func analogInput(_ channel: Int) -> Int {
        analogInputs.indices.contains(channel) ? analogInputs[channel] : 0
    }

    func analogOutput(_ channel: Int) -> Int {
        analogOutputImage.indices.contains(channel) ? analogOutputImage[channel] : 0
    }

    func digitalInputName(_ index: Int) -> String {
        BoardAddressing.name(.digitalInput(index), in: .gxWorks3)
    }

    func digitalOutputName(_ index: Int) -> String {
        BoardAddressing.name(.digitalOutput(index), in: .gxWorks3)
    }

    func analogInputName(_ channel: Int) -> String {
        BoardAddressing.name(.analogInput(channel), in: .gxWorks3)
    }

    func analogOutputName(_ channel: Int) -> String {
        BoardAddressing.name(.analogOutput(channel), in: .gxWorks3)
    }
}
