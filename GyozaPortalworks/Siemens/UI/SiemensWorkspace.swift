import Foundation
import Observation

/// The TIA Portal workspace: the project, the editors' state, compile
/// results and the S7-PLCSIM simulation. Views call its commands; every
/// command that changes the project is undoable and saved.
@MainActor @Observable final class SiemensWorkspace: PracticeWorkspace {
    nonisolated enum InspectorTab: String, CaseIterable, Hashable, Sendable {
        case properties = "Properties"
        case info = "Info"
        case diagnostics = "Diagnostics"
    }

    nonisolated enum InfoTab: String, CaseIterable, Hashable, Sendable {
        case general = "General"
        case compile = "Compile"
        case syntax = "Syntax"
    }

    nonisolated enum TaskCard: String, CaseIterable, Hashable, Sendable {
        case instructions = "Instructions"
        case testing = "Testing"
        case libraries = "Libraries"
    }

    let environment = PracticeEnvironment.tiaPortal

    // MARK: Project and undo

    private(set) var project: SiemensProject
    @ObservationIgnored private let store: ProjectStore<SiemensProject>?
    private(set) var undoStack: [SiemensProject] = []
    private(set) var redoStack: [SiemensProject] = []
    private static let undoLimit = 100
    /// Shown once at launch when the saved project couldn't be read.
    var startupAlert: String?

    // MARK: Editors

    private(set) var openTabs: [SiemensEditorTab] = []
    var selectedTab: SiemensEditorTab?
    /// Cursor per LAD/FBD block.
    var selections: [UUID: S7Selection] = [:]
    /// The operand being typed inline.
    var editingOperand: S7OperandTarget?
    var collapsedNetworks: Set<UUID> = []
    var isInterfaceCollapsed = false
    var inspectorTab: InspectorTab = .info
    var infoTab: InfoTab = .compile
    var taskCard: TaskCard = .instructions
    var treeSelection: SiemensEditorTab?
    /// The tree item being renamed inline (F2).
    var renamingTab: SiemensEditorTab?
    var showsProjectTree = true
    var showsTaskCards = true
    var showsInspector = true
    /// Collapsed project tree folders, by title.
    var collapsedFolders: Set<String> = []

    // MARK: Messages and dialogs

    private(set) var compileResult: SiemensCompileResult?
    /// The status bar's last message.
    var lastMessage = "The project Project1 was opened."
    var newBlockRequest: SiemensNewBlockRequest?
    var callOptions: SiemensCallOptions?
    var confirmation: SiemensConfirmation?
    var alertMessage: String?
    /// Selected SCL line to jump to (set by Info › Compile, consumed by the SCL editor).
    var pendingGoTo: (block: UUID, line: Int, column: Int)?

    // MARK: Simulation and online

    private(set) var session: SimulationSession?
    var isPLCSIMVisible = false
    private(set) var loadStep: SiemensLoadStep?
    @ObservationIgnored private var pendingImage: SiemensCPUImage?
    @ObservationIgnored private var pendingProject: SiemensProject?
    /// What was last downloaded: the online program.
    private(set) var downloadedProject: SiemensProject?
    private(set) var isOnline = false
    private(set) var monitoredBlocks: Set<UUID> = []
    /// Watch tables with "Monitor all" on.
    var monitoredWatchTables: Set<UUID> = []
    /// "Monitor now" results: watch table row → value text.
    private(set) var watchSnapshot: [UUID: String] = [:]
    /// Tests drive scans themselves; the app lets the session's timer run.
    @ObservationIgnored var startsSessionTimer = true

    var cpu: SiemensCPU? { session?.cpu as? SiemensCPU }

    /// Compiles SCL with the shared ST/SCL engine.
    nonisolated static func compileSCL(_ source: String, _ resolver: SymbolResolver) -> (ExecutableBody?, [Diagnostic]) {
        let result = STCompiler.compile(source, resolver: resolver)
        let body: ExecutableBody? = result.program
        return (body, result.diagnostics)
    }

