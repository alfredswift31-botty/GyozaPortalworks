import Foundation
import Testing
@testable import GyozaPortalworks

struct SiemensNetworkTests {
    @Test func seriesParallelAndNestedBranches() throws {
        // (I0.0 OR (I0.1 AND NOT I0.2)) AND I0.3 → Q0.0
        let bench = SiemensBench([
            LAD.net(LAD.par([LAD.no("%I0.0")], [LAD.no("%I0.1"), LAD.nc("%I0.2")]), LAD.no("%I0.3"), LAD.coil("%Q0.0")),
        ])
        try bench.run()
        for a in [false, true] {
            for b in [false, true] {
                for c in [false, true] {
                    for d in [false, true] {
                        bench.input("%I0.0", a, scans: 0)
                        bench.input("%I0.1", b, scans: 0)
                        bench.input("%I0.2", c, scans: 0)
                        bench.input("%I0.3", d, scans: 2)
                        #expect(bench.cpu.digitalOutput(0) == ((a || (b && !c)) && d), "\(a) \(b) \(c) \(d)")
                    }
                }
            }
        }
    }

    @Test func coilsMidRungAndOpenBranches() throws {
        let bench = SiemensBench([
            LAD.net(LAD.no("%I0.0"), LAD.coil("%M10.0"), LAD.no("%I0.1"), LAD.coil("%Q0.0")),
            LAD.net(LAD.no("%I0.2"), LAD.fan([LAD.coil("%Q0.1")], [LAD.nc("%I0.3"), LAD.coil("%Q0.2")])),
            LAD.net(LAD.no("%I0.0"), LAD.coil("%Q0.3", .negate)),
        ])
        try bench.run()
        bench.input("%I0.0", true)
        #expect(bench.bool("%M10.0"))
        #expect(!bench.bool("%Q0.0"))
        #expect(!bench.bool("%Q0.3"))
        bench.input("%I0.1", true)
        #expect(bench.bool("%Q0.0"))
        bench.input("%I0.2", true)
        #expect(bench.bool("%Q0.1") && bench.bool("%Q0.2"))
        bench.input("%I0.3", true)
        #expect(bench.bool("%Q0.1") && !bench.bool("%Q0.2"))
        bench.input("%I0.0", false)
        #expect(!bench.bool("%M10.0") && bench.bool("%Q0.3"))
    }

    @Test func setResetAndFlipFlops() throws {
        let bench = SiemensBench([
            LAD.net(LAD.no("%I0.0"), LAD.coil("%Q0.1", .set)),
            LAD.net(LAD.no("%I0.1"), LAD.coil("%Q0.1", .reset)),
            LAD.net(LAD.no("%I0.0"), LAD.box(.setReset, operand: "%M10.1", ["R1": "%I0.1"]), LAD.coil("%Q0.2")),
            LAD.net(LAD.no("%I0.1"), LAD.box(.resetSet, operand: "%M10.2", ["S1": "%I0.0"]), LAD.coil("%Q0.3")),
        ])
        try bench.run()
        bench.pulse("%I0.0")
        #expect(bench.bool("%Q0.1"))
        #expect(bench.bool("%Q0.2") && bench.bool("%Q0.3"))
        bench.pulse("%I0.1")
        #expect(!bench.bool("%Q0.1"))
        #expect(!bench.bool("%Q0.2") && !bench.bool("%Q0.3"))
        // Both inputs at once: SR's R1 dominates, RS's S1 dominates.
        bench.input("%I0.0", true, scans: 0)
        bench.input("%I0.1", true, scans: 2)
        #expect(!bench.bool("%Q0.2"))
        #expect(bench.bool("%Q0.3"))
        #expect(!bench.bool("%M10.1") && bench.bool("%M10.2"))
    }

