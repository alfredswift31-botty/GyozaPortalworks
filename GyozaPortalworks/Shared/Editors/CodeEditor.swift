import AppKit
import SwiftUI

/// A coloured range of source text.
struct HighlightSpan: Hashable {
    var range: NSRange
    var color: NSColor
    var isBold = false
}

/// A compiler message to mark in the text (1-based line and column).
struct EditorDiagnostic: Hashable {
    var line: Int
    var column: Int
    /// Characters to underline; 0 underlines to the end of the line.
    var length: Int
    var message: String
    var isError: Bool
}

/// One value in the monitor column: an operand and its live value.
struct MonitorEntry: Hashable {
    enum Style: Hashable {
        /// TIA Portal: grey value box, the operand name in front.
        case siemens
        /// GX Works3: TRUE on blue, FALSE on black, numbers on yellow.
        case melsec
    }

    var operand: String
    var value: String
    /// Bool values get the vendor's TRUE/FALSE colours.
    var boolValue: Bool?
    var style: Style
}

/// Commands for an editor from outside SwiftUI's data flow: jump to an
/// error, comment lines out.
@MainActor final class CodeEditorController {
    fileprivate weak var textView: EditorTextView?

    /// Selects the given 1-based line and column and scrolls it into view.
    func goTo(line: Int, column: Int = 1) {
        guard let textView else { return }
        let text = textView.string as NSString
        var location = 0
        var current = 1
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        let target = min(location + max(0, column - 1), NSMaxRange(lineRange))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: target, length: 0))
        textView.scrollRangeToVisible(lineRange)
        textView.showFindIndicator(for: lineRange.length > 0 ? lineRange : NSRange(location: target, length: 0))
    }

    /// Prefixes the selected lines with "// " (TIA: Ctrl+Shift+Y).
    func commentSelection() {
        textView?.transformSelectedLines { "// " + $0 }
    }

    /// Removes a leading "//" from the selected lines (TIA: Ctrl+Shift+U).
    func uncommentSelection() {
        textView?.transformSelectedLines { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix("//") else { return line }
            let indent = line.prefix(line.count - trimmed.count)
            var rest = trimmed.dropFirst(2)
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            return String(indent) + String(rest)
        }
    }

    /// Inserts text at the insertion point, replacing the selection.
    func insert(_ snippet: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(snippet, replacementRange: textView.selectedRange())
    }
}

