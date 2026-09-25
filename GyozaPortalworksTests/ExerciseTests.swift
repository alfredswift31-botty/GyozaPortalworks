import Testing
@testable import GyozaPortalworks

/// A stand-in CPU whose "program" is a Swift closure, so exercise scenarios
/// can be verified against known-good reference logic.
nonisolated final class FakeCPU: SimulatedCPU {
    let environment: PracticeEnvironment
    let digitalInputCount: Int
    let digitalOutputCount: Int
    let analogInputCount = 2
    let analogOutputCount = 1
    let analogRange: ClosedRange<Int>
    private(set) var mode: CPUMode = .stop
    private(set) var clock: Int64 = 0
    var diagnostics: [DiagnosticEvent] = []

    var inputs: [Bool]
    var outputs: [Bool]
    var analogInputs = [0, 0]
    var registers: [String: Int64] = [:]
    private var instances: [String: (FunctionBlockType, DataNode)] = [:]
    private var edges: [String: Bool] = [:]
    private let program: (FakeCPU) -> Void

    init(_ environment: PracticeEnvironment, program: @escaping (FakeCPU) -> Void) {
        self.environment = environment
        let counts = environment == .tiaPortal ? BoardAddressing.siemensCounts : BoardAddressing.melsecCounts
        digitalInputCount = counts.digitalInputs
        digitalOutputCount = counts.digitalOutputs
        analogRange = environment == .tiaPortal ? 0...27_648 : 0...4_000
        inputs = Array(repeating: false, count: counts.digitalInputs)
        outputs = Array(repeating: false, count: counts.digitalOutputs)
        self.program = program
    }

    func setMode(_ mode: CPUMode) { self.mode = mode }

    func scan(clock: Int64) {
        self.clock = clock
        if mode == .run { program(self) }
    }

    func readOperand(_ text: String) -> PLCValue? { registers[text].map { .int($0) } }
    func setDigitalInput(_ index: Int, _ value: Bool) { inputs[index] = value }
    func digitalInput(_ index: Int) -> Bool { inputs[index] }
    func digitalOutput(_ index: Int) -> Bool { outputs[index] }
    func setAnalogInput(_ channel: Int, _ value: Int) { analogInputs[channel] = value }
    func analogInput(_ channel: Int) -> Int { analogInputs[channel] }
    func analogOutput(_ channel: Int) -> Int { 0 }
    func digitalInputName(_ index: Int) -> String { BoardAddressing.name(.digitalInput(index), in: environment) }
    func digitalOutputName(_ index: Int) -> String { BoardAddressing.name(.digitalOutput(index), in: environment) }
    func analogInputName(_ channel: Int) -> String { BoardAddressing.name(.analogInput(channel), in: environment) }
    func analogOutputName(_ channel: Int) -> String { BoardAddressing.name(.analogOutput(channel), in: environment) }

    private func instance(_ name: String, type typeName: String) -> (FunctionBlockType, DataNode) {
        if let existing = instances[name] { return existing }
        let type = FunctionBlockLibrary.type(named: typeName, dialect: .melsec)!
        let made = (type, DataNode(type: .instance(type)))
        instances[name] = made
        return made
    }

    /// Calls an on-delay timer and returns Q.
    @discardableResult
    func onDelay(_ name: String, _ input: Bool, _ milliseconds: Int64) -> Bool {
        let (type, node) = instance(name, type: "TON")
        node.member("IN")?.write(.bool(input))
        node.member("PT")?.write(.time(milliseconds))
        FunctionBlockLibrary.execute(type, instance: node, now: clock)
        return q(name)
    }

    /// A timer's Q from its last call (a contact read before the timer runs this scan).
    func q(_ name: String) -> Bool {
        instances[name]?.1.member("Q")?.read().boolValue ?? false
    }

    /// Calls an up/down counter (CTUD) and returns (QU, QD).
    func upDown(_ name: String, up: Bool, down: Bool, reset: Bool, preset: Int64) -> (Bool, Bool) {
        let (type, node) = instance(name, type: "CTUD")
        node.member("CU")?.write(.bool(up))
        node.member("CD")?.write(.bool(down))
        node.member("R")?.write(.bool(reset))
        node.member("PV")?.write(.int(preset))
        FunctionBlockLibrary.execute(type, instance: node, now: clock)
        return (node.member("QU")?.read().boolValue ?? false, node.member("QD")?.read().boolValue ?? false)
    }

    func rising(_ name: String, _ value: Bool) -> Bool {
        let before = edges[name] ?? false
        edges[name] = value
        return value && !before
    }

    func flag(_ name: String) -> Bool { (registers[name] ?? 0) != 0 }
    func setFlag(_ name: String, _ value: Bool) { registers[name] = value ? 1 : 0 }
}

