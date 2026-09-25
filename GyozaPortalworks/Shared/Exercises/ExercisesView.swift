import SwiftUI

/// The exercise list for the tool that's showing, with automatic checking.
struct ExercisesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        let exercises = ExerciseLibrary.exercises(for: model.environment)
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Exercise.Level.allCases, id: \.self) { level in
                    let group = exercises.filter { $0.level == level }
                    if !group.isEmpty {
                        Section(level.title) {
                            ForEach(group) { exercise in
                                ExerciseRow(exercise: exercise, passed: model.passedExercises.contains(exercise.id))
                                    .tag(exercise.id)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .safeAreaInset(edge: .bottom) {
                Text("\(exercises.filter { model.passedExercises.contains($0.id) }.count) of \(exercises.count) passed in \(model.environment.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        } detail: {
            if let exercise = exercises.first(where: { $0.id == selection }) {
                ExerciseDetail(exercise: exercise)
                    .id(exercise.id)
            } else {
                ContentUnavailableView("Choose an exercise", systemImage: "graduationcap", description: Text("Each one comes with its wiring, hints, a reference solution and an automatic check of your program."))
            }
        }
        .navigationTitle("Exercises · \(model.environment.title)")
        .onChange(of: model.environment) {
            selection = nil
        }
    }
}

private struct ExerciseRow: View {
    let exercise: Exercise
    let passed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(passed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(exercise.number). \(exercise.title)")
                    .lineLimit(1)
                Text(exercise.skills.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(passed ? "Passed" : "Not passed yet")
    }
}

private struct ExerciseDetail: View {
    let exercise: Exercise

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var revealedHints = 0
    @State private var showsSolution = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exercise \(exercise.number) · \(exercise.level.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(exercise.title)
                        .font(.title2.weight(.semibold))
                    Text(exercise.skills.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text(exercise.goal)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                wiring

                HStack(spacing: 10) {
                    Button {
                        model.activate(exercise)
                        openWindow(id: WindowID.trainer)
                    } label: {
                        Label(isWired ? "Wired to the trainer" : "Wire to the trainer", systemImage: "switch.2")
                    }
                    .disabled(isWired)
                    Button {
                        model.check(exercise)
                    } label: {
                        Label("Check my program", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }

                if let report = model.reports[exercise.id] {
                    ReportView(report: report)
                }

                hints

                VStack(alignment: .leading, spacing: 8) {
                    Button(showsSolution ? "Hide the reference solution" : "Show a reference solution") {
                        showsSolution.toggle()
                    }
                    if showsSolution {
                        Text(exercise.solution)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var isWired: Bool { model.activeExercise?.id == exercise.id }

    private var wiring: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wiring")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(exercise.io) { assignment in
                    GridRow {
                        Text(BoardAddressing.name(assignment.point, in: exercise.environment))
                            .font(.system(.body, design: .monospaced))
                        Text(assignment.label)
                        Text(describe(assignment.device))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hints: some View {
        if !exercise.hints.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hints")
                    .font(.headline)
                ForEach(Array(exercise.hints.prefix(revealedHints).enumerated()), id: \.offset) { index, hint in
                    Label {
                        Text(hint)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                if revealedHints < exercise.hints.count {
                    Button(revealedHints == 0 ? "Show a hint" : "Show another hint") {
                        revealedHints += 1
                    }
                }
            }
        }
    }

    private func describe(_ device: IOAssignment.Device) -> String {
        switch device {
        case .pushButton: return "Push button (NO)"
        case .pushButtonNC: return "Push button, wired NC"
        case .selectorSwitch: return "Switch"
        case .sensor: return "Sensor (NO)"
        case .sensorNC: return "Sensor, wired NC"
        case .lamp: return "Lamp"
        case .motor: return "Contactor / motor"
        case .valve: return "Valve"
        case .analogSensor: return "Analog input"
        case .analogActuator: return "Analog output"
        }
    }
}

private struct ReportView: View {
    let report: CheckReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.passed ? "Passed" : "Not yet", systemImage: report.passed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(report.passed ? Color.green : Color.red)
            ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.passed ? "checkmark" : "xmark")
                        .foregroundStyle(line.passed ? Color.green : Color.red)
                    Text(line.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if line.time > 0 {
                        Text(String(format: "%.2f s", Double(line.time) / 1_000))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((report.passed ? Color.green : Color.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
