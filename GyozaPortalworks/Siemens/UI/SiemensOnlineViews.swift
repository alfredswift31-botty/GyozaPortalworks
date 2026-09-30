import AppKit
import SwiftUI

// MARK: - Watch table

/// A watch table: Name, Address, Display format, Monitor value, Modify value, the modify box, Comment.
struct SiemensWatchTableView: View {
    let workspace: SiemensWorkspace
    let table: SiemensWatchTable

    var body: some View {
        let _ = workspace.session?.frame
        VStack(spacing: 0) {
            SiemensWatchToolbar(workspace: workspace, table: table)
            SiemensTableHeader(columns: [("Name", SiemensColumns.name), ("Address", SiemensColumns.address),
                                         ("Display format", SiemensColumns.type), ("Monitor value", SiemensColumns.monitor),
                                         ("Modify value", SiemensColumns.value), ("", 26), ("Comment", nil)])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(table.rows) { row in
                        SiemensWatchRowView(workspace: workspace, table: table, row: row)
                    }
                    SiemensWatchAddRow { text in workspace.addWatchRow(text, to: table.id) }
                }
            }
        }
        .background(SiemensColors.theme.editorBackground)
    }
}

private struct SiemensWatchToolbar: View {
    let workspace: SiemensWorkspace
    let table: SiemensWatchTable