    /// Loads the saved project (Application Support/GyozaPortalworks/TIA Portal).
    convenience init() {
        let store = ProjectStore<SiemensProject>(folder: "TIA Portal")
        var alert: String?
        let project: SiemensProject
        switch store.load() {
        case let .loaded(saved):
            project = saved
        case .empty:
            project = SiemensProject.newProject()
        case let .unreadable(backup, error):
            project = SiemensProject.newProject()
            let where_ = backup.map { " It was moved to \($0.lastPathComponent)." } ?? ""
            alert = "The saved TIA Portal project couldn't be read (\(error)).\(where_) A new project was started."
        }
        self.init(project: project, store: store)
        startupAlert = alert
    }

    /// A workspace on a given project; `store` nil keeps it in memory (tests).
    init(project: SiemensProject, store: ProjectStore<SiemensProject>?) {
        self.project = project
        self.store = store
        if let main = project.blocks.first(where: { $0.kind == .organizationBlock }) {
            openTabs = [.block(main.id)]
            selectedTab = .block(main.id)
            treeSelection = .block(main.id)
        }
        lastMessage = "The project \(project.name) was opened."
    }

    // MARK: - PracticeWorkspace

    func makeCheckCPU() -> Result<any SimulatedCPU, CheckSetupError> {
        let result = SiemensProjectCompiler(compileSCL: Self.compileSCL).compile(project)
        guard let image = result.image else {
            let details = result.diagnostics.filter { $0.severity == .error }.prefix(5).map { diagnostic in
                let place = diagnostic.network.map { ", Network \($0)" } ?? diagnostic.line.map { ", line \($0)" } ?? ""
                return "\(diagnostic.block ?? project.device.name)\(place): \(diagnostic.message)"
            }
            return .failure(CheckSetupError(message: "Your program doesn't compile yet (\(result.errorCount) errors).",
                                            details: Array(details)))
        }
        let cpu = SiemensCPU()
        cpu.load(image)
        cpu.setMode(.run)
        return .success(cpu)
    }

    func save() {
        store?.saveNow()
    }

    /// Project › Save project (Ctrl+S).
    func saveProject() {
        store?.scheduleSave(project)
        store?.saveNow()
        lastMessage = "The project \(project.name) was saved."
    }

    /// Project › New: a fresh Project1 (undoable).
    func newProject() {
        edit { project in project = SiemensProject.newProject() }
        openTabs = []
        selections = [:]
        if let main = project.blocks.first { open(.block(main.id)) }
        lastMessage = "A new project was created."
    }

    /// Project › Export…
    func exportProject() {
        store?.export(project, suggestedName: project.name + ".json")
    }

    /// Project › Open… (a project file exported earlier).
    func importProject() {
        guard let imported = store?.importDocument() else { return }
        edit { project in project = imported }
        openTabs = []
        selections = [:]
        if let main = project.blocks.first(where: { $0.kind == .organizationBlock }) { open(.block(main.id)) }
        lastMessage = "The project \(project.name) was opened."
    }

    // MARK: - Editing

    /// Applies an undoable edit and schedules a save. Returns whether anything changed.
    @discardableResult
    func edit(_ change: (inout SiemensProject) -> Void) -> Bool {
        var updated = project
        change(&updated)
        guard updated != project else { return false }
        undoStack.append(project)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
        project = updated
        projectChanged()
        return true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        editingOperand = nil
        projectChanged()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        editingOperand = nil
        projectChanged()
    }

    private func projectChanged() {
        store?.scheduleSave(project)
        openTabs.removeAll { !exists($0) }
        if let selected = selectedTab, !exists(selected) { selectedTab = openTabs.last }
        for id in monitoredBlocks where onlineStatus(ofBlock: id) != .identical {
            setMonitoring(false, block: id)
        }
    }

    private func exists(_ tab: SiemensEditorTab) -> Bool {
        switch tab {
        case let .block(id): return project.blocks.contains { $0.id == id }
        case let .dataBlock(id): return project.dataBlocks.contains { $0.id == id }
        case let .dataType(id): return project.dataTypes.contains { $0.id == id }
        case let .tagTable(id): return project.tagTables.contains { $0.id == id }
        case let .watchTable(id): return project.watchTables.contains { $0.id == id }
        case .allTags, .forceTable, .deviceConfiguration, .onlineDiagnostics: return true
        }
    }

    // MARK: - Tabs

    func open(_ tab: SiemensEditorTab) {
        if !openTabs.contains(tab) { openTabs.append(tab) }
        selectedTab = tab
        treeSelection = tab
        if case let .block(id) = tab, selections[id] == nil, let block = block(id), let first = block.networks.first {
            selections[id] = S7LadderEditing.firstStop(in: first)
        }
    }