/// Known-good solutions, written the way the reference solutions describe them.
nonisolated enum ReferencePrograms {
    static func program(for id: String) -> (FakeCPU) -> Void {
        switch id {
        case "tia-01-seal-in":
            return { cpu in
                let run = (cpu.inputs[0] || cpu.outputs[0]) && cpu.inputs[1]
                cpu.outputs[0] = run
                cpu.outputs[1] = run
            }
        case "tia-02-interlock":
            return { cpu in
                cpu.outputs[0] = (cpu.inputs[0] || cpu.outputs[0]) && cpu.inputs[2] && !cpu.outputs[1]
                cpu.outputs[1] = (cpu.inputs[1] || cpu.outputs[1]) && cpu.inputs[2] && !cpu.outputs[0]
            }
        case "tia-03-ton", "gx-03-on-delay":
            return { cpu in cpu.outputs[0] = cpu.onDelay("T", cpu.inputs[0], 5_000) }
        case "tia-04-flasher":
            return { cpu in cpu.outputs[0] = cpu.inputs[0] && cpu.clock % 1_000 >= 500 }
        case "tia-05-traffic-light", "tia-10-scl-traffic-light":
            return { cpu in
                // S2 is wired NC: TRUE until pressed.
                trafficLight(cpu, start: cpu.inputs[0], stop: !cpu.inputs[1])
            }
        case "gx-05-traffic-light":
            return { cpu in trafficLight(cpu, start: cpu.inputs[0], stop: cpu.inputs[1]) }
        case "tia-06-batch-counter", "gx-06-counter":
            return { cpu in
                let (done, _) = cpu.upDown("C", up: cpu.inputs[0], down: false, reset: cpu.inputs[1], preset: 5)
                cpu.outputs[0] = done
            }
        case "tia-07-storage":
            return { cpu in
                let (full, empty) = cpu.upDown("C", up: cpu.inputs[0], down: cpu.inputs[1], reset: cpu.inputs[2], preset: 10)
                cpu.outputs[0] = empty
                cpu.outputs[1] = !empty
                cpu.outputs[2] = full
            }
        case "tia-08-star-delta":
            return { cpu in
                let main = (cpu.inputs[0] || cpu.outputs[0]) && cpu.inputs[1]
                cpu.outputs[0] = main
                let star = cpu.onDelay("Star", main, 5_000)
                let pause = cpu.onDelay("Pause", star, 100)
                cpu.outputs[1] = main && !star && !cpu.outputs[2]
                cpu.outputs[2] = pause && !cpu.outputs[1]
            }
        case "tia-09-analog-level":
            return { cpu in
                let level = Double(cpu.analogInputs[0]) / 27_648 * 100
                cpu.outputs[0] = level >= 80
                cpu.outputs[1] = level <= 20
            }
        case "gx-01-self-hold":
            return { cpu in cpu.outputs[0] = (cpu.inputs[0] || cpu.outputs[0]) && !cpu.inputs[1] }
        case "gx-02-interlock":
            return { cpu in
                cpu.outputs[0] = (cpu.inputs[0] || cpu.outputs[0]) && !cpu.inputs[2] && !cpu.outputs[1]
                cpu.outputs[1] = (cpu.inputs[1] || cpu.outputs[1]) && !cpu.inputs[2] && !cpu.outputs[0]
            }
        case "gx-04-flicker":
            return { cpu in
                let t1 = cpu.onDelay("T1", cpu.inputs[1] && !cpu.q("T2"), 1_000)
                cpu.onDelay("T2", t1, 1_000)
                cpu.outputs[1] = cpu.inputs[1] && !t1
            }
        case "gx-07-parking":
            return { cpu in
                var cars = cpu.registers["D0"] ?? 0
                if cpu.rising("X0", cpu.inputs[0]) { cars += 1 }
                if cpu.rising("X1", cpu.inputs[1]) { cars -= 1 }
                cpu.registers["D0"] = cars
                cpu.outputs[0] = cars >= 10
                cpu.outputs[1] = cars < 10
            }
        case "gx-08-mov-compare":
            return { cpu in
                var value = cpu.registers["D0"] ?? 0
                if cpu.rising("X0", cpu.inputs[0]) { value = 100 }
                if cpu.rising("X1", cpu.inputs[1]) { value = 200 }
                if cpu.rising("X2", cpu.inputs[2]) { value += 10 }
                cpu.registers["D0"] = value
                cpu.outputs[0] = value > 150
                cpu.outputs[1] = value == 200
            }
        case "gx-09-chaser":
            return { cpu in
                if !cpu.flag("started") {
                    cpu.setFlag("started", true)
                    cpu.registers["D0"] = 1
                }
                var pattern = cpu.registers["D0"] ?? 1
                if cpu.rising("SM412", cpu.clock % 1_000 >= 500) {
                    pattern = ((pattern << 1) | (pattern >> 15)) & 0xFFFF
                }
                cpu.registers["D0"] = pattern
                for bit in 0..<16 {
                    cpu.outputs[bit] = pattern & (1 << bit) != 0
                }
            }
        case "gx-10-master-control":
            return { cpu in
                let zone = cpu.inputs[5]
                cpu.outputs[0] = zone && cpu.inputs[0]
                cpu.outputs[1] = cpu.onDelay("T0", zone && cpu.inputs[1], 2_000) && zone
            }
        default:
            return { _ in }
        }
    }

    private static func trafficLight(_ cpu: FakeCPU, start: Bool, stop: Bool) {
        let run = (start || cpu.flag("run")) && !stop
        cpu.setFlag("run", run)
        let red = cpu.onDelay("T1", run && !cpu.q("T3"), 5_000)
        let green = cpu.onDelay("T2", red, 4_000)
        let amber = cpu.onDelay("T3", green, 1_000)
        cpu.outputs[0] = run && !red
        cpu.outputs[2] = red && !green
        cpu.outputs[1] = green && !amber
    }
}

