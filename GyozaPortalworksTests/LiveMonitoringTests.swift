import AppKit
import SwiftUI
import Testing
@testable import GyozaPortalworks

/// Monitoring must follow the CPU while the view stays on screen. The other
/// snapshot tests render a fresh view each time, so they can't see a view
/// that only redraws when it's rebuilt (switching tabs and back).
@MainActor
struct LiveMonitoringTests {
    /// Renders the same hosting view again after the CPU state changes.
    @MainActor private final class LiveView {
        let host: NSHostingView<AnyView>
        let window: NSWindow

        init<V: View>(_ view: V, size: CGSize) {
            host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
            host.frame = CGRect(origin: .zero, size: size)
            window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
        }

        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.tiffRepresentation)
        }
    }

    @Test func tiaLadderRedrawsWhenAnInputChanges() throws {
        let workspace = SiemensWorkspace(project: .newProject(), store: nil)
        workspace.startsSessionTimer = false
        for (command, operand) in [(S7EditorCommand.insertContact(.normallyOpen), "%I0.0"),
                                   (.insertCoil(.assign), "%Q0.0")] {
            workspace.perform(command)
            let target = try #require(workspace.editingOperand)
            let block = try #require(workspace.currentBlock)
            workspace.commitOperand(operand, target: target, inBlock: block.id)
        }
        workspace.startSimulation()
        workspace.searchDevices()
        workspace.loadFromExtendedDownload()
        workspace.confirmLoadPreview()
        workspace.finishLoad(startAll: true)
        defer { workspace.stopSimulation() }
        let cpu = try #require(workspace.cpu)
        let main = try #require(workspace.project.blocks.first { $0.name == "Main" })
        workspace.goOnline()
        workspace.toggleMonitoring(block: main.id)
        cpu.scan(clock: 10)
        workspace.session?.refresh()

        let live = LiveView(SiemensNetworkList(workspace: workspace, block: main), size: CGSize(width: 900, height: 400))
        let off = try live.pixels()

        // Press the button: the rung and coil should turn green in the same view.
        cpu.setDigitalInput(0, true)
        cpu.scan(clock: 20)
        cpu.scan(clock: 30)
        workspace.session?.refresh()
        let on = try live.pixels()
        #expect(on != off, "The monitored network didn't redraw after %I0.0 turned on")

        // And back: releasing it must show in the same view too.
        cpu.setDigitalInput(0, false)
        cpu.scan(clock: 40)
        cpu.scan(clock: 50)
        workspace.session?.refresh()
        let offAgain = try live.pixels()
        #expect(offAgain != on, "The monitored network didn't redraw after %I0.0 turned off")
    }

    /// The user's setup end to end: the app model, exercise 1 wired to the
    /// trainer, the simulation's real timer, and the coil typed "K1_motor"
    /// while the tag is K1_Motor. On a real Mac the watch table showed
    /// %Q0.0 TRUE while the trainer's lamp (the output terminal) stayed off.
    @Test func exerciseOneDrivesTheOutputTerminalsInRealTime() throws {
        let model = AppModel()
        model.environment = .tiaPortal
        let workspace = try #require(model.activeWorkspace as? SiemensWorkspace)
        var project = try #require(SiemensReferenceSolutions.project(for: "tia-01-seal-in"))
        project.blocks[0].networks = [
            LAD.net(LAD.par([LAD.no("\"S1_Start\"")], [LAD.no("\"K1_Motor\"")]), LAD.no("\"S2_Stop\""),
                    LAD.coil("\"K1_motor\""), LAD.coil("\"H1_Running\"")),
        ]
        _ = workspace.edit { $0 = project }
        workspace.startSimulation()
        workspace.searchDevices()
        workspace.loadFromExtendedDownload()
        workspace.confirmLoadPreview()
        workspace.finishLoad(startAll: true)
        defer {
            workspace.stopSimulation()
            model.activate(nil)
        }
        let exercise = try #require(ExerciseLibrary.exercises(for: .tiaPortal).first { $0.id == "tia-01-seal-in" })
        model.activate(exercise)
        let session = try #require(model.activeSession)
        #expect(session === workspace.session)
        let cpu = try #require(workspace.cpu)

        func state() -> String {
            let q0 = cpu.readOperand("%Q0.0").map { S7ValueText.text($0) } ?? "?"
            let log = cpu.diagnostics.suffix(5).map(\.message).joined(separator: " | ")
            return "mode \(cpu.mode.rawValue), %Q0.0 \(q0), terminal Q0.0 \(cpu.digitalOutput(0)), log: \(log)"
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(cpu.mode == .run, "\(state())")
        #expect(cpu.digitalInput(1), "S2 is wired normally closed: TRUE at rest")

        // Press S1 on the trainer for 0.3 s, then release it.
        cpu.setDigitalInput(0, true)
        session.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        cpu.setDigitalInput(0, false)
        session.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(cpu.readOperand("%Q0.0")?.boolValue == true, "\(state())")
        #expect(cpu.digitalOutput(0), "The K1 terminal should be on: \(state())")
        #expect(cpu.digitalOutput(1), "The H1 terminal should be on: \(state())")
    }

    /// Reported on a real Mac: the trainer's output lamps stayed off while the
    /// program switched the outputs on. Only the output grid is drawn here, so
    /// a change can only come from the lamps. Without the scroll view the test
    /// passed on the broken lamps.
    @Test func trainerOutputLampsFollowTheCPU() throws {
        let workspace = SiemensWorkspace(project: .newProject(), store: nil)
        workspace.startsSessionTimer = false
        for (command, operand) in [(S7EditorCommand.insertContact(.normallyOpen), "%I0.0"),
                                   (.insertCoil(.assign), "%Q0.0")] {
            workspace.perform(command)
            let target = try #require(workspace.editingOperand)
            let block = try #require(workspace.currentBlock)
            workspace.commitOperand(operand, target: target, inBlock: block.id)
        }
        workspace.startSimulation()
        workspace.searchDevices()
        workspace.loadFromExtendedDownload()
        workspace.confirmLoadPreview()
        workspace.finishLoad(startAll: true)
        defer { workspace.stopSimulation() }
        let session = try #require(workspace.session)
        let cpu = session.cpu
        cpu.scan(clock: 10)
        session.refresh()

        // In a scroll view, as on the trainer board: a lazy grid only builds its
        // items lazily inside one.
        let live = LiveView(ScrollView { TrainerOutputGrid(session: session, exercise: nil).padding(20) },
                            size: CGSize(width: 700, height: 260))
        let off = try live.pixels()
        #expect(!cpu.digitalOutput(0))

        cpu.setDigitalInput(0, true)
        cpu.scan(clock: 20)
        cpu.scan(clock: 30)
        session.refresh()
        #expect(cpu.digitalOutput(0))
        let on = try live.pixels()
        #expect(on != off, "The %Q0.0 lamp didn't light while the trainer stayed open")

        cpu.setDigitalInput(0, false)
        cpu.scan(clock: 40)
        cpu.scan(clock: 50)
        session.refresh()
        let offAgain = try live.pixels()
        #expect(offAgain != on, "The %Q0.0 lamp didn't go out while the trainer stayed open")
    }
}
