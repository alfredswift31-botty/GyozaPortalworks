import Foundation

/// Convert, Program Check, GX Simulator3, Write to PLC, monitoring and the
/// watch windows.
extension MelsecWorkspace {
    var compiler: MelsecProjectCompiler {
        MelsecProjectCompiler(compileST: compileST)
    }

    // MARK: Convert

    /// Convert (F4) / Rebuild All (Shift+Alt+F4): converts every program and
    /// reports to the Output window. Returns whether there were no errors.
    @discardableResult
    func convert(rebuildAll: Bool) -> Bool {
        let output = compiler.compile(project)
        recordConversion(output)
        var messages = output.diagnostics.map { diagnostic in
            message(for: diagnostic)
        }
        let errors = messages.filter { $0.result == .error }.count
        let warnings = messages.filter { $0.result == .warning }.count
        let action = rebuildAll ? "Rebuild All" : "Convert"
        messages.append(MelsecOutputMessage(id: 0, result: .information, dataName: project.name, category: action,
                                            content: "\(action) completed: \(errors) error(s), \(warnings) warning(s)."))
        setOutput(numbered(messages))
        if errors > 0 {
            bottomTab = .output
        }
        return errors == 0
    }

    private func message(for diagnostic: Diagnostic) -> MelsecOutputMessage {
        let result: MelsecOutputMessage.Result
        switch diagnostic.severity {
        case .error: result = .error
        case .warning: result = .warning
        case .information: result = .information
        }
        let program = project.programs.first { $0.name == diagnostic.block }
        var cell: MelsecCellRef?
        var line: Int?
        var category = "Label"
        if let program {
            if program.language == .ladder, let row = diagnostic.line, let column = diagnostic.column {
                cell = MelsecCellRef(row: row - 1, column: column - 1)
                category = "Ladder"
            } else if program.language == .structuredText {
                line = diagnostic.line
                category = "ST"
            } else {
                category = "Program"
            }
        }
        var content = diagnostic.message
        if let network = diagnostic.network, let row = diagnostic.line, let column = diagnostic.column {
            content = "(Block \(network), row \(row), column \(column)) " + content
        } else if program?.language == .structuredText, let row = diagnostic.line {
            content = "(Line \(row)) " + content
        }
        return MelsecOutputMessage(id: 0, result: result, dataName: diagnostic.block ?? project.name, category: category,
                                   content: content, programID: program?.id, cell: cell, line: line, column: diagnostic.column)
    }

    private func numbered(_ messages: [MelsecOutputMessage]) -> [MelsecOutputMessage] {
        messages.enumerated().map { index, message in
            var numbered = message
            numbered.id = index + 1
            return numbered
        }
    }

    /// Output window rows after the filter buttons.
    var visibleOutput: [MelsecOutputMessage] {
        outputMessages.filter { outputFilter.contains($0.result) }
    }

    func outputCount(_ result: MelsecOutputMessage.Result) -> Int {
        outputMessages.filter { $0.result == result }.count
    }

    /// Double-click in the Output window: opens the program at the error.
    func jump(to message: MelsecOutputMessage) {
        guard let id = message.programID else {
            if message.dataName == "Global Label" { open(.globalLabels) }
            return
        }
        open(.program(id))
        if let cell = message.cell {
            cursors[id] = cell
        }
        pendingSourceJump = message.line.map { MelsecSourcePosition(line: $0, column: message.column ?? 1) }
    }

    // MARK: Program Check

