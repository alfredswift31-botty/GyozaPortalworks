import Foundation
import SwiftUI
import Testing
@testable import GyozaPortalworks

/// Drives the TIA Portal workspace the way the UI does.
@MainActor
struct SiemensWorkspaceTests {
    private func makeWorkspace(tags: [SiemensTag] = []) -> SiemensWorkspace {
        var project = SiemensProject.newProject()
        for tag in tags { project.addTag(tag) }
        let workspace = SiemensWorkspace(project: project, store: nil)
        workspace.startsSessionTimer = false
        return workspace
    }

    private var main: (SiemensWorkspace) -> SiemensBlock? {
        { workspace in workspace.project.blocks.first { $0.name == "Main" } }
    }

    /// Inserts an element at the cursor and types its operand, as a user would.
    private func place(_ command: S7EditorCommand, _ operand: String?, in workspace: SiemensWorkspace) throws {
        workspace.perform(command)
        guard let operand else { return }
        let target = try #require(workspace.editingOperand)
        let block = try #require(workspace.currentBlock)
        workspace.commitOperand(operand, target: target, inBlock: block.id)
    }

    private func pin(_ name: String, _ text: String, in workspace: SiemensWorkspace) throws {
        let block = try #require(workspace.currentBlock)
        guard case let .element(network, element)? = workspace.selections[block.id] else {
            Issue.record("a box should be selected")
            return
        }
        workspace.commitOperand(text, target: S7OperandTarget(network: network, element: element, field: .pin(name)), inBlock: block.id)
    }

    // MARK: Keys

    @Test func tiaKeysMapToEditorCommands() {
        func command(_ number: Int, _ modifiers: EventModifiers) -> S7EditorCommand? {
            S7LadderEditing.command(for: VendorShortcut.function(number, modifiers) {}.key, modifiers: modifiers)
        }
        #expect(command(2, .shift) == .insertContact(.normallyOpen))
        #expect(command(3, .shift) == .insertContact(.normallyClosed))
        #expect(command(5, .shift) == .insertEmptyBox)
        #expect(command(7, .shift) == .insertCoil(.assign))
        #expect(command(8, .shift) == .openBranch)
        #expect(command(9, .shift) == .closeBranch)
        #expect(command(2, []) == .editOperand)
        #expect(S7LadderEditing.command(for: "r", modifiers: .control) == .insertNetwork)
        #expect(S7LadderEditing.command(for: .return, modifiers: []) == .editOperand)
        #expect(S7LadderEditing.command(for: .delete, modifiers: []) == .delete)
        #expect(S7LadderEditing.command(for: .leftArrow, modifiers: []) == .moveLeft)
        #expect(S7LadderEditing.command(for: "a", modifiers: []) == nil)
    }

    // MARK: Editing

    @Test func editingCommandsBuildNetworksAndUndo() throws {
        let workspace = makeWorkspace()
        let block = try #require(workspace.currentBlock)
        try place(.insertContact(.normallyOpen), "%I0.0", in: workspace)
        try place(.insertCoil(.assign), "%Q0.0", in: workspace)
        var rung = try #require(main(workspace)?.networks.first?.rungs.first)
        #expect(rung.items.count == 2)
        let coil = rung.items[1].id
        // A contact inserted while the coil is selected goes in front of it.
        workspace.select(.element(network: block.networks[0].id, id: coil), inBlock: block.id)
        try place(.insertContact(.normallyClosed), "%I0.1", in: workspace)
        rung = try #require(main(workspace)?.networks.first?.rungs.first)
        #expect(rung.items.count == 3)
        guard case let .contact(stop) = rung.items[1] else {
            Issue.record("the NC contact should sit before the coil")
            return
        }
        #expect(stop.kind == .normallyClosed)
        #expect(stop.operand == "\"Tag_3\"")
        // %I0.0 got a tag of its own.
        #expect(workspace.project.allTags.contains { $0.tag.name == "Tag_1" && $0.tag.address == "%I0.0" })

        workspace.undo()
        workspace.undo()
        #expect(main(workspace)?.networks.first?.rungs.first?.items.count == 2)
        workspace.redo()
        #expect(main(workspace)?.networks.first?.rungs.first?.items.count == 3)

        workspace.perform(.insertNetwork)
        #expect(main(workspace)?.networks.count == 2)
        let second = try #require(main(workspace)?.networks.last)
        workspace.select(.network(second.id), inBlock: block.id)
        workspace.perform(.delete)
        #expect(main(workspace)?.networks.count == 1)
    }

