import AppKit
import SwiftUI

/// Commands shared by menus, toolbar and keys.
extension SiemensWorkspace {
    /// F2: edit the selected operand in an editor, or rename the selected tree object.
    func handleF2() {
        if let block = currentBlock, case .element? = selections[block.id], block.language.usesNetworks {
            perform(.editOperand, inBlock: block.id)
        } else if let tab = treeSelection {
            renamingTab = tab
        }
    }

    /// Monitoring on/off (Ctrl+T) for the block in the editor.
    func toggleMonitoringOfCurrentBlock() {
        guard let block = currentBlock else {
            alertMessage = "Open a block to monitor it."
            return
        }
        toggleMonitoring(block: block.id)
    }

    /// Modify › Modify operand… (Ctrl+Shift+2): writes the selected element's operand.
    func modifySelectedOperand() {
        guard let block = currentBlock, case let .element(networkID, id)? = selections[block.id],
              let network = block.networks.first(where: { $0.id == networkID }), let node = network.element(id)
        else {
            alertMessage = "Select an element in a monitored block to modify its operand."
            return
        }
        let operand: String
        switch node {
        case let .contact(contact): operand = contact.operand
        case let .coil(coil): operand = coil.operand
        case let .box(box): operand = box.outputs.first?.source.operandText ?? box.inputs.first?.source.operandText ?? ""
        default: operand = ""
        }
        guard !operand.isEmpty else { return }
        openWatchRow(for: operand)
    }

    /// Adds an operand to the first watch table (creating one) and opens it, for modifying.
    func openWatchRow(for operand: String) {
        if project.watchTables.isEmpty { addWatchTable() }
        guard let table = project.watchTables.first else { return }
        if !table.rows.contains(where: { $0.operand == operand }) { addWatchRow(operand, to: table.id) }
        open(.watchTable(table.id))
        lastMessage = "Enter a modify value for \(operand) and click \"Modify now\"."
    }
}

/// The in-window menu bar: Project, Edit, View, Insert, Online, Options, Tools, Window, Help.
struct SiemensMenus {
    let workspace: SiemensWorkspace

    var menus: [(title: String, items: [MenuItem])] {
        [
            ("Project", project),
            ("Edit", edit),
            ("View", view),
            ("Insert", insert),
            ("Online", online),
            ("Options", [.command("Settings", isEnabled: false) {}]),
            ("Tools", [.command("Cross-references", isEnabled: false) {}]),
            ("Window", [.command("Split editor space vertically", isEnabled: false) {}]),
            ("Help", help),
        ]
    }

    private var project: [MenuItem] {
        [
            .command("New…") { workspace.newProject() },
            .command("Open…") { workspace.importProject() },
            .command("Save project", shortcut: "Ctrl+S") { workspace.saveProject() },
            .command("Save as…") { workspace.exportProject() },
            .divider,
            .command("Compile", shortcut: "Ctrl+B") { workspace.compile() },
        ]
    }

    private var edit: [MenuItem] {
        [
            .command("Undo", shortcut: "Ctrl+Z", isEnabled: workspace.canUndo) { workspace.undo() },
            .command("Redo", shortcut: "Ctrl+Y", isEnabled: workspace.canRedo) { workspace.redo() },
            .divider,
            .command("Delete", shortcut: "Del") { workspace.perform(.delete) },
            .command("Rename", shortcut: "F2") { workspace.handleF2() },
            .divider,
            .command("Compile", shortcut: "Ctrl+B") { workspace.compile() },
        ]
    }

    private var view: [MenuItem] {
        [
            .toggle("Project tree", isOn: workspace.showsProjectTree) { workspace.showsProjectTree.toggle() },
            .toggle("Task cards", isOn: workspace.showsTaskCards) { workspace.showsTaskCards.toggle() },
            .toggle("Inspector window", isOn: workspace.showsInspector) { workspace.showsInspector.toggle() },
        ]
    }