    /// Tool › Program Check: converts, then checks with the chosen items.
    func runProgramCheck() {
        let output = compiler.compile(project)
        recordConversion(output)
        var messages = output.diagnostics.map { message(for: $0) }
        let findings = output.findings.filter { programCheckOptions.categories.contains($0.category) }
        for finding in findings {
            let program = project.programs.first { $0.name == finding.program }
            let step = finding.step.map { "(Step \($0)) " } ?? ""
            messages.append(MelsecOutputMessage(id: 0, result: finding.severity == .error ? .error : .warning,
                                                dataName: finding.program, category: "Program Check \(finding.category.rawValue)",
                                                content: step + finding.message, programID: program?.id,
                                                cell: stepCell(program, step: finding.step)))
        }
        messages.append(MelsecOutputMessage(id: 0, result: .information, dataName: project.name, category: "Program Check",
                                            content: "Program Check completed: \(findings.count) finding(s)."))
        setOutput(numbered(messages))
        bottomTab = .output
    }

    /// The cell whose instruction starts at `step`.
    private func stepCell(_ program: MelsecProgram?, step: Int?) -> MelsecCellRef? {
        guard let program, let step, let conversion = conversions[program.id] else { return nil }
        let steps = conversion.program.stepNumbers
        guard let index = steps.firstIndex(of: step), conversion.program.instructions.indices.contains(index) else { return nil }
        return conversion.program.instructions[index].cell
    }

    /// The Conversion Result window for the selected program: Step | Code.
    var conversionListing: [MelsecListingLine] {
        guard let id = selectedProgram?.id, let conversion = conversions[id], conversion.succeeded else { return [] }
        return conversion.listing(project.profile)
    }

    // MARK: Exercise checking

    /// Compiles the current project into a new CPU in RUN for the exercise
    /// checker. The on-screen simulation is not touched.
    func makeCheckCPU() -> Result<any SimulatedCPU, CheckSetupError> {
        let output = compiler.compile(project)
        guard let image = output.image else {
            let errors = output.diagnostics.filter { $0.severity == .error }
            let details = errors.prefix(5).map { diagnostic -> String in
                var place = diagnostic.block ?? project.name
                if let network = diagnostic.network, let row = diagnostic.line, let column = diagnostic.column {
                    place += " (block \(network), row \(row), column \(column))"
                } else if let line = diagnostic.line {
                    place += " (line \(line))"
                }
                return "\(place): \(diagnostic.message)"
            }
            return .failure(CheckSetupError(message: "Your program doesn't compile yet. Convert it (F4) and fix the errors in the Output window.",
                                            details: Array(details)))
        }
        let cpu = MelsecCPU(profile: project.profile)
        cpu.load(image)
        cpu.setMode(.run)
        return .success(cpu)
    }

    // MARK: Simulation

    /// Debug › Simulation › Start Simulation: converts, then asks to write.
    func startSimulation() {
        guard session == nil else {
            isSimulatorPanelVisible = true
            return
        }
        guard convert(rebuildAll: true) else {
            alert = MelsecAlert(title: "Start Simulation", message: "The simulation cannot start because the project has conversion errors. See the Output window.")
            return
        }
        sheet = .onlineDataOperation(.startSimulation)
    }

    /// Execute in the Online Data Operation dialog.
    func executeOnlineOperation(_ operation: MelsecOnlineOperation) {
        sheet = nil
        switch operation {
        case .startSimulation:
            bootSimulator()
        case .writeToPLC:
            guard let cpu else { return }
            if cpu.mode == .run {
                alert = MelsecAlert(title: "Write to PLC", message: "The CPU is in RUN. Execute remote STOP and write?", action: .remoteStopAndWrite)
            } else {
                _ = writeProgram(restart: false)
            }
        case .readFromPLC:
            guard let written = writtenProject else { return }
            mutate { $0.programs = written.programs; $0.globalLabels = written.globalLabels }
            statusMessage = "Read from PLC completed."
        }
    }

    /// Answers a message box.
    func answerAlert(_ alert: MelsecAlert, yes: Bool) {
        self.alert = nil
        guard yes else { return }
        switch alert.action {
        case .none:
            break
        case .remoteStopAndWrite:
            session?.setMode(.stop)
            if writeProgram(restart: false) {
                self.alert = MelsecAlert(title: "Write to PLC", message: "Write to PLC completed. Execute remote RUN?", action: .remoteRun)
            }
        case .remoteRun:
            if simulatorSwitch == .run {
                session?.setMode(.run)
            }
        case .newProject:
            newProject()
        }
    }

