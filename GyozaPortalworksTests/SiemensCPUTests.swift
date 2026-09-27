import Foundation
import Testing
@testable import GyozaPortalworks

struct SiemensCompileTests {
    private func compile(_ networks: [S7Network], tags: [SiemensTag] = [],
                         configure: (inout SiemensProject) -> Void = { _ in }) -> SiemensCompileResult {
        SiemensBench(networks, tags: tags, configure: configure).compile()
    }

    @Test func aGoodProgramCompilesLikeTIA() throws {
        let result = compile([LAD.net(LAD.no("%I0.0"), LAD.coil("%Q0.0"))])
        #expect(result.succeeded)
        #expect(result.image != nil)
        #expect(result.summary == "Compiling finished (errors: 0; warnings: 0)")
        #expect(result.messages.contains { $0.path == "Main (OB1)" && $0.text == "Block was successfully compiled." })
        #expect(result.messages.last?.text == "Compiling finished (errors: 0; warnings: 0)")
        #expect(result.messages.first?.path == "PLC_1")
    }

    @Test func operandErrorsUseTIAsWording() {
        let speed = SiemensTag("Speed", .int, "%MW20")
        let cases: [(S7Network, String)] = [
            (LAD.net(LAD.no(""), LAD.coil("%Q0.0")), S7Messages.operandMissing),
            (LAD.net(LAD.no("\"Nope\""), LAD.coil("%Q0.0")), "Tag \"Nope\" not defined."),
            (LAD.net(LAD.no("#x"), LAD.coil("%Q0.0")), "Tag #x not defined."),
            (LAD.net(LAD.no("\"Data\".b"), LAD.coil("%Q0.0")), "Tag \"Data\".b not defined."),
            (LAD.net(LAD.no("%MW10"), LAD.coil("%Q0.0")), "Data type Word is not permitted here."),
            (LAD.net(LAD.no("%I0.0"), LAD.coil("%I0.0:P")), S7Messages.readOnly),
            (LAD.net(LAD.no("TRUE"), LAD.coil("%Q0.0")), S7Messages.constantAtContact),
            (LAD.net(LAD.no("%I0.0"), LAD.coil("TRUE")), S7Messages.constantNotWritable),
            (LAD.net(LAD.no("%Q0.0:P"), LAD.coil("%Q0.1")), S7Messages.peripheralOutputRead),
            (LAD.net(LAD.no("%DB1.DBX0.0"), LAD.coil("%Q0.1")), S7Messages.absoluteDataBlockAccess),
            (LAD.net(LAD.cmp("1", .equal, "2"), LAD.coil("%Q0.0")), S7Messages.selectDataType),
            (LAD.net(LAD.no("%I0.0"), LAD.box(.onDelayTimer, instance: "\"IEC_Timer_0_DB\"", ["PT": "5"]), LAD.coil("%Q0.0")),
             S7Messages.invalidConstant("5", "Time")),
            (LAD.net(LAD.no("%I0.0"), LAD.box(.onDelayTimer, ["PT": "T#1S"]), LAD.coil("%Q0.0")), S7Messages.missingInstanceDB),
            (LAD.net(LAD.box(.empty)), S7Messages.selectInstruction),
            (LAD.net(LAD.box(.add, type: .int, ["IN1": "\"Speed\"", "IN2": "1", "OUT": "%Q0.0"])), "Data type Bool is not permitted here."),
        ]
        for (network, message) in cases {
            let result = compile([network], tags: [speed]) { project in
                project.dataBlocks.append(SiemensDataBlock(name: "Data", number: 1, members: [SiemensVariable("a", "Bool")]))
                project.dataBlocks.append(SiemensDataBlock(name: "IEC_Timer_0_DB", number: 2, kind: .systemInstance, instanceOf: "IEC_TIMER"))
            }
            #expect(result.has(message), "expected \"\(message)\", got \(result.messageTexts)")
            #expect(result.image == nil)
            #expect(result.diagnostics.first { $0.message == message }?.block == "Main [OB1]")
            #expect(result.diagnostics.first { $0.message == message }?.network == 1)
        }
        let address = compile([LAD.net(LAD.no("%I0.8"), LAD.coil("%Q0.0"))])
        #expect(address.mentions("bit numbers range from 0 to 7"))
    }

