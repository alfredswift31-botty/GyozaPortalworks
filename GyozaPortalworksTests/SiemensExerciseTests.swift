import Foundation
import Testing
@testable import GyozaPortalworks

/// Every TIA Portal exercise, programmed the way the reference solution
/// describes it, compiled by the project compiler and checked on the CPU.
struct SiemensExerciseTests {
    static let compileSCL: (String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]) = { source, resolver in
        let result = STCompiler.compile(source, resolver: resolver)
        let body: ExecutableBody? = result.program
        return (body, result.diagnostics)
    }

    static let trafficLightSource = """
        IF NOT #Stop THEN
            #state := 0;
        ELSIF #Start AND #state = 0 THEN
            #state := 1;
        END_IF;
        CASE #state OF
            1: #preset := T#5S;
            2: #preset := T#4S;
            3: #preset := T#1S;
        ELSE
            #preset := T#0S;
        END_CASE;
        #timer(IN := #state <> 0, PT := #preset);
        IF #timer.Q THEN
            #state := #state MOD 3 + 1;
            #timer(IN := FALSE, PT := #preset);
        END_IF;
        #Red := #state = 1;
        #Green := #state = 2;
        #Amber := #state = 3;
        """

    private func tags(_ list: [(String, PLCDataType, String)]) -> [SiemensTag] {
        list.map { SiemensTag($0.0, $0.1, $0.2) }
    }

    private func check(_ id: String, _ bench: SiemensBench) throws {
        let exercise = try #require(ExerciseLibrary.exercises(for: .tiaPortal).first { $0.id == id })
        try bench.load()
        let report = ExerciseChecker.run(exercise, on: bench.cpu)
        #expect(report.passed, "\(id): \(report.firstFailure?.text ?? "no checks ran")")
    }

    @Test func sealIn() throws {
        let bench = SiemensBench([
            LAD.net(LAD.par([LAD.no("\"S1_Start\"")], [LAD.no("\"K1_Motor\"")]), LAD.no("\"S2_Stop\""),
                    LAD.coil("\"K1_Motor\""), LAD.coil("\"H1_Running\"")),
        ], tags: tags([("S1_Start", .bool, "%I0.0"), ("S2_Stop", .bool, "%I0.1"), ("K1_Motor", .bool, "%Q0.0"), ("H1_Running", .bool, "%Q0.1")]))
        try check("tia-01-seal-in", bench)
    }

    @Test func forwardReverseInterlock() throws {
        let bench = SiemensBench([
            LAD.net(LAD.par([LAD.no("\"S1_Forward\"")], [LAD.no("\"K1_Forward\"")]), LAD.no("\"S0_Stop\""), LAD.nc("\"K2_Reverse\""),
                    LAD.coil("\"K1_Forward\"")),
            LAD.net(LAD.par([LAD.no("\"S2_Reverse\"")], [LAD.no("\"K2_Reverse\"")]), LAD.no("\"S0_Stop\""), LAD.nc("\"K1_Forward\""),
                    LAD.coil("\"K2_Reverse\"")),
        ], tags: tags([("S1_Forward", .bool, "%I0.0"), ("S2_Reverse", .bool, "%I0.1"), ("S0_Stop", .bool, "%I0.2"),
                       ("K1_Forward", .bool, "%Q0.0"), ("K2_Reverse", .bool, "%Q0.1")]))
        try check("tia-02-interlock", bench)
    }

    @Test func onDelayTimer() throws {
        let bench = SiemensBench([], tags: tags([("S1_Switch", .bool, "%I0.0"), ("H1_Lamp", .bool, "%Q0.0")])) { project in
            let timer = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            project.blocks[0].networks = [
                LAD.net(LAD.no("\"S1_Switch\""), LAD.box(.onDelayTimer, instance: timer, ["PT": "T#5S"]), LAD.coil("\"H1_Lamp\"")),
            ]
        }
        try check("tia-03-ton", bench)
    }

    @Test func flasherWithClockMemory() throws {
        let bench = SiemensBench([LAD.net(LAD.no("\"S1_Alarm\""), LAD.no("\"Clock_1Hz\""), LAD.coil("\"H1_Warning\""))],
                                 tags: tags([("S1_Alarm", .bool, "%I0.0"), ("H1_Warning", .bool, "%Q0.0")]))
        try check("tia-04-flasher", bench)
    }

    @Test func trafficLightWithCascadedTimers() throws {
        let bench = SiemensBench([], tags: tags([("S1_Start", .bool, "%I0.0"), ("S2_Stop", .bool, "%I0.1"), ("Red", .bool, "%Q0.0"),
                                                 ("Amber", .bool, "%Q0.1"), ("Green", .bool, "%Q0.2"), ("Run", .bool, "%M10.0")])) { project in
            let t1 = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            let t2 = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            let t3 = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            project.blocks[0].networks = [
                LAD.net(LAD.par([LAD.no("\"S1_Start\"")], [LAD.no("\"Run\"")]), LAD.no("\"S2_Stop\""), LAD.coil("\"Run\"")),
                LAD.net(LAD.no("\"Run\""), LAD.nc(t3 + ".Q"), LAD.box(.onDelayTimer, instance: t1, ["PT": "T#5S"])),
                LAD.net(LAD.no(t1 + ".Q"), LAD.box(.onDelayTimer, instance: t2, ["PT": "T#4S"])),
                LAD.net(LAD.no(t2 + ".Q"), LAD.box(.onDelayTimer, instance: t3, ["PT": "T#1S"])),
                LAD.net(LAD.no("\"Run\""), LAD.nc(t1 + ".Q"), LAD.coil("\"Red\"")),
                LAD.net(LAD.no(t1 + ".Q"), LAD.nc(t2 + ".Q"), LAD.coil("\"Green\"")),
                LAD.net(LAD.no(t2 + ".Q"), LAD.nc(t3 + ".Q"), LAD.coil("\"Amber\"")),
            ]
        }
        try check("tia-05-traffic-light", bench)
    }

    @Test func batchCounter() throws {
        let bench = SiemensBench([], tags: tags([("B1_Part", .bool, "%I0.0"), ("S1_Reset", .bool, "%I0.1"),
                                                 ("H1_BatchComplete", .bool, "%Q0.0")])) { project in
            let counter = project.createInstanceDataBlock(for: .countUp) ?? ""
            project.blocks[0].networks = [
                LAD.net(LAD.no("\"B1_Part\""), LAD.box(.countUp, instance: counter, type: .int, ["R": "\"S1_Reset\"", "PV": "5"]),
                        LAD.coil("\"H1_BatchComplete\"")),
            ]
        }
        try check("tia-06-batch-counter", bench)
    }

    @Test func storageAreaWithUpDownCounter() throws {
        let bench = SiemensBench([], tags: tags([("PEB1", .bool, "%I0.0"), ("PEB2", .bool, "%I0.1"), ("RESET", .bool, "%I0.2"),
                                                 ("STOR_EMPTY", .bool, "%Q0.0"), ("STOR_NOT_EMPTY", .bool, "%Q0.1"),
                                                 ("STOR_FULL", .bool, "%Q0.2")])) { project in
            let counter = project.createInstanceDataBlock(for: .countUpDown) ?? ""
            project.blocks[0].networks = [
                LAD.net(LAD.no("\"PEB1\""),
                        LAD.box(.countUpDown, instance: counter, ["PV": "10", "QD": "\"STOR_EMPTY\""],
                                branches: ["CD": [LAD.no("\"PEB2\"")], "R": [LAD.no("\"RESET\"")]]),
                        LAD.coil("\"STOR_FULL\"")),
                LAD.net(LAD.nc(counter + ".QD"), LAD.coil("\"STOR_NOT_EMPTY\"")),
            ]
        }
        try check("tia-07-storage", bench)
    }

    @Test func starDeltaStarter() throws {
        let bench = SiemensBench([], tags: tags([("S1_Start", .bool, "%I0.0"), ("S0_Stop", .bool, "%I0.1"), ("K1_Main", .bool, "%Q0.0"),
                                                 ("K2_Star", .bool, "%Q0.1"), ("K3_Delta", .bool, "%Q0.2")])) { project in
            let star = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            let pause = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            project.blocks[0].networks = [
                LAD.net(LAD.par([LAD.no("\"S1_Start\"")], [LAD.no("\"K1_Main\"")]), LAD.no("\"S0_Stop\""), LAD.coil("\"K1_Main\"")),
                LAD.net(LAD.no("\"K1_Main\""), LAD.box(.onDelayTimer, instance: star, ["PT": "T#5S"])),
                LAD.net(LAD.no(star + ".Q"), LAD.box(.onDelayTimer, instance: pause, ["PT": "T#100MS"])),
                LAD.net(LAD.no("\"K1_Main\""), LAD.nc(star + ".Q"), LAD.nc("\"K3_Delta\""), LAD.coil("\"K2_Star\"")),
                LAD.net(LAD.no(pause + ".Q"), LAD.nc("\"K2_Star\""), LAD.coil("\"K3_Delta\"")),
            ]
        }
        try check("tia-08-star-delta", bench)
    }

    @Test func analogLevelWithNormAndScale() throws {
        let bench = SiemensBench([
            LAD.net(LAD.box(.normalize, type: .int, to: .real, ["MIN": "0", "VALUE": "%IW64", "MAX": "27648", "OUT": "#norm"]),
                    LAD.box(.scale, type: .real, to: .real, ["MIN": "0.0", "VALUE": "#norm", "MAX": "100.0", "OUT": "\"Level\""])),
            LAD.net(LAD.cmp("\"Level\"", .greaterOrEqual, "80.0"), LAD.coil("\"H1_High\"")),
            LAD.net(LAD.cmp("\"Level\"", .lessOrEqual, "20.0"), LAD.coil("\"H2_Low\"")),
        ], tags: tags([("Level", .real, "%MD20"), ("H1_High", .bool, "%Q0.0"), ("H2_Low", .bool, "%Q0.1")])) { project in
            project.blocks[0].interface.temp = [SiemensVariable("norm", "Real")]
        }
        try check("tia-09-analog-level", bench)
    }

    /// The SCL FB is compiled by the real SCL engine through SiemensSymbolResolver.
    private func trafficLightBench() -> SiemensBench {
        var fb = SiemensBlock(name: "TrafficLight", kind: .functionBlock, number: 1, language: .scl, source: Self.trafficLightSource)
        fb.interface.input = [SiemensVariable("Start", "Bool"), SiemensVariable("Stop", "Bool")]
        fb.interface.output = [SiemensVariable("Red", "Bool"), SiemensVariable("Amber", "Bool"), SiemensVariable("Green", "Bool")]
        fb.interface.staticVariables = [SiemensVariable("state", "Int"), SiemensVariable("timer", "TON_TIME")]
        fb.interface.temp = [SiemensVariable("preset", "Time")]
        let bench = SiemensBench([
            LAD.net(LAD.call(fb, instance: "\"TrafficLight_DB\"", ["Start": "\"S1_Start\"", "Stop": "\"S2_Stop\"", "Red": "\"Red\"",
                                                                   "Amber": "\"Amber\"", "Green": "\"Green\""])),
        ], tags: tags([("S1_Start", .bool, "%I0.0"), ("S2_Stop", .bool, "%I0.1"), ("Red", .bool, "%Q0.0"),
                       ("Amber", .bool, "%Q0.1"), ("Green", .bool, "%Q0.2")])) { project in
            project.blocks.append(fb)
            project.addInstanceDataBlock(of: "TrafficLight")
        }
        bench.compileSCL = Self.compileSCL
        return bench
    }

    @Test func sclTrafficLightStateMachine() throws {
        try check("tia-10-scl-traffic-light", trafficLightBench())
    }

    @Test func sclFunctionBlockRunsEndToEnd() throws {
        let bench = trafficLightBench()
        let result = try bench.load()
        #expect(result.succeeded, "\(result.messageTexts)")
        #expect(result.messages.contains { $0.path == "TrafficLight (FB1)" && $0.text == S7Messages.blockCompiled })
        bench.cpu.setMode(.run)
        bench.input("%I0.1", true, scans: 5)
        #expect(bench.int("\"TrafficLight_DB\".state") == 0)
        bench.pulse("%I0.0")
        #expect(bench.int("\"TrafficLight_DB\".state") == 1)
        #expect(bench.cpu.digitalOutput(0))
        bench.wait(3_000)
        #expect(bench.value("\"TrafficLight_DB\".timer.ET").map { $0.intValue >= 2_900 } == true)
        bench.wait(2_100)
        #expect(bench.int("\"TrafficLight_DB\".state") == 2)
        #expect(bench.cpu.digitalOutput(2) && !bench.cpu.digitalOutput(0))
        bench.input("%I0.1", false)
        #expect(bench.int("\"TrafficLight_DB\".state") == 0)
        #expect(!bench.cpu.digitalOutput(0) && !bench.cpu.digitalOutput(1) && !bench.cpu.digitalOutput(2))

        // An error in the SCL source is reported against the FB with its line.
        let broken = trafficLightBench()
        broken.project.blocks[1].source = "#state := #nothing;"
        let failed = broken.compile()
        #expect(!failed.succeeded)
        #expect(failed.diagnostics.contains { $0.block == "TrafficLight [FB1]" && $0.line == 1 })
    }
}