    @Test func edgeContactsAndCoils() throws {
        let bench = SiemensBench([
            LAD.net(LAD.edge("%I0.0", memory: "%M10.3"), LAD.box(.increment, type: .int, ["IN/OUT": "\"Rises\""])),
            LAD.net(LAD.edge("%I0.0", memory: "%M10.4", rising: false), LAD.box(.increment, type: .int, ["IN/OUT": "\"Falls\""])),
            LAD.net(LAD.no("%I0.1"), LAD.coil("%M11.1", .positiveEdge, "%M10.5")),
            LAD.net(LAD.no("%M11.1"), LAD.box(.increment, type: .int, ["IN/OUT": "\"CoilRises\""])),
            LAD.net(LAD.no("%I0.1"), LAD.coil("%M11.2", .negativeEdge, "%M10.6")),
            LAD.net(LAD.no("%M11.2"), LAD.box(.increment, type: .int, ["IN/OUT": "\"CoilFalls\""])),
            LAD.net(LAD.no("%I0.2"), LAD.box(.positiveEdgeBox, operand: "%M10.7"), LAD.box(.increment, type: .int, ["IN/OUT": "\"RloRises\""])),
        ], tags: [
            SiemensTag("Rises", .int, "%MW20"), SiemensTag("Falls", .int, "%MW22"), SiemensTag("CoilRises", .int, "%MW24"),
            SiemensTag("CoilFalls", .int, "%MW26"), SiemensTag("RloRises", .int, "%MW28"),
        ])
        try bench.run()
        bench.input("%I0.0", true, scans: 5)
        bench.input("%I0.1", true, scans: 5)
        bench.input("%I0.2", true, scans: 5)
        #expect(bench.int("\"Rises\"") == 1)
        #expect(bench.int("\"Falls\"") == 0)
        #expect(bench.int("\"CoilRises\"") == 1)
        #expect(bench.int("\"RloRises\"") == 1)
        bench.input("%I0.0", false, scans: 5)
        bench.input("%I0.1", false, scans: 5)
        #expect(bench.int("\"Rises\"") == 1)
        #expect(bench.int("\"Falls\"") == 1)
        #expect(bench.int("\"CoilFalls\"") == 1)
        bench.pulse("%I0.0")
        #expect(bench.int("\"Rises\"") == 2)
    }

    @Test func timerBoxesAcrossScans() throws {
        let bench = SiemensBench([], configure: { project in
            let ton = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            let tof = project.createInstanceDataBlock(for: .offDelayTimer) ?? ""
            let tp = project.createInstanceDataBlock(for: .pulseTimer) ?? ""
            let tonr = project.createInstanceDataBlock(for: .accumulatingTimer) ?? ""
            project.addTag(SiemensTag("Elapsed", .time, "%MD30"))
            project.blocks[0].networks = [
                LAD.net(LAD.no("%I0.0"), LAD.box(.onDelayTimer, instance: ton, ["PT": "T#500MS", "ET": "\"Elapsed\""]), LAD.coil("%Q0.0")),
                LAD.net(LAD.no("%I0.1"), LAD.box(.offDelayTimer, instance: tof, ["PT": "T#300MS"]), LAD.coil("%Q0.1")),
                LAD.net(LAD.no("%I0.2"), LAD.box(.pulseTimer, instance: tp, ["PT": "T#200MS"]), LAD.coil("%Q0.2")),
                LAD.net(LAD.no("%I0.3"), LAD.box(.accumulatingTimer, instance: tonr, ["R": "%I0.4", "PT": "T#400MS"]), LAD.coil("%Q0.3")),
            ]
        })
        try bench.run()
        bench.input("%I0.0", true)
        bench.wait(400)
        #expect(!bench.bool("%Q0.0"))
        bench.wait(150)
        #expect(bench.bool("%Q0.0"))
        #expect(bench.value("\"Elapsed\"") == .time(500))
        #expect(bench.value("\"IEC_Timer_0_DB\".ET") == .time(500))
        bench.input("%I0.0", false)
        #expect(!bench.bool("%Q0.0"))

        bench.input("%I0.1", true)
        #expect(bench.bool("%Q0.1"))
        bench.input("%I0.1", false)
        bench.wait(200)
        #expect(bench.bool("%Q0.1"))
        bench.wait(150)
        #expect(!bench.bool("%Q0.1"))

        bench.input("%I0.2", true)
        bench.input("%I0.2", false)
        #expect(bench.bool("%Q0.2"))
        bench.wait(250)
        #expect(!bench.bool("%Q0.2"))

        bench.input("%I0.3", true)
        bench.wait(250)
        bench.input("%I0.3", false)
        bench.wait(500)
        bench.input("%I0.3", true)
        bench.wait(100)
        #expect(!bench.bool("%Q0.3"))
        bench.wait(100)
        #expect(bench.bool("%Q0.3"))
        bench.input("%I0.4", true)
        #expect(!bench.bool("%Q0.3"))
    }

