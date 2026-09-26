import Foundation
import Testing
@testable import GyozaPortalworks

struct MelsecCPUTests {
    @Test func stopKeepsDevicesAndTurnsOutputsOff() throws {
        let rig = try MelsecRig(il: "LD X0 OUT Y0\nLD X0 SET M0\nLD SM400 INC D0")
        rig.set("X0"); rig.scan(3)
        #expect(rig.cpu.digitalOutput(0))
        rig.cpu.setMode(.stop)
        #expect(!rig.cpu.digitalOutput(0))
        rig.scan(5)
        #expect(rig.bit("Y0"), "the Y device keeps its value")
        #expect(rig.bit("M0"))
        #expect(rig.int("D0") == 3)
        rig.cpu.setMode(.run); rig.scan()
        #expect(rig.cpu.digitalOutput(0))
        #expect(rig.int("D0") == 4)
    }

    @Test func specialRelays() throws {
        let rig = try MelsecRig(il: "LD SM402 INC D0\nLD SM403 INC D1\nLD SM8002 INC D2\nLD SM400 INC D3\nLD SM401 INC D4")
        rig.scan(3)
        #expect(rig.int("D0") == 1)
        #expect(rig.int("D1") == 2)
        #expect(rig.int("D2") == 1)
        #expect(rig.int("D3") == 3)
        #expect(rig.int("D4") == 0)
        rig.cpu.setMode(.stop); rig.cpu.setMode(.run); rig.scan()
        #expect(rig.int("D0") == 2, "SM402 pulses again after STOP → RUN")
        #expect(rig.int("SD520") == 0 || rig.int("SD520") == 10)
        rig.scan()
        #expect(rig.int("SD520") == 10)
    }

    @Test func oneSecondClock() throws {
        let rig = try MelsecRig(il: "LD SM412 OUT Y0\nLD SM412 INCP D0")
        rig.scan(40)
        #expect(!rig.cpu.digitalOutput(0))
        rig.scan(20)
        #expect(rig.cpu.digitalOutput(0))
        rig.scan(50)
        #expect(!rig.cpu.digitalOutput(0))
        rig.run(3_000)
        #expect(rig.int("D0") == 4)
    }

    @Test func resetClearsNonLatchedDevices() throws {
        let rig = try MelsecRig(il: "LD SM400 SET M0\nLD SM400 SET L0\nLD SM400 MOV K5 D0")
        rig.scan()
        rig.cpu.reset()
        #expect(rig.cpu.mode == .stop)
        #expect(!rig.bit("M0"))
        #expect(rig.bit("L0"))
        #expect(rig.int("D0") == 0)
        rig.cpu.latchClear()
        #expect(!rig.bit("L0"))
    }

    @Test func processIOMapping() throws {
        let rig = try MelsecRig(il: "LD X17 OUT Y17\nLD SM400 MOV SD6020 D0\nLD SM400 MOV K3000 SD6180")
        let cpu = rig.cpu
        #expect(cpu.digitalInputCount == 16 && cpu.digitalOutputCount == 16)
        #expect(cpu.analogInputCount == 2 && cpu.analogOutputCount == 1)
        #expect(cpu.digitalInputName(8) == "X10")
        #expect(cpu.digitalOutputName(15) == "Y17")
        #expect(cpu.analogInputName(0) == "SD6020")
        #expect(cpu.analogInputName(1) == "SD6060")
        #expect(cpu.analogOutputName(0) == "SD6180")
        #expect(cpu.analogRange == 0...4000)
        cpu.setDigitalInput(15, true)
        cpu.setAnalogInput(0, 5000)
        #expect(cpu.analogInput(0) == 4000)
        cpu.setAnalogInput(0, 1234)
        rig.scan()
        #expect(cpu.digitalInput(15))
        #expect(cpu.digitalOutput(15))
        #expect(rig.int("D0") == 1234)
        #expect(cpu.analogOutput(0) == 3000)
        cpu.setMode(.stop)
        #expect(cpu.analogOutput(0) == 0)
    }

