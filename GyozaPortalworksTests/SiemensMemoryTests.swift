import Foundation
import Testing
@testable import GyozaPortalworks

struct SiemensAddressTests {
    @Test func parsesAndFormatsAbsoluteOperands() throws {
        let bit = try S7Address.parse("%I0.0")
        #expect(bit.area == .input && bit.width == .bit && bit.byteOffset == 0 && bit.bitNumber == 0)
        #expect(try S7Address.parse("i1.5").description == "%I1.5")
        #expect(try S7Address.parse("%IB0").description == "%IB0")
        #expect(try S7Address.parse("%IW64").width == .word)
        #expect(try S7Address.parse("%QD4").width == .doubleWord)
        #expect(try S7Address.parse("MW10").description == "%MW10")
        let peripheral = try S7Address.parse("%QW80:P")
        #expect(peripheral.isPeripheral && peripheral.area == .output && peripheral.byteOffset == 80)
        #expect(peripheral.description == "%QW80:P")
        #expect(S7Address.looksLikeAddress("I0.0"))
        #expect(!S7Address.looksLikeAddress("Motor"))
    }

    @Test func rejectsMalformedAddressesWithPreciseMessages() {
        func message(_ text: String) -> String {
            do {
                _ = try S7Address.parse(text)
                return ""
            } catch let error as ResolveError {
                return error.message
            } catch {
                return "\(error)"
            }
        }
        #expect(message("%I0.8").contains("bit numbers range from 0 to 7"))
        #expect(message("%DB1.DBX0.0") == S7Messages.absoluteDataBlockAccess)
        #expect(message("%L0.0") == S7Messages.absoluteLocalAccess)
        #expect(message("%IW1023").contains("0 to 1022"))
        #expect(message("%M8192.0").contains("out of range"))
        #expect(message("%M10").contains("needs a bit number"))
        #expect(message("%MB1.2").contains("only bit addresses"))
        #expect(message("%M0.0:P").contains(":P"))
        #expect(message("%E0.0").contains("German"))
        #expect(message("%X0.0") == S7Messages.notAnAddress("%X0.0"))
    }

    @Test func typesFitTheirAddressWidth() throws {
        #expect(try S7Address.parse("%MW10").accepts(.int))
        #expect(!(try S7Address.parse("%MB10").accepts(.int)))
        #expect(try S7Address.parse("%MD20").accepts(.real))
        #expect(try S7Address.parse("%M30.0").accepts(.lreal))
        #expect(!(try S7Address.parse("%M30.1").accepts(.lreal)))
        #expect(try S7Address.parse("%I0.0").accepts(.bool))
    }

    @Test func memoryIsBigEndianAndOverlaps() throws {
        let memory = S7Memory()
        memory.write(try S7Address.parse("%MW10"), .int(0x0102))
        #expect(memory.read(try S7Address.parse("%MB10")) == .int(1))
        #expect(memory.read(try S7Address.parse("%MB11")) == .int(2))
        #expect(memory.read(try S7Address.parse("%M11.1")) == .bool(true))
        #expect(memory.read(try S7Address.parse("%M10.0")) == .bool(true))
        #expect(memory.read(try S7Address.parse("%M11.0")) == .bool(false))
        memory.write(try S7Address.parse("%M10.7"), .bool(true))
        #expect(memory.read(try S7Address.parse("%MW10")) == .int(0x8102))
        #expect(memory.read(try S7Address.parse("%MW10"), as: .int) == .int(Int64(Int16(bitPattern: 0x8102))))

        let real = try S7Address.parse("%MD20")
        memory.write(real, as: .real, .real(1.5))
        #expect(memory.read(real, as: .real) == .real(1.5))
        #expect(memory.read(real) == .int(0x3FC0_0000))
    }