    @Test func timerCoilsAndMultiInstances() throws {
        let bench = SiemensBench([], configure: { project in
            let timer = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            var fb = project.addBlock(.functionBlock, name: "Delay")
            fb.interface.input = [SiemensVariable("Run", "Bool")]
            fb.interface.output = [SiemensVariable("Done", "Bool")]
            let instance = fb.addMultiInstance(for: .onDelayTimer) ?? ""
            fb.networks = [LAD.net(LAD.no("#Run"), LAD.box(.onDelayTimer, instance: instance, ["PT": "T#300MS"]), LAD.coil("#Done"))]
            project.blocks[project.blocks.count - 1] = fb
            project.addInstanceDataBlock(of: "Delay")
            project.blocks[0].networks = [
                LAD.net(LAD.no("%I0.1"), LAD.coil(timer, .onDelayTimer, "T#200MS")),
                LAD.net(LAD.no(timer + ".Q"), LAD.coil("%Q0.1")),
                LAD.net(LAD.no("%I0.2"), LAD.coil(timer, .resetTimer)),
                LAD.net(LAD.call(fb, instance: "\"Delay_DB\"", ["Run": "%I0.0", "Done": "%Q0.0"])),
            ]
        })
        try bench.run()
        bench.input("%I0.0", true)
        bench.wait(250)
        #expect(!bench.bool("%Q0.0"))
        bench.wait(100)
        #expect(bench.bool("%Q0.0"))
        #expect(bench.value("\"Delay_DB\".IEC_Timer_0_Instance.Q") == .bool(true))

        bench.input("%I0.1", true)
        bench.wait(250)
        #expect(bench.bool("%Q0.1"))
        bench.input("%I0.2", true)
        bench.input("%I0.2", false)
        #expect(!bench.bool("\"IEC_Timer_0_DB\".Q"))
    }

    @Test func countersWithBranchDrivenInputs() throws {
        let bench = SiemensBench([], configure: { project in
            let up = project.createInstanceDataBlock(for: .countUp) ?? ""
            let down = project.createInstanceDataBlock(for: .countDown) ?? ""
            let both = project.createInstanceDataBlock(for: .countUpDown) ?? ""
            project.blocks[0].networks = [
                LAD.net(LAD.no("%I0.0"), LAD.box(.countUp, instance: up, ["PV": "3", "CV": "%MW40"], branches: ["R": [LAD.no("%I0.1")]]),
                        LAD.coil("%Q0.0")),
                LAD.net(LAD.no("%I0.2"), LAD.box(.countDown, instance: down, ["LD": "%I0.3", "PV": "2"]), LAD.coil("%Q0.1")),
                LAD.net(LAD.no("%I0.4"), LAD.box(.countUpDown, instance: both, ["PV": "2", "CV": "%MW42"],
                                                 branches: ["CD": [LAD.no("%I0.5")], "QD": [LAD.coil("%Q0.3")]]),
                        LAD.coil("%Q0.2")),
            ]
        })
        try bench.run()
        bench.pulse("%I0.0")
        bench.pulse("%I0.0")
        #expect(!bench.bool("%Q0.0"))
        bench.pulse("%I0.0")
        #expect(bench.bool("%Q0.0"))
        #expect(bench.int("%MW40") == 3)
        bench.pulse("%I0.1")
        #expect(bench.int("%MW40") == 0)
        #expect(!bench.bool("%Q0.0"))

        bench.pulse("%I0.3")
        #expect(bench.value("\"IEC_Counter_0_DB_1\".CV") == .int(2))
        bench.pulse("%I0.2")
        #expect(!bench.bool("%Q0.1"))
        bench.pulse("%I0.2")
        #expect(bench.bool("%Q0.1"))

        #expect(bench.bool("%Q0.3"))
        bench.pulse("%I0.4")
        bench.pulse("%I0.4")
        #expect(bench.bool("%Q0.2"))
        #expect(!bench.bool("%Q0.3"))
        bench.pulse("%I0.5")
        #expect(bench.int("%MW42") == 1)
        #expect(!bench.bool("%Q0.2"))
    }

    @Test func enableOutputReportsOverflow() throws {
        let bench = SiemensBench([
            LAD.net(LAD.no("%I0.0"), LAD.box(.add, type: .int, ["IN1": "%MW50", "IN2": "1", "OUT": "%MW52"]), LAD.coil("%Q0.3")),
            LAD.net(LAD.box(.divide, type: .int, ["IN1": "10", "IN2": "%MW54", "OUT": "%MW56"]), LAD.coil("%Q0.4")),
        ])
        try bench.run()
        try bench.modify("%MW50", "16#7FFE")
        bench.input("%I0.0", true)
        #expect(bench.bool("%Q0.3"))
        #expect(bench.int("%MW52") == 0x7FFF)
        try bench.modify("%MW50", "16#7FFF")
        bench.scan()
        #expect(!bench.bool("%Q0.3"))
        #expect(bench.value("%MW52") == .int(0x8000))
        bench.input("%I0.0", false)
        #expect(!bench.bool("%Q0.3"))
        #expect(!bench.bool("%Q0.4"))
        try bench.modify("%MW54", "2")
        bench.scan()
        #expect(bench.bool("%Q0.4"))
        #expect(bench.int("%MW56") == 5)
    }

