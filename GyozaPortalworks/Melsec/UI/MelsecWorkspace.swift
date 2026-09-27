import Foundation
import Observation

/// A dialog shown over the GX Works3 workspace.
enum MelsecSheet: Identifiable, Hashable {
    case ladderInput(MelsecLadderInputState)
    case onlineDataOperation(MelsecOnlineOperation)
    case programCheck
    case modifyValue(device: String)
    case moduleDiagnostics
    case addProgram
    case rename(programID: UUID)
    case dataType(labelID: UUID, programID: UUID?)
    case programProperties(programID: UUID)

    var id: String {
        switch self {
        case .ladderInput: return "ladderInput"
        case .onlineDataOperation: return "online"
        case .programCheck: return "programCheck"
        case .modifyValue: return "modifyValue"
        case .moduleDiagnostics: return "moduleDiagnostics"
        case .addProgram: return "addProgram"
        case .rename: return "rename"
        case .dataType: return "dataType"
        case .programProperties: return "properties"
        }
    }
}

/// The Ladder Input dialog's contents.
struct MelsecLadderInputState: Hashable {
    var symbol: MelsecLadderSymbol
    var text: String
    /// Editing an existing element (Enter) rather than inserting.
    var isEditing = false
    var error: String?
}

/// A message box.
struct MelsecAlert: Identifiable, Hashable {
    enum Action: Hashable {
        case none
        /// "The CPU is running. Execute remote STOP and write?"
        case remoteStopAndWrite
        /// "Execute remote RUN?"
        case remoteRun
        /// "Create a new project? The current project is discarded."
        case newProject
    }

    var id = UUID()
    var title: String
    var message: String
    var action: Action = .none
}

/// A line and column in an ST editor to jump to.
struct MelsecSourcePosition: Hashable {
    var line: Int
    var column: Int
}

/// Undo snapshot: the project and where the cursors were.
struct MelsecUndoState: Hashable {
    var project: MelsecProject
    var cursors: [UUID: MelsecCellRef]
}

/// The GX Works3 workspace: the project, the open editors, conversion,
/// Program Check, GX Simulator3, monitoring and watch windows.
@MainActor @Observable final class MelsecWorkspace: PracticeWorkspace {
    let environment: PracticeEnvironment = .gxWorks3
    let theme = VendorTheme.gxWorks3

    private(set) var project: MelsecProject
    @ObservationIgnored private let store: ProjectStore<MelsecProject>?

    var sheet: MelsecSheet?
    var alert: MelsecAlert?
    /// A short message in the status bar (e.g. why a key did nothing).
    var statusMessage: String?

    // Editors
    private(set) var openTabs: [MelsecEditorTabID] = []
    var selectedTab: MelsecEditorTabID?
    var cursors: [UUID: MelsecCellRef] = [:]
    private(set) var isInsertMode = false
    private(set) var mode: MelsecEditorMode = .write
    var bottomTab: MelsecDockTab = .output
    var paletteSearch = ""
    var paletteSelection: String?
    /// Set by a double-click in the Output window on an ST error; the ST
    /// editor moves its cursor there and clears it.
    var pendingSourceJump: MelsecSourcePosition?
    /// Resolves watch entries' data types while no CPU is connected.
    @ObservationIgnored let typeProbe = MelsecCPU()

    // Undo
    private(set) var undoStack: [MelsecUndoState] = []
    private(set) var redoStack: [MelsecUndoState] = []
    @ObservationIgnored private var lastCoalescingKey: String?
    static let undoLimit = 200

    // Build
    private(set) var outputMessages: [MelsecOutputMessage] = []
    var outputFilter: Set<MelsecOutputMessage.Result> = Set(MelsecOutputMessage.Result.allCases)
    private(set) var conversions: [UUID: MelsecConversionResult] = [:]
    private(set) var conversionErrors: [UUID: [MelsecConversionError]] = [:]
    /// ST programs edited since they last compiled.
    private(set) var dirtyStructuredText: Set<UUID> = []
    private(set) var structuredTextDiagnostics: [UUID: [Diagnostic]] = [:]
    var programCheckOptions = MelsecProgramCheckOptions()

