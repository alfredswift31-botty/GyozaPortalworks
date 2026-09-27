import Foundation
import Testing
@testable import GyozaPortalworks

struct MelsecKeyMapTests {
    private func command(_ key: MelsecKey, _ modifiers: MelsecKeyModifiers = []) -> MelsecLadderCommand? {
        MelsecKeyMap.command(for: key, modifiers: modifiers)
    }

    @Test func functionKeysMatchGXWorks3() {
        #expect(command(.function(5)) == .ladderInput(.openContact, text: ""))
        #expect(command(.function(5), .shift) == .ladderInput(.openBranch, text: ""))
        #expect(command(.function(6)) == .ladderInput(.closeContact, text: ""))
        #expect(command(.function(6), .shift) == .ladderInput(.closeBranch, text: ""))
        #expect(command(.function(7)) == .ladderInput(.coil, text: ""))
        #expect(command(.function(8)) == .ladderInput(.instruction, text: ""))
        #expect(command(.function(7), .shift) == .ladderInput(.risingPulse, text: ""))
        #expect(command(.function(8), .shift) == .ladderInput(.fallingPulse, text: ""))
        #expect(command(.function(7), .option) == .ladderInput(.risingPulseBranch, text: ""))
        #expect(command(.function(8), .option) == .ladderInput(.fallingPulseBranch, text: ""))
        #expect(command(.function(5), .option) == .insertOperationResult(.risingPulse))
        #expect(command(.function(5), [.control, .option]) == .insertOperationResult(.fallingPulse))
        #expect(command(.function(10), [.control, .option]) == .insertOperationResult(.invert))
        #expect(command(.function(9)) == .drawHorizontalLine)
        #expect(command(.function(9), .shift) == .drawVerticalLine)
        #expect(command(.function(9), .control) == .deleteHorizontalLine)
        #expect(command(.function(10), .control) == .deleteVerticalLine)
        #expect(command(.function(4)) == .convert)
        #expect(command(.function(4), [.shift, .option]) == .rebuildAll)
        #expect(command(.function(2)) == .setMode(.write))
        #expect(command(.function(2), .shift) == .setMode(.read))
        #expect(command(.function(3)) == .setMode(.monitor))
        #expect(command(.function(3), .shift) == .setMode(.monitorWrite))
        #expect(command(.function(3), .option) == .setMode(.write))
        #expect(command(.function(11)) == nil)
    }

    @Test func editingKeys() {
        #expect(command(.arrow(.left)) == .moveCursor(.left))
        #expect(command(.arrow(.down), .control) == .drawLine(.down))
        #expect(command(.enter) == .editElement)
        #expect(command(.enter, .shift) == .toggleBit)
        #expect(command(.insert) == .toggleInsertMode)
        #expect(command(.insert, .shift) == .insertRow)
        #expect(command(.insert, .control) == .insertColumn)
        #expect(command(.delete) == .deleteElement)
        #expect(command(.delete, .shift) == .deleteRow)
        #expect(command(.delete, .control) == .deleteColumn)
        #expect(command(.character("x")) == .ladderInput(.openContact, text: "x"))
        #expect(command(.character(";")) == .ladderInput(.openContact, text: ";"))
        #expect(command(.character("z"), .control) == .undo)
        #expect(command(.character("y"), .control) == .redo)
        #expect(command(.character("z"), .command) == .undo)
        #expect(command(.character("z"), [.command, .shift]) == .redo)
        #expect(command(.escape) == nil)
    }

    @Test func everyFunctionKeyHasMenuText() {
        for binding in MelsecKeyMap.functionKeyBindings {
            #expect(MelsecKeyMap.shortcutText(binding.command) != nil, "\(binding.command)")
        }
        #expect(MelsecKeyMap.functionKeyBindings.count == 24)
    }
}

@MainActor
struct MelsecWorkspaceEditingTests {
    /// Types Ladder Input texts the way a user does: key → dialog → OK. After
    /// an OR entry the cursor moves to the next free row.
    static func type(_ inputs: [String], into workspace: MelsecWorkspace) throws {
        let id = try #require(workspace.selectedLadderID)
        for input in inputs {
            workspace.perform(.ladderInput(.openContact, text: ""))
            guard case let .ladderInput(state)? = workspace.sheet else {
                Issue.record("Ladder Input didn't open for \(input)")
                return
            }
            var typed = state
            typed.text = input
            if let error = workspace.confirmLadderInput(typed) {
                Issue.record("\(input): \(error)")
            }
            if input.uppercased().hasPrefix("OR") {
                workspace.cursors[id] = MelsecCellRef(row: workspace.program(id)?.ladder.endRow ?? 0, column: 0)
            }
        }
    }