    /// Creates the simulated FX5U, writes the project and starts it in RUN.
    func bootSimulator() {
        let cpu = MelsecCPU(profile: project.profile)
        let output = compiler.compile(project, memory: cpu.memory)
        recordConversion(output)
        guard let image = output.image else {
            alert = MelsecAlert(title: "Start Simulation", message: "The project could not be written: it has errors.")
            return
        }
        cpu.load(image)
        let session = SimulationSession(cpu: cpu)
        setOnline(session: session, cpu: cpu)
        setWritten(output.conversions, project: project)
        setSimulatorSwitch(.run)
        session.setMode(.run)
        session.start()
        isSimulatorPanelVisible = true
        cpu.isMonitoring = mode.isMonitoring
    }

    /// Writes the current project into the running simulator's CPU.
    @discardableResult
    func writeProgram(restart: Bool) -> Bool {
        guard let cpu, let session else { return false }
        let output = compiler.compile(project, memory: cpu.memory)
        recordConversion(output)
        guard let image = output.image else {
            alert = MelsecAlert(title: "Write to PLC", message: "The project has conversion errors and was not written. See the Output window.")
            return false
        }
        cpu.load(image)
        cpu.isMonitoring = mode.isMonitoring
        setWritten(output.conversions, project: project)
        if restart, simulatorSwitch == .run {
            session.setMode(.run)
        }
        session.refresh()
        return true
    }

    /// Online › Write to PLC.
    func writeToPLC() {
        guard session != nil else {
            alert = MelsecAlert(title: "Write to PLC", message: "There is no connection to a CPU. Start the simulation first (Debug › Simulation › Start Simulation).")
            return
        }
        guard convert(rebuildAll: false) else {
            alert = MelsecAlert(title: "Write to PLC", message: "The project has conversion errors. See the Output window.")
            return
        }
        sheet = .onlineDataOperation(.writeToPLC)
    }

    /// Online › Read from PLC.
    func readFromPLC() {
        guard session != nil, writtenProject != nil else {
            alert = MelsecAlert(title: "Read from PLC", message: "There is no connection to a CPU. Start the simulation first.")
            return
        }
        sheet = .onlineDataOperation(.readFromPLC)
    }

    /// Debug › Simulation › Stop Simulation.
    func stopSimulation() {
        session?.stop()
        setOnline(session: nil, cpu: nil)
        setWritten([:], project: nil)
        isSimulatorPanelVisible = false
        watching = Array(repeating: false, count: 4)
        isBatchMonitoring = false
        if mode.isMonitoring {
            setEditorMode(.write)
        }
    }

    /// GX Simulator3's RUN/STOP switch. RUN with a stop error keeps the CPU
    /// in STOP until RESET, as on the real CPU.
    func setSwitch(_ position: CPUMode) {
        setSimulatorSwitch(position)
        session?.setMode(position)
    }

    /// GX Simulator3's RESET button.
    func resetCPU() {
        guard let cpu, let session else { return }
        cpu.reset()
        if simulatorSwitch == .run {
            session.setMode(.run)
        }
        session.refresh()
    }

    /// Online › Remote Operation: Latch Clear (in STOP).
    func latchClear() {
        guard let cpu, let session else { return }
        guard cpu.mode == .stop else {
            alert = MelsecAlert(title: "Latch Clear", message: "Latch clear can only be executed while the CPU is in STOP.")
            return
        }
        cpu.latchClear()
        session.refresh()
    }

    // MARK: Modify Value

