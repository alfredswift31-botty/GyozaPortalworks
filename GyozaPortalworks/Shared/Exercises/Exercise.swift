import Foundation

/// A training-board point an exercise uses, and what is wired to it.
nonisolated struct IOAssignment: Hashable, Sendable, Identifiable {
    nonisolated enum Point: Hashable, Sendable {
        case digitalInput(Int)
        case digitalOutput(Int)
        case analogInput(Int)
        case analogOutput(Int)
    }

    /// The field device, which decides how the board draws and operates it.
    nonisolated enum Device: String, Hashable, Sendable {
        /// Momentary, normally open.
        case pushButton
        /// Momentary, wired normally closed: the input is TRUE until pressed.
        case pushButtonNC
        /// Latching switch.
        case selectorSwitch
        /// Limit switch or photo-eye, normally open.
        case sensor
        /// Sensor wired normally closed.
        case sensorNC
        case lamp
        case motor
        case valve
        case analogSensor
        case analogActuator

        var isMomentary: Bool { self == .pushButton || self == .pushButtonNC }
        var isNormallyClosed: Bool { self == .pushButtonNC || self == .sensorNC }
    }

    var point: Point
    var label: String
    var device: Device

    var id: Point { point }

    /// The input level when the device is actuated (pressed, switched, detecting)
    /// or at rest. A normally closed device reads FALSE while actuated.
    func signal(actuated: Bool) -> Bool {
        device.isNormallyClosed ? !actuated : actuated
    }
}

/// One step of an exercise's automatic check.
nonisolated enum CheckStep: Hashable, Sendable {
    /// Presses a button or switches a switch/sensor on.
    case actuate(Int)
    /// Releases a button or switches a switch/sensor off.
    case release(Int)
    /// Sets an analog input to a raw value.
    case setAnalog(Int, Int)
    /// Lets the CPU run for this many milliseconds.
    case wait(Int)
    /// A board output must be on or off; the text says what that proves.
    case expectOutput(Int, Bool, String)
    /// An operand must hold a value ("D0", "\"Level\"").
    case expectOperand(String, PLCValue, String)
    /// Within `within` ms, an output must change state between `min` and `max` times.
    case expectTransitions(Int, min: Int, max: Int, within: Int, String)
    /// For `within` ms, the two outputs must never be on together.
    case expectNeverTogether(Int, Int, within: Int, String)
    /// For `within` ms, exactly one of the outputs is on at every scan.
    case expectExactlyOneOn([Int], within: Int, String)
    /// Within `within` ms, the on/off pattern of the outputs must change
    /// between `min` and `max` times (a chaser moving along).
    case expectPatternChanges([Int], min: Int, max: Int, within: Int, String)
}