    // Online
    private(set) var session: SimulationSession?
    private(set) var cpu: MelsecCPU?
    /// The conversions of the programs last written to the CPU (monitoring
    /// maps instructions back to cells through them).
    private(set) var writtenConversions: [UUID: MelsecConversionResult] = [:]
    @ObservationIgnored private(set) var writtenProject: MelsecProject?
    /// The GX Simulator3 RUN/STOP switch.
    private(set) var simulatorSwitch: CPUMode = .stop
    var isSimulatorPanelVisible = false
    var watching: [Bool] = Array(repeating: false, count: 4)
    var watchSelection: [Int: String] = [:]
    var watchFormats: [String: MelsecDisplayFormat] = [:]
    var batchDevice = "D0"
    var isBatchMonitoring = false

    /// Compiles ST through the language engine. Replaceable for tests.
    @ObservationIgnored var compileST: (String, SymbolResolver) -> (ExecutableBody?, [Diagnostic]) = { source, resolver in
        let result = STCompiler.compile(source, resolver: resolver)
        return (result.program, result.diagnostics)
    }

    /// Loads the saved GX Works3 project (or starts a new one).
    convenience init() {
        let store = ProjectStore<MelsecProject>(folder: "GX Works3")
        switch store.load() {
        case let .loaded(project):
            self.init(project: project, store: store)
        case .empty:
            self.init(project: .newProject(), store: store)
        case let .unreadable(backup, error):
            self.init(project: .newProject(), store: store)
            let place = backup.map { "It was moved to \($0.lastPathComponent)." } ?? "It couldn't be moved aside."
            alert = MelsecAlert(title: "The saved project couldn't be opened",
                                message: "A new project was started. \(place)\n\n\(error)")
        }
    }

    /// A workspace on `project`; `store` nil keeps everything in memory (tests).
    init(project: MelsecProject, store: ProjectStore<MelsecProject>? = nil) {
        self.project = project
        self.store = store
        if let first = project.programs.first {
            openTabs = [.program(first.id)]
            selectedTab = .program(first.id)
        }
        dirtyStructuredText = Set(project.programs.filter { $0.language == .structuredText }.map(\.id))
    }

    func save() {
        store?.saveNow()
    }

    // MARK: Editing and undo

    /// Applies an edit: one undo step (or merged into the previous one when
    /// `key` repeats, e.g. typing in one field), then a scheduled save.
    func mutate(coalescing key: String? = nil, _ change: (inout MelsecProject) throws -> Void) rethrows {
        var copy = project
        try change(&copy)
        guard copy != project else { return }
        if key == nil || key != lastCoalescingKey {
            undoStack.append(MelsecUndoState(project: project, cursors: cursors))
            if undoStack.count > Self.undoLimit {
                undoStack.removeFirst(undoStack.count - Self.undoLimit)
            }
        }
        lastCoalescingKey = key
        redoStack.removeAll()
        project = copy
        store?.scheduleSave(project)
    }

    /// Changes that aren't undo steps (conversion clearing the grey state).
    private func updateWithoutUndo(_ change: (inout MelsecProject) -> Void) {
        var copy = project
        change(&copy)
        guard copy != project else { return }
        project = copy
        store?.scheduleSave(project)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(MelsecUndoState(project: project, cursors: cursors))
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(MelsecUndoState(project: project, cursors: cursors))
        restore(next)
    }

    private func restore(_ state: MelsecUndoState) {
        project = state.project
        cursors = state.cursors
        lastCoalescingKey = nil
        let ids = Set(project.programs.map(\.id))
        openTabs.removeAll { tab in tab.programID.map { !ids.contains($0) } ?? false }
        if let selected = selectedTab, !openTabs.contains(selected) {
            selectedTab = openTabs.first
        }
        store?.scheduleSave(project)
    }

    /// Project › New: starts again from GX Works3's new-project template.
    func newProject() {
        replaceProject(.newProject())
        outputMessages = []
        conversions = [:]
        conversionErrors = [:]
    }

    /// Project › Open: replaces the project with a file the user picks.
    func openProject() {
        guard let store, let opened = store.importDocument() else { return }
        replaceProject(opened)
    }

    /// Project › Save As: exports a copy.
    func exportProject() {
        store?.export(project, suggestedName: "\(project.name).gx3.json")
    }