    @Test func forcingTogglingAndModifying() throws {
        let rig = try MelsecRig(il: "LD X0 OUT Y0\nLD M5 OUT Y1")
        rig.cpu.forceInput(0, true)
        rig.scan()
        #expect(rig.cpu.digitalOutput(0))
        rig.cpu.forceInput(0, nil)
        rig.scan()
        #expect(!rig.cpu.digitalOutput(0))
        try rig.cpu.toggleBit("X0")
        #expect(rig.cpu.digitalInput(0), "X0 is the board's input")
        try rig.cpu.toggleBit("M5")
        rig.scan()
        #expect(rig.cpu.digitalOutput(0) && rig.cpu.digitalOutput(1))
        try rig.cpu.writeOperand("D10", value: "K-7")
        #expect(rig.int("D10") == -7)
        try rig.cpu.writeOperand("K4M0", value: "H00FF")
        #expect(rig.bit("M7") && !rig.bit("M8"))
        #expect(rig.cpu.readOperand("K4M0") == .int(0xFF))
        #expect(throws: MelsecOperandError.self) { try rig.cpu.toggleBit("D0") }
        #expect(throws: MelsecOperandError.self) { try rig.cpu.writeOperand("D0", value: "abc") }
        rig.cpu.forceOutput(3, true)
        #expect(rig.cpu.digitalOutput(3))
        #expect(rig.cpu.readOperand("Q9") == nil)
    }

    @Test func monitorStatePerInstruction() throws {
        let rig = try MelsecRig(il: "LD X0 ANI X1 OUT Y0")
        rig.cpu.isMonitoring = true
        rig.set("X0"); rig.scan()
        #expect(rig.cpu.monitorState(program: "ProgPou") == [true, true, true, false])
        rig.set("X1"); rig.scan()
        #expect(rig.cpu.monitorState(program: "ProgPou") == [true, false, false, false])
    }
}

struct MelsecResolverTests {
    private func project(_ labels: [MelsecLabel], locals: [MelsecLabel] = []) -> MelsecProject {
        var project = MelsecProject.newProject(language: .structuredText)
        project.globalLabels = labels
        project.programs[0].localLabels = locals
        return project
    }

    @Test func lookupOrderAndBindings() throws {
        let globals = [
            MelsecLabel(name: "Speed", dataType: .wordSigned, initialValue: "5"),
            MelsecLabel(name: "Limit", dataType: .wordSigned, labelClass: .globalConstant, initialValue: "100"),
            MelsecLabel(name: "Lamp", dataType: .bit, device: "Y2"),
            MelsecLabel(name: "count", dataType: .doubleWordSigned),
        ]
        let locals = [MelsecLabel(name: "count", dataType: .wordSigned, labelClass: .local)]
        var checked = false
        let compiler = MelsecProjectCompiler(compileST: { _, resolver in
            do {
                guard case let .local(area, _, member)? = try resolver.resolve(.plain("COUNT")) else {
                    Issue.record("count should be the local label")
                    return (nil, [])
                }
                #expect(area == .instance && member.type == .elementary(.int))
                guard case let .global(speed)? = try resolver.resolve(.plain("Speed")) else {
                    Issue.record("Speed should be global")
                    return (nil, [])
                }
                #expect(speed.place.read() == .int(5))
                guard case let .constant(_, value, type)? = try resolver.resolve(.plain("Limit")) else {
                    Issue.record("Limit should be a constant")
                    return (nil, [])
                }
                #expect(value == .int(100) && type == .int)
                guard case let .global(lamp)? = try resolver.resolve(.plain("Lamp")) else {
                    Issue.record("Lamp should resolve to Y2")
                    return (nil, [])
                }
                lamp.place.write(.bool(true))
                guard case let .global(x0)? = try resolver.resolve(.plain("X0")),
                      case let .global(bit)? = try resolver.resolve(.plain("D0.3")),
                      case let .global(t0)? = try resolver.resolve(.plain("T0")),
                      case let .global(tn0)? = try resolver.resolve(.plain("TN0")),
                      case let .global(k4)? = try resolver.resolve(.plain("K4M0")) else {
                    Issue.record("devices should resolve")
                    return (nil, [])
                }
                #expect(!x0.isWritable)
                #expect(bit.place.elementaryType == .bool)
                #expect(t0.place.elementaryType == .bool)
                #expect(tn0.place.elementaryType == .int)
                #expect(k4.place.elementaryType == .int)
                guard case let .constant(_, k10, _)? = try resolver.resolve(.plain("K10")),
                      case let .constant(_, h1f, _)? = try resolver.resolve(.plain("H1F")) else {
                    Issue.record("K and H constants should resolve")
                    return (nil, [])
                }
                #expect(k10 == .int(10) && h1f == .int(31))
                #expect(try resolver.resolve(.plain("Unknown")) == nil)
                #expect(throws: ResolveError.self) { try resolver.resolve(.plain("D9000")) }
                #expect(resolver.procedure(named: "OUT_T") != nil)
                #expect(resolver.procedure(named: "MOVP") == nil)
                checked = true
            } catch {
                Issue.record("\(error)")
            }
            return (MelsecTestBody { _ in }, [])
        })
        let output = compiler.compile(project(globals, locals: locals))
        #expect(checked)
        #expect(output.diagnostics.isEmpty)
        let image = try #require(output.image)
        #expect(image.memory.bit(.output, 2))
    }