/// A source editor for SCL / ST: monospaced, syntax-coloured, with line
/// numbers, error underlines and an optional monitor column that shows live
/// values next to each line while the program runs.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var highlight: (String) -> [HighlightSpan]
    var diagnostics: [EditorDiagnostic] = []
    /// Per 1-based line; nil hides the monitor column.
    var monitor: [Int: [MonitorEntry]]?
    /// Lines that ran in the last monitored cycle; others show dimmed.
    var executedLines: Set<Int>?
    var isEditable = true
    var controller: CodeEditorController?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CodeEditorContainer {
        let container = CodeEditorContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.string = text
        controller?.textView = textView
        context.coordinator.container = container
        context.coordinator.refresh(textChanged: true)
        return container
    }

    func updateNSView(_ container: CodeEditorContainer, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        controller?.textView = container.textView
        container.textView.isEditable = isEditable
        let textChanged = container.textView.string != text
        if textChanged {
            let selection = container.textView.selectedRange()
            container.textView.string = text
            let length = (text as NSString).length
            container.textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        if textChanged || previous.diagnostics != diagnostics {
            coordinator.refresh(textChanged: textChanged)
        }
        container.monitorColumn.update(entries: monitor, executedLines: executedLines)
        container.setMonitorVisible(monitor != nil)
        container.ruler.errorLines = Dictionary(diagnostics.map { ($0.line, $0.isError) }, uniquingKeysWith: { $0 || $1 })
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var container: CodeEditorContainer?

        init(parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = container?.textView else { return }
            parent.text = textView.string
            refresh(textChanged: true)
        }

        /// Re-colours the text and re-marks diagnostics.
        func refresh(textChanged: Bool) {
            guard let container, let storage = container.textView.textStorage else { return }
            let text = container.textView.string
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: container.textView.baseFont, .foregroundColor: NSColor.textColor], range: full)
            for span in parent.highlight(text) where NSMaxRange(span.range) <= storage.length {
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: span.color]
                if span.isBold {
                    attributes[.font] = container.textView.boldFont
                }
                storage.addAttributes(attributes, range: span.range)
            }
            let nsText = text as NSString
            for diagnostic in parent.diagnostics {
                guard let range = Self.range(of: diagnostic, in: nsText) else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: diagnostic.isError ? NSColor.systemRed : NSColor.systemOrange,
                    .toolTip: diagnostic.message,
                ], range: range)
            }
            storage.endEditing()
            container.textView.typingAttributes = [.font: container.textView.baseFont, .foregroundColor: NSColor.textColor]
            container.ruler.needsDisplay = true
            container.monitorColumn.needsDisplay = true
        }

        private static func range(of diagnostic: EditorDiagnostic, in text: NSString) -> NSRange? {
            guard diagnostic.line >= 1 else { return nil }
            var location = 0
            var line = 1
            while line < diagnostic.line {
                guard location < text.length else { return nil }
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                line += 1
            }
            guard location <= text.length else { return nil }
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location, [0x0A, 0x0D].contains(text.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            let start = min(lineRange.location + max(0, diagnostic.column - 1), contentEnd)
            var end = diagnostic.length > 0 ? min(start + diagnostic.length, contentEnd) : contentEnd
            if end <= start {
                // Nothing to underline at the end of a line: mark the last character.
                guard start > lineRange.location else { return nil }
                return NSRange(location: start - 1, length: 1)
            }
            end = max(end, start + 1)
            return NSRange(location: start, length: end - start)
        }
    }
}

/// The editor's AppKit view: text with a line-number ruler, and the monitor column.
final class CodeEditorContainer: NSView {
    let scrollView = NSScrollView()
    // An explicit TextKit 1 stack: the ruler and monitor column read line
    // positions from the layout manager.
    let textView: EditorTextView = {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        return EditorTextView(frame: .zero, textContainer: container)
    }()
    let monitorColumn = MonitorColumnView()
    private(set) var ruler: LineNumberRuler!
    private var monitorWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scrollView.documentView = textView

        ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        monitorColumn.textView = textView
        for view in [scrollView, monitorColumn] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        monitorWidth = monitorColumn.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            monitorColumn.leadingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            monitorColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            monitorColumn.topAnchor.constraint(equalTo: topAnchor),
            monitorColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            monitorWidth,
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setMonitorVisible(_ visible: Bool) {
        let width: CGFloat = visible ? 260 : 0
        if monitorWidth.constant != width {
            monitorWidth.constant = width
            monitorColumn.isHidden = !visible
        }
    }

    @objc private func scrolled() {
        monitorColumn.needsDisplay = true
    }
}

/// The text view: tab inserts four spaces, Return keeps the indentation.
final class EditorTextView: NSTextView {
    let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        font = baseFont
        isRichText = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
    }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    /// Applies `transform` to every line the selection touches, as one undo step.
    func transformSelectedLines(_ transform: (String) -> String) {
        let text = string as NSString
        let lineRange = text.lineRange(for: selectedRange())
        let block = text.substring(with: lineRange)
        var lines = block.components(separatedBy: "\n")
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        var replacement = lines.map(transform).joined(separator: "\n")
        if endsWithNewline { replacement += "\n" }
        guard shouldChangeText(in: lineRange, replacementString: replacement) else { return }
        replaceCharacters(in: lineRange, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }
}