    func close(_ tab: SiemensEditorTab) {
        guard let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if selectedTab == tab {
            selectedTab = openTabs.isEmpty ? nil : openTabs[min(index, openTabs.count - 1)]
        }
    }

    func title(of tab: SiemensEditorTab) -> String {
        switch tab {
        case let .block(id): return block(id)?.displayName ?? "Block"
        case let .dataBlock(id): return project.dataBlocks.first { $0.id == id }?.displayName ?? "Data block"
        case let .dataType(id): return project.dataTypes.first { $0.id == id }?.name ?? "PLC data type"
        case let .tagTable(id): return project.tagTables.first { $0.id == id }?.name ?? "Tag table"
        case .allTags: return "PLC tags"
        case let .watchTable(id): return project.watchTables.first { $0.id == id }?.name ?? "Watch table"
        case .forceTable: return "Force table"
        case .deviceConfiguration: return "Device configuration"
        case .onlineDiagnostics: return "Online & diagnostics"
        }
    }

    func block(_ id: UUID) -> SiemensBlock? {
        project.blocks.first { $0.id == id }
    }

    /// The block in the selected editor tab.
    var currentBlock: SiemensBlock? {
        guard case let .block(id)? = selectedTab else { return nil }
        return block(id)
    }

    // MARK: - Project tree commands

    func beginAddNewBlock(_ kind: SiemensNewBlockRequest.Kind = .function) {
        newBlockRequest = SiemensNewBlockRequest.defaults(kind, in: project)
    }

    /// "OK" in Add new block.
    func addNewBlock(_ request: SiemensNewBlockRequest) {
        var tab: SiemensEditorTab?
        edit { project in tab = request.apply(to: &project) }
        newBlockRequest = nil
        if let tab {
            lastMessage = "\(title(of: tab)) was added."
            if request.openAfterAdding { open(tab) }
        }
    }

    func addTagTable() {
        edit { project in
            let name = SiemensNaming.unique("Tag table_1", among: project.tagTables.map(\.name), style: .counting)
            project.tagTables.append(SiemensTagTable(name: name))
        }
        if let table = project.tagTables.last { open(.tagTable(table.id)) }
    }

    func addDataType() {
        edit { project in _ = project.addDataType() }
        if let type = project.dataTypes.last { open(.dataType(type.id)) }
    }

    func addWatchTable() {
        edit { project in
            let name = SiemensNaming.unique("Watch table_1", among: project.watchTables.map(\.name), style: .counting)
            project.watchTables.append(SiemensWatchTable(name: name))
        }
        if let table = project.watchTables.last { open(.watchTable(table.id)) }
    }

