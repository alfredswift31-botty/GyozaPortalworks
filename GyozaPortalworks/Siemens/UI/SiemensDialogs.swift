import AppKit
import SwiftUI

// MARK: - Add new block

/// "Add new block": OB / FB / FC / DB, Name, Language, Number, "Add new and open".
struct SiemensAddNewBlockDialog: View {
    let workspace: SiemensWorkspace
    @State var request: SiemensNewBlockRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add new block")
                .font(.headline)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    ForEach(SiemensNewBlockRequest.Kind.allCases, id: \.self) { kind in
                        SiemensBlockKindButton(kind: kind, isSelected: request.kind == kind) {
                            request = SiemensNewBlockRequest.defaults(kind, in: workspace.project)
                        }
                    }
                }
                SiemensNewBlockForm(workspace: workspace, request: $request)
                    .frame(width: 340)
            }
            if let problem = request.problem(in: workspace.project) {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Toggle("Add new and open", isOn: $request.openAfterAdding)
                Spacer()
                Button("Cancel") { workspace.newBlockRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { workspace.addNewBlock(request) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.problem(in: workspace.project) != nil)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

private struct SiemensBlockKindButton: View {
    let kind: SiemensNewBlockRequest.Kind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(kind.shortTitle)
                    .font(.system(size: 18, weight: .bold))
                Text(kind.rawValue)
                    .font(.system(size: 9))
            }
            .frame(width: 110, height: 52)
            .background(isSelected ? SiemensColors.theme.selection : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? SiemensColors.theme.accent : Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.rawValue)
    }
}

private struct SiemensNewBlockForm: View {
    let workspace: SiemensWorkspace
    @Binding var request: SiemensNewBlockRequest