    @Test func placementRulesAreChecked() {
        let cases: [(S7Network, String)] = [
            (LAD.net(LAD.no("%I0.0")), S7Messages.networkIncomplete),
            (LAD.net(LAD.cmp("\"Speed\"", .greater, "5")), S7Messages.cannotTerminate("CMP >")),
            (LAD.net(LAD.box(.onDelayTimer, instance: "\"IEC_Timer_0_DB\"", ["PT": "T#1S"]), LAD.coil("%Q0.0")),
             S7Messages.requiresPrecedingLogic),
            (LAD.net(LAD.box(.positiveEdgeBox, operand: "%M10.0"), LAD.coil("%Q0.0")), S7Messages.requiresPrecedingLogic),
            (LAD.net(LAD.coil("%Q0.0", .positiveEdge, "%M10.1")), S7Messages.requiresPrecedingLogic),
            (LAD.net(LAD.no("%I0.0"), LAD.par([LAD.no("%I0.1")], [LAD.coil("%M10.0")]), LAD.coil("%Q0.0")), S7Messages.onlyContactsInBranch),
            (LAD.net(LAD.no("%I0.0"), LAD.par([LAD.no("%I0.1")], [LAD.not()]), LAD.coil("%Q0.0")), S7Messages.onlyContactsInBranch),
            (LAD.net(LAD.par([LAD.no("%I0.0")], []), LAD.coil("%Q0.0")), S7Messages.shortCircuit),
            (LAD.net(LAD.no("%I0.0"), LAD.coil("%M10.0", .setBitField, "4"), LAD.coil("%Q0.0")), S7Messages.mustBeLast("SET_BF")),
            (LAD.net(LAD.no("%I0.0"), LAD.edge("%I0.1", memory: "#scratch"), LAD.coil("%Q0.0")),
             "The edge memory bit #scratch must be located in a data block, in the Static section of an FB or in bit memory."),
        ]
        for (network, message) in cases {
            let result = compile([network], tags: [SiemensTag("Speed", .int, "%MW20")]) { project in
                project.blocks[0].interface.temp = [SiemensVariable("scratch", "Bool")]
                project.dataBlocks.append(SiemensDataBlock(name: "IEC_Timer_0_DB", number: 1, kind: .systemInstance, instanceOf: "IEC_TIMER"))
            }
            #expect(result.has(message), "expected \"\(message)\", got \(result.messageTexts)")
        }
        // Parallel coils are fine when the branches start at the power rail.
        let railBranches = compile([LAD.net(LAD.par([LAD.no("%I0.0"), LAD.coil("%Q0.0")], [LAD.no("%I0.1"), LAD.coil("%Q0.1")]))])
        #expect(railBranches.succeeded, "\(railBranches.messageTexts)")
    }

    @Test func blockLevelErrorsAndWarnings() {
        var fc = SiemensBlock(name: "Scale", kind: .function, number: 1)
        fc.interface.input = [SiemensVariable("raw", "Int")]
        fc.networks = [LAD.net(LAD.no("%I0.0"), LAD.coil("%Q0.0"))]
        let mismatch = compile([LAD.net(LAD.call(fc, ["raw": "\"Level\""]))], tags: [SiemensTag("Level", .real, "%MD20")]) { project in
            project.blocks.append(fc)
        }
        #expect(mismatch.has(S7Messages.parameterTypeMismatch(actual: "Real", formal: "Int")))

        let missing = compile([LAD.net(LAD.call(fc))]) { project in project.blocks.append(fc) }
        #expect(missing.has(S7Messages.operandMissing))

        let scl = compile([]) { project in
            project.blocks.append(SiemensBlock(name: "Code", kind: .function, number: 2, language: .scl, source: "RETURN;"))
        }
        #expect(scl.has(S7Messages.sclNotAvailable))
        #expect(scl.diagnostics.first?.block == "Code [FC2]")

        let hardware = compile([LAD.net(LAD.no("%I4.0"), LAD.coil("%Q0.0"))])
        #expect(hardware.succeeded)
        #expect(hardware.warningCount == 1)
        #expect(hardware.has(S7Messages.ioNotConfigured))
        #expect(hardware.summary == "Compiling finished (errors: 0; warnings: 1)")

        let numbers = compile([]) { project in
            project.blocks.append(SiemensBlock(name: "A", kind: .function, number: 1))
            project.blocks.append(SiemensBlock(name: "B", kind: .function, number: 1))
            project.blocks.append(SiemensBlock(name: "C", kind: .functionBlock, number: 1, isNumberAutomatic: false))
            project.blocks.append(SiemensBlock(name: "D", kind: .functionBlock, number: 1, isNumberAutomatic: false))
        }
        #expect(numbers.project.block(named: "B")?.number == 2)
        #expect(numbers.has(S7Messages.numberUsedTwice("C [FB1]")))
    }

