import Foundation

/// The TIA Portal exercises' reference solutions as real projects: the tags
/// to declare and the networks in Main [OB1], each with a title and comment.
/// The Exercises window draws them with the LAD editor's own views, and
/// SiemensExerciseTests compiles and checks these same projects, so what is
/// shown is a solution that passes.
nonisolated enum SiemensReferenceSolutions {
    /// A reference project for a TIA Portal exercise, or nil for other ids.
    static func project(for id: String) -> SiemensProject? {
        switch id {
        case "tia-01-seal-in": sealIn()
        case "tia-02-interlock": interlock()
        case "tia-03-ton": onDelay()
        case "tia-04-flasher": flasher()
        case "tia-05-traffic-light": trafficLight()
        case "tia-06-batch-counter": batchCounter()
        case "tia-07-storage": storage()
        case "tia-08-star-delta": starDelta()
        case "tia-09-analog-level": analogLevel()
        case "tia-10-scl-traffic-light": sclTrafficLight()
        default: nil
        }
    }

    /// The tags each reference declares, in table order.
    static func declaredTags(in project: SiemensProject) -> [SiemensTag] {
        project.tagTables.flatMap(\.tags).filter { !systemTagNames.contains($0.name) }
    }

    /// Tags a new project already has (system and clock memory).
    private static let systemTagNames: Set<String> = Set(SiemensProject.newProject().tagTables.flatMap(\.tags).map(\.name))

    // MARK: Exercises

    private static func sealIn() -> SiemensProject {
        make(tags: [("S1_Start", .bool, "%I0.0"), ("S2_Stop", .bool, "%I0.1"), ("K1_Motor", .bool, "%Q0.0"), ("H1_Running", .bool, "%Q0.1")]) { _ in
            [
                LAD.net(LAD.par([LAD.no("\"S1_Start\"")], [LAD.no("\"K1_Motor\"")]), LAD.no("\"S2_Stop\""),
                        LAD.coil("\"K1_Motor\""), LAD.coil("\"H1_Running\""))
                    .titled("Motor with seal-in",
                            "S1_Start switches K1_Motor on. The K1_Motor contact in parallel with S1_Start holds it on after S1 is released. "
                                + "S2_Stop is wired normally closed, so its normally open contact opens when S2 is pressed, and Stop wins. "
                                + "H1_Running follows the motor."),
            ]
        }
    }

    private static func interlock() -> SiemensProject {
        make(tags: [("S1_Forward", .bool, "%I0.0"), ("S2_Reverse", .bool, "%I0.1"), ("S0_Stop", .bool, "%I0.2"),
                    ("K1_Forward", .bool, "%Q0.0"), ("K2_Reverse", .bool, "%Q0.1")]) { _ in
            [
                LAD.net(LAD.par([LAD.no("\"S1_Forward\"")], [LAD.no("\"K1_Forward\"")]), LAD.no("\"S0_Stop\""), LAD.nc("\"K2_Reverse\""),
                        LAD.coil("\"K1_Forward\""))
                    .titled("Forward", "Seal-in on K1_Forward. The normally closed K2_Reverse contact is the interlock: forward can't start while reverse runs."),
                LAD.net(LAD.par([LAD.no("\"S2_Reverse\"")], [LAD.no("\"K2_Reverse\"")]), LAD.no("\"S0_Stop\""), LAD.nc("\"K1_Forward\""),
                        LAD.coil("\"K2_Reverse\""))
                    .titled("Reverse", "The same with the roles swapped: the normally closed K1_Forward contact blocks reverse while forward runs."),
            ]
        }
    }

    private static func onDelay() -> SiemensProject {
        make(tags: [("S1_Switch", .bool, "%I0.0"), ("H1_Lamp", .bool, "%Q0.0")]) { project in
            let timer = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            return [
                LAD.net(LAD.no("\"S1_Switch\""), LAD.box(.onDelayTimer, instance: timer, ["PT": "T#5S"]), LAD.coil("\"H1_Lamp\""))
                    .titled("Lamp on 5 s after the switch",
                            "TON: Q turns on once IN has been on for PT = 5 s, and off at once when IN turns off. "
                                + "Placing the TON creates its instance data block (Call options)."),
            ]
        }
    }

    private static func flasher() -> SiemensProject {
        make(tags: [("S1_Alarm", .bool, "%I0.0"), ("H1_Warning", .bool, "%Q0.0")]) { _ in
            [
                LAD.net(LAD.no("\"S1_Alarm\""), LAD.no("\"Clock_1Hz\""), LAD.coil("\"H1_Warning\""))
                    .titled("Warning light flashes at 1 Hz",
                            "Clock_1Hz (%M0.5) is a clock memory bit that the CPU switches on and off once a second. "
                                + "In series with S1_Alarm, it makes the lamp flash only while the alarm is on."),
            ]
        }
    }

    private static func trafficLight() -> SiemensProject {
        make(tags: [("S1_Start", .bool, "%I0.0"), ("S2_Stop", .bool, "%I0.1"), ("Red", .bool, "%Q0.0"),
                    ("Amber", .bool, "%Q0.1"), ("Green", .bool, "%Q0.2"), ("Run", .bool, "%M10.0")]) { project in
            let t1 = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            let t2 = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            let t3 = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            return [
                LAD.net(LAD.par([LAD.no("\"S1_Start\"")], [LAD.no("\"Run\"")]), LAD.no("\"S2_Stop\""), LAD.coil("\"Run\""))
                    .titled("Run with seal-in", "Run is a memory bit that stays on from Start until Stop."),
                LAD.net(LAD.no("\"Run\""), LAD.nc(t3 + ".Q"), LAD.box(.onDelayTimer, instance: t1, ["PT": "T#5S"]))
                    .titled("Red phase: 5 s", "The first timer. When the last timer finishes, its Q breaks this rung for one cycle, which restarts the sequence."),
                LAD.net(LAD.no(t1 + ".Q"), LAD.box(.onDelayTimer, instance: t2, ["PT": "T#4S"]))
                    .titled("Green phase: 4 s", "Starts when the red phase is over."),
                LAD.net(LAD.no(t2 + ".Q"), LAD.box(.onDelayTimer, instance: t3, ["PT": "T#1S"]))
                    .titled("Amber phase: 1 s", "Starts when the green phase is over."),
                LAD.net(LAD.no("\"Run\""), LAD.nc(t1 + ".Q"), LAD.coil("\"Red\""))
                    .titled("Red lamp", "On while running and the red phase hasn't finished."),
                LAD.net(LAD.no(t1 + ".Q"), LAD.nc(t2 + ".Q"), LAD.coil("\"Green\""))
                    .titled("Green lamp", "Between the end of red and the end of green."),
                LAD.net(LAD.no(t2 + ".Q"), LAD.nc(t3 + ".Q"), LAD.coil("\"Amber\""))
                    .titled("Amber lamp", "Between the end of green and the end of amber."),
            ]
        }
    }

    private static func batchCounter() -> SiemensProject {
        make(tags: [("B1_Part", .bool, "%I0.0"), ("S1_Reset", .bool, "%I0.1"), ("H1_BatchComplete", .bool, "%Q0.0")]) { project in
            let counter = project.createInstanceDataBlock(for: .countUp) ?? ""
            return [
                LAD.net(LAD.no("\"B1_Part\""), LAD.box(.countUp, instance: counter, type: .int, ["R": "\"S1_Reset\"", "PV": "5"]),
                        LAD.coil("\"H1_BatchComplete\""))
                    .titled("Count parts in batches of 5",
                            "CTU adds 1 to CV on each rising edge at CU. Q turns on when CV reaches PV = 5. S1_Reset at R sets CV back to 0."),
            ]
        }
    }

    private static func storage() -> SiemensProject {
        make(tags: [("PEB1", .bool, "%I0.0"), ("PEB2", .bool, "%I0.1"), ("RESET", .bool, "%I0.2"),
                    ("STOR_EMPTY", .bool, "%Q0.0"), ("STOR_NOT_EMPTY", .bool, "%Q0.1"), ("STOR_FULL", .bool, "%Q0.2")]) { project in
            let counter = project.createInstanceDataBlock(for: .countUpDown) ?? ""
            return [
                LAD.net(LAD.no("\"PEB1\""),
                        LAD.box(.countUpDown, instance: counter, ["PV": "10", "QD": "\"STOR_EMPTY\""],
                                branches: ["CD": [LAD.no("\"PEB2\"")], "R": [LAD.no("\"RESET\"")]]),
                        LAD.coil("\"STOR_FULL\""))
                    .titled("Count parts in and out",
                            "PEB1 (part in) counts up at CU, PEB2 (part out) counts down at CD, RESET clears the count. "
                                + "QU (CV >= PV = 10) drives STOR_FULL; QD (CV <= 0) is written to STOR_EMPTY."),
                LAD.net(LAD.nc(counter + ".QD"), LAD.coil("\"STOR_NOT_EMPTY\""))
                    .titled("Storage not empty", "The opposite of QD, read from the counter's instance data block."),
            ]
        }
    }

    private static func starDelta() -> SiemensProject {
        make(tags: [("S1_Start", .bool, "%I0.0"), ("S0_Stop", .bool, "%I0.1"), ("K1_Main", .bool, "%Q0.0"),
                    ("K2_Star", .bool, "%Q0.1"), ("K3_Delta", .bool, "%Q0.2")]) { project in
            let star = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            let pause = project.createInstanceDataBlock(for: .onDelayTimer) ?? ""
            return [
                LAD.net(LAD.par([LAD.no("\"S1_Start\"")], [LAD.no("\"K1_Main\"")]), LAD.no("\"S0_Stop\""), LAD.coil("\"K1_Main\""))
                    .titled("Main contactor with seal-in", "K1_Main stays on from Start until Stop."),
                LAD.net(LAD.no("\"K1_Main\""), LAD.box(.onDelayTimer, instance: star, ["PT": "T#5S"]))
                    .titled("Star time: 5 s", "The motor runs up in star for 5 s."),
                LAD.net(LAD.no(star + ".Q"), LAD.box(.onDelayTimer, instance: pause, ["PT": "T#100MS"]))
                    .titled("Changeover pause: 100 ms", "Star must drop out before delta pulls in."),
                LAD.net(LAD.no("\"K1_Main\""), LAD.nc(star + ".Q"), LAD.nc("\"K3_Delta\""), LAD.coil("\"K2_Star\""))
                    .titled("Star contactor", "On until the star time ends. The normally closed K3_Delta contact is the interlock."),
                LAD.net(LAD.no(pause + ".Q"), LAD.nc("\"K2_Star\""), LAD.coil("\"K3_Delta\""))
                    .titled("Delta contactor", "On after the pause. The normally closed K2_Star contact is the interlock."),
            ]
        }
    }

    private static func analogLevel() -> SiemensProject {
        var project = make(tags: [("Level", .real, "%MD20"), ("H1_High", .bool, "%Q0.0"), ("H2_Low", .bool, "%Q0.1")]) { _ in
            [
                LAD.net(LAD.box(.normalize, type: .int, to: .real, ["MIN": "0", "VALUE": "%IW64", "MAX": "27648", "OUT": "#norm"]),
                        LAD.box(.scale, type: .real, to: .real, ["MIN": "0.0", "VALUE": "#norm", "MAX": "100.0", "OUT": "\"Level\""]))
                    .titled("Level in percent",
                            "NORM_X turns the raw analog value (0 to 27648) into 0.0 to 1.0 in the temp variable #norm. "
                                + "SCALE_X turns that into 0.0 to 100.0 % in Level."),
                LAD.net(LAD.cmp("\"Level\"", .greaterOrEqual, "80.0"), LAD.coil("\"H1_High\""))
                    .titled("High level: 80 % or more", ""),
                LAD.net(LAD.cmp("\"Level\"", .lessOrEqual, "20.0"), LAD.coil("\"H2_Low\""))
                    .titled("Low level: 20 % or less", ""),
            ]
        }
        project.blocks[0].interface.temp = [SiemensVariable("norm", "Real")]
        return project
    }

    /// The SCL function block of exercise 10.
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

    private static func sclTrafficLight() -> SiemensProject {
        var fb = SiemensBlock(name: "TrafficLight", kind: .functionBlock, number: 1, language: .scl, source: trafficLightSource)
        fb.interface.input = [SiemensVariable("Start", "Bool"), SiemensVariable("Stop", "Bool")]
        fb.interface.output = [SiemensVariable("Red", "Bool"), SiemensVariable("Amber", "Bool"), SiemensVariable("Green", "Bool")]
        fb.interface.staticVariables = [SiemensVariable("state", "Int"), SiemensVariable("timer", "TON_TIME")]
        fb.interface.temp = [SiemensVariable("preset", "Time")]
        return make(tags: [("S1_Start", .bool, "%I0.0"), ("S2_Stop", .bool, "%I0.1"), ("Red", .bool, "%Q0.0"),
                           ("Amber", .bool, "%Q0.1"), ("Green", .bool, "%Q0.2")]) { project in
            project.blocks.append(fb)
            _ = project.addInstanceDataBlock(of: "TrafficLight")
            return [
                LAD.net(LAD.call(fb, instance: "\"TrafficLight_DB\"", ["Start": "\"S1_Start\"", "Stop": "\"S2_Stop\"", "Red": "\"Red\"",
                                                                       "Amber": "\"Amber\"", "Green": "\"Green\""]))
                    .titled("Call the traffic light", "TrafficLight [FB1] is written in SCL. Its state and timer live in the instance data block TrafficLight_DB."),
            ]
        }
    }

    // MARK: Building

    private static func make(tags: [(String, PLCDataType, String)],
                             networks: (inout SiemensProject) -> [S7Network]) -> SiemensProject {
        var project = SiemensProject.newProject()
        for (name, type, address) in tags {
            _ = project.addTag(SiemensTag(name, type, address))
        }
        project.blocks[0].networks = networks(&project)
        return project
    }
}

nonisolated extension S7Network {
    /// The same network with a title and comment, as shown in the LAD editor.
    func titled(_ title: String, _ comment: String) -> S7Network {
        var network = self
        network.title = title
        network.comment = comment
        return network
    }
}