    @Test func operandEntryUsesTagsAndCreatesThem() {
        var project = SiemensProject.newProject()
        project.addTag(SiemensTag("Start", .bool, "%I0.0"))
        var block = project.blocks[0]
        block.interface.temp = [SiemensVariable("scratch", "Int")]
        #expect(SiemensOperandEntry.resolve("%I0.0", block: block, project: &project) == "\"Start\"")
        #expect(SiemensOperandEntry.resolve("i0.0", block: block, project: &project) == "\"Start\"")
        #expect(SiemensOperandEntry.resolve("start", block: block, project: &project) == "\"Start\"")
        #expect(SiemensOperandEntry.resolve("scratch", block: block, project: &project) == "#scratch")
        #expect(SiemensOperandEntry.resolve("T#5S", block: block, project: &project) == "T#5S")
        #expect(SiemensOperandEntry.resolve("%MW20", block: block, project: &project) == "\"Tag_1\"")
        #expect(project.allTags.contains { $0.tag.name == "Tag_1" && $0.tag.dataType == .word && $0.tag.address == "%MW20" })
        #expect(SiemensOperandEntry.resolve("%I0.8", block: block, project: &project) == "%I0.8")
        #expect(SiemensOperandEntry.suggestions(for: "st", block: block, project: project).first == "\"Start\"")
        #expect(SiemensOperandEntry.suggestions(for: "#scr", block: block, project: project) == ["#scratch"])
    }

    @Test func addNewBlockDefaults() throws {
        let project = SiemensProject.newProject()
        let function = SiemensNewBlockRequest.defaults(.function, in: project)
        #expect(function.name == "Block_1" && function.number == 1 && function.language == .lad && function.isNumberAutomatic)
        let organization = SiemensNewBlockRequest.defaults(.organizationBlock, in: project)
        #expect(organization.number == 123)
        let data = SiemensNewBlockRequest.defaults(.dataBlock, in: project)
        #expect(data.name == "Data_block_1" && data.number == 1)
        #expect(SiemensNewBlockRequest.dataBlockTypes(in: project).first == "Global DB")

        let workspace = makeWorkspace()
        var request = SiemensNewBlockRequest.defaults(.functionBlock, in: workspace.project)
        request.name = "Conveyor"
        request.language = .scl
        workspace.addNewBlock(request)
        let conveyor = try #require(workspace.project.block(named: "Conveyor"))
        #expect(conveyor.displayName == "Conveyor [FB1]")
        #expect(conveyor.language == .scl)
        #expect(workspace.selectedTab == .block(conveyor.id))
        var duplicate = SiemensNewBlockRequest.defaults(.function, in: workspace.project)
        duplicate.name = "conveyor"
        #expect(duplicate.problem(in: workspace.project) == S7Messages.nameUsedTwice("conveyor"))
        var instance = SiemensNewBlockRequest.defaults(.dataBlock, in: workspace.project)
        instance.dataBlockType = "Conveyor"
        workspace.addNewBlock(instance)
        #expect(workspace.project.dataBlock(named: "Data_block_1")?.kind == .instance)
    }

    @Test func callOptionsNameInstancesLikeTIA() throws {
        let workspace = makeWorkspace()
        try place(.insertContact(.normallyOpen), "%I0.0", in: workspace)
        workspace.perform(.insertBox(.onDelayTimer))
        let first = try #require(workspace.callOptions)
        #expect(first.name == "IEC_Timer_0_DB")
        #expect(first.mode == .singleInstance && !first.allowsMultiInstance)
        workspace.confirmCallOptions(first)
        #expect(workspace.callOptions == nil)
        #expect(workspace.project.dataBlock(named: "IEC_Timer_0_DB")?.instanceOf == "IEC_TIMER")
        workspace.perform(.insertBox(.onDelayTimer))
        let second = try #require(workspace.callOptions)
        #expect(second.name == "IEC_Timer_0_DB_1")
        workspace.cancelCallOptions()
        workspace.perform(.insertBox(.countUp))
        #expect(workspace.callOptions?.name == "IEC_Counter_0_DB")

        var fb = SiemensBlock(name: "Line", kind: .functionBlock, number: 1)
        fb.networks = [S7Network()]
        let box = S7Box(.onDelayTimer)
        var options = try #require(SiemensCallOptions.proposal(for: box, in: fb, network: fb.networks[0].id, project: workspace.project))
        #expect(options.allowsMultiInstance)
        options.switchMode(to: .multiInstance, block: fb, project: workspace.project)
        #expect(options.name == "IEC_Timer_0_Instance")
    }