    @Test func clockMemoryFollowsTheCPUClock() throws {
        let memory = S7Memory()
        let oneHertz = try S7Address.parse("%M0.5")
        memory.updateClockMemory(byte: 0, clock: 250)
        #expect(memory.read(oneHertz) == .bool(false))
        memory.updateClockMemory(byte: 0, clock: 750)
        #expect(memory.read(oneHertz) == .bool(true))
        memory.updateClockMemory(byte: 0, clock: 1_050)
        #expect(memory.read(try S7Address.parse("%M0.0")) == .bool(true))
        memory.updateSystemMemory(byte: 1, firstScan: true, diagnosticStatusChanged: false)
        #expect(memory.read(try S7Address.parse("%MB1")) == .int(0b0000_0101))
        memory.updateSystemMemory(byte: 1, firstScan: false, diagnosticStatusChanged: false)
        #expect(memory.read(try S7Address.parse("%M1.0")) == .bool(false))
        #expect(memory.read(try S7Address.parse("%M1.2")) == .bool(true))
        #expect(memory.read(try S7Address.parse("%M1.3")) == .bool(false))
    }
}

struct SiemensTagTests {
    @Test func newProjectMatchesTIAsTemplate() throws {
        let project = SiemensProject.newProject()
        #expect(project.name == "Project1")
        #expect(project.device.name == "PLC_1")
        #expect(project.device.cpuType == "CPU 1214C DC/DC/DC")
        let main = try #require(project.blocks.first)
        #expect(main.displayName == "Main [OB1]")
        #expect(main.title == "Main Program Sweep (Cycle)")
        #expect(main.language == .lad)
        #expect(main.networks.count == 1)
        #expect(main.interface.input.map(\.name) == ["Initial_Call", "Remanence"])
        let tags = Dictionary(uniqueKeysWithValues: project.allTags.map { ($0.tag.name, $0.tag.address) })
        #expect(tags["FirstScan"] == "%M1.0")
        #expect(tags["AlwaysTRUE"] == "%M1.2")
        #expect(tags["Clock_1Hz"] == "%M0.5")
        #expect(tags["Clock_10Hz"] == "%M0.0")
        #expect(project.tagIssues.isEmpty)
        #expect(project.tagTables.first?.name == "Default tag table")
    }

    @Test func duplicateNamesAreRenamedAndFlagged() {
        var project = SiemensProject.newProject()
        let first = project.addTag(SiemensTag("Motor", .bool, "%Q0.0"))
        let second = project.addTag(SiemensTag("Motor", .bool, "%Q0.1"))
        let third = project.addTag(SiemensTag("motor", .bool, "%Q0.2"))
        #expect(first.name == "Motor")
        #expect(second.name == "Motor(1)")
        #expect(third.name == "motor(2)")
        project.rename(row: third.id, to: "Motor")
        #expect(project.allTags.contains { $0.tag.name == "Motor(2)" })
        // A decoded file can still contain duplicates: both rows are marked.
        project.tagTables[0].tags.append(SiemensTag("Motor", .bool, "%Q0.3"))
        let issues = project.tagIssues.filter { $0.column == .name }
        #expect(issues.count == 2)
        #expect(issues.allSatisfy { $0.message == S7Messages.nameUsedTwice("Motor") })
    }

    @Test func addressesAreValidatedAgainstTypeAndEachOther() {
        var project = SiemensProject.newProject()
        let a = project.addTag(SiemensTag("A", .bool, "q0.0"))
        let b = project.addTag(SiemensTag("B", .bool, "%Q0.0"))
        let wrong = project.addTag(SiemensTag("Level", .int, "%MB20"))
        let quoted = project.addTag(SiemensTag("Bad\"Name", .bool, "%M20.0"))
        let peripheral = project.addTag(SiemensTag("Direct", .bool, "%I0.0:P"))
        #expect(a.address == "%Q0.0")
        let issues = project.tagIssues
        let duplicates = issues.filter { $0.message == S7Messages.addressUsedTwice("%Q0.0") }.map(\.rowID)
        #expect(Set(duplicates) == [a.id, b.id])
        #expect(issues.contains { $0.rowID == wrong.id && $0.message == S7Messages.addressDoesNotFit("%MB20", "Int") })
        #expect(issues.contains { $0.rowID == quoted.id && $0.message == S7Messages.quotesInName })
        #expect(issues.contains { $0.rowID == peripheral.id && $0.message == S7Messages.peripheralInTagTable })
    }