    @Test func moveConvertAndMath() throws {
        let bench = SiemensBench([
            LAD.net(LAD.box(.move, ["IN": "16#1234", "OUT1": "%MW60", "OUT2": "%MW62"])),
            LAD.net(LAD.box(.convert, ["IN": "\"Raw\"", "OUT": "\"AsReal\""])),
            LAD.net(LAD.box(.round, type: .real, to: .dint, ["IN": "\"Half\"", "OUT": "\"Rounded\""])),
            LAD.net(LAD.box(.maximum, type: .int, ["IN1": "\"Raw\"", "IN2": "3", "IN3": "12", "OUT": "\"Largest\""])),
            LAD.net(LAD.box(.limit, type: .int, ["MN": "0", "IN": "\"Raw\"", "MX": "5", "OUT": "\"Clamped\""])),
            LAD.net(LAD.box(.shiftLeft, type: .word, ["IN": "%MW60", "N": "4", "OUT": "%MW64"])),
            LAD.net(LAD.box(.wordAnd, type: .word, ["IN1": "%MW60", "IN2": "16#00FF", "OUT": "%MW66"])),
            LAD.net(LAD.box(.squareRoot, type: .real, ["IN": "16.0", "OUT": "\"Root\""])),
        ], tags: [
            SiemensTag("Raw", .int, "%MW70"),
            SiemensTag("AsReal", .real, "%MD72"),
            SiemensTag("Half", .real, "%MD76"),
            SiemensTag("Rounded", .dint, "%MD80"),
            SiemensTag("Largest", .int, "%MW84"),
            SiemensTag("Clamped", .int, "%MW86"),
            SiemensTag("Root", .real, "%MD88"),
        ])
        try bench.run()
        try bench.modify("\"Raw\"", "7")
        try bench.modify("\"Half\"", "2.5")
        bench.scan()
        #expect(bench.int("%MW60") == 0x1234)
        #expect(bench.int("%MW62") == 0x1234)
        #expect(bench.real("\"AsReal\"") == 7.0)
        #expect(bench.int("\"Rounded\"") == 2)
        #expect(bench.int("\"Largest\"") == 12)
        #expect(bench.int("\"Clamped\"") == 5)
        #expect(bench.int("%MW64") == 0x2340)
        #expect(bench.int("%MW66") == 0x0034)
        #expect(bench.real("\"Root\"") == 4.0)
    }

    @Test func normalizeAndScaleAnAnalogInput() throws {
        let bench = SiemensBench([
            LAD.net(LAD.box(.normalize, type: .int, to: .real, ["MIN": "0", "VALUE": "%IW64", "MAX": "27648", "OUT": "\"Norm\""]),
                    LAD.box(.scale, type: .real, to: .real, ["MIN": "0.0", "VALUE": "\"Norm\"", "MAX": "100.0", "OUT": "\"Level\""])),
            LAD.net(LAD.box(.inRange, type: .real, ["MIN": "40.0", "VAL": "\"Level\"", "MAX": "60.0"]), LAD.coil("%Q0.4")),
            LAD.net(LAD.box(.outOfRange, type: .real, ["MIN": "40.0", "VAL": "\"Level\"", "MAX": "60.0"]), LAD.coil("%Q0.5")),
            LAD.net(LAD.cmp("\"Level\"", .greaterOrEqual, "80.0"), LAD.coil("%Q0.6")),
        ], tags: [SiemensTag("Norm", .real, "%MD100"), SiemensTag("Level", .real, "%MD104")])
        try bench.run()
        bench.cpu.setAnalogInput(0, 13_824)
        bench.scan(2)
        #expect(bench.real("\"Level\"") == 50.0)
        #expect(bench.bool("%Q0.4") && !bench.bool("%Q0.5") && !bench.bool("%Q0.6"))
        bench.cpu.setAnalogInput(0, 22_119)
        bench.scan(2)
        #expect(abs((bench.real("\"Level\"") ?? 0) - 80.0) < 0.01)
        #expect(!bench.bool("%Q0.4") && bench.bool("%Q0.5") && bench.bool("%Q0.6"))
    }

