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
    private final class LiveView {
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
}