    // MARK: Simulation

    @Test func compileDownloadAndRunLikeTIA() throws {
        let workspace = makeWorkspace()
        try place(.insertContact(.normallyOpen), "%I0.0", in: workspace)
        try place(.insertCoil(.assign), "%Q0.0", in: workspace)
        let result = workspace.compile()
        #expect(result.summary == "Compiling finished (errors: 0; warnings: 0)")
        #expect(workspace.inspectorTab == .info && workspace.infoTab == .compile)

        workspace.startSimulation()
        #expect(workspace.isPLCSIMVisible)
        #expect(workspace.loadStep == .extendedDownload(searched: false))
        workspace.loadFromExtendedDownload()
        #expect(workspace.loadStep == .extendedDownload(searched: false))
        workspace.searchDevices()
        workspace.loadFromExtendedDownload()
        #expect(workspace.loadStep == .loadPreview(stopModules: false))
        workspace.confirmLoadPreview()
        #expect(workspace.loadStep == .loadResults(startAll: true))
        workspace.finishLoad(startAll: true)
        let cpu = try #require(workspace.cpu)
        #expect(cpu.mode == .run)
        cpu.setDigitalInput(0, true)
        cpu.scan(clock: 10)
        cpu.scan(clock: 20)
        #expect(cpu.digitalOutput(0))

        let mainID = try #require(main(workspace)?.id)
        workspace.toggleMonitoring(block: mainID)
        #expect(!workspace.isMonitoring(mainID))
        workspace.goOnline()
        #expect(workspace.isOnline)
        #expect(workspace.onlineStatus(ofBlock: mainID) == .identical)
        workspace.toggleMonitoring(block: mainID)
        #expect(workspace.isMonitoring(mainID))
        cpu.scan(clock: 30)
        #expect(workspace.monitor(ofBlock: mainID) != nil)

        // Changing the block offline stops monitoring until the next download.
        try place(.insertCoil(.assign), "%Q0.1", in: workspace)
        #expect(workspace.onlineStatus(ofBlock: mainID) == .different)
        #expect(!workspace.isMonitoring(mainID))
        #expect(workspace.monitoringProblem(ofBlock: mainID)?.contains("different") == true)

        workspace.downloadToDevice()
        #expect(workspace.loadStep == .loadPreview(stopModules: true))
        workspace.confirmLoadPreview()
        #expect(cpu.mode == .stop)
        workspace.finishLoad(startAll: true)
        #expect(cpu.mode == .run)
        cpu.scan(clock: 40)
        cpu.scan(clock: 50)
        #expect(cpu.digitalOutput(1))
        #expect(workspace.onlineStatus(ofBlock: mainID) == .identical)

        workspace.requestStopCPU()
        #expect(workspace.confirmation == .stopCPU)
        workspace.confirm(.stopCPU)
        #expect(cpu.mode == .stop)
        workspace.stopSimulation()
        #expect(workspace.session == nil && !workspace.isOnline)
    }

    @Test func simulationRefusesAProgramWithErrors() {
        let workspace = makeWorkspace()
        workspace.perform(.insertContact(.normallyOpen))
        workspace.startSimulation()
        #expect(workspace.session == nil)
        #expect(workspace.loadStep == nil)
        #expect(workspace.lastMessage.contains("errors: 2"))
    }

    // MARK: Exercises built through the editor

    private func check(_ id: String, _ workspace: SiemensWorkspace) throws {
        let exercise = try #require(ExerciseLibrary.exercises(for: .tiaPortal).first { $0.id == id })
        switch workspace.makeCheckCPU() {
        case let .success(cpu):
            let report = ExerciseChecker.run(exercise, on: cpu)
            #expect(report.passed, "\(id): \(report.firstFailure?.text ?? "no checks ran")")
        case let .failure(error):
            Issue.record("\(id) doesn't compile: \(error.message) \(error.details)")
        }
    }