    private var insert: [MenuItem] {
        [
            .command("Network", shortcut: "Ctrl+R") { workspace.perform(.insertNetwork) },
            .divider,
            .command("Normally open contact", shortcut: "Shift+F2") { workspace.perform(.insertContact(.normallyOpen)) },
            .command("Normally closed contact", shortcut: "Shift+F3") { workspace.perform(.insertContact(.normallyClosed)) },
            .command("Empty box", shortcut: "Shift+F5") { workspace.perform(.insertEmptyBox) },
            .command("Assignment", shortcut: "Shift+F7") { workspace.perform(.insertCoil(.assign)) },
            .command("Open branch", shortcut: "Shift+F8") { workspace.perform(.openBranch) },
            .command("Close branch", shortcut: "Shift+F9") { workspace.perform(.closeBranch) },
            .divider,
            .command("Add new block…") { workspace.beginAddNewBlock() },
        ]
    }

    private var online: [MenuItem] {
        let simulating = workspace.session != nil
        return [
            .command("Go online", shortcut: "Ctrl+K", isEnabled: !workspace.isOnline) { workspace.goOnline() },
            .command("Go offline", shortcut: "Ctrl+M", isEnabled: workspace.isOnline) { workspace.goOffline() },
            .divider,
            .submenu("Simulation", [
                .command("Start", shortcut: "Ctrl+Shift+X") { workspace.startSimulation() },
                .command("Stop", isEnabled: simulating) { workspace.stopSimulation() },
            ]),
            .command("Download to device", shortcut: "Ctrl+L") { workspace.downloadToDevice() },
            .command("Extended download to device…") { workspace.startSimulation() },
            .divider,
            .command("Start CPU", shortcut: "Ctrl+Shift+E", isEnabled: simulating) { workspace.requestStartCPU() },
            .command("Stop CPU", shortcut: "Ctrl+Shift+Q", isEnabled: simulating) { workspace.requestStopCPU() },
            .command("Memory reset", isEnabled: simulating) { workspace.confirmation = .memoryReset },
            .divider,
            .command("Monitoring on/off", shortcut: "Ctrl+T") { workspace.toggleMonitoringOfCurrentBlock() },
            .submenu("Modify", [
                .command("Modify to 1", shortcut: "Ctrl+Shift+1") { workspace.modifySelection(to: true) },
                .command("Modify to 0", shortcut: "Ctrl+Shift+9") { workspace.modifySelection(to: false) },
                .command("Modify operand…", shortcut: "Ctrl+Shift+2") { workspace.modifySelectedOperand() },
            ]),
            .divider,
            .command("Online & diagnostics") { workspace.open(.onlineDiagnostics) },
        ]
    }

    private var help: [MenuItem] {
        [
            .command("Keyboard shortcuts") {
                workspace.alertMessage = """
                Ctrl+B compile · Ctrl+Shift+X start simulation · Ctrl+L download · Ctrl+K / Ctrl+M go online / offline · \
                Ctrl+T monitoring · Ctrl+R insert network · Shift+F2 / F3 contacts · Shift+F5 empty box · Shift+F7 coil · \
                Shift+F8 / F9 open / close branch · F2 edit operand or rename · Ctrl+Z / Ctrl+Y undo / redo.
                Hold fn for F-keys, or enable 'Use F1, F2, etc. keys as standard function keys' in System Settings › Keyboard.
                """
            },
        ]
    }
}

/// The toolbar under the menu bar.
struct SiemensToolStrip: View {
    let workspace: SiemensWorkspace
    @State private var search = ""

    var body: some View {
        ToolStrip(items: items, theme: SiemensColors.theme, trailing: AnyView(searchField))
    }