    @Test func newWorkspaceOpensProgPou() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        #expect(workspace.title(for: .program(id)) == "ProgPou [PRG] [LD]")
        #expect(workspace.openTabs == [.program(id)])
        #expect(MelsecEditorTabID(key: MelsecEditorTabID.program(id).key) == .program(id))
        #expect(MelsecEditorTabID(key: "globalLabels") == .globalLabels)
    }

    @Test func ladderInputDialogPlacesElements() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        workspace.perform(.ladderInput(.openContact, text: ""))
        guard case let .ladderInput(state)? = workspace.sheet else {
            Issue.record("no dialog")
            return
        }
        var typed = state
        typed.text = "X0"
        #expect(workspace.confirmLadderInput(typed) == nil)
        #expect(workspace.sheet == nil)
        #expect(workspace.program(id)?.ladder.rows[0].cells[0] == .contact(.normallyOpen, operand: "X0"))
        #expect(workspace.cursor(for: id) == MelsecCellRef(row: 0, column: 1))

        let coil = MelsecLadderInputState(symbol: .coil, text: "T0")
        #expect(workspace.confirmLadderInput(coil) == nil)
        #expect(workspace.program(id)?.ladder.rows[0].cells[11] == .output(mnemonic: "OUT", operands: ["T0", "?"]))

        let bad = MelsecLadderInputState(symbol: .instruction, text: "FOO X0")
        let error = workspace.confirmLadderInput(bad)
        #expect(error?.contains("does not exist") == true)
        guard case let .ladderInput(shown)? = workspace.sheet else {
            Issue.record("the dialog should stay open with the error")
            return
        }
        #expect(shown.error == error)
    }

    @Test func typingInTheCoilColumnStartsACoil() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        workspace.cursors[id] = MelsecCellRef(row: 0, column: 11)
        workspace.perform(.ladderInput(.openContact, text: "Y"))
        guard case let .ladderInput(state)? = workspace.sheet else {
            Issue.record("no dialog")
            return
        }
        #expect(state.symbol == .coil)
        #expect(state.text == "Y")
    }

    @Test func editingOperationsUndoAndRedo() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        try Self.type(["LD X0", "OUT Y0"], into: workspace)
        #expect(workspace.undoStack.count == 2)
        workspace.cursors[id] = MelsecCellRef(row: 0, column: 0)
        workspace.perform(.insertRow)
        #expect(workspace.program(id)?.ladder.rows.count == 2)
        workspace.perform(.undo)
        #expect(workspace.program(id)?.ladder.rows.count == 1)
        workspace.perform(.redo)
        #expect(workspace.program(id)?.ladder.rows.count == 2)
        workspace.undo()
        workspace.undo()
        #expect(workspace.program(id)?.ladder.rows[0].cells[11] == .empty)
        #expect(workspace.canRedo)
    }

    @Test func readModeBlocksEdits() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        workspace.perform(.setMode(.read))
        workspace.perform(.drawHorizontalLine)
        #expect(workspace.program(id)?.ladder.rows.isEmpty == true)
        #expect(workspace.statusMessage?.contains("F2") == true)
        workspace.perform(.moveCursor(.right))
        #expect(workspace.cursor(for: id).column == 1)
        workspace.perform(.setMode(.write))
        workspace.perform(.drawHorizontalLine)
        #expect(workspace.program(id)?.ladder.rows.count == 1)
    }

    @Test func insertModeAndClipboard() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        try Self.type(["LD X1"], into: workspace)
        workspace.cursors[id] = MelsecCellRef(row: 0, column: 0)
        #expect(workspace.copiedElementText == "LD X1")
        workspace.perform(.toggleInsertMode)
        #expect(workspace.isInsertMode)
        workspace.pasteElement("LDI X2")
        #expect(workspace.program(id)?.ladder.rows[0].cells[1] == .contact(.normallyOpen, operand: "X1"))
        #expect(workspace.program(id)?.ladder.rows[0].cells[0] == .contact(.normallyClosed, operand: "X2"))
        workspace.cursors[id] = MelsecCellRef(row: 0, column: 1)
        #expect(workspace.cutElement() == "LD X1")
        #expect(workspace.program(id)?.ladder.rows[0].cells[1] == .empty)
    }

    @Test func labelsCoalesceTypingIntoOneUndoStep() {
        let workspace = MelsecWorkspace(project: .newProject())
        workspace.addLabel(programID: nil)
        let label = workspace.project.globalLabels[0]
        #expect(label.name == "Label1")
        let before = workspace.undoStack.count
        workspace.updateLabel(label.id, programID: nil, field: "name") { $0.name = "S" }
        workspace.updateLabel(label.id, programID: nil, field: "name") { $0.name = "St" }
        workspace.updateLabel(label.id, programID: nil, field: "name") { $0.name = "Start" }
        #expect(workspace.undoStack.count == before + 1)
        #expect(workspace.project.globalLabels[0].name == "Start")
        workspace.undo()
        #expect(workspace.project.globalLabels[0].name == "Label1")
        workspace.updateLabel(label.id, programID: nil, field: "name") { $0.name = "X0" }
        #expect(workspace.labelProblems(programID: nil).contains { $0.contains("device") })
    }

    @Test func programsCanBeAddedRenamedAndDeleted() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        #expect(workspace.addProgram(name: "Conveyor", language: .structuredText) == nil)
        #expect(workspace.project.programs.count == 2)
        #expect(workspace.addProgram(name: "conveyor", language: .ladder)?.contains("already exists") == true)
        #expect(workspace.addProgram(name: "M0", language: .ladder) != nil)
        let id = try #require(workspace.project.programs.last?.id)
        #expect(workspace.selectedTab == .program(id))
        #expect(workspace.renameProgram(id, to: "Belt") == nil)
        #expect(workspace.program(id)?.name == "Belt")
        #expect(workspace.deleteProgram(id) == nil)
        #expect(workspace.deleteProgram(workspace.project.programs[0].id)?.contains("at least one") == true)
        #expect(!workspace.openTabs.contains(.program(id)))
    }

    @Test func navigationAndPaletteTrees() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        try Self.type(["LD X0", "OUT Y0"], into: workspace)
        let tree = MelsecNavigationNode.tree(for: workspace.project, unconverted: workspace.unconvertedPrograms)
        let program = try #require(tree.first?.children?.first { $0.title == "Program" })
        let scan = try #require(program.children?.first { $0.title == "Scan" })
        let main = try #require(scan.children?.first)
        #expect(main.title == "MAIN")
        #expect(main.children?.first?.title == "ProgPou")
        #expect(main.children?.first?.state == .unconverted)
        workspace.perform(.convert)
        let converted = MelsecNavigationNode.tree(for: workspace.project, unconverted: workspace.unconvertedPrograms)
        let block = converted.first?.children?.first { $0.title == "Program" }?.children?.first { $0.title == "Scan" }?.children?.first?.children?.first
        #expect(block?.state == .normal)

        let palette = MelsecPaletteNode.tree(search: "mov")
        let titles = palette.flatMap { $0.children ?? [] }.flatMap { $0.children ?? [] }.map(\.title)
        #expect(titles.contains("MOV") && titles.contains("DMOVP"))
        #expect(!titles.contains("LD"))
        #expect(MelsecPaletteNode.ladderInput(for: "MOV")?.symbol == .instruction)
        #expect(MelsecPaletteNode.ladderInput(for: "MOV")?.text == "MOV ")
        #expect(MelsecPaletteNode.ladderInput(for: "LDI")?.symbol == .openContact)
        #expect(MelsecPaletteNode.ladderInput(for: "OUT")?.symbol == .coil)
        #expect(MelsecPaletteNode.ladderInput(for: "INV")?.text == "INV")
    }

    @Test func displayFormatsAndBatchRows() throws {
        #expect(MelsecDisplayFormat.hexadecimal.format(.int(255), type: .int) == "00FFH")
        #expect(MelsecDisplayFormat.binary.format(.int(5), type: .int) == "0000000000000101")
        #expect(MelsecDisplayFormat.decimal.format(.int(-3), type: .int) == "-3")
        #expect(MelsecDisplayFormat.hexadecimal.format(.int(-1), type: .int) == "FFFFH")
        #expect(MelsecDisplayFormat.decimal.format(.bool(true), type: .bool) == "TRUE")
        let memory = MelsecDeviceMemory()
        memory.setWord(.dataRegister, 1, 0x4142)
        memory.setBit(.internalRelay, 17, true)
        let words = try #require(MelsecBatchRow.rows(start: "D0", count: 4, memory: memory) { $0 == "D1" ? "Speed" : nil })
        #expect(words.count == 4)
        #expect(words[1].value == 0x4142)
        #expect(words[1].string == "BA")
        #expect(words[1].comment == "Speed")
        #expect(words[1].bits[15] == false && words[1].bits[14] == true)
        #expect(words[1].bitDevices[15] == "D1.0")
        let bits = try #require(MelsecBatchRow.rows(start: "M16", count: 1, memory: memory) { _ in nil })
        #expect(bits[0].device == "M16")
        #expect(bits[0].bits[14])
        #expect(bits[0].bitDevices[14] == "M17")
        #expect(MelsecBatchRow.rows(start: "K10", memory: memory) { _ in nil } == nil)
    }
}