    @Test func sealInBuiltWithTheEditor() throws {
        let workspace = makeWorkspace(tags: [
            SiemensTag("S1_Start", .bool, "%I0.0"), SiemensTag("S2_Stop", .bool, "%I0.1"),
            SiemensTag("K1_Motor", .bool, "%Q0.0"), SiemensTag("H1_Running", .bool, "%Q0.1"),
        ])
        try place(.insertContact(.normallyOpen), "S1_Start", in: workspace)
        try place(.insertContact(.normallyOpen), "S2_Stop", in: workspace)
        try place(.insertCoil(.assign), "K1_Motor", in: workspace)
        try place(.insertCoil(.assign), "H1_Running", in: workspace)
        let block = try #require(workspace.currentBlock)
        let network = block.networks[0]
        workspace.select(.rail(network: network.id, path: network.rungs[0].id), inBlock: block.id)
        workspace.perform(.openBranch)
        try place(.insertContact(.normallyOpen), "K1_Motor", in: workspace)
        workspace.perform(.closeBranch)
        guard case .parallel? = workspace.currentBlock?.networks[0].rungs[0].items.first else {
            Issue.record("the seal-in branch should be closed around S1_Start")
            return
        }
        try check("tia-01-seal-in", workspace)
    }

    @Test func onDelayBuiltWithTheEditor() throws {
        let workspace = makeWorkspace(tags: [SiemensTag("S1_Switch", .bool, "%I0.0"), SiemensTag("H1_Lamp", .bool, "%Q0.0")])
        try place(.insertContact(.normallyOpen), "S1_Switch", in: workspace)
        workspace.perform(.insertBox(.onDelayTimer))
        workspace.confirmCallOptions(try #require(workspace.callOptions))
        try pin("PT", "T#5S", in: workspace)
        try place(.insertCoil(.assign), "H1_Lamp", in: workspace)
        try check("tia-03-ton", workspace)
    }

    @Test func batchCounterBuiltWithTheEditor() throws {
        let workspace = makeWorkspace(tags: [
            SiemensTag("B1_Part", .bool, "%I0.0"), SiemensTag("S1_Reset", .bool, "%I0.1"),
            SiemensTag("H1_BatchComplete", .bool, "%Q0.0"),
        ])
        try place(.insertContact(.normallyOpen), "B1_Part", in: workspace)
        workspace.perform(.insertEmptyBox)
        let block = try #require(workspace.currentBlock)
        guard case let .element(network, box)? = workspace.selections[block.id] else {
            Issue.record("the empty box should be selected")
            return
        }
        workspace.commitOperand("CTU", target: S7OperandTarget(network: network, element: box, field: .slot(.operand)), inBlock: block.id)
        workspace.confirmCallOptions(try #require(workspace.callOptions))
        #expect(workspace.project.dataBlock(named: "IEC_Counter_0_DB")?.isRetain == true)
        try pin("R", "S1_Reset", in: workspace)
        try pin("PV", "5", in: workspace)
        try place(.insertCoil(.assign), "H1_BatchComplete", in: workspace)
        try check("tia-06-batch-counter", workspace)
    }

    @Test func checkCPUReportsCompileErrors() {
        let workspace = makeWorkspace()
        workspace.perform(.insertContact(.normallyOpen))
        guard case let .failure(error) = workspace.makeCheckCPU() else {
            Issue.record("an unfinished network must not compile")
            return
        }
        #expect(error.message.hasPrefix("Your program doesn't compile yet"))
        #expect(!error.details.isEmpty && error.details.count <= 5)
        #expect(workspace.session == nil)
    }

    @Test func treeCommandsAreUndoable() throws {
        let workspace = makeWorkspace()
        workspace.addWatchTable()
        let table = try #require(workspace.project.watchTables.first)
        #expect(table.name == "Watch table_1")
        workspace.addWatchRow("%MW10", to: table.id)
        workspace.addWatchRow("// motor", to: table.id)
        #expect(workspace.project.watchTables[0].rows.count == 2)
        #expect(workspace.project.watchTables[0].rows[1].isCommentLine)
        workspace.rename(.watchTable(table.id), to: "Commissioning")
        #expect(workspace.project.watchTables[0].name == "Commissioning")
        workspace.delete(.watchTable(table.id))
        #expect(workspace.project.watchTables.isEmpty)
        #expect(!workspace.openTabs.contains(.watchTable(table.id)))
        workspace.undo()
        #expect(workspace.project.watchTables.first?.name == "Commissioning")
        workspace.addTagTable()
        #expect(workspace.project.tagTables.last?.name == "Tag table_1")
        let tagTable = try #require(workspace.project.tagTables.first)
        workspace.addTag(toTable: tagTable.id)
        let added = try #require(workspace.project.tagTables[0].tags.last)
        workspace.updateTag(added.id) { tag in tag.name = "Start" }
        workspace.updateTag(added.id) { tag in tag.address = "q0.0" }
        #expect(workspace.project.tagTables[0].tags.last?.address == "%Q0.0")
    }
}