    var body: some View {
        let monitoring = workspace.monitoredWatchTables.contains(table.id)
        HStack(spacing: 4) {
            button("eyeglasses", "Monitor all", active: monitoring) { workspace.toggleMonitorAll(table.id) }
            button("eye", "Monitor now") { workspace.monitorNow(table.id) }
            Divider().frame(height: 16)
            button("bolt.fill", "Modify now") { workspace.modifyNow(table.id) }
            Spacer()
            Text(monitoring ? "Monitoring" : (workspace.isOnline ? "Online" : "Offline"))
                .font(.system(size: 10))
                .foregroundStyle(monitoring ? SiemensColors.online : Color.secondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(SiemensColors.theme.paneBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func button(_ image: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 24, height: 20)
                .foregroundStyle(active ? SiemensColors.online : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SiemensWatchRowView: View {
    let workspace: SiemensWorkspace
    let table: SiemensWatchTable
    let row: SiemensWatchRow

    var body: some View {
        if row.isCommentLine {
            SiemensCellField(text: "// " + row.comment) { text in
                let body = text.hasPrefix("//") ? String(text.dropFirst(2)) : text
                workspace.updateWatchRow(row.id, in: table.id) { $0.comment = body.trimmingCharacters(in: .whitespaces) }
            }
            .foregroundStyle(.green)
            .frame(height: 22)
            .contextMenu { Button("Delete") { workspace.deleteWatchRow(row.id, in: table.id) } }
        } else {
            SiemensWatchValueRow(workspace: workspace, table: table, row: row)
        }
    }
}

private struct SiemensWatchValueRow: View {
    let workspace: SiemensWorkspace
    let table: SiemensWatchTable
    let row: SiemensWatchRow

    var body: some View {
        // A row of a lazy stack: read the refresh counter here so its monitor value stays live.
        let _ = workspace.session?.frame
        let resolved = resolve()
        HStack(spacing: 0) {
            SiemensCellField(text: row.operand) { text in workspace.updateWatchRow(row.id, in: table.id) { $0.operand = text } }
                .frame(width: SiemensColumns.name)
            Divider()
            Text(resolved.address)
                .font(.system(size: 11))
                .frame(width: SiemensColumns.address, alignment: .leading)
                .padding(.leading, 4)
            Divider()
            Picker("", selection: Binding(get: { row.displayFormat ?? S7DisplayFormat.standard(for: resolved.type) }, set: { format in
                workspace.updateWatchRow(row.id, in: table.id) { $0.displayFormat = format }
            })) {
                ForEach(S7DisplayFormat.available(for: resolved.type), id: \.self) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: SiemensColumns.type)
            Divider()
            Text(workspace.watchValue(row, table: table.id) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(workspace.monitoredWatchTables.contains(table.id) ? Color.primary : Color.secondary)
                .frame(width: SiemensColumns.monitor, alignment: .leading)
                .padding(.leading, 4)
            Divider()
            SiemensCellField(text: row.modifyValue) { text in workspace.updateWatchRow(row.id, in: table.id) { $0.modifyValue = text } }
                .frame(width: SiemensColumns.value)
            Divider()
            Toggle("", isOn: Binding(get: { row.isModifyEnabled }, set: { value in
                workspace.updateWatchRow(row.id, in: table.id) { $0.isModifyEnabled = value }
            }))
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 26)
            .help("Include this row in Modify now")
            Divider()
            SiemensCellField(text: row.comment) { text in workspace.updateWatchRow(row.id, in: table.id) { $0.comment = text } }
        }
        .frame(height: 22)
        .contextMenu {
            Button("Modify now") { workspace.modifyOperand(row.operand, to: row.modifyValue, format: row.displayFormat) }
                .disabled(row.modifyValue.isEmpty)
            Button("Delete") { workspace.deleteWatchRow(row.id, in: table.id) }
        }
    }

    /// The tag's address and type, when the operand names a tag or an address.
    private func resolve() -> (address: String, type: PLCDataType) {
        let text = row.operand.trimmingCharacters(in: .whitespaces)
        if let entry = workspace.project.allTags.first(where: { "\"\($0.tag.name)\"" == text || $0.tag.name == text }) {
            return (entry.tag.address, entry.tag.dataType)
        }
        if let address = try? S7Address.parse(text) {
            return (address.description, address.width.defaultType)
        }
        return ("", .int)
    }
}

private struct SiemensWatchAddRow: View {
    let add: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("<Add new>", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.leading, 4)
            .frame(height: 22)
            .onSubmit {
                add(draft)
                draft = ""
            }
            .help("Type an operand, or // for a comment line, and press Return")
    }
}

// MARK: - Force table

/// The force table: I/O addresses with ":P", Force to 0/1, Force all, Stop forcing.
struct SiemensForceTableView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        let _ = workspace.session?.frame
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Force all") { workspace.requestForceAll() }
                Button("Stop forcing") { workspace.stopForcing() }
                Spacer()
                if workspace.cpu?.isMaintenanceLEDOn == true {
                    Label("Force jobs active (MAINT)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .controlSize(.small)
            .padding(6)
            SiemensTableHeader(columns: [("Name", SiemensColumns.name), ("Monitor value", SiemensColumns.monitor),
                                         ("Force value", SiemensColumns.value), ("F", 26), ("Comment", nil)])
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(workspace.project.forceTable) { row in
                        SiemensForceRowView(workspace: workspace, row: row)
                    }
                    SiemensWatchAddRow { text in workspace.addForceRow(text) }
                }
            }
        }
        .background(SiemensColors.theme.editorBackground)
    }
}

private struct SiemensForceRowView: View {
    let workspace: SiemensWorkspace
    let row: SiemensForceRow

    var body: some View {
        let _ = workspace.session?.frame
        HStack(spacing: 0) {
            SiemensCellField(text: row.operand) { text in workspace.updateForceRow(row.id) { $0.operand = text } }
                .frame(width: SiemensColumns.name)
            Divider()
            Text(workspace.monitorValue(ofOperand: row.operand) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: SiemensColumns.monitor, alignment: .leading)
                .padding(.leading, 4)
            Divider()
            SiemensCellField(text: row.forceValue) { text in workspace.updateForceRow(row.id) { $0.forceValue = text } }
                .frame(width: SiemensColumns.value)
            Divider()
            Toggle("", isOn: Binding(get: { row.isForceEnabled }, set: { value in
                workspace.updateForceRow(row.id) { $0.isForceEnabled = value }
            }))
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 26)
            Divider()
            SiemensCellField(text: row.comment) { text in workspace.updateForceRow(row.id) { $0.comment = text } }
        }
        .frame(height: 22)
        .contextMenu {
            Button("Force to 1") { workspace.force(row, to: true) }
            Button("Force to 0") { workspace.force(row, to: false) }
            Divider()
            Button("Delete") { workspace.deleteForceRow(row.id) }
        }
    }
}

// MARK: - Device configuration

/// PLC_1's device view: the CPU drawing, onboard I/O and the settings the program depends on.
struct SiemensDeviceConfigurationView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        let device = workspace.project.device
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    SiemensCPUDrawing(hasSignalBoard: device.hasSignalBoard)
                    SiemensDeviceFacts(device: device)
                }
                SiemensDeviceSettings(workspace: workspace, device: device)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SiemensColors.theme.editorBackground)
    }
}

