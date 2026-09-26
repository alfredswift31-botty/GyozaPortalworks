import AppKit
import SwiftUI

/// The colours of a vendor's engineering tool.
nonisolated struct VendorTheme: Sendable {
    /// Selection outlines, primary buttons, focus.
    var accent: Color
    /// Menu bar and tool strip.
    var chrome: Color
    var paneBackground: Color
    var paneHeader: Color
    var paneHeaderText: Color
    var editorBackground: Color
    var selection: Color
    var statusBar: Color
    var statusText: Color
    /// Title bar tint while online / monitoring (TIA turns orange).
    var online: Color

    /// TIA Portal V16/V17 project view: light grey panes, petrol accent.
    static let tiaPortal = VendorTheme(
        accent: Color(red: 0.0, green: 0.6, blue: 0.6),
        chrome: Color(nsColor: .windowBackgroundColor),
        paneBackground: Color(nsColor: .controlBackgroundColor),
        paneHeader: Color(red: 0.84, green: 0.87, blue: 0.88),
        paneHeaderText: Color(red: 0.13, green: 0.2, blue: 0.24),
        editorBackground: Color(nsColor: .textBackgroundColor),
        selection: Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.22),
        statusBar: Color(red: 0.84, green: 0.87, blue: 0.88),
        statusText: Color(red: 0.13, green: 0.2, blue: 0.24),
        online: Color(red: 1.0, green: 0.55, blue: 0.0)
    )

    /// GX Works3: light panes, blue docking-window headers.
    static let gxWorks3 = VendorTheme(
        accent: Color(red: 0.0, green: 0.36, blue: 0.75),
        chrome: Color(nsColor: .windowBackgroundColor),
        paneBackground: Color(nsColor: .controlBackgroundColor),
        paneHeader: Color(red: 0.25, green: 0.4, blue: 0.62),
        paneHeaderText: .white,
        editorBackground: Color(nsColor: .textBackgroundColor),
        selection: Color(red: 0.0, green: 0.36, blue: 0.75).opacity(0.2),
        statusBar: Color(red: 0.9, green: 0.92, blue: 0.95),
        statusText: Color(red: 0.1, green: 0.15, blue: 0.25),
        online: Color(red: 0.0, green: 0.45, blue: 0.9)
    )
}

/// A menu entry in a vendor's in-window menu bar.
indirect enum MenuItem {
    /// `shortcut` is the vendor's key text ("Ctrl+B", "F4"), shown after the title.
    case command(String, shortcut: String? = nil, isEnabled: Bool = true, action: () -> Void)
    case toggle(String, isOn: Bool, shortcut: String? = nil, action: () -> Void)
    case submenu(String, [MenuItem])
    case divider
}

/// A Windows-style menu bar inside the window ("Project  Edit  View  …"),
/// laid out the way the vendor's tool lays out its menus.
struct MenuBarStrip: View {
    let menus: [(title: String, items: [MenuItem])]
    let theme: VendorTheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(menus.enumerated()), id: \.offset) { _, menu in
                Menu {
                    MenuItemList(items: menu.items)
                } label: {
                    Text(menu.title)
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 7)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 24)
        .background(theme.chrome)
    }
}

/// The contents of one menu.
struct MenuItemList: View {
    let items: [MenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            entry(item)
        }
    }

    @ViewBuilder
    private func entry(_ item: MenuItem) -> some View {
        switch item {
        case let .command(title, shortcut, isEnabled, action):
            Button(Self.label(title, shortcut), action: action)
                .disabled(!isEnabled)
        case let .toggle(title, isOn, shortcut, action):
            Button(action: action) {
                if isOn {
                    Label(Self.label(title, shortcut), systemImage: "checkmark")
                } else {
                    Text(Self.label(title, shortcut))
                }
            }
        case let .submenu(title, children):
            Menu(title) {
                MenuItemList(items: children)
            }
        case .divider:
            Divider()
        }
    }

    private static func label(_ title: String, _ shortcut: String?) -> String {
        guard let shortcut else { return title }
        return "\(title)    \(shortcut)"
    }
}