    /// Rename (F2) in the project tree.
    func rename(_ tab: SiemensEditorTab, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("\"") else {
            alertMessage = name.isEmpty ? S7Messages.emptyName : S7Messages.quotesInName
            return
        }
        switch tab {
        case let .block(id):
            guard !project.blockNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                alertMessage = S7Messages.nameUsedTwice(name)
                return
            }
            edit { project in
                if let index = project.blocks.firstIndex(where: { $0.id == id }) { project.blocks[index].name = name }
            }
        case let .dataBlock(id):
            guard !project.blockNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                alertMessage = S7Messages.nameUsedTwice(name)
                return
            }
            edit { project in
                if let index = project.dataBlocks.firstIndex(where: { $0.id == id }) { project.dataBlocks[index].name = name }
            }
        case let .dataType(id):
            edit { project in
                if let index = project.dataTypes.firstIndex(where: { $0.id == id }) { project.dataTypes[index].name = name }
            }
        case let .tagTable(id):
            edit { project in
                if let index = project.tagTables.firstIndex(where: { $0.id == id }) { project.tagTables[index].name = name }
            }
        case let .watchTable(id):
            edit { project in
                if let index = project.watchTables.firstIndex(where: { $0.id == id }) { project.watchTables[index].name = name }
            }
        default:
            break
        }
    }

    /// Delete in the project tree. The last program cycle OB and the default tag table stay.
    func delete(_ tab: SiemensEditorTab) {
        switch tab {
        case let .block(id):
            edit { project in project.blocks.removeAll { $0.id == id } }
        case let .dataBlock(id):
            edit { project in project.dataBlocks.removeAll { $0.id == id } }
        case let .dataType(id):
            edit { project in project.dataTypes.removeAll { $0.id == id } }
        case let .tagTable(id):
            guard project.tagTables.first?.id != id else {
                alertMessage = "The default tag table can't be deleted."
                return
            }
            edit { project in project.tagTables.removeAll { $0.id == id } }
        case let .watchTable(id):
            edit { project in project.watchTables.removeAll { $0.id == id } }
        default:
            break
        }
    }

    // MARK: - Compile

    /// Compile › Software (Ctrl+B). Results go to Info › Compile.
    @discardableResult
    func compile() -> SiemensCompileResult {
        let result = SiemensProjectCompiler(compileSCL: Self.compileSCL).compile(project)
        if result.project != project {
            edit { project in project = result.project }
        }
        compileResult = result
        inspectorTab = .info
        infoTab = .compile
        lastMessage = result.summary
        return result
    }

    /// Diagnostics of one block from the last compile.
    func diagnostics(ofBlock name: String) -> [Diagnostic] {
        compileResult?.diagnostics.filter { ($0.block ?? "").hasPrefix(name + " [") } ?? []
    }

    /// Double-click on a compile message: open the block and go to the network or line.
    func goTo(_ message: SiemensCompileMessage) {
        guard let id = message.blockID else { return }
        if let block = block(id) {
            open(.block(id))
            if let network = message.network, network >= 1, network <= block.networks.count {
                let target = block.networks[network - 1]
                selections[id] = .network(target.id)
                collapsedNetworks.remove(target.id)
            }
            if let line = message.line {
                pendingGoTo = (id, line, message.column ?? 1)
            }
        } else if project.dataBlocks.contains(where: { $0.id == id }) {
            open(.dataBlock(id))
        }
    }

    // MARK: - Simulation (S7-PLCSIM) and download

    /// Online › Simulation › Start (Ctrl+Shift+X): compile, power up
    /// S7-PLCSIM, then the Extended download dialog.
    func startSimulation() {
        let result = compile()
        guard let image = result.image else {
            lastMessage = "Loading was canceled because the program contains errors. " + result.summary
            return
        }
        if session == nil {
            let simulated = SiemensCPU()
            let newSession = SimulationSession(cpu: simulated)
            if startsSessionTimer { newSession.start() }
            session = newSession
        }
        isPLCSIMVisible = true
        pendingImage = image
        pendingProject = result.project
        loadStep = downloadedProject == nil ? .extendedDownload(searched: false) : .loadPreview(stopModules: cpu?.mode == .run)
        lastMessage = "S7-PLCSIM was started."
    }

    /// Online › Download to device (Ctrl+L).
    func downloadToDevice() {
        guard session != nil else {
            startSimulation()
            return
        }
        let result = compile()
        guard let image = result.image else {
            lastMessage = "Loading was canceled because the program contains errors. " + result.summary
            return
        }
        pendingImage = image
        pendingProject = result.project
        loadStep = .loadPreview(stopModules: cpu?.mode == .run)
    }

    /// "Start search" in Extended download to device.
    func searchDevices() {
        guard case .extendedDownload = loadStep else { return }
        loadStep = .extendedDownload(searched: true)
    }

    /// "Load" in Extended download to device.
    func loadFromExtendedDownload() {
        guard case .extendedDownload(searched: true) = loadStep else { return }
        loadStep = .loadPreview(stopModules: cpu?.mode == .run)
    }

    /// "Load" in Load preview.
    func confirmLoadPreview() {
        guard case .loadPreview = loadStep, let cpu, let image = pendingImage else { return }
        if cpu.mode == .run { cpu.setMode(.stop) }
        cpu.load(image)
        downloadedProject = pendingProject
        pendingImage = nil
        pendingProject = nil
        monitoredBlocks = []
        loadStep = .loadResults(startAll: true)
        session?.refresh()
        lastMessage = "Loading completed (errors: 0; warnings: 0)."
    }

    /// "Finish" in Load results.
    func finishLoad(startAll: Bool) {
        guard case .loadResults = loadStep else { return }
        loadStep = nil
        if startAll, let cpu, cpu.mode == .stop {
            cpu.setMode(.run)
        }
        session?.refresh()
    }

    func cancelLoad() {
        loadStep = nil
        pendingImage = nil
        pendingProject = nil
        lastMessage = "Loading was canceled."
    }

    func setLoadStartAll(_ startAll: Bool) {
        if case .loadResults = loadStep { loadStep = .loadResults(startAll: startAll) }
    }

    /// Closing S7-PLCSIM: the simulated CPU powers off.
    func stopSimulation() {
        session?.stop()
        session = nil
        isPLCSIMVisible = false
        isOnline = false
        monitoredBlocks = []
        monitoredWatchTables = []
        downloadedProject = nil
        loadStep = nil
        lastMessage = "S7-PLCSIM was closed."
    }

    // MARK: - Online

    /// Online › Go online (Ctrl+K).
    func goOnline() {
        guard session != nil, downloadedProject != nil else {
            alertMessage = "No accessible device found. Start the simulation (Ctrl+Shift+X) and download the program first."
            return
        }
        isOnline = true
        lastMessage = "Connected to PLC_1, address IP=192.168.0.1."
    }

    /// Online › Go offline (Ctrl+M).
    func goOffline() {
        for id in monitoredBlocks { setMonitoring(false, block: id) }
        monitoredWatchTables = []
        isOnline = false
        lastMessage = "The online connection to PLC_1 was terminated."
    }

    /// The comparison icon of a block in the project tree while online.
    func onlineStatus(ofBlock id: UUID) -> SiemensOnlineStatus {
        guard let offline = block(id) else { return .offlineOnly }
        guard let online = downloadedProject?.blocks.first(where: { $0.id == id }) else { return .offlineOnly }
        return online == offline ? .identical : .different
    }

    func onlineStatus(ofDataBlock id: UUID) -> SiemensOnlineStatus {
        guard let offline = project.dataBlocks.first(where: { $0.id == id }) else { return .offlineOnly }
        guard let online = downloadedProject?.dataBlocks.first(where: { $0.id == id }) else { return .offlineOnly }
        return online == offline ? .identical : .different
    }

    /// Why monitoring can't start for a block, or nil.
    func monitoringProblem(ofBlock id: UUID) -> String? {
        guard session != nil, isOnline else { return "Go online (Ctrl+K) to monitor the block." }
        switch onlineStatus(ofBlock: id) {
        case .identical: return nil
        case .different: return "The online and offline versions of the block are different. Download the block (Ctrl+L) to monitor it."
        case .offlineOnly: return "The block doesn't exist online. Download it (Ctrl+L) to monitor it."
        }
    }

    /// Monitoring on/off (Ctrl+T).
    func toggleMonitoring(block id: UUID) {
        if monitoredBlocks.contains(id) {
            setMonitoring(false, block: id)
            return
        }
        if let problem = monitoringProblem(ofBlock: id) {
            alertMessage = problem
            return
        }
        setMonitoring(true, block: id)
    }

    private func setMonitoring(_ enabled: Bool, block id: UUID) {
        let name = downloadedProject?.blocks.first { $0.id == id }?.name ?? block(id)?.name
        if let name { cpu?.setMonitoring(enabled, block: name) }
        if enabled { monitoredBlocks.insert(id) } else { monitoredBlocks.remove(id) }
    }

    // MARK: - CPU operator panel

    func requestStartCPU() {
        guard session != nil, cpu?.image != nil else {
            alertMessage = "No accessible device found. Start the simulation (Ctrl+Shift+X) and download the program first."
            return
        }
        confirmation = .startCPU
    }

    func requestStopCPU() {
        guard session != nil else {
            alertMessage = "No accessible device found. Start the simulation (Ctrl+Shift+X) first."
            return
        }
        confirmation = .stopCPU
    }

    func confirm(_ confirmation: SiemensConfirmation) {
        self.confirmation = nil
        switch confirmation {
        case .startCPU: setCPUMode(.run)
        case .stopCPU: setCPUMode(.stop)
        case .memoryReset:
            cpu?.memoryReset()
            session?.refresh()
        case .forceAll: forceAll()
        }
    }

    /// RUN / STOP from the operator panel or PLCSIM.
    func setCPUMode(_ mode: CPUMode) {
        guard let session else { return }
        session.setMode(mode)
        lastMessage = mode == .run ? "PLC_1 was started." : "PLC_1 was stopped."
    }

    // MARK: - Modify

    /// Modify › Modify operand… or a watch table's "Modify now" for one row.
    func modifyOperand(_ operand: String, to value: String, format: S7DisplayFormat? = nil) {
        guard let cpu else {
            alertMessage = "Modifying requires an online connection to the CPU."
            return
        }
        do {
            try cpu.modify(operand, to: value, format: format)
            session?.refresh()
        } catch let error as ResolveError {
            alertMessage = error.message
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Modify to 1 (Ctrl+Shift+1) / Modify to 0 (Ctrl+Shift+9) for the selected contact or coil.
    func modifySelection(to value: Bool) {
        guard let block = currentBlock, monitoredBlocks.contains(block.id),
              case let .element(networkID, id)? = selections[block.id],
              let network = block.networks.first(where: { $0.id == networkID }), let node = network.element(id)
        else {
            alertMessage = "Select a contact or coil in a monitored block to modify its operand."
            return
        }
        let operand: String
        switch node {
        case let .contact(contact): operand = contact.operand
        case let .coil(coil): operand = coil.operand
        default:
            alertMessage = "Only Bool operands of contacts and coils can be modified to 0 or 1."
            return
        }
        modifyOperand(operand, to: value ? "TRUE" : "FALSE")
    }

    // MARK: - Watch and force tables

    func watchValue(_ row: SiemensWatchRow, table: UUID) -> String? {
        guard !row.isCommentLine, !row.operand.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if monitoredWatchTables.contains(table), let cpu {
            switch cpu.monitorValue(row.operand, format: row.displayFormat) {
            case let .success(text): return text
            case let .failure(error): return error.message
            }
        }
        return watchSnapshot[row.id]
    }

    func toggleMonitorAll(_ table: UUID) {
        if monitoredWatchTables.contains(table) {
            monitoredWatchTables.remove(table)
        } else if isOnline {
            monitoredWatchTables.insert(table)
        } else {
            alertMessage = "Go online (Ctrl+K) to monitor the watch table."
        }
    }

    /// "Monitor now": reads every row once.
    func monitorNow(_ tableID: UUID) {
        guard isOnline, let cpu, let table = project.watchTables.first(where: { $0.id == tableID }) else {
            alertMessage = "Go online (Ctrl+K) to monitor the watch table."
            return
        }
        for row in table.rows where !row.isCommentLine {
            switch cpu.monitorValue(row.operand, format: row.displayFormat) {
            case let .success(text): watchSnapshot[row.id] = text
            case let .failure(error): watchSnapshot[row.id] = error.message
            }
        }
    }

    /// "Modify now": writes every checked row's modify value once.
    func modifyNow(_ tableID: UUID) {
        guard isOnline, let table = project.watchTables.first(where: { $0.id == tableID }) else {
            alertMessage = "Go online (Ctrl+K) to modify values."
            return
        }
        for row in table.rows where row.isModifyEnabled && !row.isCommentLine && !row.modifyValue.isEmpty {
            modifyOperand(row.operand, to: row.modifyValue, format: row.displayFormat)
        }
    }

    func requestForceAll() {
        guard isOnline else {
            alertMessage = "Go online (Ctrl+K) to force values."
            return
        }
        confirmation = .forceAll
    }

    /// Forces every row with the "F" box ticked.
    func forceAll() {
        guard let cpu else { return }
        for row in project.forceTable where row.isForceEnabled {
            do {
                try cpu.force(row.operand, to: row.forceValue)
            } catch let error as ResolveError {
                alertMessage = "\(row.operand): \(error.message)"
            } catch {
                alertMessage = error.localizedDescription
            }
        }
        session?.refresh()
    }

    /// Force to 0 / Force to 1 for one row.
    func force(_ row: SiemensForceRow, to value: Bool) {
        edit { project in
            if let index = project.forceTable.firstIndex(where: { $0.id == row.id }) {
                project.forceTable[index].forceValue = value ? "TRUE" : "FALSE"
                project.forceTable[index].isForceEnabled = true
            }
        }
        requestForceAll()
    }

    func stopForcing() {
        cpu?.stopForcing()
        session?.refresh()
        lastMessage = "Forcing was stopped."
    }
}
