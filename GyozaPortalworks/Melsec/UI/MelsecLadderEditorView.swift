import AppKit
import SwiftUI

/// The ladder editor: the grid canvas with GX Works3's keys.
struct MelsecLadderEditorView: View {
    let workspace: MelsecWorkspace
    let programID: UUID
    @FocusState private var isFocused: Bool

    var body: some View {
        // Monitoring redraws with every simulator refresh.
        let _ = workspace.session?.frame
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                if let drawing = workspace.ladderDrawing(programID: programID, isFocused: isFocused) {
                    ZStack(alignment: .topLeading) {
                        MelsecLadderCanvas(drawing: drawing, accent: workspace.theme.accent)
                        cursorAnchor(drawing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, coordinateSpace: .local) { location in
                        doubleClick(at: location, drawing: drawing)
                    }
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        click(at: location, drawing: drawing)
                    }
                }
            }
            .onChange(of: workspace.cursor(for: programID)) {
                proxy.scrollTo("cursor")
            }
        }
        .background(workspace.theme.editorBackground)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handle(press)
        }
        .onAppear {
            isFocused = true
        }
    }

    /// An invisible view at the cursor so the scroll view can follow it.
    private func cursorAnchor(_ drawing: MelsecLadderDrawing) -> some View {
        let rect = drawing.layout.cellRect(drawing.cursor)
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .id("cursor")
            .allowsHitTesting(false)
    }

    private func click(at location: CGPoint, drawing: MelsecLadderDrawing) {
        isFocused = true
        guard let cell = drawing.layout.cell(at: location, endRow: drawing.ladder.endRow) else { return }
        workspace.cursors[programID] = cell
    }

    private func doubleClick(at location: CGPoint, drawing: MelsecLadderDrawing) {
        click(at: location, drawing: drawing)
        if NSEvent.modifierFlags.contains(.shift) || workspace.mode == .monitor {
            workspace.perform(.toggleBit)
        } else {
            workspace.perform(.editElement)
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard workspace.sheet == nil, let key = MelsecKeyTranslation.key(press) else { return .ignored }
        let modifiers = MelsecKeyTranslation.modifiers(press.modifiers)
        guard let command = MelsecKeyMap.command(for: key, modifiers: modifiers) else { return .ignored }
        workspace.perform(command)
        return .handled
    }
}

/// SwiftUI key events → the editor's key model.
enum MelsecKeyTranslation {
    static func key(_ press: KeyPress) -> MelsecKey? {
        switch press.key {
        case .upArrow: return .arrow(.up)
        case .downArrow: return .arrow(.down)
        case .leftArrow: return .arrow(.left)
        case .rightArrow: return .arrow(.right)
        case .return: return .enter
        case .delete: return .backspace
        case .deleteForward: return .delete
        case .escape: return .escape
        default: break
        }
        guard let scalar = press.key.character.unicodeScalars.first else { return nil }
        let value = Int(scalar.value)
        if value == NSHelpFunctionKey || value == NSInsertFunctionKey {
            return .insert
        }
        if value >= NSF1FunctionKey, value <= NSF35FunctionKey {
            return .function(value - NSF1FunctionKey + 1)
        }
        if value == 3 || value == 13 {
            return .enter
        }
        let character = press.characters.first ?? press.key.character
        guard !character.isNewline else { return nil }
        if let ascii = character.asciiValue, ascii < 32 {
            // Ctrl+letter arrives as a control character; recover the letter.
            return .character(Character(UnicodeScalar(ascii + 96)))
        }
        return .character(character)
    }

    static func modifiers(_ modifiers: EventModifiers) -> MelsecKeyModifiers {
        var result: MelsecKeyModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }

    static func eventModifiers(_ modifiers: MelsecKeyModifiers) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }
}