    /// Debug › Modify Value: Set. Returns an error message, or nil.
    func modifyValue(device: String, type: MelsecModifyType, value: String) -> String? {
        guard let cpu, let session else { return "There is no connection to a CPU." }
        do {
            try cpu.writeOperand(device, value: value, context: type.context)
        } catch let error as MelsecOperandError {
            return error.message
        } catch {
            return "'\(device)' cannot be changed."
        }
        session.refresh()
        return nil
    }

    // MARK: Watch

    /// One watch row's live columns: Current Value, Data Type, Comment.
    func watchRow(_ name: String, format: MelsecDisplayFormat, list: Int) -> (value: String, type: String, comment: String) {
        let comment = project.comment(for: name) ?? labelComment(name) ?? ""
        let place = try? (cpu ?? typeProbe).place(for: name)
        guard let place else { return ("", "", comment) }
        let type = MelsecDisplayFormat.typeName(place.type)
        guard watching.indices.contains(list), watching[list], cpu != nil else { return ("", type, comment) }
        return (format.format(place.place.read(), type: place.type), type, comment)
    }

    private func labelComment(_ name: String) -> String? {
        let base = String(name.split(separator: ".").first ?? "")
        let label = project.globalLabels.first { $0.name.caseInsensitiveCompare(base) == .orderedSame }
        return label.flatMap { $0.comment.isEmpty ? nil : $0.comment }
    }

    /// ON / OFF / Switch ON/OFF for the selected watch row.
    func watchSet(list: Int, bit: Bool?) {
        guard let name = watchSelection[list], let cpu, let session else { return }
        do {
            if let bit {
                try cpu.writeOperand(name, value: bit ? "TRUE" : "FALSE", context: .bit)
            } else {
                try cpu.toggleBit(name)
            }
        } catch let error as MelsecOperandError {
            statusMessage = error.message
        } catch {
            statusMessage = "'\(name)' cannot be changed."
        }
        session.refresh()
    }

    // MARK: Monitor values in the ladder

    /// The instruction indices of a cell in the program written to the CPU.
    func monitoredInstructions(programID: UUID, cell: MelsecCellRef) -> [Int] {
        writtenConversions[programID]?.cellInstructions[cell] ?? []
    }

    /// Whether the monitored program has a cell energised (contact
    /// conducting, coil/instruction executed with its condition ON).
    func isEnergized(programID: UUID, cell: MelsecCellRef) -> Bool {
        guard mode.isMonitoring, let cpu, let program = program(programID),
              let state = cpu.monitorState(program: program.name) else { return false }
        return monitoredInstructions(programID: programID, cell: cell).contains { state.indices.contains($0) && state[$0] }
    }

    /// A value to show under an operand while monitoring: word devices and
    /// the current value of timer/counter coils. nil for bits.
    func monitorValue(_ operand: String, isTimerCoil: Bool = false) -> String? {
        guard mode.isMonitoring, let cpu, operand != "?" else { return nil }
        let name = isTimerCoil ? timerValueOperand(operand) : operand
        guard let resolved = try? cpu.place(for: name) else { return nil }
        guard resolved.type != .bool else { return nil }
        return MelsecDisplayFormat.decimal.format(resolved.place.read(), type: resolved.type)
    }

    /// The bit state of an operand while monitoring (coils, contacts).
    func monitorBit(_ operand: String) -> Bool? {
        guard mode.isMonitoring, let cpu, operand != "?", let resolved = try? cpu.place(for: operand, context: .bit),
              resolved.type == .bool else { return nil }
        return resolved.place.read().boolValue
    }

    /// T0 → TN0 (and tmLabel → tmLabel.N) for the value shown by a coil.
    private func timerValueOperand(_ operand: String) -> String {
        if case let .device(device, index)? = try? MelsecOperandParser.parse(operand, profile: project.profile), device.kind.isTimerOrCounter {
            return MelsecOperand.device(MelsecDevice(device.kind, device.number, facet: .value), index: index).text(project.profile)
        }
        return operand + ".N"
    }
}
