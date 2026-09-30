import AppKit
import SwiftUI
import Testing
@testable import GyozaPortalworks

/// Renders the real views off screen and writes PNGs, so CI proves the views
/// build and lay out without crashing, and the images can be reviewed.
@MainActor
enum Snapshot {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ui-snapshots", isDirectory: true)

    @discardableResult
    static func render<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 1440, height: 900)) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its update passes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.noBitmap
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        window.contentView = nil
        return data
    }

    enum SnapshotError: Error {
        case noBitmap
    }
}

@MainActor
struct UISnapshotTests {
    @Test func gxWorks3NewProject() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        let data = try Snapshot.render(MelsecWorkspaceView(workspace: workspace), name: "gx-new-project")
        #expect(data.count > 10_000)
    }

    @Test func gxWorks3MonitoringASelfHold() throws {
        let workspace = MelsecWorkspace(project: .newProject())
        try MelsecWorkspaceEditingTests.type(["LD X0", "ANI X1", "OUT Y0", "OR Y0", "LD X2", "OUT T0 K50"], into: workspace)
        workspace.startSimulation()
        workspace.executeOnlineOperation(.startSimulation)
        defer { workspace.stopSimulation() }
        let cpu = try #require(workspace.cpu)
        workspace.changeMode(to: .monitor)
        cpu.setDigitalInput(0, true)
        cpu.setDigitalInput(2, true)
        for step in 1...30 { cpu.scan(clock: Int64(step) * 100) }
        cpu.setDigitalInput(0, false)
        cpu.scan(clock: 3_100)
        workspace.session?.refresh()
        let data = try Snapshot.render(MelsecWorkspaceView(workspace: workspace), name: "gx-monitoring")
        #expect(data.count > 10_000)
    }

    @Test func tiaPortalNewProject() throws {
        let workspace = SiemensWorkspace(project: .newProject(), store: nil)
        workspace.startsSessionTimer = false
        let data = try Snapshot.render(SiemensWorkspaceView(workspace: workspace), name: "tia-new-project")
        #expect(data.count > 10_000)
    }

    @Test func tiaPortalMonitoringANetwork() throws {
        let workspace = SiemensWorkspace(project: .newProject(), store: nil)
        workspace.startsSessionTimer = false
        for (command, operand) in [(S7EditorCommand.insertContact(.normallyOpen), "%I0.0"),
                                   (.insertContact(.normallyClosed), "%I0.1"),
                                   (.insertCoil(.assign), "%Q0.0")] {
            workspace.perform(command)
            let target = try #require(workspace.editingOperand)
            let block = try #require(workspace.currentBlock)
            workspace.commitOperand(operand, target: target, inBlock: block.id)
        }
        _ = workspace.compile()
        workspace.startSimulation()
        workspace.searchDevices()
        workspace.loadFromExtendedDownload()
        workspace.confirmLoadPreview()
        workspace.finishLoad(startAll: true)
        defer { workspace.stopSimulation() }
        let cpu = try #require(workspace.cpu)
        let mainID = try #require(workspace.project.blocks.first { $0.name == "Main" }?.id)
        workspace.goOnline()
        workspace.toggleMonitoring(block: mainID)
        cpu.setDigitalInput(0, true)
        cpu.scan(clock: 10)
        cpu.scan(clock: 20)
        workspace.session?.refresh()
        let data = try Snapshot.render(SiemensWorkspaceView(workspace: workspace), name: "tia-monitoring")
        #expect(data.count > 10_000)
    }

    /// Reference solutions drawn with the editors' own views, for review.
    @Test(arguments: ["tia-01-seal-in", "tia-05-traffic-light", "tia-07-storage", "tia-10-scl-traffic-light",
                      "gx-01-self-hold", "gx-05-traffic-light", "gx-10-master-control"])
    func referenceSolution(_ id: String) throws {
        let exercise = try #require(ExerciseLibrary.all.first { $0.id == id })
        let view = ScrollView { ReferenceSolutionView(exercise: exercise).padding(24) }
        let data = try Snapshot.render(view, name: "ref-\(id)", size: CGSize(width: 780, height: 1100))
        #expect(data.count > 10_000)
    }

    @Test func exercisesWindow() throws {
        let model = AppModel()
        model.environment = .gxWorks3
        let data = try Snapshot.render(ExercisesView().environment(model), name: "exercises", size: CGSize(width: 960, height: 680))
        #expect(data.count > 5_000)
    }
}