    @Test func calculateBox() throws {
        let bench = SiemensBench([
            LAD.net(LAD.box(.calculate, type: .int, expression: "(IN1 + IN2) * IN3 - IN1 / 2",
                            ["IN1": "\"A\"", "IN2": "\"B\"", "IN3": "3", "OUT": "\"Result\""])),
            LAD.net(LAD.box(.calculate, type: .real, expression: "SQRT(IN1 * IN1 + IN2 * IN2)",
                            ["IN1": "3.0", "IN2": "4.0", "OUT": "\"Hypotenuse\""])),
        ], tags: [
            SiemensTag("A", .int, "%MW140"), SiemensTag("B", .int, "%MW142"),
            SiemensTag("Result", .int, "%MW144"), SiemensTag("Hypotenuse", .real, "%MD146"),
        ])
        try bench.run()
        try bench.modify("\"A\"", "10")
        try bench.modify("\"B\"", "4")
        bench.scan()
        #expect(bench.int("\"Result\"") == 37)
        #expect(bench.real("\"Hypotenuse\"") == 5.0)
    }

    @Test func functionAndFunctionBlockCalls() throws {
        var addOne = SiemensBlock(name: "AddOne", kind: .function, number: 1)
        addOne.interface.input = [SiemensVariable("x", "Int")]
        addOne.interface.returnType = "Int"
        addOne.networks = [LAD.net(LAD.box(.add, type: .int, ["IN1": "#x", "IN2": "1", "OUT": "#AddOne"]))]
        var motor = SiemensBlock(name: "Motor", kind: .functionBlock, number: 1)
        motor.interface.input = [SiemensVariable("Start", "Bool"), SiemensVariable("Stop", "Bool")]
        motor.interface.output = [SiemensVariable("Running", "Bool")]
        motor.interface.staticVariables = [SiemensVariable("starts", "Int")]
        motor.networks = [
            LAD.net(LAD.par([LAD.no("#Start")], [LAD.no("#Running")]), LAD.no("#Stop"), LAD.coil("#Running")),
            LAD.net(LAD.edge("#Start", memory: "#edge"), LAD.box(.increment, type: .int, ["IN/OUT": "#starts"])),
        ]
        motor.interface.staticVariables.append(SiemensVariable("edge", "Bool"))
        let bench = SiemensBench([
            LAD.net(LAD.call(addOne, ["x": "\"Count\"", "Ret_Val": "\"Next\""]), LAD.coil("%Q0.5")),
            LAD.net(LAD.call(motor, instance: "\"Motor_DB\"", ["Start": "%I0.0", "Stop": "%I0.1", "Running": "%Q0.0"])),
        ], tags: [SiemensTag("Count", .int, "%MW120"), SiemensTag("Next", .int, "%MW122")], configure: { project in
            project.blocks += [addOne, motor]
            project.addInstanceDataBlock(of: "Motor")
        })
        try bench.run()
        try bench.modify("\"Count\"", "41")
        bench.scan()
        #expect(bench.int("\"Next\"") == 42)
        #expect(bench.bool("%Q0.5"))
        bench.input("%I0.1", true)
        bench.pulse("%I0.0")
        #expect(bench.bool("%Q0.0"))
        #expect(bench.int("\"Motor_DB\".starts") == 1)
        bench.input("%I0.1", false)
        #expect(!bench.bool("%Q0.0"))
    }

    @Test func ladAndFbdEvaluateIdentically() throws {
        let networks = [
            LAD.net(LAD.par([LAD.no("%I0.0")], [LAD.no("%Q0.0")]), LAD.nc("%I0.1"), LAD.coil("%Q0.0"), LAD.no("%I0.2"), LAD.coil("%Q0.1")),
            LAD.net(LAD.no("%I0.3"), LAD.fan([LAD.coil("%Q0.2")], [LAD.not(), LAD.coil("%Q0.3")])),
        ]
        func trace(_ language: SiemensLanguage) throws -> [[Bool]] {
            let bench = SiemensBench(networks)
            let switched = bench.project.blocks[0].switchLanguage(to: language)
            #expect(switched)
            try bench.run()
            var outputs: [[Bool]] = []
            let steps: [(String, Bool)] = [("%I0.0", true), ("%I0.0", false), ("%I0.2", true), ("%I0.3", true), ("%I0.1", true),
                                           ("%I0.1", false), ("%I0.3", false)]
            for (address, value) in steps {
                bench.input(address, value, scans: 2)
                outputs.append((0..<4).map { bench.cpu.digitalOutput($0) })
            }
            return outputs
        }
        let lad = try trace(.lad)
        let fbd = try trace(.fbd)
        #expect(lad == fbd)
        #expect(lad[2] == [true, true, false, true])
        #expect(lad[3] == [true, true, true, false])

        var block = SiemensBlock(name: "Code", kind: .function, number: 1, language: .scl)
        let sclSwitched = block.switchLanguage(to: .lad)
        #expect(!sclSwitched)
        var ladBlock = SiemensBlock(name: "Main", kind: .organizationBlock, number: 1)
        let toSCL = ladBlock.switchLanguage(to: .scl)
        let toFBD = ladBlock.switchLanguage(to: .fbd)
        #expect(!toSCL && toFBD)
        #expect(block.language == .scl && ladBlock.language == .fbd)
    }