struct ExerciseTests {
    @Test(arguments: ExerciseLibrary.all)
    func referenceSolutionPasses(_ exercise: Exercise) {
        let cpu = FakeCPU(exercise.environment, program: ReferencePrograms.program(for: exercise.id))
        let report = ExerciseChecker.run(exercise, on: cpu)
        #expect(report.passed, "\(exercise.id): \(report.firstFailure?.text ?? "no checks ran")")
    }

    @Test func libraryIsWellFormed() {
        let ids = ExerciseLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for environment in PracticeEnvironment.allCases {
            let exercises = ExerciseLibrary.exercises(for: environment)
            #expect(exercises.map(\.number) == Array(1...exercises.count))
            let counts = environment == .tiaPortal ? BoardAddressing.siemensCounts : BoardAddressing.melsecCounts
            for exercise in exercises {
                #expect(!exercise.steps.isEmpty)
                for assignment in exercise.io {
                    switch assignment.point {
                    case let .digitalInput(index): #expect(index < counts.digitalInputs, "\(exercise.id)")
                    case let .digitalOutput(index): #expect(index < counts.digitalOutputs, "\(exercise.id)")
                    case let .analogInput(channel): #expect(channel < counts.analogInputs, "\(exercise.id)")
                    case let .analogOutput(channel): #expect(channel < counts.analogOutputs, "\(exercise.id)")
                    }
                }
            }
        }
    }

    @Test func aProgramWithoutSealInFails() {
        let exercise = ExerciseLibrary.exercises(for: .tiaPortal)[0]
        let cpu = FakeCPU(.tiaPortal) { cpu in
            cpu.outputs[0] = cpu.inputs[0] && cpu.inputs[1]
        }
        let report = ExerciseChecker.run(exercise, on: cpu)
        #expect(!report.passed)
        #expect(report.firstFailure?.text.contains("seal-in") == true)
        #expect(report.firstFailure?.text.contains("%Q0.0 K1 Motor") == true)
    }

    @Test func boardAddressesFollowEachController() {
        #expect(BoardAddressing.name(.digitalInput(9), in: .tiaPortal) == "%I1.1")
        #expect(BoardAddressing.name(.digitalOutput(8), in: .tiaPortal) == "%Q1.0")
        #expect(BoardAddressing.name(.analogInput(1), in: .tiaPortal) == "%IW66")
        #expect(BoardAddressing.name(.digitalInput(8), in: .gxWorks3) == "X10")
        #expect(BoardAddressing.name(.digitalOutput(15), in: .gxWorks3) == "Y17")
    }
}