    @Test func stInstructionFunctionsDriveTimersAndCounters() throws {
        let compiler = MelsecProjectCompiler(compileST: { _, resolver in
            guard case let .global(x0)? = try? resolver.resolve(.plain("X0")),
                  case let .global(x1)? = try? resolver.resolve(.plain("X1")),
                  case let .global(tc0)? = try? resolver.resolve(.plain("TC0")),
                  case let .global(ts0)? = try? resolver.resolve(.plain("TS0")),
                  case let .global(cc0)? = try? resolver.resolve(.plain("CC0")),
                  case let .global(y0)? = try? resolver.resolve(.plain("Y0")),
                  case let .global(d0)? = try? resolver.resolve(.plain("D0")),
                  let outT = resolver.procedure(named: "OUT_T"),
                  let outC = resolver.procedure(named: "OUT_C"),
                  let rst = resolver.procedure(named: "RST"),
                  let bcd = resolver.procedure(named: "BCD") else {
                return (nil, [Diagnostic.error("resolve failed")])
            }
            return (MelsecTestBody { frame in
                _ = try outT.run([.value(x0.place.read()), .place(tc0.place), .value(.int(10))], frame)
                y0.place.write(ts0.place.read())
                _ = try outC.run([.value(x1.place.read()), .place(cc0.place), .value(.int(2))], frame)
                _ = try rst.run([.value(.bool(x0.place.read().boolValue && x1.place.read().boolValue)), .place(cc0.place)], frame)
                _ = try bcd.run([.value(.bool(true)), .value(.int(1234)), .place(d0.place)], frame)
            }, [])
        })
        let output = compiler.compile(MelsecProject.newProject(language: .structuredText))
        let image = try #require(output.image)
        let cpu = MelsecCPU()
        cpu.load(image)
        let rig = MelsecRig(cpu: cpu)
        cpu.setMode(.run)
        rig.set("X0"); rig.scan(); rig.run(990)
        #expect(!cpu.digitalOutput(0))
        rig.scan()
        #expect(cpu.digitalOutput(0))
        #expect(rig.int("D0") == 0x1234)
        rig.set("X0", false)
        rig.set("X1"); rig.scan(); rig.set("X1", false); rig.scan(); rig.set("X1"); rig.scan()
        #expect(rig.int("CN0") == 2)
        #expect(rig.bit("CS0"))
    }

    @Test func stOperationErrorsStopTheCPU() throws {
        let compiler = MelsecProjectCompiler(compileST: { _, resolver in
            guard let bin = resolver.procedure(named: "BIN"), case let .global(d0)? = try? resolver.resolve(.plain("D0")) else {
                return (nil, [])
            }
            return (MelsecTestBody { frame in
                _ = try bin.run([.value(.bool(true)), .value(.int(0x12A4)), .place(d0.place)], frame)
            }, [])
        })
        let image = try #require(compiler.compile(MelsecProject.newProject(language: .structuredText)).image)
        let cpu = MelsecCPU()
        cpu.load(image)
        cpu.setMode(.run)
        cpu.scan(clock: 10)
        #expect(cpu.mode == .stop)
        #expect(cpu.errorMessage?.contains("BCD") == true)
    }

