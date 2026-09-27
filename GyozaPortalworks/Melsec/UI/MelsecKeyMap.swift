import Foundation

/// A key as the ladder editor sees it, independent of SwiftUI/AppKit.
nonisolated enum MelsecKey: Hashable, Sendable {
    case function(Int)
    case arrow(MelsecDirection)
    case enter
    case delete
    case backspace
    /// Insert (the Help key on Mac keyboards with a PC layout).
    case insert
    case escape
    case character(Character)
}

nonisolated struct MelsecKeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let shift = MelsecKeyModifiers(rawValue: 1)
    static let control = MelsecKeyModifiers(rawValue: 2)
    /// Alt on a PC keyboard.
    static let option = MelsecKeyModifiers(rawValue: 4)
    static let command = MelsecKeyModifiers(rawValue: 8)
}

/// The editor modes of GX Works3's ladder editor.
nonisolated enum MelsecEditorMode: String, Hashable, Sendable {
    /// Write mode (F2).
    case write
    /// Read mode (Shift+F2).
    case read
    /// Monitor mode (F3): read only.
    case monitor
    /// Monitor (Write Mode) (Shift+F3): monitor while editing.
    case monitorWrite

    var isMonitoring: Bool { self == .monitor || self == .monitorWrite }
    var allowsEditing: Bool { self == .write || self == .monitorWrite }
}

/// What a key does in the ladder editor.
nonisolated enum MelsecLadderCommand: Hashable, Sendable {
    case moveCursor(MelsecDirection)
    /// Opens the Ladder Input dialog with a symbol and initial text.
    case ladderInput(MelsecLadderSymbol, text: String)
    /// Enter: edits the element at the cursor.
    case editElement
    case insertOperationResult(MelsecOperationResultKind)
    case drawHorizontalLine
    case drawVerticalLine
    case deleteHorizontalLine
    case deleteVerticalLine
    case drawLine(MelsecDirection)
    case insertRow
    case deleteRow
    case insertColumn
    case deleteColumn
    case toggleInsertMode
    case deleteElement
    /// Shift+Enter in monitor mode: invert the bit at the cursor.
    case toggleBit
    case setMode(MelsecEditorMode)
    case convert
    case rebuildAll
    case undo
    case redo

    /// Whether the command changes the program (blocked in read/monitor mode).
    var edits: Bool {
        switch self {
        case .moveCursor, .toggleBit, .setMode, .convert, .rebuildAll, .undo, .redo:
            return false
        default:
            return true
        }
    }
}