    @Test func unusedSystemInstanceDBsAreRemoved() throws {
        let result = compile([LAD.net(LAD.no("%I0.0"), LAD.coil("%Q0.0"))]) { project in
            _ = project.createInstanceDataBlock(for: .onDelayTimer)
            project.addGlobalDataBlock(name: "Keep")
        }
        #expect(result.succeeded)
        #expect(result.project.dataBlocks.map(\.name) == ["Keep"])
    }
}

struct SiemensResolverTests {
    @Test func resolvesEveryKindOfName() throws {
        let memory = S7Memory()
        let table = SiemensSymbolTable(memory: memory)
        table.add(SiemensTag("Motor", .bool, "%Q0.0"))
        table.add(SiemensTag("Speed", .int, "%MW10"))
        table.add(SiemensUserConstant("Max", .int, "10"))
        let data = DataNode(type: .structure(name: nil, members: [PLCMember("speed", .elementary(.int))]))
        table.addDataBlock(named: "Data", node: data)
        let helper = BlockHandle(name: "Helper", kind: .function, number: 1, members: [])
        table.add(helper)
        let block = BlockHandle(name: "Test", kind: .function, number: 2, members: [
            PLCMember("x", .elementary(.int), section: .input),
            PLCMember("Motor", .elementary(.bool), section: .temp),
        ])
        let resolver = SiemensSymbolResolver(block: block, table: table)

        guard case let .local(area, index, _)? = try resolver.resolve(.local("x")) else {
            Issue.record("#x should be local")
            return
        }
        #expect(area == .instance && index == 0)
        guard case let .global(motor)? = try resolver.resolve(.global("Motor")) else {
            Issue.record("\"Motor\" should be a tag")
            return
        }
        #expect(motor.displayName == "\"Motor\"")
        motor.place.write(.bool(true))
        #expect(memory.read(try S7Address.parse("%Q0.0")) == .bool(true))
        guard case let .global(speed)? = try resolver.resolve(.global("Speed")) else {
            Issue.record("\"Speed\" should be a tag")
            return
        }
        #expect(speed.place.elementaryType == .int)
        guard case let .constant(_, value, type)? = try resolver.resolve(.global("Max")) else {
            Issue.record("\"Max\" should be a user constant")
            return
        }
        #expect(value == .int(10) && type == .int)
        guard case let .global(db)? = try resolver.resolve(.global("Data")) else {
            Issue.record("\"Data\" should be a data block")
            return
        }
        #expect(db.place.node === data)
        guard case let .global(word)? = try resolver.resolve(.absolute("%MW10")) else {
            Issue.record("%MW10 should resolve")
            return
        }
        #expect(word.place.elementaryType == .word)
        #expect(throws: ResolveError.self) { try resolver.resolve(.absolute("%I0.8")) }
        guard case .local? = try resolver.resolve(.plain("Motor")) else {
            Issue.record("a plain name looks in the interface first")
            return
        }
        guard case .global? = try resolver.resolve(.plain("Speed")) else {
            Issue.record("then in the tags")
            return
        }
        guard case .global? = try resolver.resolve(.plain("I0.0")) else {
            Issue.record("an address without % resolves")
            return
        }
        #expect(try resolver.resolve(.plain("Nope")) == nil)
        #expect(resolver.userBlock(named: "helper") === helper)
        #expect(resolver.procedure(named: "SET") == nil)
        #expect(resolver.dialect == .siemens)
        #expect(resolver.address(of: .global("Speed"))?.address.description == "%MW10")
        let peripheral = try #require(try resolver.resolvePeripheral(.global("Motor")))
        #expect(peripheral.isWritable)
        #expect(peripheral.displayName == "\"Motor\":P")
        #expect(throws: ResolveError.self) { try resolver.resolvePeripheral(.global("Speed")) }
        #expect(throws: ResolveError.self) { try resolver.resolvePeripheral(.plain("Motor")) }
    }

