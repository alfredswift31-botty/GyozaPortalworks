import Foundation

/// The practice tasks for both tools. Board wiring follows each controller:
/// on the CPU 1214C, board inputs 0–13 are %I0.0–%I1.5 and outputs 0–9 are
/// %Q0.0–%Q1.1; on the FX5U, inputs 0–15 are X0–X17 and outputs 0–15 are
/// Y0–Y17 (octal). Every check leaves a margin of several scans around each
/// timed transition.
nonisolated enum ExerciseLibrary {
    static func exercises(for environment: PracticeEnvironment) -> [Exercise] {
        switch environment {
        case .tiaPortal: return siemens
        case .gxWorks3: return melsec
        }
    }

    static var all: [Exercise] { siemens + melsec }

    // MARK: - Shared scenarios

    /// Start/stop with seal-in. `stopIndex` is actuated to stop.
    private static func sealInSteps(start: Int, stop: Int, lamp: Int?) -> [CheckStep] {
        var steps: [CheckStep] = [
            .wait(50),
            .expectOutput(0, false, "the motor is off before Start is pressed."),
            .actuate(start), .wait(50), .release(start), .wait(50),
            .expectOutput(0, true, "the motor keeps running after Start is released (seal-in)."),
        ]
        if let lamp {
            steps.append(.expectOutput(lamp, true, "the lamp shows that the motor runs."))
        }
        steps += [
            .actuate(stop), .wait(50),
            .expectOutput(0, false, "Stop switches the motor off."),
            .release(stop), .wait(50),
            .expectOutput(0, false, "the motor stays off after Stop is released."),
            .actuate(start), .actuate(stop), .wait(50),
            .expectOutput(0, false, "Stop wins when both buttons are pressed."),
            .release(start), .release(stop), .wait(50),
            .expectOutput(0, false, "releasing both buttons doesn't restart the motor."),
        ]
        return steps
    }

    private static func interlockSteps(forward: Int, reverse: Int, stop: Int) -> [CheckStep] {
        [
            .actuate(forward), .wait(50), .release(forward), .wait(50),
            .expectOutput(0, true, "Forward starts and seals in."),
            .expectOutput(1, false, "Reverse stays off."),
            .actuate(reverse), .wait(50), .release(reverse), .wait(50),
            .expectOutput(1, false, "Reverse is locked out while Forward runs."),
            .expectOutput(0, true, "Forward keeps running."),
            .actuate(stop), .wait(50), .release(stop), .wait(50),
            .expectOutput(0, false, "Stop switches Forward off."),
            .actuate(reverse), .wait(50), .release(reverse), .wait(50),
            .expectOutput(1, true, "Reverse starts and seals in."),
            .actuate(forward), .wait(50), .release(forward), .wait(50),
            .expectOutput(0, false, "Forward is locked out while Reverse runs."),
            .actuate(stop), .wait(50), .release(stop), .wait(50),
            .expectOutput(1, false, "Stop switches Reverse off."),
        ]
    }

    private static func onDelaySteps(switchIndex: Int) -> [CheckStep] {
        [
            .expectOutput(0, false, "the lamp is off while the switch is off."),
            .actuate(switchIndex), .wait(4_850),
            .expectOutput(0, false, "the lamp stays off for the first 5 s."),
            .wait(300),
            .expectOutput(0, true, "the lamp lights 5 s after the switch turns on."),
            .release(switchIndex), .wait(50),
            .expectOutput(0, false, "the lamp goes out as soon as the switch turns off."),
            .actuate(switchIndex), .wait(2_000), .release(switchIndex), .wait(50),
            .actuate(switchIndex), .wait(4_000),
            .expectOutput(0, false, "the delay starts again from zero each time the switch turns on."),
            .wait(1_200),
            .expectOutput(0, true, "the lamp lights after a full 5 s."),
        ]
    }

    /// Red 5 s → green 4 s → amber 1 s, repeating. Outputs: red, amber, green.
    private static func trafficLightSteps(start: Int, stop: Int, red: Int, amber: Int, green: Int) -> [CheckStep] {
        [
            .expectOutput(red, false, "all lights are off before Start."),
            .actuate(start), .wait(50), .release(start), .wait(100),
            .expectOutput(red, true, "the cycle starts with red."),
            .expectOutput(green, false, "green is off during red."),
            .wait(5_000),
            .expectOutput(red, false, "red lasts 5 s."),
            .expectOutput(green, true, "green follows red."),
            .wait(4_000),
            .expectOutput(green, false, "green lasts 4 s."),
            .expectOutput(amber, true, "amber follows green."),
            .wait(1_000),
            .expectOutput(amber, false, "amber lasts 1 s."),
            .expectOutput(red, true, "the cycle repeats with red."),
            .actuate(stop), .wait(100),
            .expectOutput(red, false, "Stop switches the lights off."),
            .expectOutput(green, false, "Stop switches the lights off."),
            .expectOutput(amber, false, "Stop switches the lights off."),
        ]
    }

    private static func pulses(_ index: Int, count: Int) -> [CheckStep] {
        Array(repeating: [CheckStep.actuate(index), .wait(50), .release(index), .wait(50)], count: count).flatMap { $0 }
    }

    /// Joins scenario parts; keeps long scenarios cheap to type-check.
    private static func sequence(_ parts: [CheckStep]...) -> [CheckStep] {
        parts.flatMap { $0 }
    }

    // MARK: - TIA Portal

    private static let siemens: [Exercise] = [
        Exercise(
            id: "tia-01-seal-in", environment: .tiaPortal, number: 1,
            title: "Motor start/stop with seal-in", level: .beginner,
            skills: ["Contacts and coils", "Seal-in", "NC-wired stop"],
            goal: """
            In Main [OB1] (LAD), build one network: pressing S1 starts motor contactor K1, and K1 keeps running after S1 is released. S2 stops it, and Stop must win if both buttons are pressed. Lamp H1 shows that the motor runs.

            S2 is wired normally closed, as stop buttons are for safety: %I0.1 is TRUE until S2 is pressed. That means you program it with a normally open contact.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "S1 Start", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "S2 Stop (NC)", device: .pushButtonNC),
                IOAssignment(point: .digitalOutput(0), label: "K1 Motor", device: .motor),
                IOAssignment(point: .digitalOutput(1), label: "H1 Running", device: .lamp),
            ],
            hints: [
                "Declare tags first (PLC tags › Default tag table): S1_Start %I0.0, S2_Stop %I0.1, K1_Motor %Q0.0, H1_Running %Q0.1.",
                "Put a normally open contact for K1_Motor in parallel with S1_Start: that branch holds the coil on (seal-in).",
                "Put S2_Stop in series after the parallel branch. Because it's wired NC, its normally open contact opens when S2 is pressed.",
                "A second coil for H1_Running can follow the motor coil on the same rung: on an S7-1200, coils may sit mid-rung.",
            ],
            solution: """
            Network 1: Motor with seal-in
            ──┬──| |──┬──| |──────( )──────( )
              │ "S1_Start" │ "S2_Stop"   "K1_Motor"   "H1_Running"
              └──| |──┘
                 "K1_Motor"
            """,
            steps: sealInSteps(start: 0, stop: 1, lamp: 1)
        ),
        Exercise(
            id: "tia-02-interlock", environment: .tiaPortal, number: 2,
            title: "Forward/reverse with interlock", level: .beginner,
            skills: ["Seal-in", "Interlocking", "NC contacts"],
            goal: """
            A conveyor runs forward (K1) or in reverse (K2). S1 starts forward and S2 starts reverse, each sealing in. S0 stops either direction.

            K1 and K2 must never be on together: while one direction runs, the other start button does nothing. This is the interlock. S0 is wired normally closed.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "S1 Forward", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "S2 Reverse", device: .pushButton),
                IOAssignment(point: .digitalInput(2), label: "S0 Stop (NC)", device: .pushButtonNC),
                IOAssignment(point: .digitalOutput(0), label: "K1 Forward", device: .motor),
                IOAssignment(point: .digitalOutput(1), label: "K2 Reverse", device: .motor),
            ],
            hints: [
                "Build one seal-in network per direction.",
                "In the forward rung, add a normally closed contact of K2_Reverse; in the reverse rung, a normally closed contact of K1_Forward.",
            ],
            solution: """
            Network 1: Forward
            ──┬──| |──┬──| |──|/|──( )
              │"S1_Forward"│"S0_Stop" "K2_Reverse" "K1_Forward"
              └──| |──┘
                 "K1_Forward"
            Network 2: Reverse
            ──┬──| |──┬──| |──|/|──( )
              │"S2_Reverse"│"S0_Stop" "K1_Forward" "K2_Reverse"
              └──| |──┘
                 "K2_Reverse"
            """,
            steps: interlockSteps(forward: 0, reverse: 1, stop: 2)
        ),
        Exercise(
            id: "tia-03-ton", environment: .tiaPortal, number: 3,
            title: "Delayed start with TON", level: .beginner,
            skills: ["IEC timers", "Instance DBs"],
            goal: """
            While switch S1 is on, lamp H1 lights after 5 seconds. Switching S1 off turns H1 off at once, and the next start waits a full 5 s again.

            Use a TON (on-delay) box. When you drop it into the network, TIA Portal asks for an instance data block: accept IEC_Timer_0_DB.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "S1 Switch", device: .selectorSwitch),
                IOAssignment(point: .digitalOutput(0), label: "H1 Lamp", device: .lamp),
            ],
            hints: [
                "Instructions › Basic instructions › Timer operations › TON.",
                "Wire S1 to IN, set PT to T#5S, and put the H1 coil on Q.",
            ],
            solution: """
            Network 1: 5 s delay
                          %DB1 "IEC_Timer_0_DB"
                            ┌───TON───┐
            ──| |───────────┤IN      Q├──────( )
             "S1_Switch" T#5S┤PT     ET├     "H1_Lamp"
                            └─────────┘
            """,
            steps: onDelaySteps(switchIndex: 0)
        ),
        Exercise(
            id: "tia-04-flasher", environment: .tiaPortal, number: 4,
            title: "Flashing warning light", level: .beginner,
            skills: ["Clock memory", "System and clock memory bits"],
            goal: """
            While S1 is on, warning light H1 flashes at 1 Hz (0.5 s on, 0.5 s off). While S1 is off, H1 stays off.

            The CPU's clock memory byte (MB0) supplies ready-made flashing bits. Clock_1Hz is %M0.5.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "S1 Alarm", device: .selectorSwitch),
                IOAssignment(point: .digitalOutput(0), label: "H1 Warning", device: .lamp),
            ],
            hints: [
                "Clock memory is enabled under PLC_1 › Device configuration › System and clock memory. The tags are already in the default tag table.",
                "Put S1 and Clock_1Hz in series before the H1 coil.",
            ],
            solution: """
            Network 1: Flash at 1 Hz
            ──| |────────| |────────( )
             "S1_Alarm"  "Clock_1Hz"  "H1_Warning"
            """,
            steps: [
                .actuate(0),
                .expectTransitions(0, min: 5, max: 7, within: 3_000, "it flashes about once a second while S1 is on."),
                .release(0), .wait(100),
                .expectOutput(0, false, "it goes out when S1 is off."),
                .expectTransitions(0, min: 0, max: 0, within: 1_500, "it stays off while S1 is off."),
            ]
        ),
        Exercise(
            id: "tia-05-traffic-light", environment: .tiaPortal, number: 5,
            title: "Traffic light sequence", level: .intermediate,
            skills: ["Cascaded timers", "Run bit"],
            goal: """
            S1 starts a repeating sequence and S2 stops it with all lights off. The sequence is: red 5 s → green 4 s → amber 1 s → red again.

            S2 is wired normally closed. Use a seal-in run bit such as %M10.0 and three TON timers, each starting when the previous one finishes.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "S1 Start", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "S2 Stop (NC)", device: .pushButtonNC),
                IOAssignment(point: .digitalOutput(0), label: "Red", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "Amber", device: .lamp),
                IOAssignment(point: .digitalOutput(2), label: "Green", device: .lamp),
            ],
            hints: [
                "Timer 1 (red, 5 s) runs while Run is on and timer 3 hasn't finished.",
                "Timer 2 (green, 4 s) starts on timer 1's Q; timer 3 (amber, 1 s) starts on timer 2's Q.",
                "When timer 3 finishes, its Q resets timer 1, which resets the whole chain.",
                "Red = Run AND NOT T1.Q; Green = T1.Q AND NOT T2.Q; Amber = T2.Q AND NOT T3.Q.",
            ],
            solution: """
            Network 1: Run  ──┬─| |"S1_Start"─┬─| |"S2_Stop"─( )"Run"
                              └─| |"Run"──────┘
            Network 2: ─| |"Run"─|/|"T3".Q─ TON "T1" PT:=T#5S
            Network 3: ─| |"T1".Q─ TON "T2" PT:=T#4S
            Network 4: ─| |"T2".Q─ TON "T3" PT:=T#1S
            Network 5: ─| |"Run"─|/|"T1".Q──( )"Red"
            Network 6: ─| |"T1".Q─|/|"T2".Q─( )"Green"
            Network 7: ─| |"T2".Q─|/|"T3".Q─( )"Amber"
            """,
            steps: trafficLightSteps(start: 0, stop: 1, red: 0, amber: 1, green: 2)
        ),
        Exercise(
            id: "tia-06-batch-counter", environment: .tiaPortal, number: 6,
            title: "Batch counter", level: .intermediate,
            skills: ["IEC counters", "Edge counting"],
            goal: """
            Photo-eye B1 counts parts on a conveyor. After 5 parts, lamp H1 "Batch complete" lights. S1 resets the count.

            Use a CTU (count up) with PV = 5. A part that stays in front of the sensor must count only once.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "B1 Part sensor", device: .sensor),
                IOAssignment(point: .digitalInput(1), label: "S1 Reset", device: .pushButton),
                IOAssignment(point: .digitalOutput(0), label: "H1 Batch complete", device: .lamp),
            ],
            hints: [
                "Instructions › Counter operations › CTU. Accept the instance DB IEC_Counter_0_DB.",
                "B1 on CU, S1 on R, PV = 5, and H1 on Q. The counter reacts to rising edges only.",
            ],
            solution: """
            Network 1: Count parts
                        %DB2 "IEC_Counter_0_DB"
                          ┌───CTU Int───┐
            ──| |─────────┤CU          Q├──────( )
              "B1_Part"   │             │     "H1_BatchComplete"
            ──| |─────────┤R          CV├
              "S1_Reset" 5┤PV           │
                          └─────────────┘
            """,
            steps: sequence(
                pulses(0, count: 4),
                [
                    .expectOutput(0, false, "the batch isn't complete after 4 parts."),
                ],
                pulses(0, count: 1),
                [
                    .expectOutput(0, true, "the batch is complete after the 5th part."),
                    .actuate(1), .wait(50), .release(1), .wait(50),
                    .expectOutput(0, false, "S1 resets the count."),
                    .actuate(0), .wait(1_000), .release(0), .wait(50),
                    .expectOutput(0, false, "a part standing in front of the sensor counts once, not every scan."),
                ],
                pulses(0, count: 4),
                [
                    .expectOutput(0, true, "5 parts after the reset, the batch is complete again."),
                ]
            )
        ),
        Exercise(
            id: "tia-07-storage", environment: .tiaPortal, number: 7,
            title: "Storage area fill level (CTUD)", level: .intermediate,
            skills: ["Up/down counter", "Compare"],
            goal: """
            Packages enter a storage area past photo-eye PEB1 and leave past PEB2. It holds 10 packages. Count with a CTUD and show the fill level:
            - STOR_EMPTY when it holds none.
            - STOR_NOT_EMPTY when it holds at least one.
            - STOR_FULL when it holds 10 or more.

            RESET sets the count back to 0. This is adapted from the TIA Portal help example.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "PEB1 In", device: .sensor),
                IOAssignment(point: .digitalInput(1), label: "PEB2 Out", device: .sensor),
                IOAssignment(point: .digitalInput(2), label: "RESET", device: .pushButton),
                IOAssignment(point: .digitalOutput(0), label: "STOR_EMPTY", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "STOR_NOT_EMPTY", device: .lamp),
                IOAssignment(point: .digitalOutput(2), label: "STOR_FULL", device: .lamp),
            ],
            hints: [
                "CTUD: PEB1 on CU, PEB2 on CD, RESET on R, PV = 10.",
                "QD (CV ≤ 0) is 'empty', QU (CV ≥ PV) is 'full', and NOT QD is 'not empty'.",
            ],
            solution: """
            Network 1: CTUD "IEC_Counter_0_DB"  CU:="PEB1"  CD:="PEB2"  R:="RESET"  PV:=10
                       QU => "STOR_FULL"   QD => "STOR_EMPTY"
            Network 2: ─|/| "IEC_Counter_0_DB".QD ─( ) "STOR_NOT_EMPTY"
            """,
            steps: sequence(
                [
                    .expectOutput(0, true, "the area starts empty."),
                ],
                pulses(0, count: 3),
                [
                    .expectOutput(0, false, "it's no longer empty after 3 packages."),
                    .expectOutput(1, true, "it shows 'not empty'."),
                ],
                pulses(1, count: 1),
                pulses(0, count: 8),
                [
                    .expectOutput(2, true, "3 in, 1 out, 8 in makes 10: full."),
                ],
                pulses(1, count: 1),
                [
                    .expectOutput(2, false, "one package out: no longer full."),
                    .actuate(2), .wait(50), .release(2), .wait(50),
                    .expectOutput(0, true, "RESET empties the count."),
                ]
            )
        ),
        Exercise(
            id: "tia-08-star-delta", environment: .tiaPortal, number: 8,
            title: "Star-delta starter", level: .advanced,
            skills: ["Timers", "Interlocks", "Sequencing"],
            goal: """
            Pressing S1 switches on main contactor K1 and star contactor K2. After 5 s, K2 drops out, and after a short pause of about 100 ms, delta contactor K3 pulls in. S0 (wired normally closed) stops everything.

            K2 and K3 must never be on at the same time: that would be a short circuit.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "S1 Start", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "S0 Stop (NC)", device: .pushButtonNC),
                IOAssignment(point: .digitalOutput(0), label: "K1 Main", device: .motor),
                IOAssignment(point: .digitalOutput(1), label: "K2 Star", device: .motor),
                IOAssignment(point: .digitalOutput(2), label: "K3 Delta", device: .motor),
            ],
            hints: [
                "Seal in K1 with S1/S0 as in exercise 1.",
                "TON star time (T#5S) runs while K1 is on. K2 = K1 AND NOT star-timer.Q AND NOT K3.",
                "A second TON (T#100MS) starts on the star timer's Q. K3 = its Q AND NOT K2, which also interlocks the two contactors.",
            ],
            solution: """
            Network 1: K1 seal-in       ──┬─| |"S1_Start"─┬─| |"S0_Stop"─( )"K1_Main"
                                          └─| |"K1_Main"──┘
            Network 2: star time        ─| |"K1_Main"─ TON "T_Star" PT:=T#5S
            Network 3: changeover pause ─| |"T_Star".Q─ TON "T_Pause" PT:=T#100MS
            Network 4: ─| |"K1_Main"─|/|"T_Star".Q─|/|"K3_Delta"─( )"K2_Star"
            Network 5: ─| |"T_Pause".Q─|/|"K2_Star"─( )"K3_Delta"
            """,
            steps: [
                .actuate(0), .wait(50), .release(0), .wait(100),
                .expectOutput(0, true, "K1 pulls in on Start."),
                .expectOutput(1, true, "the motor starts in star."),
                .expectOutput(2, false, "delta is off during the star phase."),
                .expectNeverTogether(1, 2, within: 5_500, "star and delta are interlocked through the changeover."),
                .expectOutput(1, false, "star drops out after 5 s."),
                .expectOutput(2, true, "delta pulls in after the pause."),
                .expectOutput(0, true, "K1 stays on in delta."),
                .actuate(1), .wait(100),
                .expectOutput(0, false, "Stop drops K1."),
                .expectOutput(2, false, "Stop drops K3."),
            ]
        ),
        Exercise(
            id: "tia-09-analog-level", environment: .tiaPortal, number: 9,
            title: "Tank level with NORM_X and SCALE_X", level: .advanced,
            skills: ["Analog inputs", "NORM_X / SCALE_X", "Comparators"],
            goal: """
            Level transmitter LT1 sends 0–10 V, which the CPU reads at %IW64 as 0…27648. Scale it to 0.0…100.0 % in a Real tag, for example "Level" at %MD20:
            1. NORM_X: MIN 0, VALUE %IW64, MAX 27648.
            2. SCALE_X: MIN 0.0, MAX 100.0.

            Then light H1 at 80 % or more (high level) and H2 at 20 % or less (low level).
            """,
            io: [
                IOAssignment(point: .analogInput(0), label: "LT1 Level 0–100 %", device: .analogSensor),
                IOAssignment(point: .digitalOutput(0), label: "H1 High ≥ 80 %", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "H2 Low ≤ 20 %", device: .lamp),
            ],
            hints: [
                "Instructions › Conversion operations › NORM_X, then SCALE_X; use a Temp or %MD Real between them.",
                "Comparator CMP >= Real with 80.0 drives H1; CMP <= Real with 20.0 drives H2.",
            ],
            solution: """
            Network 1: NORM_X Int to Real: MIN:=0 VALUE:=%IW64 MAX:=27648 OUT=>#norm
                       SCALE_X Real to Real: MIN:=0.0 VALUE:=#norm MAX:=100.0 OUT=>"Level"
            Network 2: ─[ "Level" >= 80.0 ]──( )"H1_High"
            Network 3: ─[ "Level" <= 20.0 ]──( )"H2_Low"
            """,
            steps: [
                .setAnalog(0, 13_824), .wait(100),
                .expectOutput(0, false, "50 % isn't high."),
                .expectOutput(1, false, "50 % isn't low."),
                .setAnalog(0, 24_883), .wait(100),
                .expectOutput(0, true, "90 % is high."),
                .setAnalog(0, 22_119), .wait(100),
                .expectOutput(0, true, "exactly 80 % counts as high."),
                .setAnalog(0, 4_147), .wait(100),
                .expectOutput(1, true, "15 % is low."),
                .expectOutput(0, false, "15 % isn't high."),
            ]
        ),
        Exercise(
            id: "tia-10-scl-traffic-light", environment: .tiaPortal, number: 10,
            title: "Traffic light as an SCL state machine", level: .advanced,
            skills: ["SCL", "CASE", "Multi-instance timers"],
            goal: """
            Build exercise 5's traffic light again, this time as an SCL function block ("TrafficLight" [FB1]), called from Main [OB1]. The FB has:
            - inputs Start and Stop;
            - outputs Red, Amber and Green;
            - a Static #state (Int) and one TON_TIME multi-instance #timer.

            Use CASE #state OF … END_CASE, with one state per light. S2 is wired normally closed.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "S1 Start", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "S2 Stop (NC)", device: .pushButtonNC),
                IOAssignment(point: .digitalOutput(0), label: "Red", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "Amber", device: .lamp),
                IOAssignment(point: .digitalOutput(2), label: "Green", device: .lamp),
            ],
            hints: [
                "State 0 = off. Start moves to 1 (red); 1 → 2 (green) after 5 s; 2 → 3 (amber) after 4 s; 3 → 1 after 1 s.",
                "Run the timer as #timer(IN := #running, PT := #preset); set IN to FALSE for one call when you change state, so it restarts.",
                "Assign the outputs at the end of the FB from #state, e.g. #Red := #state = 1;",
            ],
            solution: """
            // FB "TrafficLight": Input Start, Stop : Bool; Output Red, Amber, Green : Bool;
            // Static state : Int; timer : TON_TIME; Temp preset : Time
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

            // OB1:
            "TrafficLight_DB"(Start := "S1_Start", Stop := "S2_Stop",
                              Red => "Red", Amber => "Amber", Green => "Green");
            """,
            steps: trafficLightSteps(start: 0, stop: 1, red: 0, amber: 1, green: 2)
        ),
    ]

    // MARK: - GX Works3

    private static let melsec: [Exercise] = [
        Exercise(
            id: "gx-01-self-hold", environment: .gxWorks3, number: 1,
            title: "Self-holding circuit", level: .beginner,
            skills: ["LD / OR / ANI / OUT", "Self-hold"],
            goal: """
            In ProgPou (ladder), pressing X0 starts motor Y0, and Y0 stays on after X0 is released. X1 stops it, and Stop must win when both are pressed. X1 is a normally open push button, so it is programmed with a normally closed contact (ANI).

            Convert with F4, start the simulation, then use monitor mode (F3) to watch the circuit.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "Start", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "Stop", device: .pushButton),
                IOAssignment(point: .digitalOutput(0), label: "Motor", device: .motor),
            ],
            hints: [
                "F5 places a normally open contact, Shift+F5 an OR branch, F6 a normally closed contact, and F7 a coil.",
                "Or type the instructions straight into the ladder: LD X0 ↵, OR Y0 ↵, ANI X1 ↵, OUT Y0 ↵.",
            ],
            solution: """
            0   LD   X0
            1   OR   Y0
            2   ANI  X1
            3   OUT  Y0
            4   END
            """,
            steps: sealInSteps(start: 0, stop: 1, lamp: nil)
        ),
        Exercise(
            id: "gx-02-interlock", environment: .gxWorks3, number: 2,
            title: "Forward/reverse interlock", level: .beginner,
            skills: ["Self-hold", "Interlock"],
            goal: """
            X0 starts forward (Y0), X1 starts reverse (Y1), and X2 stops both. Each direction self-holds. Y0 and Y1 must never be on together: while one runs, the other start button does nothing.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "Forward", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "Reverse", device: .pushButton),
                IOAssignment(point: .digitalInput(2), label: "Stop", device: .pushButton),
                IOAssignment(point: .digitalOutput(0), label: "Forward", device: .motor),
                IOAssignment(point: .digitalOutput(1), label: "Reverse", device: .motor),
            ],
            hints: [
                "Add ANI Y1 to the forward rung and ANI Y0 to the reverse rung.",
            ],
            solution: """
            LD X0   OR Y0   ANI X2   ANI Y1   OUT Y0
            LD X1   OR Y1   ANI X2   ANI Y0   OUT Y1
            END
            """,
            steps: interlockSteps(forward: 0, reverse: 1, stop: 2)
        ),
        Exercise(
            id: "gx-03-on-delay", environment: .gxWorks3, number: 3,
            title: "On-delay timer", level: .beginner,
            skills: ["OUT T", "Timer contacts"],
            goal: """
            While switch X0 is on, lamp Y0 lights after 5 seconds. Switching X0 off turns Y0 off at once.

            On the FX5U, OUT T0 K50 is a 100 ms timer, so K50 = 5.0 s.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "Switch", device: .selectorSwitch),
                IOAssignment(point: .digitalOutput(0), label: "Lamp", device: .lamp),
            ],
            hints: [
                "Coil input: F7, then type T0 K50.",
                "Use T0's contact to drive Y0.",
            ],
            solution: """
            LD  X0
            OUT T0 K50
            LD  T0
            OUT Y0
            END
            """,
            steps: onDelaySteps(switchIndex: 0)
        ),
        Exercise(
            id: "gx-04-flicker", environment: .gxWorks3, number: 4,
            title: "Flicker circuit with two timers", level: .beginner,
            skills: ["Timers", "Timer chains"],
            goal: """
            While X1 is on, Y1 flickers 1 s on, 1 s off, using two timers T1 and T2. This is the classic Mitsubishi flicker circuit. Y1 is off while X1 is off.
            """,
            io: [
                IOAssignment(point: .digitalInput(1), label: "Flicker on", device: .selectorSwitch),
                IOAssignment(point: .digitalOutput(1), label: "Flicker lamp", device: .lamp),
            ],
            hints: [
                "T1 times while X1 is on and T2 is off. T2 times while T1 is on. When T2 finishes, it resets T1.",
                "Y1 = X1 AND NOT T1.",
            ],
            solution: """
            LD  X1
            ANI T2
            OUT T1 K10
            LD  T1
            OUT T2 K10
            LD  X1
            ANI T1
            OUT Y1
            END
            """,
            steps: [
                .actuate(1),
                .expectTransitions(1, min: 5, max: 7, within: 6_000, "it flickers 1 s on / 1 s off."),
                .release(1), .wait(100),
                .expectOutput(1, false, "it goes out when X1 is off."),
            ]
        ),
        Exercise(
            id: "gx-05-traffic-light", environment: .gxWorks3, number: 5,
            title: "Traffic light (cascaded timers)", level: .intermediate,
            skills: ["Run relay", "Cascaded timers"],
            goal: """
            X0 starts and X1 stops a repeating sequence: red Y0 for 5 s → green Y2 for 4 s → amber Y1 for 1 s. Keep the running state in M0. All lights are off when stopped.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "Start", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "Stop", device: .pushButton),
                IOAssignment(point: .digitalOutput(0), label: "Red", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "Amber", device: .lamp),
                IOAssignment(point: .digitalOutput(2), label: "Green", device: .lamp),
            ],
            hints: [
                "M0 self-holds like exercise 1.",
                "T0 (red, K50) runs while M0 is on and T2 is off. T1 (green, K40) starts on T0. T2 (amber, K10) starts on T1.",
            ],
            solution: """
            LD X0   OR M0   ANI X1   OUT M0
            LD M0   ANI T2  OUT T0 K50
            LD T0   OUT T1 K40
            LD T1   OUT T2 K10
            LD M0   ANI T0  OUT Y0
            LD T0   ANI T1  OUT Y2
            LD T1   ANI T2  OUT Y1
            END
            """,
            steps: trafficLightSteps(start: 0, stop: 1, red: 0, amber: 1, green: 2)
        ),
        Exercise(
            id: "gx-06-counter", environment: .gxWorks3, number: 6,
            title: "Counting parts with OUT C", level: .intermediate,
            skills: ["Counters", "RST"],
            goal: """
            Sensor X0 counts parts. After 5 parts, Y0 "batch done" lights. X1 resets the counter. A part that stays at the sensor counts only once.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "Part sensor", device: .sensor),
                IOAssignment(point: .digitalInput(1), label: "Reset", device: .pushButton),
                IOAssignment(point: .digitalOutput(0), label: "Batch done", device: .lamp),
            ],
            hints: [
                "OUT C0 K5 counts each OFF→ON of its coil.",
                "RST C0 clears the count and the contact.",
            ],
            solution: """
            LD  X0
            OUT C0 K5
            LD  C0
            OUT Y0
            LD  X1
            RST C0
            END
            """,
            steps: sequence(
                pulses(0, count: 4),
                [
                    .expectOutput(0, false, "not done after 4 parts."),
                ],
                pulses(0, count: 1),
                [
                    .expectOutput(0, true, "done after the 5th part."),
                    .actuate(1), .wait(50), .release(1), .wait(50),
                    .expectOutput(0, false, "RST C0 clears it."),
                    .actuate(0), .wait(1_000), .release(0), .wait(50),
                    .expectOutput(0, false, "a part held at the sensor counts once."),
                ]
            )
        ),
        Exercise(
            id: "gx-07-parking", environment: .gxWorks3, number: 7,
            title: "Car park counter", level: .intermediate,
            skills: ["INCP / DECP", "Compare contacts", "Data registers"],
            goal: """
            Each car passing entry sensor X0 adds one to D0; each car passing exit sensor X1 takes one away. The car park holds 10 cars. Show FULL on Y0 when D0 ≥ 10, and SPACES on Y1 when D0 < 10.

            Pulse instructions (INCP, DECP) act once per rising edge, not on every scan.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "Entry", device: .sensor),
                IOAssignment(point: .digitalInput(1), label: "Exit", device: .sensor),
                IOAssignment(point: .digitalOutput(0), label: "FULL", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "SPACES", device: .lamp),
            ],
            hints: [
                "F8 opens application-instruction input: INCP D0.",
                "Comparison contacts: LD>= D0 K10 and LD< D0 K10.",
            ],
            solution: """
            LD   X0
            INCP D0
            LD   X1
            DECP D0
            LD>= D0 K10
            OUT  Y0
            LD<  D0 K10
            OUT  Y1
            END
            """,
            steps: sequence(
                [
                    .expectOutput(1, true, "an empty car park has spaces."),
                ],
                pulses(0, count: 10),
                [
                    .expectOperand("D0", .int(10), "D0 counts 10 cars."),
                    .expectOutput(0, true, "10 cars: FULL."),
                    .expectOutput(1, false, "no spaces when full."),
                ],
                pulses(1, count: 1),
                [
                    .expectOperand("D0", .int(9), "a car left."),
                    .expectOutput(0, false, "no longer full."),
                    .expectOutput(1, true, "spaces again."),
                ]
            )
        ),
        Exercise(
            id: "gx-08-mov-compare", environment: .gxWorks3, number: 8,
            title: "MOV, add and compare", level: .intermediate,
            skills: ["MOVP", "+P", "Compare contacts"],
            goal: """
            X0 loads 100 into D0, and X1 loads 200. Each press of X2 adds 10 to D0. Y0 lights while D0 > 150, and Y1 while D0 = 200.
            """,
            io: [
                IOAssignment(point: .digitalInput(0), label: "Load 100", device: .pushButton),
                IOAssignment(point: .digitalInput(1), label: "Load 200", device: .pushButton),
                IOAssignment(point: .digitalInput(2), label: "Add 10", device: .pushButton),
                IOAssignment(point: .digitalOutput(0), label: "D0 > 150", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "D0 = 200", device: .lamp),
            ],
            hints: [
                "MOVP K100 D0 moves once per press; plain MOV would move on every scan.",
                "+P K10 D0 adds 10 to D0 once per press.",
            ],
            solution: """
            LD X0   MOVP K100 D0
            LD X1   MOVP K200 D0
            LD X2   +P   K10  D0
            LD> D0 K150   OUT Y0
            LD= D0 K200   OUT Y1
            END
            """,
            steps: sequence(
                [
                    .actuate(0), .wait(50), .release(0), .wait(50),
                    .expectOperand("D0", .int(100), "X0 loads 100."),
                    .expectOutput(0, false, "100 isn't above 150."),
                ],
                pulses(2, count: 6),
                [
                    .expectOperand("D0", .int(160), "six presses add 60."),
                    .expectOutput(0, true, "160 is above 150."),
                    .actuate(1), .wait(50), .release(1), .wait(50),
                    .expectOutput(1, true, "X1 loads exactly 200."),
                ]
            )
        ),
        Exercise(
            id: "gx-09-chaser", environment: .gxWorks3, number: 9,
            title: "Lamp chaser with ROL", level: .advanced,
            skills: ["SM402 / SM412", "ROLP", "Digit specification"],
            goal: """
            When the CPU goes to RUN, a single lit lamp runs along Y0–Y17, moving one step each second. Use:
            - SM402 (ON for the first scan) to load H1 into D0;
            - SM412 (1 s clock) with ROLP D0 K1;
            - MOV D0 K4Y0 to show D0's 16 bits on Y0–Y17.
            """,
            io: (0..<16).map { IOAssignment(point: .digitalOutput($0), label: "Lamp \($0 + 1)", device: .lamp) },
            hints: [
                "K4Y0 means 4 digits × 4 bits = the 16 outputs Y0–Y17.",
                "ROLP rotates once per rising edge of SM412.",
            ],
            solution: """
            LD   SM402
            MOV  H1 D0
            LD   SM412
            ROLP D0 K1
            LD   SM400
            MOV  D0 K4Y0
            END
            """,
            steps: [
                .expectExactlyOneOn(Array(0..<16), within: 3_000, "exactly one lamp is lit at every moment."),
                .expectPatternChanges(Array(0..<16), min: 4, max: 6, within: 5_000, "the light moves one step about every second."),
            ]
        ),
        Exercise(
            id: "gx-10-master-control", environment: .gxWorks3, number: 10,
            title: "Master control zone (MC/MCR)", level: .advanced,
            skills: ["MC / MCR", "Timer reset"],
            goal: """
            X5 enables a machine zone programmed between MC N0 M50 and MCR N0. Inside the zone:
            - X0 drives Y0;
            - X1 runs timer T0 (K20, 2 s), and T0 drives Y1.

            Watch what happens when X5 turns off: the coils drop and the timer resets.
            """,
            io: [
                IOAssignment(point: .digitalInput(5), label: "Zone enable", device: .selectorSwitch),
                IOAssignment(point: .digitalInput(0), label: "Output switch", device: .selectorSwitch),
                IOAssignment(point: .digitalInput(1), label: "Timer switch", device: .selectorSwitch),
                IOAssignment(point: .digitalOutput(0), label: "Zone output", device: .lamp),
                IOAssignment(point: .digitalOutput(1), label: "Timer output", device: .lamp),
            ],
            hints: [
                "Type MC N0 M50 on a rung after LD X5, and MCR N0 after the zone.",
            ],
            solution: """
            LD  X5
            MC  N0 M50
            LD  X0
            OUT Y0
            LD  X1
            OUT T0 K20
            LD  T0
            OUT Y1
            MCR N0
            END
            """,
            steps: [
                .actuate(0), .wait(100),
                .expectOutput(0, false, "the zone is off while X5 is off."),
                .actuate(5), .wait(100),
                .expectOutput(0, true, "enabling the zone lets X0 drive Y0."),
                .actuate(1), .wait(2_200),
                .expectOutput(1, true, "T0 times out after 2 s inside the zone."),
                .release(5), .wait(100),
                .expectOutput(0, false, "Y0 drops when the zone turns off."),
                .expectOutput(1, false, "T0 resets when the zone turns off."),
                .actuate(5), .wait(500),
                .expectOutput(1, false, "T0 starts timing from zero again."),
                .expectOutput(0, true, "Y0 comes back with the zone."),
            ]
        ),
    ]
}
