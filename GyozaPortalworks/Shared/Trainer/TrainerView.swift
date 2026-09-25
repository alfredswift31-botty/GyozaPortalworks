import SwiftUI

/// The I/O trainer: a bench of switches, push buttons, lamps and analog
/// knobs wired to the simulated CPU of the tool that's showing.
struct TrainerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.activeSession {
                TrainerBoard(session: session, environment: model.environment, exercise: model.activeExercise)
            } else {
                ContentUnavailableView {
                    Label("\(model.environment.simulatorName) isn't running", systemImage: "powerplug")
                } description: {
                    Text("Start the simulation in \(model.environment.title) with \(model.environment.startSimulationHint). The trainer then wires itself to the simulated \(model.environment.controller).")
                }
            }
        }
        .frame(minWidth: 540, minHeight: 380)
    }
}

private struct TrainerBoard: View {
    let session: SimulationSession
    let environment: PracticeEnvironment
    let exercise: Exercise?

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10)]

    var body: some View {
        // Reading the frame counter redraws the board with every refresh.
        let _ = session.frame
        let cpu = session.cpu
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                section("Inputs") {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(0..<cpu.digitalInputCount, id: \.self) { index in
                            InputControl(session: session, index: index, assignment: exercise?.assignment(for: .digitalInput(index)))
                        }
                    }
                }
                section("Outputs") {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(0..<cpu.digitalOutputCount, id: \.self) { index in
                            OutputIndicator(name: cpu.digitalOutputName(index), isOn: cpu.digitalOutput(index), assignment: exercise?.assignment(for: .digitalOutput(index)))
                        }
                    }
                }
                if cpu.analogInputCount + cpu.analogOutputCount > 0 {
                    section("Analog") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(0..<cpu.analogInputCount, id: \.self) { channel in
                                AnalogInputControl(session: session, channel: channel, assignment: exercise?.assignment(for: .analogInput(channel)))
                            }
                            ForEach(0..<cpu.analogOutputCount, id: \.self) { channel in
                                AnalogOutputGauge(session: session, channel: channel, assignment: exercise?.assignment(for: .analogOutput(channel)))
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.controller)
                    .font(.headline)
                Text(exercise.map { "Wired for exercise \($0.number): \($0.title)" } ?? "Generic wiring: choose an exercise to label the devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ModeBadge(mode: session.mode)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct ModeBadge: View {
    let mode: CPUMode

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mode == .run ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(mode.rawValue)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CPU in \(mode.rawValue)")
    }
}

/// A push button or switch on one digital input, with the input's LED.
private struct InputControl: View {
    let session: SimulationSession
    let index: Int
    let assignment: IOAssignment?

    @State private var isPressed = false

    private var device: IOAssignment.Device { assignment?.device ?? .selectorSwitch }
    private var name: String { session.cpu.digitalInputName(index) }
    private var signal: Bool { session.cpu.digitalInput(index) }
    private var actuated: Bool { device.isNormallyClosed ? !signal : signal }

    var body: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if device.isMomentary {
                pushButton
            } else {
                Toggle(isOn: Binding(get: { actuated }, set: { set(actuated: $0) })) {
                    Text(assignment?.label ?? name)
                }
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Circle()
                .fill(signal ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 7, height: 7)
                .help(signal ? "\(name) = TRUE" : "\(name) = FALSE")
            Text(assignment?.label ?? " ")
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 30, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    private var pushButton: some View {
        Circle()
            .fill(buttonColor.gradient)
            .frame(width: 34, height: 34)
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 2))
            .scaleEffect(isPressed ? 0.9 : 1)
            .shadow(radius: isPressed ? 0 : 2, y: isPressed ? 0 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        set(actuated: true)
                    }
                    .onEnded { _ in
                        isPressed = false
                        set(actuated: false)
                    }
            )
            .help(device.isNormallyClosed ? "Push button, wired normally closed: \(name) is TRUE until pressed." : "Push button: \(name) is TRUE while pressed.")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(assignment?.label ?? name)
    }

    private var buttonColor: Color {
        let label = (assignment?.label ?? "").lowercased()
        if label.contains("stop") || label.contains("reset") { return .red }
        if label.contains("start") || label.contains("forward") || label.contains("reverse") { return .green }
        return .gray
    }

    private func set(actuated: Bool) {
        session.cpu.setDigitalInput(index, device.isNormallyClosed ? !actuated : actuated)
        session.refresh()
    }
}

private struct OutputIndicator: View {
    let name: String
    let isOn: Bool
    let assignment: IOAssignment?

    var body: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if assignment?.device == .motor || assignment?.device == .valve {
                Image(systemName: assignment?.device == .valve ? "spigot.fill" : "gearshape.2.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(isOn ? Color.green : Color.secondary.opacity(0.35))
                    .frame(height: 34)
            } else {
                Circle()
                    .fill(isOn ? lampColor : lampColor.opacity(0.12))
                    .overlay(Circle().strokeBorder(lampColor.opacity(0.6), lineWidth: 1.5))
                    .shadow(color: isOn ? lampColor.opacity(0.8) : .clear, radius: isOn ? 8 : 0)
                    .frame(width: 30, height: 30)
                    .frame(height: 34)
            }
            Text(assignment?.label ?? " ")
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 30, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(assignment?.label ?? name), \(isOn ? "on" : "off")")
    }

    private var lampColor: Color {
        let label = (assignment?.label ?? "").lowercased()
        if label.contains("red") || label.contains("stop") || label.contains("full") || label.contains("high") || label.contains("warning") { return .red }
        if label.contains("amber") || label.contains("low") { return .orange }
        if label.contains("green") || label.contains("run") || label.contains("space") { return .green }
        return .yellow
    }
}

private struct AnalogInputControl: View {
    let session: SimulationSession
    let channel: Int
    let assignment: IOAssignment?

    var body: some View {
        let cpu = session.cpu
        let range = cpu.analogRange
        let value = cpu.analogInput(channel)
        let span = Double(max(1, range.upperBound - range.lowerBound))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cpu.analogInputName(channel))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(assignment?.label ?? "Analog input \(channel + 1)")
                    .font(.caption)
                Spacer()
                Text("\(value)  ·  \(Int((Double(value - range.lowerBound) / span * 100).rounded())) %")
                    .font(.system(.caption, design: .monospaced))
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { newValue in
                        cpu.setAnalogInput(channel, Int(newValue.rounded()))
                        session.refresh()
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .accessibilityLabel(assignment?.label ?? cpu.analogInputName(channel))
        }
    }
}

private struct AnalogOutputGauge: View {
    let session: SimulationSession
    let channel: Int
    let assignment: IOAssignment?

    var body: some View {
        let cpu = session.cpu
        let range = cpu.analogRange
        let value = cpu.analogOutput(channel)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cpu.analogOutputName(channel))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(assignment?.label ?? "Analog output \(channel + 1)")
                    .font(.caption)
                Spacer()
                Text("\(value)")
                    .font(.system(.caption, design: .monospaced))
            }
            Gauge(value: Double(min(max(value, range.lowerBound), range.upperBound)), in: Double(range.lowerBound)...Double(range.upperBound)) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
        }
    }
}
