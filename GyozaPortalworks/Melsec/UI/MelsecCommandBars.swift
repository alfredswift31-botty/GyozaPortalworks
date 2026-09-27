import AppKit
import SwiftUI

/// GX Works3's menu bar and toolbar, built from the workspace's commands.
@MainActor enum MelsecCommandBars {
    static func menus(_ workspace: MelsecWorkspace) -> [(title: String, items: [MenuItem])] {
        [
            ("Project", projectMenu(workspace)),
            ("Edit", editMenu(workspace)),
            ("Find/Replace", findMenu()),
            ("Convert", convertMenu(workspace)),
            ("View", viewMenu(workspace)),
            ("Online", onlineMenu(workspace)),
            ("Debug", debugMenu(workspace)),
            ("Recording", [.command("Recording Setting", isEnabled: false, action: {})]),
            ("Diagnostics", [.command("Module Diagnostics (CPU Diagnostics)", action: { workspace.sheet = .moduleDiagnostics })]),
            ("Tool", toolMenu(workspace)),
            ("Window", windowMenu(workspace)),
            ("Help", helpMenu(workspace)),
        ]
    }

    private static func command(_ workspace: MelsecWorkspace, _ title: String, _ ladder: MelsecLadderCommand, enabled: Bool = true) -> MenuItem {
        .command(title, shortcut: MelsecKeyMap.shortcutText(ladder), isEnabled: enabled, action: { workspace.perform(ladder) })
    }