    @Test func closureBodiesRunThroughTheResolver() throws {
        let memory = S7Memory()
        let table = SiemensSymbolTable(memory: memory)
        table.add(SiemensTag("Lamp", .bool, "%Q0.1"))
        table.add(SiemensTag("Count", .int, "%MW20"))
        let block = BlockHandle(name: "Code", kind: .function, number: 1, members: [PLCMember("step", .elementary(.int), section: .input)])
        let resolver = SiemensSymbolResolver(block: block, table: table)
        guard case let .global(lamp)? = try resolver.resolve(.global("Lamp")),
              case let .global(count)? = try resolver.resolve(.plain("Count")),
              case let .local(area, index, _)? = try resolver.resolve(.local("step"))
        else {
            Issue.record("names should resolve")
            return
        }
        block.body = ClosureBody { frame in
            let step = frame.node(area, index).read()
            count.place.write(PLCOperations.arithmetic(.add, count.place.read(), step, as: .int).value)
            lamp.place.write(.bool(true))
        }
        let context = ExecutionContext(dialect: .siemens, blocks: [block])
        let parameters = block.makeInstanceArea()
        parameters.member("step")?.write(.int(3))
        try context.run(block, instance: parameters)
        try context.run(block, instance: parameters)
        #expect(memory.read(try S7Address.parse("%MW20"), as: .int) == .int(6))
        #expect(memory.read(try S7Address.parse("%Q0.1")) == .bool(true))
    }
}

struct SiemensCPUTests {
    @Test func boardMapsToTheCPU1214C() throws {
        let bench = SiemensBench([
            LAD.net(LAD.no("%I1.5"), LAD.coil("%Q1.1")),
            LAD.net(LAD.box(.move, ["IN": "%IW64", "OUT1": "%QW80"])),
        ])
        let cpu = bench.cpu
        #expect(cpu.digitalInputCount == 14 && cpu.digitalOutputCount == 10)
        #expect(cpu.analogInputCount == 2 && cpu.analogOutputCount == 1)
        #expect(cpu.analogRange == 0...27_648)
        #expect(cpu.digitalInputName(13) == "%I1.5")
        #expect(cpu.digitalOutputName(9) == "%Q1.1")
        #expect(cpu.analogInputName(1) == "%IW66")
        #expect(cpu.analogOutputName(0) == "%QW80")
        try bench.run()
        cpu.setDigitalInput(13, true)
        cpu.setAnalogInput(0, 1_234)
        bench.scan()
        #expect(cpu.digitalInput(13))
        #expect(cpu.digitalOutput(9))
        #expect(cpu.analogInput(0) == 1_234)
        #expect(cpu.analogOutput(0) == 1_234)
        #expect(bench.value("%I1.5") == .bool(true))

        cpu.setMode(.stop)
        #expect(cpu.mode == .stop)
        #expect(!cpu.digitalOutput(9))
        #expect(cpu.analogOutput(0) == 0)
        #expect(cpu.diagnostics.last?.message == S7Messages.stopRequested)
        cpu.setMode(.run)
        bench.scan()
        #expect(cpu.digitalOutput(9))
    }

    @Test func withoutAProgramTheCPUStaysInStop() {
        let cpu = SiemensCPU()
        cpu.setMode(.run)
        #expect(cpu.mode == .stop)
        #expect(cpu.diagnostics.last?.message == S7Messages.noProgram)
        cpu.scan(clock: 10)
        #expect(cpu.mode == .stop)
    }