@MainActor
struct MelsecWorkspaceBuildTests {
    @Test func convertUpdatesBlockStateAndOutput() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        try MelsecWorkspaceEditingTests.type(["LD X0", "OUT Y0"], into: workspace)
        #expect(workspace.program(id)?.ladder.hasUnconvertedRows == true)
        workspace.perform(.convert)
        #expect(workspace.program(id)?.ladder.hasUnconvertedRows == false)
        #expect(workspace.outputCount(.error) == 0)
        #expect(workspace.outputMessages.last?.content.contains("0 error") == true)
        #expect(workspace.title(for: .program(id)) == "ProgPou [PRG] [LD] 3 Step")
        #expect(workspace.stepStatus(programID: id)?.total == 3)
        #expect(workspace.conversionListing.map(\.code) == ["LD X0", "OUT Y0", "END"])
        let drawing = try #require(workspace.ladderDrawing(programID: id, isFocused: true))
        #expect(drawing.blockSteps[0] == 0)
        #expect(drawing.endStep == 2)
    }

    @Test func conversionErrorsGoToOutputAndJump() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let id = try #require(workspace.selectedLadderID)
        try MelsecWorkspaceEditingTests.type(["LD X0", "OUT Y0", "LD X8", "OUT Y1"], into: workspace)
        workspace.perform(.convert)
        #expect(workspace.outputCount(.error) == 1)
        let error = try #require(workspace.outputMessages.first { $0.result == .error })
        #expect(error.cell == MelsecCellRef(row: 1, column: 0))
        #expect(error.content.contains("octal"))
        #expect(workspace.conversionErrors[id]?.isEmpty == false)
        #expect(workspace.program(id)?.ladder.hasUnconvertedRows == true)
        workspace.cursors[id] = MelsecCellRef(row: 0, column: 0)
        workspace.jump(to: error)
        #expect(workspace.cursor(for: id) == MelsecCellRef(row: 1, column: 0))
        workspace.outputFilter.remove(.error)
        #expect(!workspace.visibleOutput.contains { $0.result == .error })
    }

    @Test func programCheckReportsToOutput() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        try MelsecWorkspaceEditingTests.type(["LD X0", "OUT Y0", "LD X1", "OUT Y0"], into: workspace)
        workspace.runProgramCheck()
        #expect(workspace.outputMessages.contains { $0.result == .warning && $0.content.contains("Duplicated coil") })
        workspace.programCheckOptions.categories.remove(.duplicatedCoil)
        workspace.runProgramCheck()
        #expect(!workspace.outputMessages.contains { $0.content.contains("Duplicated coil") })
    }

    @Test func makeCheckCPUReportsCompileErrors() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        try MelsecWorkspaceEditingTests.type(["LD X9", "OUT Y0"], into: workspace)
        switch workspace.makeCheckCPU() {
        case .success:
            Issue.record("should not compile")
        case let .failure(error):
            #expect(error.message.contains("doesn't compile"))
            #expect(error.details.first?.contains("ProgPou") == true)
        }
        #expect(workspace.session == nil)
    }

    @Test(arguments: ["gx-01-self-hold", "gx-03-on-delay", "gx-07-parking"])
    func makeCheckCPUPassesExercises(_ id: String) throws {
        let exercise = try #require(ExerciseLibrary.exercises(for: .gxWorks3).first { $0.id == id })
        let inputs = try #require(MelsecExerciseTests.ladders[id])
        let workspace = MelsecWorkspace(project: .newProject())
        try MelsecWorkspaceEditingTests.type(inputs, into: workspace)
        switch workspace.makeCheckCPU() {
        case let .success(cpu):
            #expect(cpu.mode == .run)
            let report = ExerciseChecker.run(exercise, on: cpu)
            #expect(report.passed, "\(report.lines.map(\.text))")
        case let .failure(error):
            Issue.record("\(error.message) \(error.details)")
        }
        #expect(workspace.session == nil, "the check CPU is separate from the simulation")
    }

    @Test func structuredTextProgramsCompileThroughTheSTEngine() throws {
        var project = MelsecProject.newProject(language: .structuredText)
        project.programs[0].structuredText = "Y0 := X0 AND NOT X1;"
        let workspace = MelsecWorkspace(project: project)
        let id = project.programs[0].id
        #expect(workspace.unconvertedPrograms.contains(id))
        #expect(workspace.convert(rebuildAll: true))
        #expect(!workspace.unconvertedPrograms.contains(id))
        workspace.setStructuredText("Y0 := X0 AND;", programID: id)
        #expect(!workspace.convert(rebuildAll: false))
        #expect(workspace.outputMessages.contains { $0.result == .error && $0.category == "ST" })
        #expect(!workspace.structuredTextMarks(programID: id).isEmpty)
    }
}