/// Line numbers down the left, with a red bar on lines that have errors.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var errorLines: [Int: Bool] = [:] {
        didSet {
            if oldValue != errorLines { needsDisplay = true }
        }
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        var line = 1
        var scan = 0
        while scan < characters.location {
            scan = NSMaxRange(text.lineRange(for: NSRange(location: scan, length: 0)))
            if scan <= characters.location { line += 1 }
        }

        func draw(_ number: Int, lineRect: NSRect) {
            let origin = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y), from: textView)
            if let isError = errorLines[number] {
                (isError ? NSColor.systemRed : NSColor.systemOrange).setFill()
                NSRect(x: 0, y: origin.y, width: 3, height: lineRect.height).fill()
            }
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: origin.y + (lineRect.height - size.height) / 2), withAttributes: attributes)
        }

        var index = characters.location
        while index < NSMaxRange(characters) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            draw(line, lineRect: layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil))
            index = NSMaxRange(lineRange)
            line += 1
        }
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, text.length == 0 || text.hasSuffix("\n") {
            draw(line, lineRect: extra)
        }
    }
}

/// The monitor column to the right of the code (like TIA Portal's SCL
/// monitoring table): each line's operands and their current values.
final class MonitorColumnView: NSView {
    weak var textView: NSTextView?
    private var entries: [Int: [MonitorEntry]] = [:]
    private var executedLines: Set<Int>?

    override var isFlipped: Bool { true }

    func update(entries newEntries: [Int: [MonitorEntry]]?, executedLines newExecuted: Set<Int>?) {
        let entries = newEntries ?? [:]
        if entries != self.entries || newExecuted != executedLines {
            self.entries = entries
            executedLines = newExecuted
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        guard !entries.isEmpty, let textView, let layoutManager = textView.layoutManager else { return }
        let text = textView.string as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        var location = 0
        var line = 1
        let lastLine = entries.keys.max() ?? 0
        while line <= lastLine, location <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            if let lineEntries = entries[line], !lineEntries.isEmpty {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(lineRange.location, max(0, text.length - 1)))
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let origin = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y), from: textView)
                if origin.y + lineRect.height >= dirtyRect.minY, origin.y <= dirtyRect.maxY {
                    let ran = executedLines?.contains(line) ?? true
                    drawEntries(lineEntries, at: NSPoint(x: 8, y: origin.y), height: lineRect.height, font: font, dimmed: !ran)
                }
            }
            if NSMaxRange(lineRange) == location { break }
            location = NSMaxRange(lineRange)
            line += 1
        }
    }

    private func drawEntries(_ lineEntries: [MonitorEntry], at origin: NSPoint, height: CGFloat, font: NSFont, dimmed: Bool) {
        var x = origin.x
        for entry in lineEntries {
            let nameAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor]
            let name = entry.operand as NSString
            let nameSize = name.size(withAttributes: nameAttributes)
            name.draw(at: NSPoint(x: x, y: origin.y + (height - nameSize.height) / 2), withAttributes: nameAttributes)
            x += nameSize.width + 4

            let (fill, textColor) = colors(for: entry, dimmed: dimmed)
            let valueAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let value = entry.value as NSString
            let valueSize = value.size(withAttributes: valueAttributes)
            let box = NSRect(x: x, y: origin.y + 1, width: valueSize.width + 8, height: max(0, height - 2))
            fill.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            value.draw(at: NSPoint(x: box.minX + 4, y: origin.y + (height - valueSize.height) / 2), withAttributes: valueAttributes)
            x = box.maxX + 10
            if x > bounds.width - 20 { break }
        }
    }

    private func colors(for entry: MonitorEntry, dimmed: Bool) -> (NSColor, NSColor) {
        if dimmed {
            return (NSColor.quaternaryLabelColor, NSColor.secondaryLabelColor)
        }
        switch entry.style {
        case .siemens:
            return (NSColor.gray.withAlphaComponent(0.25), NSColor.labelColor)
        case .melsec:
            switch entry.boolValue {
            case .some(true): return (NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.9, alpha: 1), .white)
            case .some(false): return (NSColor.black, .white)
            case .none: return (NSColor(calibratedRed: 1, green: 0.93, blue: 0.4, alpha: 1), .black)
            }
        }
    }
}