    @Test func proposesTheNextFreeAddress() {
        let tables = [SiemensTagTable(name: "T", tags: [
            SiemensTag("S1", .bool, "%I0.7"),
            SiemensTag("Speed", .int, "%MW10"),
            SiemensTag("Taken", .int, "%MW12"),
        ])]
        #expect(SiemensTagRules.proposedAddress(for: .bool, after: tables[0].tags[0], in: tables) == "%I1.0")
        #expect(SiemensTagRules.proposedAddress(for: .int, after: tables[0].tags[1], in: tables) == "%MW14")
        #expect(SiemensTagRules.proposedAddress(for: .bool, after: nil, in: []) == "%I0.0")
        #expect(SiemensTagRules.proposedAddress(for: .real, after: nil, in: []) == "%MD0")
        var project = SiemensProject(tagTables: [SiemensTagTable(name: SiemensTagTable.defaultName)])
        let first = project.addNewTag()
        let second = project.addNewTag()
        #expect(first.name == "Tag_1" && first.address == "%I0.0")
        #expect(second.name == "Tag_2" && second.address == "%I0.1")
    }

    @Test func retainFlagMovesTheRetentiveRange() {
        var project = SiemensProject.newProject()
        let speed = project.addTag(SiemensTag("Speed", .int, "%MW10"))
        let lamp = project.addTag(SiemensTag("Lamp", .bool, "%Q0.0"))
        #expect(!project.isRetain(speed))
        project.setRetain(true, forTag: speed.id)
        #expect(project.device.retentiveMarkerBytes == 12)
        #expect(project.isRetain(speed))
        project.setRetain(true, forTag: lamp.id)
        #expect(project.device.retentiveMarkerBytes == 12)
        project.setRetain(false, forTag: speed.id)
        #expect(project.device.retentiveMarkerBytes == 10)
    }

    @Test func systemAndClockMemoryTagsFollowTheSettings() {
        var project = SiemensProject.newProject()
        project.setClockMemory(enabled: true, byte: 100)
        #expect(project.allTags.first { $0.tag.name == "Clock_1Hz" }?.tag.address == "%M100.5")
        project.setSystemMemory(enabled: false)
        #expect(!project.allTags.contains { $0.tag.name == "FirstScan" })
    }