    @Test func warmRestartKeepsOnlyRetentiveData() throws {
        let bench = SiemensBench([
            LAD.net(LAD.no("FirstScan"), LAD.box(.increment, type: .int, ["IN/OUT": "\"Data\".starts"])),
            LAD.net(LAD.no("#Initial_Call"), LAD.box(.increment, type: .int, ["IN/OUT": "\"Data\".calls"])),
            LAD.net(LAD.no("%I0.0"), LAD.box(.countUp, instance: "\"IEC_Counter_0_DB\"", ["PV": "10"])),
        ], configure: { project in
            project.device.retentiveMarkerBytes = 4
            project.dataBlocks.append(SiemensDataBlock(name: "Data", number: 1, members: [
                SiemensVariable("starts", "Int", retain: .retain),
                SiemensVariable("calls", "Int", retain: .retain),
                SiemensVariable("kept", "Int", retain: .retain),
                SiemensVariable("lost", "Int", startValue: "3"),
            ]))
            _ = project.createInstanceDataBlock(for: .countUp)
        })
        try bench.run()
        bench.scan(5)
        #expect(bench.int("\"Data\".starts") == 1)
        #expect(bench.int("\"Data\".calls") == 1)
        try bench.modify("%MW2", "7")
        try bench.modify("%MW10", "9")
        try bench.modify("\"Data\".kept", "5")
        try bench.modify("\"Data\".lost", "8")
        bench.pulse("%I0.0")
        bench.pulse("%I0.0")
        #expect(bench.int("\"IEC_Counter_0_DB\".CV") == 2)

        bench.cpu.setMode(.stop)
        bench.cpu.setMode(.run)
        bench.scan(3)
        #expect(bench.int("%MW2") == 7)
        #expect(bench.int("%MW10") == 0)
        #expect(bench.int("\"Data\".kept") == 5)
        #expect(bench.int("\"Data\".lost") == 3)
        #expect(bench.int("\"Data\".starts") == 2)
        #expect(bench.int("\"Data\".calls") == 2)
        #expect(bench.int("\"IEC_Counter_0_DB\".CV") == 2)
        #expect(bench.cpu.diagnostics.contains { $0.message == S7Messages.startupToRun })

        bench.cpu.memoryReset()
        #expect(bench.cpu.mode == .stop)
        #expect(bench.int("%MW2") == 0)
        #expect(bench.int("\"Data\".kept") == 0)
        #expect(bench.int("\"IEC_Counter_0_DB\".CV") == 0)
        bench.cpu.setMode(.run)
        bench.scan()
        #expect(bench.cpu.mode == .run)
        #expect(bench.int("\"Data\".starts") == 1)
    }

    @Test func startupOBRunsOnceBeforeTheCycle() throws {
        let bench = SiemensBench([
            LAD.net(LAD.box(.increment, type: .int, ["IN/OUT": "\"Cycles\""])),
        ], tags: [SiemensTag("Boots", .int, "%MW40"), SiemensTag("Cycles", .int, "%MW42"), SiemensTag("Seen", .int, "%MW44")]) { project in
            var startup = project.addBlock(.organizationBlock, event: .startup)
            startup.networks = [
                LAD.net(LAD.box(.increment, type: .int, ["IN/OUT": "\"Boots\""])),
                LAD.net(LAD.box(.move, ["IN": "\"Cycles\"", "OUT1": "\"Seen\""])),
            ]
            project.blocks[1] = startup
            project.device.retentiveMarkerBytes = 64
        }
        try bench.run()
        bench.scan(4)
        #expect(bench.int("\"Boots\"") == 1)
        #expect(bench.int("\"Cycles\"") == 5)
        #expect(bench.int("\"Seen\"") == 0)
        bench.cpu.setMode(.stop)
        bench.cpu.setMode(.run)
        bench.scan()
        #expect(bench.int("\"Boots\"") == 2)
        #expect(bench.int("\"Seen\"") == 5)
        #expect(bench.int("\"Cycles\"") == 6)
    }