    var body: some View {
        Form {
            TextField("Name:", text: $request.name)
            if request.kind == .dataBlock {
                Picker("Type:", selection: $request.dataBlockType) {
                    ForEach(SiemensNewBlockRequest.dataBlockTypes(in: workspace.project), id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
            } else {
                Picker("Language:", selection: $request.language) {
                    ForEach(SiemensLanguage.allCases, id: \.self) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
            }
            if request.kind == .organizationBlock {
                Picker("Event class:", selection: $request.event) {
                    ForEach(SiemensOBEvent.allCases, id: \.self) { event in
                        Text(event.rawValue).tag(event)
                    }
                }
            }
            Picker("Number:", selection: $request.isNumberAutomatic) {
                Text("Manual").tag(false)
                Text("Automatic").tag(true)
            }
            .pickerStyle(.radioGroup)
            if !request.isNumberAutomatic {
                TextField("", value: $request.number, format: .number)
            } else {
                Text("\(request.number)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - Call options

/// "Call options": Single instance (instance DB) or Multi instance (Static of the FB).
struct SiemensCallOptionsDialog: View {
    let workspace: SiemensWorkspace
    @State var options: SiemensCallOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Call options")
                .font(.headline)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    modeButton(.singleInstance, "cylinder", "The called block saves its data in its own instance data block.")
                    modeButton(.multiInstance, "square.stack.3d.down.right",
                               "The called block saves its data as a multi-instance in the instance data block of the calling function block.")
                        .disabled(!options.allowsMultiInstance)
                }
                Form {
                    TextField("Name:", text: $options.name)
                    if options.mode == .singleInstance {
                        Picker("Number:", selection: $options.isNumberAutomatic) {
                            Text("Manual").tag(false)
                            Text("Automatic").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        if !options.isNumberAutomatic {
                            TextField("", value: $options.number, format: .number)
                        }
                    } else {
                        Text("Declared in the interface of \(workspace.block(options.blockID)?.displayName ?? "the FB") (Static).")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 300)
            }
            if let block = workspace.block(options.blockID), let problem = options.problem(in: workspace.project, block: block) {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { workspace.cancelCallOptions() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { workspace.confirmCallOptions(options) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func modeButton(_ mode: SiemensCallOptions.Mode, _ image: String, _ help: String) -> some View {
        Button {
            if let block = workspace.block(options.blockID) {
                options.switchMode(to: mode, block: block, project: workspace.project)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: image)
                    .font(.system(size: 20))
                Text(mode.rawValue)
                    .font(.system(size: 10))
            }
            .frame(width: 130, height: 60)
            .background(options.mode == mode ? SiemensColors.theme.selection : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(mode.rawValue)
    }
}

// MARK: - Download

/// Extended download to device → Load preview → Load results.
struct SiemensLoadDialog: View {
    let workspace: SiemensWorkspace
    let step: SiemensLoadStep

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case let .extendedDownload(searched):
                SiemensExtendedDownload(workspace: workspace, searched: searched)
            case let .loadPreview(stopModules):
                SiemensLoadPreview(workspace: workspace, stopModules: stopModules)
            case let .loadResults(startAll):
                SiemensLoadResults(workspace: workspace, startAll: startAll)
            }
        }
        .padding(18)
        .frame(width: 640)
    }
}

private struct SiemensExtendedDownload: View {
    let workspace: SiemensWorkspace
    let searched: Bool

    var body: some View {
        Text("Extended download to device").font(.headline)
        Form {
            LabeledContent("Type of the PG/PC interface:", value: "PN/IE")
            LabeledContent("PG/PC interface:", value: "PLCSIM")
            LabeledContent("Connection to interface/subnet:", value: "Direct at slot '1 X1'")
        }
        .font(.system(size: 12))
        Text("Select target device:").font(.system(size: 12, weight: .semibold))
        VStack(spacing: 0) {
            SiemensTableHeader(columns: [("Device", 140), ("Device type", 170), ("Interface type", 110), ("Address", nil)])
            if searched {
                HStack(spacing: 0) {
                    Text("CPUcommon").frame(width: 140, alignment: .leading)
                    Text("CPU 1214C DC/DC/DC").frame(width: 170, alignment: .leading)
                    Text("PN/IE").frame(width: 110, alignment: .leading)
                    Text("192.168.0.1")
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(4)
                .background(SiemensColors.theme.selection)
            } else {
                Text("Click \"Start search\" to find accessible devices.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
        HStack {
            Button("Start search") { workspace.searchDevices() }
            Spacer()
            Button("Cancel") { workspace.cancelLoad() }
                .keyboardShortcut(.cancelAction)
            Button("Load") { workspace.loadFromExtendedDownload() }
                .keyboardShortcut(.defaultAction)
                .disabled(!searched)
        }
    }
}

private struct SiemensLoadPreview: View {
    let workspace: SiemensWorkspace
    let stopModules: Bool

    var body: some View {
        Text("Load preview").font(.headline)
        Text("Check before loading")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        VStack(spacing: 0) {
            SiemensTableHeader(columns: [("Status", 50), ("Target", 150), ("Message", nil), ("Action", 150)])
            SiemensLoadRow(ok: true, target: "PLC_1", message: "Ready for loading.", action: "")
            if stopModules {
                SiemensLoadRow(ok: false, target: "Modules", message: "The modules are stopped for downloading to device.",
                               action: "Stop all")
            }
            SiemensLoadRow(ok: true, target: "Software", message: "Download software to device", action: "Consistent download")
        }
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
        HStack {
            Spacer()
            Button("Cancel") { workspace.cancelLoad() }
                .keyboardShortcut(.cancelAction)
            Button("Load") { workspace.confirmLoadPreview() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct SiemensLoadResults: View {
    let workspace: SiemensWorkspace
    let startAll: Bool

    var body: some View {
        Text("Load results").font(.headline)
        Text("Status and actions after downloading to device")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        VStack(spacing: 0) {
            SiemensTableHeader(columns: [("Status", 50), ("Target", 150), ("Message", nil), ("Action", 150)])
            SiemensLoadRow(ok: true, target: "PLC_1", message: "Downloading to device completed without error.", action: "")
            HStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 50)
                Text("Start modules").frame(width: 150, alignment: .leading)
                Text("Start modules after downloading to device.").frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Start all", isOn: Binding(get: { startAll }, set: { workspace.setLoadStartAll($0) }))
                    .frame(width: 150, alignment: .leading)
            }
            .font(.system(size: 11))
            .padding(.vertical, 4)
        }
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
        HStack {
            Spacer()
            Button("Finish") { workspace.finishLoad(startAll: startAll) }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct SiemensLoadRow: View {
    let ok: Bool
    let target: String
    let message: String
    let action: String

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .frame(width: 50)
            Text(target).frame(width: 150, alignment: .leading)
            Text(message).frame(maxWidth: .infinity, alignment: .leading)
            Text(action).frame(width: 150, alignment: .leading)
        }
        .font(.system(size: 11))
        .padding(.vertical, 4)
    }
}

// MARK: - S7-PLCSIM

/// The compact S7-PLCSIM window floating over the workspace.
struct SiemensPLCSIMWindow: View {
    let workspace: SiemensWorkspace

    var body: some View {
        let _ = workspace.session?.frame
        let cpu = workspace.cpu
        let phase = ((cpu?.clock ?? 0) / 250) % 2 == 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu")
                Text("S7-PLCSIM")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    workspace.stopSimulation()
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("Power off the simulation")
                .accessibilityLabel("Power off the simulation")
            }
            Text("PLC_1 [CPU 1214C DC/DC/DC]")
                .font(.system(size: 11))
            Text("IP address: 192.168.0.1")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                SiemensLED(title: cpu?.mode == .run ? "RUN" : "STOP", color: cpu?.mode == .run ? .green : .orange, isOn: cpu != nil)
                SiemensLED(title: "ERROR", color: .red, isOn: false, isFlashing: cpu?.isErrorLEDFlashing ?? false, phase: phase)
                SiemensLED(title: "MAINT", color: .orange, isOn: cpu?.isMaintenanceLEDOn ?? false)
            }
            HStack(spacing: 6) {
                Button("RUN") { workspace.setCPUMode(.run) }
                    .disabled(cpu?.image == nil || cpu?.mode == .run)
                Button("STOP") { workspace.setCPUMode(.stop) }
                    .disabled(cpu?.mode != .run)
                Button("MRES") { workspace.confirmation = .memoryReset }
                    .disabled(cpu == nil)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
        .shadow(radius: 6)
    }
}