    private func replaceProject(_ newProject: MelsecProject) {
        mutate { $0 = newProject }
        cursors = [:]
        openTabs = newProject.programs.first.map { [.program($0.id)] } ?? []
        selectedTab = openTabs.first
        dirtyStructuredText = Set(newProject.programs.filter { $0.language == .structuredText }.map(\.id))
    }

    // MARK: Tabs

    func open(_ tab: MelsecEditorTabID) {
        if !openTabs.contains(tab) {
            openTabs.append(tab)
        }
        selectedTab = tab
    }

    func close(_ tab: MelsecEditorTabID) {
        guard let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if selectedTab == tab {
            selectedTab = openTabs.isEmpty ? nil : openTabs[min(index, openTabs.count - 1)]
        }
    }

    func program(_ id: UUID) -> MelsecProgram? {
        project.programs.first { $0.id == id }
    }

    func programIndex(_ id: UUID) -> Int? {
        project.programs.firstIndex { $0.id == id }
    }

    /// The program of the selected editor tab.
    var selectedProgram: MelsecProgram? {
        guard case let .program(id)? = selectedTab else { return nil }
        return program(id)
    }

    /// The tab title GX Works3 shows: "ProgPou [PRG] [LD] 5 Step".
    func title(for tab: MelsecEditorTabID) -> String {
        switch tab {
        case let .program(id):
            guard let program = program(id) else { return "?" }
            let language = program.language == .ladder ? "LD" : "ST"
            var title = "\(program.name) [PRG] [\(language)]"
            if let steps = conversions[id].map({ $0.endStep + 1 }) {
                title += " \(steps) Step"
            }
            switch mode {
            case .monitor: title += " Monitoring (Read Only)"
            case .monitorWrite: title += " Monitoring (Write)"
            case .read: title += " (Read Only)"
            case .write: break
            }
            return title
        case let .localLabels(id):
            return "\(program(id)?.name ?? "?") [Local Label Setting]"
        case .globalLabels:
            return "Global Label Setting Global"
        case .deviceComments:
            return "Device Comment"
        case .deviceMemory:
            return "Device/Buffer Memory Batch Monitor"
        case .cpuParameter:
            return "CPU Parameter"
        }
    }

    /// Programs shown red in the Navigation window.
    var unconvertedPrograms: Set<UUID> {
        var result = dirtyStructuredText
        for program in project.programs where program.language == .ladder && program.ladder.hasUnconvertedRows {
            result.insert(program.id)
        }
        return result
    }

    // MARK: Programs and labels