/// One button in a tool strip.
struct ToolItem: Identifiable {
    let id = UUID()
    var systemImage: String
    var help: String
    var isEnabled = true
    var isActive = false
    var action: () -> Void
    /// Starts a new group with a separator before it.
    var startsGroup = false
}

/// A row of icon buttons under the menu bar, like the vendor's toolbar.
struct ToolStrip: View {
    let items: [ToolItem]
    let theme: VendorTheme
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                if item.startsGroup {
                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 4)
                }
                Button(action: item.action) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 13))
                        .frame(width: 26, height: 24)
                        .foregroundStyle(item.isActive ? theme.accent : Color.primary)
                        .background(item.isActive ? theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.35)
                .help(item.help)
                .accessibilityLabel(item.help)
            }
            Spacer(minLength: 8)
            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(theme.chrome)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// A docked pane with a title bar ("Project tree", "Navigation", "Output").
struct DockPanel<Content: View>: View {
    let title: String
    let theme: VendorTheme
    var accessory: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.paneHeaderText)
                Spacer(minLength: 4)
                if let accessory {
                    accessory
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.paneHeader)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.paneBackground)
        }
    }
}

/// A tab in the editor area.
struct EditorTab: Identifiable, Hashable {
    var id: String
    var title: String
    var systemImage: String?
    /// Unsaved or unconverted changes: shows a dot.
    var isModified = false
}

/// The tab strip above the editors (TIA's editor bar sits below; GX's above).
struct EditorTabStrip: View {
    let tabs: [EditorTab]
    @Binding var selection: String?
    let theme: VendorTheme
    var onClose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(tabs) { tab in
                    let selected = tab.id == selection
                    HStack(spacing: 5) {
                        if let image = tab.systemImage {
                            Image(systemName: image)
                                .font(.system(size: 10))
                        }
                        Text(tab.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        if tab.isModified {
                            Circle()
                                .frame(width: 5, height: 5)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            onClose(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Close \(tab.title)")
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(selected ? theme.editorBackground : theme.paneBackground.opacity(0.6))
                    .overlay(alignment: .top) {
                        if selected {
                            Rectangle()
                                .fill(theme.accent)
                                .frame(height: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = tab.id
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .frame(height: 24)
        .background(theme.chrome)
    }
}

/// The status bar at the bottom of the window.
struct StatusStrip: View {
    let segments: [String]
    let theme: VendorTheme
    var leading: AnyView?

    var body: some View {
        HStack(spacing: 0) {
            if let leading {
                leading
                    .padding(.trailing, 10)
            }
            Spacer(minLength: 8)
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Divider()
                    .frame(height: 14)
                Text(segment)
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
            }
        }
        .foregroundStyle(theme.statusText)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(theme.statusBar)
    }
}

/// A vendor keyboard shortcut, as it's written in the vendor's docs.
struct VendorShortcut {
    var key: KeyEquivalent
    var modifiers: EventModifiers
    var action: () -> Void

    /// Function key F1–F12 (bare, or with modifiers: Shift+F5 is `.function(5, [.shift])`).
    static func function(_ number: Int, _ modifiers: EventModifiers = [], action: @escaping () -> Void) -> VendorShortcut {
        let scalar = UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(max(1, min(number, 35)) - 1)) ?? UnicodeScalar(0xF704)!
        return VendorShortcut(key: KeyEquivalent(Character(scalar)), modifiers: modifiers, action: action)
    }

    static func key(_ key: KeyEquivalent, _ modifiers: EventModifiers = [], action: @escaping () -> Void) -> VendorShortcut {
        VendorShortcut(key: key, modifiers: modifiers, action: action)
    }
}

/// Invisible buttons that give a workspace its vendor keyboard shortcuts
/// (Ctrl+B compile, F4 convert, Shift+F5 …) while it's on screen.
struct ShortcutLayer: View {
    let shortcuts: [VendorShortcut]

    var body: some View {
        ZStack {
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, shortcut in
                Button("", action: shortcut.action)
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