    @Test func stEndToEndThroughTheSTCompiler() throws {
        var project = MelsecProject.newProject(language: .structuredText)
        project.globalLabels = [MelsecLabel(name: "Total", dataType: .wordSigned)]
        project.programs[0].structuredText = """
        OUT_T(X0, TC0, 10);
        Y0 := TS0;
        IF X1 THEN
            Total := Total + K1;
        END_IF;
        MOV(X2, H1F, D1);
        D2.3 := X3;
        """
        let compiler = MelsecProjectCompiler(compileST: { source, resolver in
            let result = STCompiler.compile(source, resolver: resolver)
            return (result.program, result.diagnostics)
        })
        let output = compiler.compile(project)
        #expect(output.diagnostics.filter { $0.severity == .error }.map(\.message) == [])
        let image = try #require(output.image)
        let cpu = MelsecCPU()
        cpu.load(image)
        cpu.setMode(.run)
        let rig = MelsecRig(cpu: cpu)
        rig.set("X0"); rig.set("X1"); rig.set("X2"); rig.set("X3")
        rig.scan(); rig.run(990)
        #expect(!cpu.digitalOutput(0))
        rig.scan()
        #expect(cpu.digitalOutput(0))
        #expect(cpu.readOperand("Total") == .int(101), "one increment per scan while X1 is ON")
        #expect(rig.int("D1") == 31)
        #expect(rig.int("D2") == 8)
    }
}

struct MelsecProjectTests {
    @Test func newProjectHasOnlyEND() throws {
        let project = MelsecProject.newProject()
        #expect(project.programs.count == 1)
        #expect(project.programs[0].fileName == "MAIN")
        #expect(project.programs[0].name == "ProgPou")
        #expect(project.programs[0].language == .ladder)
        #expect(project.watchLists.map(\.name) == ["Watch 1", "Watch 2", "Watch 3", "Watch 4"])
        let output = MelsecProjectCompiler().compile(project)
        #expect(output.diagnostics.isEmpty)
        #expect(output.conversions[project.programs[0].id]?.listing(.fx5u).map(\.code) == ["END"])
        #expect(output.image != nil)
    }

    @Test func codableWithOlderFiles() throws {
        var project = MelsecProject.newProject(name: "Line 1")
        project.programs[0].ladder = try MelsecTestLadder.build(["LD X0", "OUT Y0"])
        project.globalLabels = [MelsecLabel(name: "Start", dataType: .bit, device: "X0", comment: "Start button")]
        try project.setComment("Motor", for: "y0")
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MelsecProject.self, from: data)
        #expect(decoded == project)
        #expect(decoded.comment(for: "Y0") == "Motor")
        let minimal = try JSONDecoder().decode(MelsecProject.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(minimal.programs.count == 1)
        #expect(minimal.watchLists.count == 4)
    }

    @Test func compilerReportsErrorsWithPositions() throws {
        var project = MelsecProject.newProject()
        project.programs[0].ladder = try MelsecTestLadder.build(["LD X0", "OUT Y0", "LD X9", "OUT Y1"])
        project.globalLabels = [MelsecLabel(name: "X1", dataType: .bit)]
        let output = MelsecProjectCompiler().compile(project)
        #expect(output.image == nil)
        #expect(output.diagnostics.contains { $0.block == "ProgPou" && $0.line == 2 && $0.column == 1 && $0.network == 2 })
        #expect(output.diagnostics.contains { $0.block == "Global Label" })

        var st = MelsecProject.newProject(language: .structuredText)
        st.programs[0].structuredText = "Y0 := X0;"
        #expect(MelsecProjectCompiler().compile(st).diagnostics.contains { $0.message.contains("ST compiler") })
    }

    @Test func programCheckFindingsAreReported() throws {
        var project = MelsecProject.newProject()
        project.programs[0].ladder = try MelsecTestLadder.build(["LD X0", "OUT Y0", "LD X1", "OUT Y0"])
        let output = MelsecProjectCompiler().compile(project)
        #expect(output.image != nil)
        #expect(output.findings.contains { $0.message.contains("Duplicated coil") })
    }
}