/// A practice task with an automatic check against the user's program.
nonisolated struct Exercise: Identifiable, Hashable, Sendable {
    nonisolated enum Level: Int, CaseIterable, Comparable, Hashable, Sendable {
        case beginner = 1
        case intermediate
        case advanced

        var title: String {
            switch self {
            case .beginner: return "Beginner"
            case .intermediate: return "Intermediate"
            case .advanced: return "Advanced"
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var environment: PracticeEnvironment
    var number: Int
    var title: String
    var level: Level
    /// What it practises: "Seal-in", "IEC timers", "CASE".
    var skills: [String]
    /// The task, in the tool's own vocabulary.
    var goal: String
    var io: [IOAssignment]
    var hints: [String]
    /// A reference solution: LAD sketch, SCL code or a GX Works instruction list.
    var solution: String
    var steps: [CheckStep]

    func assignment(for point: IOAssignment.Point) -> IOAssignment? {
        io.first { $0.point == point }
    }
}

/// The outcome of checking an exercise.
nonisolated struct CheckReport: Hashable, Sendable {
    nonisolated struct Line: Hashable, Sendable {
        var passed: Bool
        var text: String
        /// Simulated time of the check, in ms after the CPU went to RUN.
        var time: Int64
    }

    var lines: [Line]

    var passed: Bool { !lines.isEmpty && lines.allSatisfy(\.passed) }
    var firstFailure: Line? { lines.first { !$0.passed } }
}

/// Runs an exercise's scenario against a freshly loaded CPU in simulated time,
/// scan by scan, the way a test engineer would at a training rig.
nonisolated enum ExerciseChecker {
    static let scanTime: Int64 = 10
    static let startupTime: Int64 = 100

    static func run(_ exercise: Exercise, on cpu: any SimulatedCPU) -> CheckReport {
        var clock = cpu.clock
        let origin = clock
        var lines: [CheckReport.Line] = []

        func elapsed() -> Int64 { clock - origin }

        func scan() {
            clock += scanTime
            cpu.scan(clock: clock)
        }

        func advance(_ milliseconds: Int64) {
            let end = clock + milliseconds
            while clock < end {
                scan()
            }
        }

        func outputName(_ index: Int) -> String {
            let label = exercise.assignment(for: .digitalOutput(index))?.label
            let address = cpu.digitalOutputName(index)
            return label.map { "\(address) \($0)" } ?? address
        }

        func setInput(_ index: Int, actuated: Bool) {
            guard index < cpu.digitalInputCount else { return }
            let assignment = exercise.assignment(for: .digitalInput(index))
            cpu.setDigitalInput(index, assignment?.signal(actuated: actuated) ?? actuated)
        }

        func stoppedLine() -> CheckReport.Line {
            let reason = cpu.diagnostics.last(where: \.isError)?.message ?? "no error was logged"
            return CheckReport.Line(passed: false, text: "The CPU went to STOP (\(reason)).", time: elapsed())
        }

        // Inputs at rest: normally closed devices read TRUE.
        for assignment in exercise.io {
            if case let .digitalInput(index) = assignment.point {
                setInput(index, actuated: false)
            }
        }
        cpu.setMode(.run)
        advance(startupTime)

        for step in exercise.steps {
            guard cpu.mode == .run else {
                lines.append(stoppedLine())
                break
            }
            switch step {
            case let .actuate(index):
                setInput(index, actuated: true)
            case let .release(index):
                setInput(index, actuated: false)
            case let .setAnalog(channel, value):
                cpu.setAnalogInput(channel, value)
            case let .wait(milliseconds):
                advance(Int64(milliseconds))
            case let .expectOutput(index, expected, meaning):
                let actual = cpu.digitalOutput(index)
                let state = expected ? "ON" : "OFF"
                let detail = actual == expected ? "" : " It is \(actual ? "ON" : "OFF")."
                lines.append(CheckReport.Line(passed: actual == expected, text: "\(outputName(index)) is \(state): \(meaning)\(detail)", time: elapsed()))
            case let .expectOperand(operand, expected, meaning):
                let actual = cpu.readOperand(operand)
                let passed = actual.map { matches($0, expected) } ?? false
                let detail: String
                if let actual {
                    detail = passed ? "" : " It is \(describe(actual))."
                } else {
                    detail = " \(operand) doesn't exist in your program."
                }
                lines.append(CheckReport.Line(passed: passed, text: "\(operand) = \(describe(expected)): \(meaning)\(detail)", time: elapsed()))
            case let .expectTransitions(index, minimum, maximum, window, meaning):
                var last = cpu.digitalOutput(index)
                var changes = 0
                let end = clock + Int64(window)
                while clock < end, cpu.mode == .run {
                    scan()
                    let now = cpu.digitalOutput(index)
                    if now != last {
                        changes += 1
                        last = now
                    }
                }
                let passed = changes >= minimum && changes <= maximum
                lines.append(CheckReport.Line(passed: passed, text: "\(outputName(index)): \(meaning)\(passed ? "" : " It changed \(changes) times in \(window) ms.")", time: elapsed()))
            case let .expectNeverTogether(first, second, window, meaning):
                var clash: Int64?
                let end = clock + Int64(window)
                while clock < end, cpu.mode == .run {
                    scan()
                    if clash == nil, cpu.digitalOutput(first), cpu.digitalOutput(second) {
                        clash = elapsed()
                    }
                }
                let text = "\(outputName(first)) and \(outputName(second)) never on together: \(meaning)"
                lines.append(CheckReport.Line(passed: clash == nil, text: clash.map { "\(text) Both were on at \($0) ms." } ?? text, time: elapsed()))
            case let .expectExactlyOneOn(indices, window, meaning):
                var problem: String?
                let end = clock + Int64(window)
                while clock < end, cpu.mode == .run, problem == nil {
                    scan()
                    let lit = indices.filter { cpu.digitalOutput($0) }
                    if lit.count != 1 {
                        problem = lit.isEmpty
                            ? "No output was on at \(elapsed()) ms."
                            : "\(lit.map(outputName).joined(separator: ", ")) were on together at \(elapsed()) ms."
                    }
                }
                lines.append(CheckReport.Line(passed: problem == nil, text: "\(meaning)\(problem.map { " \($0)" } ?? "")", time: elapsed()))
            case let .expectPatternChanges(indices, minimum, maximum, window, meaning):
                var last = indices.map { cpu.digitalOutput($0) }
                var changes = 0
                let end = clock + Int64(window)
                while clock < end, cpu.mode == .run {
                    scan()
                    let now = indices.map { cpu.digitalOutput($0) }
                    if now != last {
                        changes += 1
                        last = now
                    }
                }
                let passed = changes >= minimum && changes <= maximum
                lines.append(CheckReport.Line(passed: passed, text: "\(meaning)\(passed ? "" : " The pattern changed \(changes) times in \(window) ms.")", time: elapsed()))
            }
            if let last = lines.last, !last.passed {
                break
            }
        }
        if cpu.mode != .run, lines.last?.passed ?? true {
            lines.append(stoppedLine())
        }
        return CheckReport(lines: lines)
    }

    private static func matches(_ actual: PLCValue, _ expected: PLCValue) -> Bool {
        switch (actual, expected) {
        case (.bool, _), (_, .bool):
            return actual.boolValue == expected.boolValue
        case (.real, _), (_, .real):
            return abs(actual.doubleValue - expected.doubleValue) <= max(1e-3, abs(expected.doubleValue) * 1e-4)
        default:
            return actual.intValue == expected.intValue
        }
    }

    private static func describe(_ value: PLCValue) -> String {
        switch value {
        case let .bool(flag): return flag ? "TRUE" : "FALSE"
        case let .int(number): return String(number)
        case let .real(number): return RealLiteral.format(number)
        case let .time(milliseconds): return TimeLiteral.format(milliseconds: milliseconds)
        }
    }
}