    /// Navigation › Add New Data: a program block in MAIN.
    func addProgram(name rawName: String, language: MelsecProgramLanguage) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = programNameProblem(name, excluding: nil) { return problem }
        let program = MelsecProgram(fileName: project.programs.first?.fileName ?? "MAIN", name: name, language: language)
        mutate { $0.programs.append(program) }
        if language == .structuredText {
            dirtyStructuredText.insert(program.id)
        }
        open(.program(program.id))
        return nil
    }

    func renameProgram(_ id: UUID, to rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = programNameProblem(name, excluding: id) { return problem }
        guard let index = programIndex(id) else { return "The program no longer exists." }
        mutate { $0.programs[index].name = name }
        return nil
    }

    func deleteProgram(_ id: UUID) -> String? {
        guard project.programs.count > 1 else { return "A project needs at least one program." }
        guard let index = programIndex(id) else { return nil }
        mutate { $0.programs.remove(at: index) }
        close(.program(id))
        close(.localLabels(id))
        return nil
    }

    private func programNameProblem(_ name: String, excluding id: UUID?) -> String? {
        guard !name.isEmpty else { return "Enter a data name." }
        if project.programs.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "'\(name)' already exists."
        }
        if let problem = MelsecLabelRules.problem(with: name, profile: project.profile) {
            return problem.replacingOccurrences(of: "label name", with: "data name")
        }
        return nil
    }

    /// The labels of a label editor: global (programID nil) or local.
    func labels(programID: UUID?) -> [MelsecLabel] {
        guard let programID else { return project.globalLabels }
        return program(programID)?.localLabels ?? []
    }

    func addLabel(programID: UUID?) {
        let existing = Set(labels(programID: programID).map { $0.name.lowercased() })
        var number = 1
        while existing.contains("label\(number)") { number += 1 }
        let label = MelsecLabel(name: "Label\(number)", dataType: .bit, labelClass: programID == nil ? .global : .local)
        updateLabels(programID: programID) { $0.append(label) }
    }

    func updateLabel(_ id: UUID, programID: UUID?, field: String, _ change: (inout MelsecLabel) -> Void) {
        mutate(coalescing: "label-\(id.uuidString)-\(field)") { project in
            Self.editLabels(&project, programID: programID) { labels in
                guard let index = labels.firstIndex(where: { $0.id == id }) else { return }
                change(&labels[index])
            }
        }
    }

    func deleteLabel(_ id: UUID, programID: UUID?) {
        updateLabels(programID: programID) { $0.removeAll { $0.id == id } }
    }

    private func updateLabels(programID: UUID?, _ change: (inout [MelsecLabel]) -> Void) {
        mutate { project in
            Self.editLabels(&project, programID: programID, change)
        }
    }

    private static func editLabels(_ project: inout MelsecProject, programID: UUID?, _ change: (inout [MelsecLabel]) -> Void) {
        guard let programID else {
            change(&project.globalLabels)
            return
        }
        guard let index = project.programs.firstIndex(where: { $0.id == programID }) else { return }
        change(&project.programs[index].localLabels)
    }

    /// Problems in a label list, shown under the label editor.
    func labelProblems(programID: UUID?) -> [String] {
        MelsecLabelScope.problems(in: labels(programID: programID), profile: project.profile)
    }

    // MARK: ST text

    func setStructuredText(_ text: String, programID: UUID) {
        guard let index = programIndex(programID), project.programs[index].structuredText != text else { return }
        mutate(coalescing: "st-\(programID.uuidString)") { $0.programs[index].structuredText = text }
        dirtyStructuredText.insert(programID)
    }

    // MARK: Device comments and watch lists

    func setDeviceComment(_ text: String, device: String) {
        mutate(coalescing: "comment-\(device)") { project in
            try? project.setComment(text, for: device)
        }
    }

    func addWatchEntry(_ name: String, list: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, project.watchLists.indices.contains(list) else { return }
        mutate { $0.watchLists[list].entries.append(trimmed) }
    }

    func removeWatchEntry(at index: Int, list: Int) {
        guard project.watchLists.indices.contains(list), project.watchLists[list].entries.indices.contains(index) else { return }
        mutate { $0.watchLists[list].entries.remove(at: index) }
    }

    // MARK: Conversion bookkeeping (used by the Build extension)

    func recordConversion(_ output: MelsecCompileOutput) {
        var converted: [UUID] = []
        for program in project.programs {
            switch program.language {
            case .ladder:
                if let result = output.conversions[program.id] {
                    conversions[program.id] = result
                    conversionErrors[program.id] = result.errors
                    if result.succeeded { converted.append(program.id) }
                }
            case .structuredText:
                let messages = output.diagnostics.filter { $0.block == program.name }
                structuredTextDiagnostics[program.id] = messages
                if !messages.contains(where: { $0.severity == .error }) {
                    dirtyStructuredText.remove(program.id)
                }
            }
        }
        updateWithoutUndo { project in
            for id in converted {
                if let index = project.programs.firstIndex(where: { $0.id == id }) {
                    project.programs[index].ladder.markConverted()
                }
            }
        }
    }

    func setOutput(_ messages: [MelsecOutputMessage]) {
        outputMessages = messages
    }

    func setOnline(session: SimulationSession?, cpu: MelsecCPU?) {
        self.session = session
        self.cpu = cpu
    }

    func setWritten(_ conversions: [UUID: MelsecConversionResult], project: MelsecProject?) {
        writtenConversions = conversions
        writtenProject = project
    }

    func setSimulatorSwitch(_ position: CPUMode) {
        simulatorSwitch = position
    }

    func setEditorMode(_ newMode: MelsecEditorMode) {
        mode = newMode
    }

    func setInsertMode(_ value: Bool) {
        isInsertMode = value
    }
}