    @Test func projectsRoundTripAndOldFilesDecode() throws {
        var project = SiemensProject.newProject()
        project.addTag(SiemensTag("Start", .bool, "%I0.0"))
        project.blocks[0].networks = [LAD.net(LAD.no("\"Start\""), LAD.coil("%Q0.0"))]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(SiemensProject.self, from: data)
        #expect(decoded == project)
        let old = try JSONDecoder().decode(SiemensProject.self, from: Data(#"{"name":"Old","blocks":[{"name":"Main","kind":"OB","number":1}]}"#.utf8))
        #expect(old.name == "Old")
        #expect(old.device.name == "PLC_1")
        #expect(old.blocks.first?.language == .lad)
        #expect(old.tagTables.first?.name == "Default tag table")
    }
}

struct SiemensTypeTests {
    @Test func parsesDataTypeColumn() throws {
        #expect(try SiemensTypeParser.parse("Int") == .elementary(.int))
        #expect(try SiemensTypeParser.parse("Array[0..9] of Int") == .array(lower: 0, upper: 9, element: .elementary(.int)))
        #expect(try SiemensTypeParser.parse("Array [1..3] of \"Motor\"") == .array(lower: 1, upper: 3, element: .named("Motor")))
        #expect(try SiemensTypeParser.parse("Struct") == .structure)
        #expect(try SiemensTypeParser.parse("\"UDT_Name\"") == .named("UDT_Name"))
        #expect(try SiemensTypeParser.parse("ton_time") == .system("TON_TIME"))
        #expect(try SiemensTypeParser.parse("TON") == .system("TON_TIME"))
        #expect(throws: ResolveError.self) { try SiemensTypeParser.parse("Array[0..1, 0..1] of Int") }
        #expect(throws: ResolveError.self) { try SiemensTypeParser.parse("String") }
        #expect(throws: ResolveError.self) { try SiemensTypeParser.parse("Array[5..1] of Int") }
    }

    @Test func resolvesUDTsInstancesAndStartValues() throws {
        let udt = SiemensDataType(name: "Motor", members: [
            SiemensVariable("Speed", "Int", startValue: "100"),
            SiemensVariable("On", "Bool"),
        ])
        var fb = SiemensBlock(name: "Conveyor", kind: .functionBlock, number: 1)
        fb.interface.input = [SiemensVariable("Start", "Bool")]
        fb.interface.staticVariables = [SiemensVariable("drive", "\"Motor\""), SiemensVariable("timer", "TON_TIME")]
        fb.interface.temp = [SiemensVariable("scratch", "Int")]
        let environment = SiemensTypeEnvironment(dataTypes: [udt], blocks: [fb])
        let type = try environment.type(of: SiemensVariable("m", "\"Motor\""))
        let node = DataNode(type: type)
        #expect(node.member("Speed")?.read() == .int(100))
        let conveyor = try #require(try environment.functionBlockType(named: "Conveyor"))
        #expect(conveyor.members.map(\.name) == ["Start", "drive", "timer"])
        let handle = BlockHandle(name: fb.name, kind: .functionBlock, number: 1, members: environment.interfaceMembers(of: fb).members)
        #expect(handle.functionBlockType == conveyor)

        let recursive = SiemensDataType(name: "Loop", members: [SiemensVariable("inner", "\"Loop\"")])
        let bad = SiemensTypeEnvironment(dataTypes: [recursive], blocks: [])
        #expect(throws: ResolveError.self) { try bad.dataType(named: "Loop") }
        #expect(throws: ResolveError.self) { try environment.startValue("abc", for: .elementary(.int)) }
    }

    @Test func counterInstancesAreRetentiveAndNamedLikeTIA() {
        var project = SiemensProject.newProject()
        let names = [
            project.createInstanceDataBlock(for: .onDelayTimer),
            project.createInstanceDataBlock(for: .pulseTimer),
            project.createInstanceDataBlock(for: .countUp),
            project.createInstanceDataBlock(for: .risingEdgeTrigger),
        ]
        #expect(names == ["\"IEC_Timer_0_DB\"", "\"IEC_Timer_0_DB_1\"", "\"IEC_Counter_0_DB\"", "\"R_TRIG_DB\""])
        #expect(project.dataBlock(named: "IEC_Counter_0_DB")?.isRetain == true)
        #expect(project.dataBlock(named: "IEC_Timer_0_DB")?.instanceOf == "IEC_TIMER")
        #expect(project.dataBlock(named: "IEC_Timer_0_DB")?.isProgramResource == true)
        #expect(project.dataBlocks.map(\.number) == [1, 2, 3, 4])
        let block = project.addBlock(.function)
        let second = project.addBlock(.function)
        #expect(block.name == "Block_1" && block.number == 1)
        #expect(second.name == "Block_2" && second.number == 2)
        let dataBlock = project.addGlobalDataBlock()
        #expect(dataBlock.name == "Data_block_1")
        let startup = project.addBlock(.organizationBlock, event: .startup)
        #expect(startup.displayName == "Startup [OB100]")
        let extraCycle = project.addBlock(.organizationBlock)
        #expect(extraCycle.number == 123)

        var fb = SiemensBlock(name: "Line", kind: .functionBlock, number: 1)
        let multiInstance = fb.addMultiInstance(for: .onDelayTimer)
        #expect(multiInstance == "#IEC_Timer_0_Instance")
        #expect(fb.interface.staticVariables.first?.dataType == "TON_TIME")
    }
}