    @Test func dataBlocksHoldStructuredDataWithStartValues() throws {
        let bench = SiemensBench([
            LAD.net(LAD.box(.move, ["IN": "\"Recipe\".motor.Speed", "OUT1": "\"Recipe\".values[2]"])),
            LAD.net(LAD.no("\"Recipe\".settings.enabled"), LAD.coil("%Q0.0")),
            LAD.net(LAD.no("\"Recipe\".values[2].%X0"), LAD.coil("%Q0.1")),
        ]) { project in
            project.dataTypes = [SiemensDataType(name: "Motor", members: [
                SiemensVariable("Speed", "Int", startValue: "1500"),
                SiemensVariable("Direction", "Bool"),
            ])]
            project.dataBlocks = [SiemensDataBlock(name: "Recipe", number: 1, members: [
                SiemensVariable("motor", "\"Motor\""),
                SiemensVariable("values", "Array[0..4] of Int", startValue: "7"),
                SiemensVariable("settings", "Struct", members: [
                    SiemensVariable("enabled", "Bool", startValue: "TRUE"),
                    SiemensVariable("limit", "Real", startValue: "2.5"),
                ]),
            ])]
        }
        try bench.run()
        #expect(bench.int("\"Recipe\".values[0]") == 7)
        #expect(bench.int("\"Recipe\".values[2]") == 1_500)
        #expect(bench.real("\"Recipe\".settings.limit") == 2.5)
        #expect(bench.cpu.digitalOutput(0))
        #expect(!bench.cpu.digitalOutput(1))
        try bench.modify("\"Recipe\".motor.Speed", "1501")
        bench.scan()
        #expect(bench.cpu.digitalOutput(1))

        let broken = SiemensBench([]) { project in
            project.dataBlocks = [SiemensDataBlock(name: "Bad", number: 1, members: [SiemensVariable("x", "\"Missing\"")])]
        }
        let result = broken.compile()
        #expect(result.has(S7Messages.dataTypeNotDefined("Missing")))
        #expect(result.diagnostics.first?.block == "Bad [DB1]")
    }

    @Test func downloadKeepsDataBlockValuesUnlessReinitialized() throws {
        let bench = SiemensBench([], configure: { project in
            project.dataBlocks.append(SiemensDataBlock(name: "Data", number: 1, members: [SiemensVariable("count", "Int", startValue: "1")]))
        })
        try bench.load()
        try bench.modify("\"Data\".count", "5")
        try bench.modify("%MW20", "11")
        try bench.load()
        #expect(bench.int("\"Data\".count") == 5)
        #expect(bench.int("%MW20") == 11)
        try bench.load(reinitialize: true)
        #expect(bench.int("\"Data\".count") == 1)
        try bench.modify("\"Data\".count", "6")
        bench.project.dataBlocks[0].members.append(SiemensVariable("extra", "Bool"))
        try bench.load()
        #expect(bench.int("\"Data\".count") == 1)
        #expect(bench.cpu.diagnostics.contains { $0.message == S7Messages.downloaded })
    }

    @Test func programmingErrorsKeepTheCPUInRun() throws {
        let bench = SiemensBench([
            LAD.net(LAD.box(.move, ["IN": "5", "OUT1": "\"Data\".values[\"Index\"]"])),
            LAD.net(LAD.box(.increment, type: .int, ["IN/OUT": "\"Data\".after"])),
        ], tags: [SiemensTag("Index", .int, "%MW30")], configure: { project in
            project.dataBlocks.append(SiemensDataBlock(name: "Data", number: 1, members: [
                SiemensVariable("values", "Array[0..3] of Int"),
                SiemensVariable("after", "Int"),
            ]))
        })
        try bench.run()
        try bench.modify("\"Index\"", "2")
        bench.scan()
        #expect(bench.int("\"Data\".values[2]") == 5)
        let before = bench.int("\"Data\".after") ?? 0
        try bench.modify("\"Index\"", "7")
        bench.scan(3)
        #expect(bench.cpu.mode == .run)
        #expect(bench.cpu.isErrorLEDFlashing)
        #expect(bench.int("\"Data\".after") == before)
        let entry = try #require(bench.cpu.diagnostics.last { $0.isError })
        #expect(entry.message.hasPrefix("Programming error in block Main [OB1], Network 1"))
        #expect(bench.cpu.diagnostics.filter(\.isError).count == 1)
    }

