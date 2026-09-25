import AppKit
import SwiftUI

enum WindowID {
    static let main = "main"
    static let trainer = "trainer"
    static let exercises = "exercises"
}

@main
struct GyozaPortalworksApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("GyozaPortalworks", id: WindowID.main) {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            PracticeCommands(model: model)
        }

        Window("I/O Trainer", id: WindowID.trainer) {
            TrainerView()
                .environment(model)
        }
        .defaultSize(width: 680, height: 560)

        Window("Exercises", id: WindowID.exercises) {
            ExercisesView()
                .environment(model)
        }
        .defaultSize(width: 960, height: 680)
    }
}

struct PracticeCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About GyozaPortalworks") {
                AboutPanel.show()
            }
        }
        CommandMenu("Practice") {
            Button("TIA Portal") {
                model.environment = .tiaPortal
            }
            .keyboardShortcut("1", modifiers: .command)
            Button("GX Works3") {
                model.environment = .gxWorks3
            }
            .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Exercises") {
                openWindow(id: WindowID.exercises)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("I/O Trainer") {
                openWindow(id: WindowID.trainer)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}

enum AboutPanel {
    static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(
            string: """
            Practise PLC programming the way TIA Portal and GX Works3 work: \
            LAD, FBD, SCL, ladder and ST, with simulated S7-1200 and FX5U CPUs.

            Not affiliated with or endorsed by Siemens AG or Mitsubishi Electric \
            Corporation. TIA Portal, SIMATIC and STEP 7 are trademarks of Siemens AG. \
            MELSEC and GX Works are trademarks of Mitsubishi Electric Corporation.
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