@MainActor
struct MelsecWorkspaceOnlineTests {
    private func runningWorkspace(_ inputs: [String]) throws -> MelsecWorkspace {
        let workspace = MelsecWorkspace(project: .newProject())
        try MelsecWorkspaceEditingTests.type(inputs, into: workspace)
        workspace.startSimulation()
        #expect(workspace.sheet == .onlineDataOperation(.startSimulation))
        workspace.executeOnlineOperation(.startSimulation)
        return workspace
    }

    @Test func startSimulationPutsTheCPUInRun() throws {
        let workspace = try runningWorkspace(["LD X0", "OUT Y0"])
        defer { workspace.stopSimulation() }
        let cpu = try #require(workspace.cpu)
        #expect(workspace.session != nil)
        #expect(cpu.mode == .run)
        #expect(workspace.simulatorSwitch == .run)
        #expect(workspace.isSimulatorPanelVisible)
        cpu.setDigitalInput(0, true)
        cpu.scan(clock: 10)
        #expect(cpu.digitalOutput(0))
    }

    @Test func startSimulationStopsOnConversionErrors() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        try MelsecWorkspaceEditingTests.type(["LD X8", "OUT Y0"], into: workspace)
        workspace.startSimulation()
        #expect(workspace.sheet == nil)
        #expect(workspace.session == nil)
        #expect(workspace.alert?.message.contains("conversion errors") == true)
    }

    @Test func shiftEnterTogglesTheBitAtTheCursor() throws {
        let workspace = try runningWorkspace(["LD M0", "OUT Y0"])
        defer { workspace.stopSimulation() }
        let id = try #require(workspace.selectedLadderID)
        let cpu = try #require(workspace.cpu)
        workspace.cursors[id] = MelsecCellRef(row: 0, column: 0)
        workspace.perform(.toggleBit)
        #expect(cpu.readOperand("M0") == .bool(false), "only in monitor mode")
        workspace.perform(.setMode(.monitor))
        #expect(workspace.mode == .monitor)
        #expect(cpu.isMonitoring)
        workspace.perform(.toggleBit)
        #expect(cpu.readOperand("M0") == .bool(true))
        cpu.scan(clock: 20)
        #expect(cpu.digitalOutput(0))
        #expect(workspace.isEnergized(programID: id, cell: MelsecCellRef(row: 0, column: 0)))
        #expect(workspace.title(for: .program(id)).hasSuffix("Monitoring (Read Only)"))
        workspace.perform(.drawHorizontalLine)
        #expect(workspace.statusMessage?.contains("read only") == true)
    }

    @Test func monitorShowsTimerValuesByTheCoil() throws {
        let workspace = try runningWorkspace(["LD X0", "OUT T0 K50", "LD SM400", "MOV K7 D5"])
        defer { workspace.stopSimulation() }
        let id = try #require(workspace.selectedLadderID)
        let cpu = try #require(workspace.cpu)
        workspace.perform(.setMode(.monitor))
        cpu.setDigitalInput(0, true)
        cpu.scan(clock: 100)
        cpu.scan(clock: 400)
        let drawing = try #require(workspace.ladderDrawing(programID: id, isFocused: false))
        #expect(drawing.coilValues[MelsecCellRef(row: 0, column: 11)] == "3")
        #expect(drawing.values["D5"] == "7")
        #expect(drawing.energized.contains(MelsecCellRef(row: 0, column: 0)))
    }

    @Test func writeToPLCWhileRunningAsksForRemoteStop() throws {
        let workspace = try runningWorkspace(["LD X0", "OUT Y0"])
        defer { workspace.stopSimulation() }
        let cpu = try #require(workspace.cpu)
        try MelsecWorkspaceEditingTests.type(["LD X1", "OUT Y1"], into: workspace)
        workspace.writeToPLC()
        #expect(workspace.sheet == .onlineDataOperation(.writeToPLC))
        workspace.executeOnlineOperation(.writeToPLC)
        let stop = try #require(workspace.alert)
        #expect(stop.action == .remoteStopAndWrite)
        workspace.answerAlert(stop, yes: true)
        #expect(cpu.mode == .stop)
        let run = try #require(workspace.alert)
        #expect(run.action == .remoteRun)
        workspace.answerAlert(run, yes: true)
        #expect(cpu.mode == .run)
        cpu.setDigitalInput(1, true)
        cpu.scan(clock: 10)
        #expect(cpu.digitalOutput(1), "the new rung was written")
    }

    @Test func operationErrorsLatchUntilReset() throws {
        let workspace = try runningWorkspace(["LD X0", "/ D0 D1 D2"])
        defer { workspace.stopSimulation() }
        let cpu = try #require(workspace.cpu)
        cpu.setDigitalInput(0, true)
        cpu.scan(clock: 10)
        #expect(cpu.mode == .stop)
        #expect(cpu.hasError)
        workspace.setSwitch(.stop)
        workspace.setSwitch(.run)
        #expect(cpu.mode == .stop, "RUN is refused until RESET")
        cpu.setDigitalInput(0, false)
        workspace.resetCPU()
        #expect(!cpu.hasError)
        #expect(cpu.mode == .run)
    }

    @Test func modifyValueAndWatch() throws {
        let workspace = try runningWorkspace(["LD X0", "OUT Y0"])
        defer { workspace.stopSimulation() }
        let cpu = try #require(workspace.cpu)
        #expect(workspace.modifyValue(device: "D0", type: .word, value: "K10") == nil)
        #expect(cpu.readOperand("D0") == .int(10))
        #expect(workspace.modifyValue(device: "D2", type: .doubleWord, value: "100000") == nil)
        #expect(try cpu.memory.readInteger(.device(MelsecDevice(.dataRegister, 2), index: nil), width: .doubleWord) == 100_000)
        #expect(workspace.modifyValue(device: "M0", type: .bit, value: "TRUE") == nil)
        #expect(cpu.readOperand("M0") == .bool(true))
        #expect(workspace.modifyValue(device: "D8000", type: .word, value: "1") != nil)

        workspace.addWatchEntry("M0", list: 0)
        workspace.addWatchEntry("D0", list: 0)
        #expect(workspace.project.watchLists[0].entries == ["M0", "D0"])
        #expect(workspace.watchRow("M0", format: .decimal, list: 0).value == "")
        workspace.watching[0] = true
        #expect(workspace.watchRow("M0", format: .decimal, list: 0).value == "TRUE")
        #expect(workspace.watchRow("M0", format: .decimal, list: 0).type == "Bit")
        #expect(workspace.watchRow("D0", format: .hexadecimal, list: 0).value == "000AH")
        workspace.watchSelection[0] = "M0"
        workspace.watchSet(list: 0, bit: nil)
        #expect(cpu.readOperand("M0") == .bool(false))
    }

    @Test func stopSimulationClearsTheSession() throws {
        let workspace = try runningWorkspace(["LD X0", "OUT Y0"])
        workspace.perform(.setMode(.monitor))
        workspace.stopSimulation()
        #expect(workspace.session == nil)
        #expect(workspace.cpu == nil)
        #expect(workspace.mode == .write)
        workspace.perform(.setMode(.monitor))
        #expect(workspace.mode == .write)
        #expect(workspace.alert != nil)
    }
}