    private var searchField: some View {
        TextField("Search in project", text: $search)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 180)
            .onSubmit { find() }
    }

    private func find() {
        let key = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }
        if let row = workspace.treeRows().first(where: { row in
            if case .tab = row.target { return row.title.lowercased().contains(key) }
            return false
        }) {
            workspace.activate(row)
        } else {
            workspace.lastMessage = "No object named \"\(search)\" was found."
        }
    }

    private var items: [ToolItem] {
        let simulating = workspace.session != nil
        return [
            ToolItem(systemImage: "doc.badge.plus", help: "New project") { workspace.newProject() },
            ToolItem(systemImage: "folder", help: "Open project") { workspace.importProject() },
            ToolItem(systemImage: "square.and.arrow.down", help: "Save project (Ctrl+S)") { workspace.saveProject() },
            ToolItem(systemImage: "scissors", help: "Cut", isEnabled: false, action: {}, startsGroup: true),
            ToolItem(systemImage: "doc.on.doc", help: "Copy", isEnabled: false) {},
            ToolItem(systemImage: "doc.on.clipboard", help: "Paste", isEnabled: false) {},
            ToolItem(systemImage: "xmark", help: "Delete (Del)") { workspace.perform(.delete) },
            ToolItem(systemImage: "arrow.uturn.backward", help: "Undo (Ctrl+Z)", isEnabled: workspace.canUndo,
                     action: { workspace.undo() }, startsGroup: true),
            ToolItem(systemImage: "arrow.uturn.forward", help: "Redo (Ctrl+Y)", isEnabled: workspace.canRedo) { workspace.redo() },
            ToolItem(systemImage: "hammer", help: "Compile (Ctrl+B)", action: { workspace.compile() }, startsGroup: true),
            ToolItem(systemImage: "square.and.arrow.down.on.square", help: "Download to device (Ctrl+L)") { workspace.downloadToDevice() },
            ToolItem(systemImage: "desktopcomputer", help: "Start simulation (Ctrl+Shift+X)", isActive: simulating) {
                workspace.startSimulation()
            },
            ToolItem(systemImage: "link", help: "Go online (Ctrl+K)", isEnabled: !workspace.isOnline, isActive: workspace.isOnline,
                     action: { workspace.goOnline() }, startsGroup: true),
            ToolItem(systemImage: "link.badge.plus", help: "Go offline (Ctrl+M)", isEnabled: workspace.isOnline) { workspace.goOffline() },
            ToolItem(systemImage: "play.fill", help: "Start CPU (Ctrl+Shift+E)", isEnabled: simulating) { workspace.requestStartCPU() },
            ToolItem(systemImage: "stop.fill", help: "Stop CPU (Ctrl+Shift+Q)", isEnabled: simulating) { workspace.requestStopCPU() },
        ]
    }
}

/// TIA's keyboard shortcuts, live while the workspace is on screen.
struct SiemensKeyboard {
    let workspace: SiemensWorkspace

    var shortcuts: [VendorShortcut] {
        let control: EventModifiers = .control
        let controlShift: EventModifiers = [.control, .shift]
        return [
            .key("b", control) { workspace.compile() },
            .key("l", control) { workspace.downloadToDevice() },
            .key("x", controlShift) { workspace.startSimulation() },
            .key("k", control) { workspace.goOnline() },
            .key("m", control) { workspace.goOffline() },
            .key("t", control) { workspace.toggleMonitoringOfCurrentBlock() },
            .key("e", controlShift) { workspace.requestStartCPU() },
            .key("q", controlShift) { workspace.requestStopCPU() },
            .key("r", control) { workspace.perform(.insertNetwork) },
            .key("s", control) { workspace.saveProject() },
            .key("z", control) { workspace.undo() },
            .key("y", control) { workspace.redo() },
            .key("z", .command) { workspace.undo() },
            .key("z", [.command, .shift]) { workspace.redo() },
            .key("1", controlShift) { workspace.modifySelection(to: true) },
            .key("9", controlShift) { workspace.modifySelection(to: false) },
            .key("2", controlShift) { workspace.modifySelectedOperand() },
            .function(2, .shift) { workspace.perform(.insertContact(.normallyOpen)) },
            .function(3, .shift) { workspace.perform(.insertContact(.normallyClosed)) },
            .function(5, .shift) { workspace.perform(.insertEmptyBox) },
            .function(7, .shift) { workspace.perform(.insertCoil(.assign)) },
            .function(8, .shift) { workspace.perform(.openBranch) },
            .function(9, .shift) { workspace.perform(.closeBranch) },
            .function(2) { workspace.handleF2() },
        ]
    }
}