struct MelsecExerciseTests {
    /// Ladder Input sequences that draw each exercise's reference solution.
    static let ladders: [String: [String]] = [
        "gx-01-self-hold": ["LD X0", "ANI X1", "OUT Y0", "OR Y0"],
        "gx-02-interlock": ["LD X0", "ANI X2", "ANI Y1", "OUT Y0", "OR Y0",
                            "LD X1", "ANI X2", "ANI Y0", "OUT Y1", "OR Y1"],
        "gx-03-on-delay": ["LD X0", "OUT T0 K50", "LD T0", "OUT Y0"],
        "gx-04-flicker": ["LD X1", "ANI T2", "OUT T1 K10", "LD T1", "OUT T2 K10", "LD X1", "ANI T1", "OUT Y1"],
        "gx-05-traffic-light": ["LD X0", "ANI X1", "OUT M0", "OR M0",
                                "LD M0", "ANI T2", "OUT T0 K50", "LD T0", "OUT T1 K40", "LD T1", "OUT T2 K10",
                                "LD M0", "ANI T0", "OUT Y0", "LD T0", "ANI T1", "OUT Y2", "LD T1", "ANI T2", "OUT Y1"],
        "gx-06-counter": ["LD X0", "OUT C0 K5", "LD C0", "OUT Y0", "LD X1", "RST C0"],
        "gx-07-parking": ["LD X0", "INCP D0", "LD X1", "DECP D0", "LD>= D0 K10", "OUT Y0", "LD< D0 K10", "OUT Y1"],
        "gx-08-mov-compare": ["LD X0", "MOVP K100 D0", "LD X1", "MOVP K200 D0", "LD X2", "+P K10 D0",
                              "LD> D0 K150", "OUT Y0", "LD= D0 K200", "OUT Y1"],
        "gx-09-chaser": ["LD SM402", "MOV H1 D0", "LD SM412", "ROLP D0 K1", "LD SM400", "MOV D0 K4Y0"],
        "gx-10-master-control": ["LD X5", "MC N0 M50", "LD X0", "OUT Y0", "LD X1", "OUT T0 K20", "LD T0", "OUT Y1", "MCR N0"],
    ]

    static var exercises: [Exercise] { ExerciseLibrary.exercises(for: .gxWorks3) }

    private func describe(_ report: CheckReport) -> String {
        report.lines.map { "\($0.passed ? "ok" : "FAIL") @\($0.time) ms: \($0.text)" }.joined(separator: "\n")
    }

    @Test func everyExerciseHasALadder() {
        #expect(Set(Self.exercises.map(\.id)) == Set(Self.ladders.keys))
    }

    @Test(arguments: ExerciseLibrary.exercises(for: .gxWorks3).map(\.id))
    func referenceSolutionPassesAsInstructionList(_ id: String) throws {
        let exercise = try #require(Self.exercises.first { $0.id == id })
        let rig = try MelsecRig(il: exercise.solution, run: false)
        let report = ExerciseChecker.run(exercise, on: rig.cpu)
        #expect(report.passed, "\(id):\n\(describe(report))")
    }

    @Test(arguments: ExerciseLibrary.exercises(for: .gxWorks3).map(\.id))
    func ladderSolutionConvertsAndPasses(_ id: String) throws {
        let exercise = try #require(Self.exercises.first { $0.id == id })
        let inputs = try #require(Self.ladders[id])
        var project = MelsecProject.newProject(name: id)
        project.programs[0].ladder = try MelsecTestLadder.build(inputs)
        #expect(MelsecTestLadder.codes(project.programs[0].ladder) == MelsecTestLadder.codes(il: exercise.solution),
                "the ladder converts to the reference instruction list")
        let output = MelsecProjectCompiler().compile(project)
        #expect(output.diagnostics.isEmpty, "\(output.diagnostics.map(\.message))")
        let image = try #require(output.image)
        let cpu = MelsecCPU()
        cpu.load(image)
        let report = ExerciseChecker.run(exercise, on: cpu)
        #expect(report.passed, "\(id):\n\(describe(report))")
    }
}