    private static func projectMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        [
            .command("New…", shortcut: "Ctrl+N", action: {
                workspace.alert = MelsecAlert(title: "New", message: "Discard the current project and create a new FX5U project?", action: .newProject)
            }),
            .command("Open…", shortcut: "Ctrl+O", action: { workspace.openProject() }),
            .divider,
            .command("Save", shortcut: "Ctrl+S", action: { workspace.save() }),
            .command("Save As…", action: { workspace.exportProject() }),
        ]
    }

    private static func editMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        let editable = workspace.mode.allowsEditing && workspace.selectedLadderID != nil
        return [
            .command("Undo", shortcut: "Ctrl+Z", isEnabled: workspace.canUndo, action: { workspace.undo() }),
            .command("Redo", shortcut: "Ctrl+Y", isEnabled: workspace.canRedo, action: { workspace.redo() }),
            .divider,
            .command("Cut", shortcut: "Ctrl+X", isEnabled: editable, action: { MelsecClipboard.cut(workspace) }),
            .command("Copy", shortcut: "Ctrl+C", action: { MelsecClipboard.copy(workspace) }),
            .command("Paste", shortcut: "Ctrl+V", isEnabled: editable, action: { MelsecClipboard.paste(workspace) }),
            .divider,
            command(workspace, "Insert Row", .insertRow, enabled: editable),
            command(workspace, "Delete Row", .deleteRow, enabled: editable),
            command(workspace, "Insert Column", .insertColumn, enabled: editable),
            command(workspace, "Delete Column", .deleteColumn, enabled: editable),
            .divider,
            .submenu("Ladder Edit Mode", [
                .toggle("Overwrite", isOn: !workspace.isInsertMode, shortcut: "Insert", action: {
                    if workspace.isInsertMode { workspace.perform(.toggleInsertMode) }
                }),
                .toggle("Insert", isOn: workspace.isInsertMode, shortcut: "Insert", action: {
                    if !workspace.isInsertMode { workspace.perform(.toggleInsertMode) }
                }),
            ]),
            .submenu("Ladder Symbol", symbolItems(workspace, enabled: editable)),
            .divider,
            .command("Edit Line Statement", isEnabled: editable, action: { workspace.perform(.ladderInput(.openContact, text: ";")) }),
            .command("Edit Note", isEnabled: editable, action: { workspace.perform(.ladderInput(.coil, text: "OUT ?;")) }),
        ]
    }

    /// Ladder symbols with their keys, for the Edit menu.
    static func symbolItems(_ workspace: MelsecWorkspace, enabled: Bool) -> [MenuItem] {
        [
            command(workspace, "Open Contact", .ladderInput(.openContact, text: ""), enabled: enabled),
            command(workspace, "Open Branch", .ladderInput(.openBranch, text: ""), enabled: enabled),
            command(workspace, "Close Contact", .ladderInput(.closeContact, text: ""), enabled: enabled),
            command(workspace, "Close Branch", .ladderInput(.closeBranch, text: ""), enabled: enabled),
            command(workspace, "Coil", .ladderInput(.coil, text: ""), enabled: enabled),
            command(workspace, "Application Instruction", .ladderInput(.instruction, text: ""), enabled: enabled),
            .divider,
            command(workspace, "Rising Pulse", .ladderInput(.risingPulse, text: ""), enabled: enabled),
            command(workspace, "Falling Pulse", .ladderInput(.fallingPulse, text: ""), enabled: enabled),
            command(workspace, "Rising Pulse OR", .ladderInput(.risingPulseBranch, text: ""), enabled: enabled),
            command(workspace, "Falling Pulse OR", .ladderInput(.fallingPulseBranch, text: ""), enabled: enabled),
            command(workspace, "Operation Result Rising Pulse (MEP)", .insertOperationResult(.risingPulse), enabled: enabled),
            command(workspace, "Operation Result Falling Pulse (MEF)", .insertOperationResult(.fallingPulse), enabled: enabled),
            command(workspace, "Invert Operation Results (INV)", .insertOperationResult(.invert), enabled: enabled),
            .divider,
            command(workspace, "Horizontal Line", .drawHorizontalLine, enabled: enabled),
            command(workspace, "Vertical Line", .drawVerticalLine, enabled: enabled),
            command(workspace, "Delete Horizontal Line", .deleteHorizontalLine, enabled: enabled),
            command(workspace, "Delete Vertical Line", .deleteVerticalLine, enabled: enabled),
            .command("Draw Line (Ctrl+Arrow)", isEnabled: enabled, action: { workspace.perform(.drawLine(.right)) }),
        ]
    }

    private static func findMenu() -> [MenuItem] {
        [
            .command("Find Device", shortcut: "Ctrl+F", isEnabled: false, action: {}),
            .command("Cross Reference", isEnabled: false, action: {}),
        ]
    }

    private static func convertMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        [
            command(workspace, "Convert", .convert),
            command(workspace, "Rebuild All", .rebuildAll),
        ]
    }

    private static func viewMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        var docking: [MenuItem] = [
            .command("Output", action: { workspace.bottomTab = .output }),
            .command("Conversion Result", action: { workspace.bottomTab = .conversionResult }),
        ]
        for index in 0..<4 {
            docking.append(.command("Watch \(index + 1)", action: { workspace.bottomTab = .watch(index) }))
        }
        return [.submenu("Docking Window", docking)]
    }

    private static func onlineMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        let online = workspace.session != nil
        return [
            .command("Write to PLC…", isEnabled: online, action: { workspace.writeToPLC() }),
            .command("Read from PLC…", isEnabled: online, action: { workspace.readFromPLC() }),
            .divider,
            .submenu("Monitor", [
                command(workspace, "Monitor Mode", .setMode(.monitor), enabled: online),
                command(workspace, "Monitor (Write Mode)", .setMode(.monitorWrite), enabled: online),
                .command("Stop Monitoring", shortcut: "Alt+F3", isEnabled: workspace.mode.isMonitoring, action: { workspace.perform(.setMode(.write)) }),
                .divider,
                .command("Device/Buffer Memory Batch Monitor", action: { workspace.open(.deviceMemory) }),
            ]),
            .submenu("Watch", watchItems(workspace)),
            .submenu("Remote Operation", [
                .command("RUN", isEnabled: online, action: { workspace.setSwitch(.run) }),
                .command("STOP", isEnabled: online, action: { workspace.setSwitch(.stop) }),
                .command("RESET", isEnabled: online, action: { workspace.resetCPU() }),
                .command("Latch Clear", isEnabled: online, action: { workspace.latchClear() }),
            ]),
        ]
    }

    private static func watchItems(_ workspace: MelsecWorkspace) -> [MenuItem] {
        var items: [MenuItem] = [
            .command("Register to Watch Window 1", isEnabled: workspace.operandAtCursor != nil, action: {
                if let operand = workspace.operandAtCursor { workspace.addWatchEntry(operand, list: 0) }
                workspace.bottomTab = .watch(0)
            }),
            .divider,
        ]
        for index in 0..<4 {
            items.append(.command("Watch Window \(index + 1)", action: { workspace.bottomTab = .watch(index) }))
        }
        return items
    }

    private static func debugMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        let online = workspace.session != nil
        return [
            .submenu("Simulation", [
                .command("Start Simulation", isEnabled: !online, action: { workspace.startSimulation() }),
                .command("Stop Simulation", isEnabled: online, action: { workspace.stopSimulation() }),
                .command("Show GX Simulator3", isEnabled: online, action: { workspace.isSimulatorPanelVisible = true }),
            ]),
            .divider,
            .command("Modify Value…", isEnabled: online, action: {
                workspace.sheet = .modifyValue(device: workspace.operandAtCursor ?? "")
            }),
            .command("Change Current Value (Shift+Enter)", shortcut: "Shift+Enter", isEnabled: workspace.mode.isMonitoring,
                     action: { workspace.perform(.toggleBit) }),
        ]
    }

    private static func toolMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        [
            .command("Program Check…", action: { workspace.sheet = .programCheck }),
            .divider,
            .command("Options…", isEnabled: false, action: {}),
        ]
    }

    private static func windowMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        [
            .command("Close All", action: {
                for tab in workspace.openTabs { workspace.close(tab) }
            }),
        ]
    }

    private static func helpMenu(_ workspace: MelsecWorkspace) -> [MenuItem] {
        [
            .command("Instruction Help", shortcut: "F1", action: { showInstructionHelp(workspace) }),
            .command("Keyboard Shortcuts", action: {
                workspace.alert = MelsecAlert(title: "GX Works3 keys", message: MelsecCommandBars.keyHelp)
            }),
        ]
    }

    static func showInstructionHelp(_ workspace: MelsecWorkspace) {
        let mnemonic = workspace.paletteSelection.flatMap { $0.hasPrefix("item:") ? String($0.dropFirst(5)) : nil }
            ?? workspace.elementAtCursor.text.split(separator: " ").first.map(String.init)
        guard let mnemonic, let definition = MelsecInstructionSet.definition(mnemonic) else {
            workspace.alert = MelsecAlert(title: "Instruction Help", message: "Select an instruction in Element Selection or put the cursor on one.")
            return
        }
        let operands = definition.forms.map { form in
            ([definition.mnemonic] + form.operands.map(\.name)).joined(separator: " ") + "  (\(form.steps) steps)"
        }.joined(separator: "\n")
        workspace.alert = MelsecAlert(title: definition.mnemonic, message: definition.help + "\n\n" + operands)
    }

    static let keyHelp = """
    F2 Write Mode · Shift+F2 Read Mode · F3 Monitor · Shift+F3 Monitor (Write Mode) · Alt+F3 Stop Monitoring
    F4 Convert · Shift+Alt+F4 Rebuild All
    F5 Open Contact · Shift+F5 Open Branch · F6 Close Contact · Shift+F6 Close Branch
    F7 Coil · F8 Application Instruction · Shift+F7/F8 Rising/Falling Pulse · Alt+F7/F8 Pulse OR
    Alt+F5 MEP · Ctrl+Alt+F5 MEF · Ctrl+Alt+F10 INV
    F9 Horizontal Line · Shift+F9 Vertical Line · Ctrl+F9/Ctrl+F10 Delete Lines · Ctrl+Arrow Draw Line
    Shift+Insert/Delete Rows · Ctrl+Insert/Delete Columns · Insert Overwrite/Insert
    Enter Edit · Shift+Enter Change Bit (Monitor) · Ctrl+Z Undo · Ctrl+Y Redo
    On a Mac, hold fn for F-keys, or enable "Use F1, F2, etc. keys as standard function keys". Insert is the Help key or fn+Enter on some keyboards; the Edit menu has every command.
    """

    // MARK: Toolbar

    static func toolItems(_ workspace: MelsecWorkspace) -> [ToolItem] {
        let editable = workspace.mode.allowsEditing && workspace.selectedLadderID != nil
        let online = workspace.session != nil
        var items: [ToolItem] = [
            ToolItem(systemImage: "doc.badge.plus", help: "New Project (Ctrl+N)", action: {
                workspace.alert = MelsecAlert(title: "New", message: "Discard the current project and create a new FX5U project?", action: .newProject)
            }),
            ToolItem(systemImage: "folder", help: "Open Project (Ctrl+O)", action: { workspace.openProject() }),
            ToolItem(systemImage: "square.and.arrow.down", help: "Save Project (Ctrl+S)", action: { workspace.save() }),
            ToolItem(systemImage: "scissors", help: "Cut (Ctrl+X)", isEnabled: editable, action: { MelsecClipboard.cut(workspace) }, startsGroup: true),
            ToolItem(systemImage: "doc.on.doc", help: "Copy (Ctrl+C)", action: { MelsecClipboard.copy(workspace) }),
            ToolItem(systemImage: "doc.on.clipboard", help: "Paste (Ctrl+V)", isEnabled: editable, action: { MelsecClipboard.paste(workspace) }),
            ToolItem(systemImage: "arrow.uturn.backward", help: "Undo (Ctrl+Z)", isEnabled: workspace.canUndo, action: { workspace.undo() }, startsGroup: true),
            ToolItem(systemImage: "arrow.uturn.forward", help: "Redo (Ctrl+Y)", isEnabled: workspace.canRedo, action: { workspace.redo() }),
        ]
        items += modeItems(workspace, online: online)
        items += [
            ToolItem(systemImage: "arrow.triangle.2.circlepath", help: "Convert (F4)", action: { workspace.perform(.convert) }, startsGroup: true),
            ToolItem(systemImage: "arrow.clockwise.circle", help: "Rebuild All (Shift+Alt+F4)", action: { workspace.perform(.rebuildAll) }),
            ToolItem(systemImage: "square.and.arrow.down.on.square", help: "Write to PLC", isEnabled: online, action: { workspace.writeToPLC() }, startsGroup: true),
            ToolItem(systemImage: "square.and.arrow.up.on.square", help: "Read from PLC", isEnabled: online, action: { workspace.readFromPLC() }),
            ToolItem(systemImage: online ? "stop.circle" : "play.circle", help: online ? "Stop Simulation" : "Start Simulation",
                     isActive: online, action: { online ? workspace.stopSimulation() : workspace.startSimulation() }, startsGroup: true),
            ToolItem(systemImage: "binoculars", help: "Watch", action: { workspace.bottomTab = .watch(0) }),
        ]
        items += symbolToolItems(workspace, enabled: editable)
        return items
    }

    private static func modeItems(_ workspace: MelsecWorkspace, online: Bool) -> [ToolItem] {
        [
            ToolItem(systemImage: "pencil", help: "Write Mode (F2)", isActive: workspace.mode == .write,
                     action: { workspace.perform(.setMode(.write)) }, startsGroup: true),
            ToolItem(systemImage: "book", help: "Read Mode (Shift+F2)", isActive: workspace.mode == .read,
                     action: { workspace.perform(.setMode(.read)) }),
            ToolItem(systemImage: "eye", help: "Monitor Mode (F3)", isEnabled: online, isActive: workspace.mode == .monitor,
                     action: { workspace.perform(.setMode(.monitor)) }),
            ToolItem(systemImage: "eye.circle", help: "Monitor (Write Mode) (Shift+F3)", isEnabled: online, isActive: workspace.mode == .monitorWrite,
                     action: { workspace.perform(.setMode(.monitorWrite)) }),
        ]
    }

    private static func symbolToolItems(_ workspace: MelsecWorkspace, enabled: Bool) -> [ToolItem] {
        let symbols: [(String, String, MelsecLadderCommand)] = [
            ("pause", "Open Contact (F5)", .ladderInput(.openContact, text: "")),
            ("pause.circle", "Open Branch (Shift+F5)", .ladderInput(.openBranch, text: "")),
            ("slash.circle", "Close Contact (F6)", .ladderInput(.closeContact, text: "")),
            ("slash.circle.fill", "Close Branch (Shift+F6)", .ladderInput(.closeBranch, text: "")),
            ("arrow.up.circle", "Rising Pulse (Shift+F7)", .ladderInput(.risingPulse, text: "")),
            ("arrow.down.circle", "Falling Pulse (Shift+F8)", .ladderInput(.fallingPulse, text: "")),
            ("circle", "Coil (F7)", .ladderInput(.coil, text: "")),
            ("curlybraces.square", "Application Instruction (F8)", .ladderInput(.instruction, text: "")),
            ("minus", "Horizontal Line (F9)", .drawHorizontalLine),
            ("poweron", "Vertical Line (Shift+F9)", .drawVerticalLine),
            ("minus.circle", "Delete Horizontal Line (Ctrl+F9)", .deleteHorizontalLine),
            ("xmark.circle", "Delete Vertical Line (Ctrl+F10)", .deleteVerticalLine),
        ]
        return symbols.enumerated().map { index, symbol in
            ToolItem(systemImage: symbol.0, help: symbol.1, isEnabled: enabled, action: { workspace.perform(symbol.2) }, startsGroup: index == 0)
        }
    }

    // MARK: Shortcuts

    static func shortcuts(_ workspace: MelsecWorkspace) -> [VendorShortcut] {
        var shortcuts = MelsecKeyMap.functionKeyBindings.map { binding in
            VendorShortcut.function(binding.number, MelsecKeyTranslation.eventModifiers(binding.modifiers)) {
                // Keys belong to an open dialog, not the editor behind it.
                if workspace.sheet == nil { workspace.perform(binding.command) }
            }
        }
        shortcuts.append(.function(1) { showInstructionHelp(workspace) })
        shortcuts.append(.key("n", [.control]) {
            workspace.alert = MelsecAlert(title: "New", message: "Discard the current project and create a new FX5U project?", action: .newProject)
        })
        shortcuts.append(.key("o", [.control]) { workspace.openProject() })
        shortcuts.append(.key("z", [.control]) { workspace.undo() })
        shortcuts.append(.key("y", [.control]) { workspace.redo() })
        shortcuts.append(.key("z", [.command]) { workspace.undo() })
        shortcuts.append(.key("z", [.command, .shift]) { workspace.redo() })
        shortcuts.append(.key("s", [.control]) { workspace.save() })
        return shortcuts
    }
}

/// Copy/cut/paste of ladder elements through the system pasteboard.
@MainActor enum MelsecClipboard {
    static func copy(_ workspace: MelsecWorkspace) {
        guard let text = workspace.copiedElementText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func cut(_ workspace: MelsecWorkspace) {
        guard let text = workspace.cutElement() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func paste(_ workspace: MelsecWorkspace) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        workspace.pasteElement(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
