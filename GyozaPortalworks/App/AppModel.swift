import AppKit
import Foundation
import Observation

/// App-wide state: which tool is showing, both workspaces, and exercise progress.
@MainActor @Observable final class AppModel {
    private enum Keys {
        static let environment = "environment"
        static let passed = "passedExercises"
        static let activeExercises = "activeExercises"
    }

    var environment: PracticeEnvironment {
        didSet { UserDefaults.standard.set(environment.rawValue, forKey: Keys.environment) }
    }

    /// One workspace per tool, alive for the whole session so switching keeps
    /// each tool's project, editors and simulation.
    private(set) var workspaces: [PracticeEnvironment: any PracticeWorkspace] = [:]

    /// The exercise wired to the trainer board, per tool.
    private(set) var activeExerciseIDs: [PracticeEnvironment: String] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: activeExerciseIDs.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(stored, forKey: Keys.activeExercises)
        }
    }

    /// The latest check of each exercise, by exercise id.
    private(set) var reports: [String: CheckReport] = [:]

    private(set) var passedExercises: Set<String> {
        didSet { UserDefaults.standard.set(Array(passedExercises).sorted(), forKey: Keys.passed) }
    }

    init() {
        let defaults = UserDefaults.standard
        environment = defaults.string(forKey: Keys.environment).flatMap(PracticeEnvironment.init(rawValue:)) ?? .tiaPortal
        passedExercises = Set(defaults.stringArray(forKey: Keys.passed) ?? [])
        var active: [PracticeEnvironment: String] = [:]
        for (key, value) in (defaults.dictionary(forKey: Keys.activeExercises) as? [String: String]) ?? [:] {
            if let environment = PracticeEnvironment(rawValue: key) {
                active[environment] = value
            }
        }
        activeExerciseIDs = active
        for environment in PracticeEnvironment.allCases {
            workspaces[environment] = WorkspaceRegistry.makeWorkspace(for: environment)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveAll()
            }
        }
    }

    var activeWorkspace: (any PracticeWorkspace)? { workspaces[environment] }
    var activeSession: SimulationSession? { activeWorkspace?.session }

    var activeExercise: Exercise? {
        guard let id = activeExerciseIDs[environment] else { return nil }
        return ExerciseLibrary.exercises(for: environment).first { $0.id == id }
    }

    /// Wires an exercise to the trainer board (labels, push buttons, NC contacts).
    func activate(_ exercise: Exercise?) {
        activeExerciseIDs[environment] = exercise?.id
        applyRestInputs()
    }

    /// Puts every input the active exercise uses into its rest state, so a
    /// normally closed stop button reads TRUE until it's pressed.
    func applyRestInputs() {
        guard let session = activeSession, let exercise = activeExercise else { return }
        for assignment in exercise.io {
            if case let .digitalInput(index) = assignment.point, index < session.cpu.digitalInputCount {
                session.cpu.setDigitalInput(index, assignment.signal(actuated: false))
            }
        }
        session.refresh()
    }

    /// Compiles the user's program into a fresh CPU and runs the exercise's
    /// scenario against it.
    func check(_ exercise: Exercise) {
        guard let workspace = workspaces[exercise.environment] else {
            reports[exercise.id] = CheckReport(lines: [
                CheckReport.Line(passed: false, text: "\(exercise.environment.title) isn't available.", time: 0),
            ])
            return
        }
        switch workspace.makeCheckCPU() {
        case let .success(cpu):
            let report = ExerciseChecker.run(exercise, on: cpu)
            reports[exercise.id] = report
            if report.passed {
                passedExercises.insert(exercise.id)
            }
        case let .failure(error):
            let text = ([error.message] + error.details).joined(separator: "\n")
            reports[exercise.id] = CheckReport(lines: [CheckReport.Line(passed: false, text: text, time: 0)])
        }
    }

    func saveAll() {
        for workspace in workspaces.values {
            workspace.save()
        }
    }
}
