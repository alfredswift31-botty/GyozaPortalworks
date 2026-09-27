import AppKit
import SwiftUI

/// Colours of TIA's LAD/FBD monitoring and validation.
nonisolated enum SiemensColors {
    static let theme = VendorTheme.tiaPortal
    /// Power flows: green solid line.
    static let satisfied = Color(red: 0.0, green: 0.62, blue: 0.2)
    /// No power flow: blue dashed line.
    static let notSatisfied = Color(red: 0.1, green: 0.35, blue: 0.85)
    /// Unknown / not executed: grey.
    static let unknown = Color.secondary
    static let placeholder = Color.red
    static let duplicate = Color.yellow.opacity(0.35)
    static let error = Color.red.opacity(0.22)
    static let online = VendorTheme.tiaPortal.online

    static func wire(_ signal: S7Signal?) -> Color {
        switch signal {
        case .satisfied?: return satisfied
        case .notSatisfied?: return notSatisfied
        case .unknown?, nil: return Color.primary.opacity(0.75)
        }
    }

    static func stroke(_ signal: S7Signal?) -> StrokeStyle {
        signal == .notSatisfied ? StrokeStyle(lineWidth: 1.5, dash: [4, 3]) : StrokeStyle(lineWidth: signal == .satisfied ? 2 : 1.2)
    }
}

/// A table cell that edits text and commits on Return or when focus leaves.
struct SiemensCellField: View {
    let text: String
    var placeholder = ""
    var isError = false
    var isWarning = false
    var onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .focused($focused)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .background(background)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !focused { draft = newValue }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit { commit() }
    }

    private var background: Color {
        if isError { return SiemensColors.error }
        if isWarning { return SiemensColors.duplicate }
        return Color.clear
    }

    private func commit() {
        if draft != text { onCommit(draft) }
    }
}

/// A header cell of a TIA table.
struct SiemensHeaderCell: View {
    let title: String
    var width: CGFloat?

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SiemensColors.theme.paneHeaderText)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// One CPU status LED.
struct SiemensLED: View {
    let title: String
    let color: Color
    let isOn: Bool
    var isFlashing = false
    var phase = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(lit ? color : Color.gray.opacity(0.35))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) LED \(lit ? "on" : "off")")
    }

    private var lit: Bool {
        isFlashing ? phase : isOn
    }
}

/// The CPU operator panel: RUN/STOP, ERROR and MAINT LEDs and the RUN / STOP / MRES buttons.
struct SiemensOperatorPanel: View {
    let workspace: SiemensWorkspace
    var showsButtons = true

    var body: some View {
        let _ = workspace.session?.frame
        let cpu = workspace.cpu
        let phase = ((cpu?.clock ?? 0) / 250) % 2 == 0
        VStack(alignment: .leading, spacing: 8) {
            Text("CPU operator panel")
                .font(.system(size: 11, weight: .semibold))
            Text("PLC_1 [CPU 1214C DC/DC/DC]")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                SiemensLED(title: "RUN / STOP", color: cpu?.mode == .run ? .green : .orange, isOn: cpu != nil)
                SiemensLED(title: "ERROR", color: .red, isOn: false, isFlashing: cpu?.isErrorLEDFlashing ?? false, phase: phase)
                SiemensLED(title: "MAINT", color: .orange, isOn: cpu?.isMaintenanceLEDOn ?? false)
            }
            if showsButtons {
                HStack(spacing: 8) {
                    Button("RUN") { workspace.requestStartCPU() }
                        .disabled(cpu == nil || cpu?.mode == .run)
                    Button("STOP") { workspace.requestStopCPU() }
                        .disabled(cpu == nil || cpu?.mode == .stop)
                    Button("MRES") { workspace.confirmation = .memoryReset }
                        .disabled(cpu == nil)
                }
                .controlSize(.small)
            }
            Text(cpu == nil ? "Offline: no simulation is running." : "Mode: \(cpu?.mode.rawValue ?? "")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

/// The diagnostics buffer of the CPU, newest first.
struct SiemensDiagnosticsBuffer: View {
    let workspace: SiemensWorkspace

    var body: some View {
        let _ = workspace.session?.frame
        let events = Array((workspace.cpu?.diagnostics ?? []).reversed())
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SiemensHeaderCell(title: "No.", width: 40)
                SiemensHeaderCell(title: "Time", width: 90)
                SiemensHeaderCell(title: "Event")
            }
            .frame(height: 22)
            .background(SiemensColors.theme.paneHeader)
            if events.isEmpty {
                Text("The diagnostics buffer is empty.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        SiemensDiagnosticRow(number: index + 1, event: event)
                    }
                }
            }
        }
    }
}

private struct SiemensDiagnosticRow: View {
    let number: Int
    let event: DiagnosticEvent

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .frame(width: 40, alignment: .leading)
            Text(Self.time(event.time))
                .frame(width: 90, alignment: .leading)
            Image(systemName: event.isError ? "exclamationmark.circle.fill" : "info.circle")
                .foregroundStyle(event.isError ? Color.red : Color.secondary)
                .padding(.trailing, 4)
            Text(event.message)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    static func time(_ milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", seconds / 3_600, (seconds / 60) % 60, seconds % 60, milliseconds % 1_000)
    }
}
