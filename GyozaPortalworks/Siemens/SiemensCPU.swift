import Foundation

/// A modify job from a watch table with a trigger other than "Modify now".
nonisolated struct SiemensModifyJob {
    var operand: String
    var value: String
    var trigger: S7ModifyTrigger
}

/// A simulated CPU 1214C DC/DC/DC (S7-PLCSIM for the practice board): 14 DI
/// %I0.0…%I1.5, 10 DQ %Q0.0…%Q1.1, 2 AI %IW64/%IW66 (0…27648) and, with
/// the SB 1232 signal board, 1 AQ %QW80.
///
/// RUN runs a warm restart first (non-retentive data to start values, process
/// images cleared, startup OBs), then cycles: inputs → cycle OBs → outputs.
/// A programming error is logged, ends the cycle program and leaves the CPU in
/// RUN with the ERROR LED flashing; an exceeded cycle time stops it.
nonisolated final class SiemensCPU: SimulatedCPU {
    private(set) var image: SiemensCPUImage?
    private(set) var memory: S7Memory
    private(set) var mode: CPUMode = .stop
    private(set) var clock: Int64 = 0
    private(set) var diagnostics: [DiagnosticEvent] = []
    /// The ERROR LED flashes after a programming error until the next STOP → RUN.
    private(set) var isErrorLEDFlashing = false
    private var startupPending = false
    private var firstCycle = false
    private var initialCallPending: Set<ObjectIdentifier> = []
    private var loggedFaults: Set<String> = []
    private var modifyJobs: [(job: SiemensModifyJob, operand: S7Operand, value: PLCValue)] = []
    /// Active force jobs as the force table shows them: operand → value text.
    private(set) var forceJobs: [(operand: String, value: String)] = []

    init(image: SiemensCPUImage? = nil) {
        self.image = image
        self.memory = image?.memory ?? S7Memory()
    }

    // MARK: LEDs

    /// RUN/STOP LED: green in RUN, yellow in STOP.
    var isRunLEDGreen: Bool { mode == .run }
    /// MAINT LED: yellow while force jobs are active.
    var isMaintenanceLEDOn: Bool { memory.hasForceJobs }

    // MARK: Operating mode

    func setMode(_ newMode: CPUMode) {
        switch newMode {
        case .run:
            guard mode == .stop else { return }
            guard let image, !image.cycleBlocks.isEmpty else {
                log(S7Messages.noProgram, isError: true)
                return
            }
            log(S7Messages.warmRestartRequested)
            mode = .run
            startupPending = true
            isErrorLEDFlashing = false
            loggedFaults = []
        case .stop:
            guard mode == .run else { return }
            log(S7Messages.stopRequested)
            enterStop()
        }
    }

    private func enterStop() {
        applyModifyJobs(at: [.onceAtTransitionToStop, .permanentlyAtTransitionToStop])
        modifyJobs.removeAll { $0.job.trigger == .onceAtTransitionToStop }
        mode = .stop
        startupPending = false
        memory.switchOffBoardOutputs()
    }

    /// Memory reset (MRES): bit memory, process images and every data block
    /// back to start values, retentive or not. The program and force jobs stay.
    func memoryReset() {
        if mode == .run {
            log(S7Messages.stopRequested)
            enterStop()
        }
        memory.memoryReset()
        if let image {
            for dataBlock in image.dataBlocks { dataBlock.node.reset() }
            for block in image.cycleBlocks + image.startupBlocks { image.locals(of: block).reset() }
        }
        isErrorLEDFlashing = false
        log(S7Messages.memoryReset)
    }

    /// Downloads a compiled program. A CPU in RUN is stopped, loaded and
    /// restarted ("Stop modules" … "Start all"). Data blocks whose layout is
    /// unchanged keep their actual values unless `reinitialize` is set; bit
    /// memory, the I/O and force jobs always carry over.
    func load(_ newImage: SiemensCPUImage, reinitialize: Bool = false) {
        let wasRunning = mode == .run
        if wasRunning {
            log(S7Messages.stopRequested)
            enterStop()
        }
        newImage.memory.copyContents(from: memory)
        if !reinitialize, let old = image {
            for entry in newImage.dataBlocks {
                if let previous = old.dataBlocks.first(where: { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }),
                   previous.type == entry.type {
                    entry.node.assign(from: previous.node)
                }
            }
        }
        image = newImage
        memory = newImage.memory
        modifyJobs = []
        log(S7Messages.downloaded)
        if wasRunning { setMode(.run) }
    }

    // MARK: Cycle

    func scan(clock newClock: Int64) {
        clock = newClock
        guard mode == .run, let image else { return }
        if startupPending {
            startup(image)
            guard mode == .run else { return }
        }
        cycle(image)
    }

    private func startup(_ image: SiemensCPUImage) {
        startupPending = false
        memory.warmRestart(retainedMarkerBytes: image.device.retentiveMarkerBytes)
        for dataBlock in image.dataBlocks { dataBlock.node.reset(keepingRetain: true) }
        for block in image.cycleBlocks + image.startupBlocks { image.locals(of: block).reset() }
        initialCallPending = Set((image.cycleBlocks + image.startupBlocks).map { ObjectIdentifier($0) })
        image.context.beginScan(clock: clock)
        for block in image.startupBlocks {
            prepareOrganizationBlock(block, image: image)
            do {
                try image.context.run(block, instance: image.locals(of: block))
            } catch let fault as RuntimeFault {
                if handle(fault) { return }
            } catch {
                log(error.localizedDescription, isError: true)
            }
        }
        firstCycle = true
        log(S7Messages.startupToRun)
    }

    private func cycle(_ image: SiemensCPUImage) {
        image.context.beginScan(clock: clock)
        memory.transferInputs(image.device.inputRanges)
        applyModifyJobs(at: [.permanent, .permanentlyAtStartOfCycle, .onceAtStartOfCycle])
        modifyJobs.removeAll { $0.job.trigger == .onceAtStartOfCycle }
        if image.device.isSystemMemoryEnabled {
            memory.updateSystemMemory(byte: image.device.systemMemoryByte, firstScan: firstCycle, diagnosticStatusChanged: false)
        }
        if image.device.isClockMemoryEnabled {
            memory.updateClockMemory(byte: image.device.clockMemoryByte, clock: clock)
        }
        for block in image.cycleBlocks {
            prepareOrganizationBlock(block, image: image)
            do {
                try image.context.run(block, instance: image.locals(of: block))
            } catch let fault as RuntimeFault {
                if handle(fault) { return }
                break
            } catch {
                log(error.localizedDescription, isError: true)
                break
            }
        }
        firstCycle = false
        applyModifyJobs(at: [.permanentlyAtEndOfCycle, .onceAtEndOfCycle])
        modifyJobs.removeAll { $0.job.trigger == .onceAtEndOfCycle }
        memory.transferOutputs(image.device.outputRanges)
    }

    /// Sets an OB's Initial_Call / Remanence inputs for this call.
    private func prepareOrganizationBlock(_ block: BlockHandle, image: SiemensCPUImage) {
        let locals = image.locals(of: block)
        let initial = initialCallPending.remove(ObjectIdentifier(block)) != nil
        locals.member("Initial_Call")?.write(.bool(initial))
        locals.member("Remanence")?.write(.bool(initial && image.hasRetentiveData))
        locals.member("LostRetentive")?.write(.bool(false))
        locals.member("LostRTC")?.write(.bool(false))
    }

    /// Reacts to a run-time fault; true when the CPU went to STOP.
    private func handle(_ fault: RuntimeFault) -> Bool {
        if fault.kind == .cycleTimeExceeded {
            log(S7Messages.cycleTimeStop + ": " + fault.message, isError: true)
            enterStop()
            return true
        }
        isErrorLEDFlashing = true
        let text = S7Messages.programmingError(fault)
        if loggedFaults.insert(text).inserted {
            log(text, isError: true)
        }
        return false
    }

    private func log(_ message: String, isError: Bool = false) {
        diagnostics.append(DiagnosticEvent(time: clock, message: message, isError: isError))
        if diagnostics.count > 50 { diagnostics.removeFirst(diagnostics.count - 50) }
    }

    // MARK: Online access (watch and force tables)

    /// A global view for operands typed into watch tables.
    private func watchCompiler() -> (compiler: S7OperandCompiler, frame: Frame) {
        let table = image?.symbols ?? SiemensSymbolTable(memory: memory)
        let context = image?.context ?? scratchContext
        let block = BlockHandle(name: "Watch table", kind: .organizationBlock, number: 0, members: [])
        let resolver = SiemensSymbolResolver(block: block, table: table)
        let frame = Frame(context: context, block: block, instance: block.makeInstanceArea(), temps: block.makeTemps())
        return (S7OperandCompiler(resolver: resolver), frame)
    }

    private let scratchContext = ExecutionContext(dialect: .siemens)

    /// Compiles a watch-table operand, throwing TIA-style errors.
    func operand(_ text: String, usage: S7OperandUsage) throws -> (operand: S7Operand, frame: Frame) {
        let access = watchCompiler()
        return (try access.compiler.compile(text, expected: nil, usage: usage), access.frame)
    }

    func readOperand(_ text: String) -> PLCValue? {
        guard let access = try? operand(text, usage: .read), access.operand.elementary != nil else { return nil }
        return try? access.operand.read(access.frame)
    }

    /// The Monitor value column for an operand: its value in a display format,
    /// or the reason it can't be shown.
    func monitorValue(_ text: String, format: S7DisplayFormat? = nil) -> Result<String, ResolveError> {
        do {
            let (compiled, frame) = try operand(text, usage: .read)
            guard let type = compiled.elementary else {
                return .failure(ResolveError(message: S7Messages.dataTypeNotPermitted(compiled.type.displayName)))
            }
            let value = try compiled.read(frame)
            return .success((format ?? S7DisplayFormat.standard(for: type)).format(value, as: type))
        } catch let problem as ResolveError {
            return .failure(problem)
        } catch {
            return .failure(ResolveError(message: error.localizedDescription))
        }
    }

    /// "Modify now": writes a value once. Peripheral inputs can't be modified.
    func modify(_ text: String, to valueText: String, format: S7DisplayFormat? = nil) throws {
        let (compiled, frame) = try operand(text, usage: .write)
        guard let type = compiled.elementary else { throw ResolveError(message: S7Messages.dataTypeNotPermitted(compiled.type.displayName)) }
        guard let value = (format ?? S7DisplayFormat.standard(for: type)).parse(valueText, as: type) else {
            throw ResolveError(message: S7Messages.invalidConstant(valueText, type.rawValue))
        }
        try compiled.write(frame, value)
    }

    /// Replaces the modify jobs that run with a trigger ("Modify with trigger").
    func setModifyJobs(_ jobs: [SiemensModifyJob]) throws {
        var compiledJobs: [(job: SiemensModifyJob, operand: S7Operand, value: PLCValue)] = []
        for job in jobs {
            let (compiled, _) = try operand(job.operand, usage: .write)
            guard let type = compiled.elementary, let value = S7DisplayFormat.standard(for: type).parse(job.value, as: type) else {
                throw ResolveError(message: S7Messages.invalidConstant(job.value, compiled.type.displayName))
            }
            compiledJobs.append((job, compiled, value))
        }
        modifyJobs = compiledJobs
    }

    private func applyModifyJobs(at triggers: [S7ModifyTrigger]) {
        guard !modifyJobs.isEmpty else { return }
        let frame = watchCompiler().frame
        for entry in modifyJobs where triggers.contains(entry.job.trigger) {
            try? entry.operand.write(frame, entry.value)
        }
    }

    /// Forces an I/O operand ("%I0.0:P", "\"Start\":P", "%QW80:P"). Only I/O
    /// addresses with ":P" can be forced on an S7-1200.
    func force(_ text: String, to valueText: String) throws {
        let (address, type) = try forceAddress(text)
        guard let value = S7DisplayFormat.standard(for: type).parse(valueText, as: type) else {
            throw ResolveError(message: S7Messages.invalidConstant(valueText, type.rawValue))
        }
        memory.force(address, type: type, value)
        forceJobs.removeAll { $0.operand.caseInsensitiveCompare(text) == .orderedSame }
        forceJobs.append((operand: text, value: valueText))
    }

    /// "Stop forcing": removes every force job.
    func stopForcing() {
        memory.clearForces()
        forceJobs = []
    }

    private func forceAddress(_ text: String) throws -> (S7Address, PLCDataType) {
        let path = try S7OperandParser.parse(text)
        guard path.isPeripheral, path.accessors.isEmpty else {
            throw ResolveError(message: "Only I/O addresses with \":P\" can be forced on an S7-1200, e.g. %I0.0:P.")
        }
        let table = image?.symbols ?? SiemensSymbolTable(memory: memory)
        switch path.root {
        case let .absolute(address):
            let parsed = try S7Address.parse(address + ":P")
            return (parsed, parsed.width.defaultType)
        case let .global(name), let .plain(name):
            if let entry = table.tag(named: name) {
                guard entry.address.area != .memory else { throw ResolveError(message: S7Messages.peripheralOnlyForIO) }
                var address = entry.address
                address.isPeripheral = true
                return (address, entry.tag.dataType)
            }
            let parsed = try S7Address.parse(name + ":P")
            return (parsed, parsed.width.defaultType)
        case .local:
            throw ResolveError(message: S7Messages.peripheralOnlyForIO)
        }
    }

    // MARK: Monitoring

    /// Switches LAD/FBD monitoring ("Monitoring on/off") for a block.
    func setMonitoring(_ enabled: Bool, block name: String) {
        guard let image, let block = image.block(named: name) else { return }
        if enabled {
            image.context.monitoredBlocks.insert(ObjectIdentifier(block))
        } else {
            image.context.monitoredBlocks.remove(ObjectIdentifier(block))
            image.monitor(ofBlock: name)?.reset()
        }
    }

    /// What the LAD/FBD editor shows while monitoring a block.
    func monitor(ofBlock name: String) -> S7BlockMonitor? {
        image?.monitor(ofBlock: name)
    }

    /// A data block's storage, for "Monitor all" in the DB editor.
    func dataBlock(named name: String) -> DataNode? {
        image?.dataBlock(named: name)
    }

    // MARK: ProcessIO

    var digitalInputCount: Int { BoardAddressing.siemensCounts.digitalInputs }
    var digitalOutputCount: Int { BoardAddressing.siemensCounts.digitalOutputs }
    var analogInputCount: Int { BoardAddressing.siemensCounts.analogInputs }
    var analogOutputCount: Int {
        (image?.device.hasSignalBoard ?? true) ? BoardAddressing.siemensCounts.analogOutputs : 0
    }
    var analogRange: ClosedRange<Int> { 0...27_648 }

    func setDigitalInput(_ index: Int, _ value: Bool) {
        guard index >= 0, index < digitalInputCount else { return }
        memory.setBoardInputBit(byte: index / 8, bit: index % 8, value)
    }

    func digitalInput(_ index: Int) -> Bool {
        guard index >= 0, index < digitalInputCount else { return false }
        return memory.boardInputBit(byte: index / 8, bit: index % 8)
    }

    func digitalOutput(_ index: Int) -> Bool {
        guard index >= 0, index < digitalOutputCount else { return false }
        return memory.effectiveBoardOutputBit(byte: index / 8, bit: index % 8)
    }

    func setAnalogInput(_ channel: Int, _ value: Int) {
        guard channel >= 0, channel < analogInputCount else { return }
        memory.setBoardInputWord(byte: 64 + 2 * channel, min(max(value, -32_768), 32_767))
    }

    func analogInput(_ channel: Int) -> Int {
        guard channel >= 0, channel < analogInputCount else { return 0 }
        return memory.boardInputWord(byte: 64 + 2 * channel)
    }

    func analogOutput(_ channel: Int) -> Int {
        guard channel >= 0, channel < analogOutputCount else { return 0 }
        return memory.effectiveBoardOutputWord(byte: 80 + 2 * channel)
    }

    func digitalInputName(_ index: Int) -> String { BoardAddressing.name(.digitalInput(index), in: .tiaPortal) }
    func digitalOutputName(_ index: Int) -> String { BoardAddressing.name(.digitalOutput(index), in: .tiaPortal) }
    func analogInputName(_ channel: Int) -> String { BoardAddressing.name(.analogInput(channel), in: .tiaPortal) }
    func analogOutputName(_ channel: Int) -> String { BoardAddressing.name(.analogOutput(channel), in: .tiaPortal) }
}