    @Test func editingOperationsBuildASealIn() throws {
        var network = S7Network()
        let rung = network.rungs[0].id
        let startID = network.insertContact(operand: "%I0.0", at: .start(path: rung))
        let start = try #require(startID)
        let stopID = network.insertContact(.normallyClosed, operand: "%I0.1", at: .after(element: start))
        let stop = try #require(stopID)
        let motorID = network.insertCoil(operand: "%Q0.0", at: .after(element: stop))
        let motor = try #require(motorID)
        let branchID = network.openBranch(at: .start(path: rung))
        let branch = try #require(branchID)
        let holdID = network.insertContact(operand: "%Q0.0", at: .start(path: branch))
        let hold = try #require(holdID)
        let closed = network.closeBranch(branch, onto: start)
        #expect(closed)
        let boxID = network.insertEmptyBox(at: .after(element: motor))
        let box = try #require(boxID)
        let picked = network.setInstruction(.add, of: box)
        let typed = network.setDataType(.int, of: box)
        let added = network.addBoxInput(to: box)
        let pinned = network.setPin("IN1", to: "%MW10", of: box)
        #expect(picked && typed && pinned)
        #expect(added == "IN3")
        let removed = network.removeElement(box)
        #expect(removed)
        #expect(network.element(hold) != nil)
        guard case let .parallel(group)? = network.rungs[0].items.first else {
            Issue.record("the seal-in should be a closed branch")
            return
        }
        #expect(group.branches.count == 2)
        #expect(network.rungs[0].items.count == 3)

        let bench = SiemensBench([network])
        try bench.run()
        bench.input("%I0.1", false)
        bench.pulse("%I0.0")
        #expect(bench.bool("%Q0.0"))
        bench.input("%I0.1", true)
        #expect(!bench.bool("%Q0.0"))

        var block = SiemensBlock(name: "Main", kind: .organizationBlock, number: 1)
        block.insertNetwork(after: 0)
        #expect(block.networks.count == 2)
        block.deleteNetwork(at: 0)
        #expect(block.networks.count == 1)
    }

    @Test func monitoringReportsPowerFlowAndValues() throws {
        let start = S7Contact(.normallyOpen, "%I0.0")
        let stop = S7Contact(.normallyClosed, "%I0.1")
        let coil = S7Coil(.assign, "%Q0.0")
        let add = S7Box(.add, dataType: .int, inputs: [S7Pin("IN1", "%MW10"), S7Pin("IN2", "5")], outputs: [S7Pin("OUT", "%MW12")])
        let bench = SiemensBench([
            LAD.net(.contact(start), .contact(stop), .coil(coil)),
            LAD.net(.box(add)),
        ])
        try bench.run()
        bench.cpu.setMonitoring(true, block: "Main")
        bench.input("%I0.0", true)
        let monitor = try #require(bench.cpu.monitor(ofBlock: "Main"))
        #expect(monitor.status(of: start.id).state == .satisfied)
        #expect(monitor.status(of: start.id).output == .satisfied)
        #expect(monitor.status(of: stop.id).state == .satisfied)
        #expect(monitor.status(of: coil.id).state == .satisfied)
        #expect(monitor.status(of: add.id).values["OUT"] == .int(5))
        bench.input("%I0.1", true)
        #expect(monitor.status(of: stop.id).state == .notSatisfied)
        #expect(monitor.status(of: coil.id).input == .notSatisfied)
        bench.cpu.setMonitoring(false, block: "Main")
        bench.scan()
        #expect(monitor.status(of: start.id).state == .unknown)
    }
}