    @Test func exceedingTheCycleTimeStopsTheCPU() throws {
        let loop = SiemensBlock(name: "Loop", kind: .function, number: 1, language: .scl, source: "WHILE TRUE DO END_WHILE;")
        let bench = SiemensBench([LAD.net(LAD.call(loop))], configure: { project in project.blocks.append(loop) })
        bench.compileSCL = { _, _ in
            let body: ExecutableBody = ClosureBody { _ in
                throw RuntimeFault(.cycleTimeExceeded, "Maximum cycle time exceeded.")
            }
            return (body, [])
        }
        try bench.run()
        #expect(bench.cpu.mode == .stop)
        #expect(bench.cpu.diagnostics.last?.message.hasPrefix(S7Messages.cycleTimeStop) == true)
    }

    @Test func watchTablesMonitorAndModify() throws {
        let bench = SiemensBench([
            LAD.net(LAD.no("%I0.0"), LAD.coil("%Q0.0")),
            LAD.net(LAD.box(.move, ["IN": "0", "OUT1": "%MW12"])),
        ])
        try bench.run()
        try bench.modify("%MW10", "16#0102")
        #expect(try bench.cpu.monitorValue("%MW10").get() == "16#0102")
        #expect(try bench.cpu.monitorValue("%MW10", format: .decimal).get() == "258")
        #expect(try bench.cpu.monitorValue("%MW10", format: .binary).get() == "2#0000_0001_0000_0010")
        #expect(try bench.cpu.monitorValue("%M11.1").get() == "TRUE")
        if case let .failure(error) = bench.cpu.monitorValue("\"Nope\"") {
            #expect(error.message == "Tag \"Nope\" not defined.")
        } else {
            Issue.record("an unknown tag can't be monitored")
        }
        #expect(throws: ResolveError.self) { try bench.cpu.modify("%I0.0:P", to: "TRUE") }
        #expect(bench.value("%Q0.1:P") == nil)
        try bench.cpu.modify("%Q0.1:P", to: "TRUE")
        #expect(bench.cpu.digitalOutput(1))
        #expect(bench.value("%I0.0:P") == .bool(false))

        try bench.cpu.setModifyJobs([SiemensModifyJob(operand: "%MW12", value: "5", trigger: .permanentlyAtEndOfCycle)])
        bench.scan()
        #expect(bench.int("%MW12") == 5)
        try bench.cpu.setModifyJobs([SiemensModifyJob(operand: "%MW12", value: "9", trigger: .onceAtStartOfCycle)])
        bench.scan()
        #expect(bench.int("%MW12") == 0)
    }

    @Test func forcingOverridesTheIO() throws {
        let bench = SiemensBench([LAD.net(LAD.no("%I0.0"), LAD.coil("%Q0.0"))], tags: [SiemensTag("Start", .bool, "%I0.0")])
        try bench.run()
        try bench.cpu.force("\"Start\":P", to: "TRUE")
        bench.scan()
        #expect(bench.cpu.isMaintenanceLEDOn)
        #expect(!bench.cpu.digitalInput(0))
        #expect(bench.cpu.digitalOutput(0))
        try bench.cpu.force("%Q0.1:P", to: "TRUE")
        bench.scan()
        #expect(bench.cpu.digitalOutput(1))
        bench.cpu.setMode(.stop)
        #expect(bench.cpu.digitalOutput(1))
        #expect(!bench.cpu.digitalOutput(0))
        #expect(bench.cpu.forceJobs.count == 2)
        #expect(throws: ResolveError.self) { try bench.cpu.force("%M10.0:P", to: "TRUE") }
        #expect(throws: ResolveError.self) { try bench.cpu.force("%I0.0", to: "TRUE") }
        bench.cpu.stopForcing()
        #expect(!bench.cpu.digitalOutput(1))
        #expect(!bench.cpu.isMaintenanceLEDOn)
    }
}