/// A CPU 1214C drawn with shapes: housing, terminal strips, status LEDs and the signal board slot.
private struct SiemensCPUDrawing: View {
    let hasSignalBoard: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.27, green: 0.33, blue: 0.37))
                .frame(width: 220, height: 150)
            VStack(alignment: .leading, spacing: 0) {
                terminalStrip(count: 14)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(["RUN/STOP", "ERROR", "MAINT"], id: \.self) { label in
                            HStack(spacing: 3) {
                                Circle().fill(Color.gray.opacity(0.6)).frame(width: 5, height: 5)
                                Text(label).font(.system(size: 6)).foregroundStyle(.white)
                            }
                        }
                    }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(hasSignalBoard ? Color(red: 0.2, green: 0.25, blue: 0.28) : Color.black.opacity(0.3))
                        .frame(width: 60, height: 40)
                        .overlay(Text(hasSignalBoard ? "SB 1232\nAQ" : "SB slot").font(.system(size: 7)).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("S7-1200").font(.system(size: 7)).foregroundStyle(.white.opacity(0.7))
                        Text("CPU 1214C").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        Text("DC/DC/DC").font(.system(size: 8)).foregroundStyle(.white)
                    }
                }
                .padding(8)
                Spacer(minLength: 0)
                terminalStrip(count: 10)
            }
            .frame(width: 220, height: 150)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU 1214C DC/DC/DC\(hasSignalBoard ? " with SB 1232 AQ" : "")")
    }

    private func terminalStrip(count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.75, green: 0.75, blue: 0.72))
                    .frame(width: 10, height: 12)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct SiemensDeviceFacts: View {
    let device: SiemensDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(device.name) [\(device.cpuType)]").font(.system(size: 13, weight: .semibold))
            fact("Article number", device.articleNumber)
            fact("Firmware version", device.firmware)
            fact("IP address", "192.168.0.1")
            fact("Digital inputs", "14 DI 24 V DC: %I0.0 … %I0.7, %I1.0 … %I1.5")
            fact("Digital outputs", "10 DQ 24 V DC: %Q0.0 … %Q0.7, %Q1.0 … %Q1.1")
            fact("Analog inputs", "2 AI 0…10 V: %IW64, %IW66 (0 … 27648)")
            fact("Signal board", device.hasSignalBoard ? "\(device.signalBoard): 1 AQ at %QW80" : "none")
        }
        .font(.system(size: 11))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title + ":").foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value)
        }
    }
}

/// Properties › General › System and clock memory, plus the signal board.
private struct SiemensDeviceSettings: View {
    let workspace: SiemensWorkspace
    let device: SiemensDevice

    var body: some View {
        GroupBox("System and clock memory") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("Enable the use of system memory byte", isOn: Binding(get: { device.isSystemMemoryEnabled }, set: { value in
                        workspace.updateDevice { $0.setSystemMemory(enabled: value) }
                    }))
                    Stepper("Address of system memory byte (MBx): \(device.systemMemoryByte)", value: Binding(get: { device.systemMemoryByte },
                        set: { value in workspace.updateDevice { $0.setSystemMemory(enabled: device.isSystemMemoryEnabled, byte: max(0, min(value, 8_191))) } }))
                        .disabled(!device.isSystemMemoryEnabled)
                }
                HStack {
                    Toggle("Enable the use of clock memory byte", isOn: Binding(get: { device.isClockMemoryEnabled }, set: { value in
                        workspace.updateDevice { $0.setClockMemory(enabled: value) }
                    }))
                    Stepper("Address of clock memory byte (MBx): \(device.clockMemoryByte)", value: Binding(get: { device.clockMemoryByte },
                        set: { value in workspace.updateDevice { $0.setClockMemory(enabled: device.isClockMemoryEnabled, byte: max(0, min(value, 8_191))) } }))
                        .disabled(!device.isClockMemoryEnabled)
                }
                Stepper("Retentive memory: bytes of bit memory from MB0: \(device.retentiveMarkerBytes)",
                        value: Binding(get: { device.retentiveMarkerBytes },
                                       set: { value in workspace.updateDevice { $0.device.retentiveMarkerBytes = max(0, min(value, 8_192)) } }))
                Toggle("SB 1232 AQ signal board (1 analog output at %QW80)", isOn: Binding(get: { device.hasSignalBoard }, set: { value in
                    workspace.updateDevice { $0.device.hasSignalBoard = value }
                }))
            }
            .font(.system(size: 11))
            .padding(6)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Online & diagnostics

/// Online & diagnostics: the CPU operator panel and the diagnostics buffer.
struct SiemensOnlineDiagnosticsView: View {
    let workspace: SiemensWorkspace

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Online access").font(.system(size: 12, weight: .semibold))
                Text(workspace.isOnline ? "Online: PLC_1 at 192.168.0.1 (PLCSIM)" : "Offline")
                    .font(.system(size: 11))
                    .foregroundStyle(workspace.isOnline ? SiemensColors.online : Color.secondary)
                HStack {
                    Button("Go online") { workspace.goOnline() }.disabled(workspace.isOnline)
                    Button("Go offline") { workspace.goOffline() }.disabled(!workspace.isOnline)
                }
                .controlSize(.small)
                SiemensOperatorPanel(workspace: workspace)
                    .background(SiemensColors.theme.paneBackground, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
            }
            .padding(12)
            .frame(width: 300)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Diagnostics buffer").font(.system(size: 12, weight: .semibold)).padding(8)
                SiemensDiagnosticsBuffer(workspace: workspace)
            }
        }
        .background(SiemensColors.theme.editorBackground)
    }
}
