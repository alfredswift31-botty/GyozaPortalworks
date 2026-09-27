import SwiftUI

/// The floating "GX Simulator3" window: LEDs, the RUN/STOP switch and RESET.
struct MelsecSimulatorPanel: View {
    let workspace: MelsecWorkspace
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        let _ = workspace.session?.frame
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 10) {
                Text("1.1 FX5UCPU")
                    .font(.system(size: 12, weight: .semibold))
                ledGroup
                switchGroup
                if let error = workspace.cpu?.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
        .shadow(radius: 8)
        .offset(offset)
    }

    private var titleBar: some View {
        HStack {
            Text("GX Simulator3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(workspace.theme.paneHeaderText)
            Spacer()
            Button {
                workspace.isSimulatorPanelVisible = false
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(workspace.theme.paneHeaderText)
            .help("Hide GX Simulator3 (Debug › Simulation › Show GX Simulator3 brings it back)")
            .accessibilityLabel("Hide GX Simulator3")
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(workspace.theme.paneHeader, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .gesture(DragGesture().onChanged { value in
            offset = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height)
        }.onEnded { _ in
            dragStart = offset
        })
    }

    private var ledGroup: some View {
        GroupBox("LED") {
            HStack(spacing: 14) {
                MelsecLED(title: "READY", isOn: workspace.session?.isRunning == true, color: .green)
                MelsecLED(title: "ERROR", isOn: workspace.cpu?.hasError == true, color: .red)
                MelsecLED(title: "P RUN", isOn: workspace.session?.mode == .run, color: .green)
                MelsecLED(title: "USER", isOn: false, color: .red)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var switchGroup: some View {
        GroupBox("SWITCH") {
            HStack {
                Picker("Switch", selection: Binding(get: { workspace.simulatorSwitch }, set: { workspace.setSwitch($0) })) {
                    Text("RUN").tag(CPUMode.run)
                    Text("STOP").tag(CPUMode.stop)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                Spacer()
                Button("RESET(R)") {
                    workspace.resetCPU()
                }
                .help("Reset the CPU: clears the error and non-latched devices")
            }
        }
    }
}

private struct MelsecLED: View {
    let title: String
    let isOn: Bool
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .fill(isOn ? color : Color.gray.opacity(0.3))
                .frame(width: 12, height: 12)
                .shadow(color: isOn ? color : .clear, radius: 3)
            Text(title)
                .font(.system(size: 9, weight: .medium))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) LED \(isOn ? "on" : "off")")
    }
}