/// GX Works3's ladder editor keys.
nonisolated enum MelsecKeyMap {
    static func command(for key: MelsecKey, modifiers rawModifiers: MelsecKeyModifiers) -> MelsecLadderCommand? {
        let modifiers = rawModifiers
        let shift = modifiers.contains(.shift)
        let control = modifiers.contains(.control)
        let option = modifiers.contains(.option)
        let command = modifiers.contains(.command)
        switch key {
        case let .function(number):
            return functionKey(number, shift: shift, control: control, option: option)
        case let .arrow(direction):
            if control { return .drawLine(direction) }
            return .moveCursor(direction)
        case .enter:
            return shift ? .toggleBit : .editElement
        case .delete:
            if shift { return .deleteRow }
            if control { return .deleteColumn }
            return .deleteElement
        case .backspace:
            return .deleteElement
        case .insert:
            if shift { return .insertRow }
            if control { return .insertColumn }
            return .toggleInsertMode
        case .escape:
            return nil
        case let .character(character):
            if command || control {
                switch (character.lowercased(), shift) {
                case ("z", false): return .undo
                case ("z", true): return .redo
                case ("y", _): return control ? .redo : nil
                default: return nil
                }
            }
            guard !option, character.isLetter || character.isNumber || character == ";" else { return nil }
            return .ladderInput(.openContact, text: String(character))
        }
    }

    private static func functionKey(_ number: Int, shift: Bool, control: Bool, option: Bool) -> MelsecLadderCommand? {
        switch (number, shift, control, option) {
        case (2, false, false, false): return .setMode(.write)
        case (2, true, false, false): return .setMode(.read)
        case (3, false, false, false): return .setMode(.monitor)
        case (3, true, false, false): return .setMode(.monitorWrite)
        case (3, false, false, true): return .setMode(.write)
        case (4, false, false, false): return .convert
        case (4, true, false, true): return .rebuildAll
        case (5, false, false, false): return .ladderInput(.openContact, text: "")
        case (5, true, false, false): return .ladderInput(.openBranch, text: "")
        case (5, false, false, true): return .insertOperationResult(.risingPulse)
        case (5, false, true, true): return .insertOperationResult(.fallingPulse)
        case (6, false, false, false): return .ladderInput(.closeContact, text: "")
        case (6, true, false, false): return .ladderInput(.closeBranch, text: "")
        case (7, false, false, false): return .ladderInput(.coil, text: "")
        case (7, true, false, false): return .ladderInput(.risingPulse, text: "")
        case (7, false, false, true): return .ladderInput(.risingPulseBranch, text: "")
        case (8, false, false, false): return .ladderInput(.instruction, text: "")
        case (8, true, false, false): return .ladderInput(.fallingPulse, text: "")
        case (8, false, false, true): return .ladderInput(.fallingPulseBranch, text: "")
        case (9, false, false, false): return .drawHorizontalLine
        case (9, true, false, false): return .drawVerticalLine
        case (9, false, true, false): return .deleteHorizontalLine
        case (10, false, true, false): return .deleteVerticalLine
        case (10, false, true, true): return .insertOperationResult(.invert)
        default: return nil
        }
    }

    /// The key text GX Works3 shows for a command, for menus and tooltips.
    static func shortcutText(_ command: MelsecLadderCommand) -> String? {
        switch command {
        case .setMode(.write): return "F2"
        case .setMode(.read): return "Shift+F2"
        case .setMode(.monitor): return "F3"
        case .setMode(.monitorWrite): return "Shift+F3"
        case .convert: return "F4"
        case .rebuildAll: return "Shift+Alt+F4"
        case .ladderInput(.openContact, _): return "F5"
        case .ladderInput(.openBranch, _): return "Shift+F5"
        case .ladderInput(.closeContact, _): return "F6"
        case .ladderInput(.closeBranch, _): return "Shift+F6"
        case .ladderInput(.coil, _): return "F7"
        case .ladderInput(.instruction, _): return "F8"
        case .ladderInput(.risingPulse, _): return "Shift+F7"
        case .ladderInput(.fallingPulse, _): return "Shift+F8"
        case .ladderInput(.risingPulseBranch, _): return "Alt+F7"
        case .ladderInput(.fallingPulseBranch, _): return "Alt+F8"
        case .insertOperationResult(.risingPulse): return "Alt+F5"
        case .insertOperationResult(.fallingPulse): return "Ctrl+Alt+F5"
        case .insertOperationResult(.invert): return "Ctrl+Alt+F10"
        case .drawHorizontalLine: return "F9"
        case .drawVerticalLine: return "Shift+F9"
        case .deleteHorizontalLine: return "Ctrl+F9"
        case .deleteVerticalLine: return "Ctrl+F10"
        case .insertRow: return "Shift+Insert"
        case .deleteRow: return "Shift+Delete"
        case .insertColumn: return "Ctrl+Insert"
        case .deleteColumn: return "Ctrl+Delete"
        case .toggleInsertMode: return "Insert"
        case .toggleBit: return "Shift+Enter"
        case .undo: return "Ctrl+Z"
        case .redo: return "Ctrl+Y"
        default: return nil
        }
    }

    /// Every F-key binding, for the shortcut layer: (number, modifiers, command).
    static var functionKeyBindings: [(number: Int, modifiers: MelsecKeyModifiers, command: MelsecLadderCommand)] {
        var bindings: [(number: Int, modifiers: MelsecKeyModifiers, command: MelsecLadderCommand)] = []
        let combinations: [MelsecKeyModifiers] = [[], [.shift], [.control], [.option], [.control, .option], [.shift, .option]]
        for number in 2...10 {
            for modifiers in combinations {
                if let command = command(for: .function(number), modifiers: modifiers) {
                    bindings.append((number, modifiers, command))
                }
            }
        }
        return bindings
    }
}
