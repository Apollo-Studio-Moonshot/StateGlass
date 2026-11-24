import AppKit
import SwiftUI

enum SourceLanguage {
    static func id(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "py": return "python"
        case "swift": return "swift"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "rs": return "rust"
        case "json": return "json"
        case "toml", "yml", "yaml", "ini", "cfg", "sh", "zsh", "bash": return "config"
        case "md", "markdown": return "markdown"
        default: return "text"
        }
    }

    static func label(for language: String) -> String {
        switch language {
        case "python": return "Python"
        case "swift": return "Swift"
        case "javascript": return "JavaScript"
        case "typescript": return "TypeScript"
        case "rust": return "Rust"
        case "json": return "JSON"
        case "markdown": return "Markdown"
        case "config": return "Config"
        default: return "Plain Text"
        }
    }
}

/// Native code editor on TextKit 1.
///
/// TextKit 1 keeps `NSLayoutManager` line fragments, which the gutter and the
/// execution-line highlight both measure. Syntax color is applied as temporary
/// attributes so it never enters the undo stack.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: String
    var traceLine: Int?
    var revealToken: Int
    var onCursorChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = EditorTextView(usingTextLayoutManager: false)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 2
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [
            .font: EditorTextView.editorFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.font = EditorTextView.editorFont
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.isEditable = true
        textView.isSelectable = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = text
        textView.setAccessibilityLabel("Source code editor")
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.highlightedSnapshot = nil
            coordinator?.highlightIfNeeded()
        }

        scrollView.documentView = textView

        let ruler = LineNumberRuler(scrollView: scrollView)
        ruler.clientView = textView
        scrollView.hasVerticalRuler = true
        scrollView.hasHorizontalRuler = false
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.highlightIfNeeded()
        ruler.invalidateMetrics()

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        if textView.string != text {
            context.coordinator.replaceText(text)
        }
        context.coordinator.highlightIfNeeded()
        context.coordinator.fillViewport()
        if context.coordinator.appliedRevealToken != revealToken {
            context.coordinator.appliedRevealToken = revealToken
            if let traceLine {
                context.coordinator.reveal(traceLine)
            }
        }
        textView.traceLine = traceLine
        context.coordinator.ruler?.traceLine = traceLine
        context.coordinator.ruler?.needsDisplay = true
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        (scrollView.documentView as? NSTextView)?.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: EditorTextView?
        weak var ruler: LineNumberRuler?
        var suppressing = false
        var highlightedSnapshot: String?
        var highlightedLanguage: String?
        var appliedRevealToken = -1

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        @objc func boundsChanged(_ notification: Notification) {
            ruler?.needsDisplay = true
            fillViewport()
        }

        /// Keep the text view at least as tall as the viewport, so clicks below
        /// the last line still land in the editor. Show the gutter once the
        /// scroll view is in a window; AppKit ignores `rulersVisible` before that.
        func fillViewport() {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            if textView.window != nil {
                scrollView.rulersVisible = true
            }
            let height = scrollView.contentView.bounds.height
            guard height > 1, abs(textView.minSize.height - height) > 0.5 else { return }
            var minimum = textView.minSize
            minimum.height = height
            textView.minSize = minimum
        }

        func replaceText(_ text: String) {
            guard let textView else { return }
            suppressing = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            suppressing = false
            highlightedSnapshot = nil
            highlightIfNeeded()
            ruler?.invalidateMetrics()
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            reportCursor()
            if textView.window != nil {
                textView.window?.makeFirstResponder(textView)
            }
        }

        func highlightIfNeeded() {
            guard let textView, let layout = textView.layoutManager else { return }
            let language = parent.language
            if highlightedSnapshot == textView.string && highlightedLanguage == language { return }
            let length = (textView.string as NSString).length
            let full = NSRange(location: 0, length: length)
            if length > 0 {
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                for token in SyntaxHighlighter.tokens(in: textView.string, language: language) {
                    let range = token.range
                    guard range.length > 0, range.location >= 0, range.location + range.length <= length else { continue }
                    layout.addTemporaryAttribute(.foregroundColor, value: token.color, forCharacterRange: range)
                }
                layout.invalidateDisplay(forCharacterRange: full)
            }
            highlightedSnapshot = textView.string
            highlightedLanguage = language
        }

        func reveal(_ line: Int) {
            guard let textView, let container = textView.textContainer, line > 0 else { return }
            textView.layoutManager?.ensureLayout(for: container)
            let length = (textView.string as NSString).length
            let index = min(textView.characterIndex(ofLine: line), length)
            suppressing = true
            textView.setSelectedRange(NSRange(location: index, length: 0))
            suppressing = false
            if let rect = textView.lineFragmentRect(forLine: line) {
                let visible = textView.enclosingScrollView?.contentView.bounds.height ?? 400
                var target = rect
                target.origin.y = max(0, rect.midY - visible / 2)
                target.size.height = visible
                textView.scrollToVisible(target)
            } else {
                textView.scrollRangeToVisible(NSRange(location: index, length: 0))
            }
            reportCursor()
            ruler?.needsDisplay = true
            textView.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressing, let textView = notification.object as? EditorTextView else { return }
            highlightIfNeeded()
            parent.text = textView.string
            ruler?.invalidateMetrics()
            reportCursor()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !suppressing else { return }
            textView?.needsDisplay = true
            ruler?.needsDisplay = true
            reportCursor()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                changeIndent(outdent: false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                changeIndent(outdent: true)
                return true
            }
            return false
        }

        private func reportCursor() {
            guard let textView else { return }
            let position = textView.cursorPosition()
            parent.onCursorChange(position.line, position.column)
        }

        private func changeIndent(outdent: Bool) {
            guard let textView else { return }
            let ns = textView.string as NSString
            let selected = textView.selectedRange()
            if selected.length == 0 && !outdent {
                MainActor.assumeIsolated {
                    textView.insertText("    ", replacementRange: selected)
                }
                return
            }

            let block = ns.lineRange(for: selected)
            let blockText = ns.substring(with: block)
            let endsWithNewline = blockText.hasSuffix("\n")
            var lines = blockText.components(separatedBy: "\n")
            if endsWithNewline, lines.last?.isEmpty == true {
                lines.removeLast()
            }
            let updatedLines = lines.map { line -> String in
                if outdent {
                    return String(line.dropFirst(min(4, line.prefix { $0 == " " }.count)))
                }
                return "    " + line
            }
            let updated = updatedLines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
            guard updated != blockText else { return }
            MainActor.assumeIsolated {
                textView.insertText(updated, replacementRange: block)
            }
        }
    }
}

final class EditorTextView: NSTextView {
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutterFontActive = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

    var onAppearanceChange: (() -> Void)?
    var traceLine: Int? {
        didSet {
            if oldValue != traceLine { needsDisplay = true }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enclosingScrollView?.rulersVisible = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let caret = cursorPosition().line
        if let traceLine, traceLine > 0 {
            fillLine(traceLine, color: NSColor.systemYellow.withAlphaComponent(0.18), clip: rect)
            if let band = lineFragmentRect(forLine: traceLine), band.intersects(rect) {
                NSColor.systemOrange.setFill()
                NSRect(x: 0, y: band.minY, width: 2, height: band.height).fill()
            }
        }
        if traceLine != caret {
            fillLine(caret, color: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10), clip: rect)
        }
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    func cursorPosition() -> (line: Int, column: Int) {
        let ns = string as NSString
        let location = min(selectedRange().location, ns.length)
        var line = 1
        var lineStart = 0
        var index = 0
        while index < location {
            if ns.character(at: index) == 10 {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return (line, location - lineStart + 1)
    }

    func characterIndex(ofLine line: Int) -> Int {
        let ns = string as NSString
        if line <= 1 { return 0 }
        var current = 1
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 10 {
                current += 1
                if current == line { return min(index + 1, ns.length) }
            }
            index += 1
        }
        return ns.length
    }

    func lineFragmentRect(forLine line: Int) -> NSRect? {
        guard let layoutManager, let container = textContainer else { return nil }
        let ns = string as NSString
        if ns.length == 0 {
            let height = Self.editorFont.ascender - Self.editorFont.descender + Self.editorFont.leading
            return NSRect(x: 0, y: textContainerOrigin.y, width: bounds.width, height: max(16, height))
        }
        layoutManager.ensureLayout(for: container)
        let index = min(characterIndex(ofLine: line), ns.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyph,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        var rect = fragment
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(bounds.width, fragment.maxX + textContainerOrigin.x)
        return rect
    }

    private func fillLine(_ line: Int, color: NSColor, clip: NSRect) {
        guard let band = lineFragmentRect(forLine: line), band.intersects(clip) else { return }
        color.setFill()
        band.fill()
    }
}

final class LineNumberRuler: NSRulerView {
    var traceLine: Int?

    init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 46
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        clipsToBounds = true
    }

    required init(coder: NSCoder) {
        fatalError("LineNumberRuler is created in code")
    }

    func invalidateMetrics() {
        guard let textView = clientView as? NSTextView else {
            needsDisplay = true
            return
        }
        let ns = textView.string as NSString
        var lines = 1
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 10 { lines += 1 }
            index += 1
        }
        let digits = max(2, String(lines).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let font = EditorTextView.gutterFont
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 22
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
            scrollView?.tile()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let visible = scrollView?.contentView.bounds ?? rect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let font = EditorTextView.gutterFont
        let activeFont = EditorTextView.gutterFontActive
        let ns = textView.string as NSString
        let caret = (textView as? EditorTextView)?.cursorPosition().line ?? 1

        if ns.length == 0 || glyphRange.length == 0 {
            drawLabel("1", y: textView.textContainerOrigin.y - visible.minY, font: activeFont, color: .labelColor, paragraph: paragraph, height: 18)
            return
        }

        var glyphIndex = glyphRange.location
        var guardCount = 0
        while glyphIndex < NSMaxRange(glyphRange) && guardCount < 10_000 {
            guardCount += 1
            var range = NSRange()
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &range,
                withoutAdditionalLayout: true
            )
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let line = lineNumber(at: charIndex, in: ns)
            let highlighted = line == traceLine || line == caret
            let color: NSColor = line == traceLine ? .systemOrange : (line == caret ? .labelColor : .tertiaryLabelColor)
            let y = fragment.minY + textView.textContainerOrigin.y - visible.minY
            drawLabel(
                "\(line)",
                y: y,
                font: highlighted ? activeFont : font,
                color: color,
                paragraph: paragraph,
                height: fragment.height
            )
            let next = NSMaxRange(range)
            if next <= glyphIndex { break }
            glyphIndex = next
        }
    }

    private func drawLabel(_ text: String, y: CGFloat, font: NSFont, color: NSColor, paragraph: NSParagraphStyle, height: CGFloat) {
        let label = text as NSString
        let size = label.size(withAttributes: [.font: font])
        let rect = NSRect(x: 4, y: y + max(0, (height - size.height) / 2), width: bounds.width - 12, height: size.height)
        label.draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private func lineNumber(at location: Int, in text: NSString) -> Int {
        let end = min(max(0, location), text.length)
        var line = 1
        var index = 0
        while index < end {
            if text.character(at: index) == 10 { line += 1 }
            index += 1
        }
        return line
    }
}

enum SyntaxHighlighter {
    struct Token {
        let range: NSRange
        let color: NSColor
    }

    static func tokens(in text: String, language: String) -> [Token] {
        let ns = text as NSString
        if ns.length == 0 || ns.length > 400_000 { return [] }
        switch language {
        case "python": return scan(ns, kind: .python)
        case "swift": return scan(ns, kind: .swift)
        case "javascript", "typescript": return scan(ns, kind: .javascript)
        case "rust": return scan(ns, kind: .rust)
        case "json": return scan(ns, kind: .json)
        case "config": return scan(ns, kind: .config)
        default: return []
        }
    }

    private enum Kind {
        case python, swift, javascript, rust, json, config

        var keywords: Set<String> {
            switch self {
            case .python:
                return ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
            case .swift:
                return ["associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try", "async", "await"]
            case .javascript:
                return ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "null", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "yield", "of", "from"]
            case .rust:
                return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
            case .json:
                return ["true", "false", "null"]
            case .config:
                return []
            }
        }

        var declarations: Set<String> {
            switch self {
            case .python: return ["def", "class"]
            case .swift: return ["func", "class", "struct", "enum", "protocol"]
            case .javascript: return ["function", "class"]
            case .rust: return ["fn", "struct", "enum", "trait", "type"]
            case .json, .config: return []
            }
        }

        var builtins: Set<String> {
            switch self {
            case .python:
                return ["self", "cls", "print", "len", "range", "str", "int", "float", "list", "dict", "set", "tuple", "bool", "type", "isinstance", "open", "super", "enumerate", "zip", "map", "filter"]
            default:
                return []
            }
        }

        var hashComments: Bool {
            self == .python || self == .config
        }
    }

    private static let comment = NSColor.tertiaryLabelColor
    private static let string = NSColor.systemOrange
    private static let keyword = NSColor.systemBlue
    private static let number = NSColor.systemCyan
    private static let declaration = NSColor.systemPurple
    private static let builtin = NSColor.systemTeal
    private static let decorator = NSColor.systemPink
    private static let prefixes: Set<String> = ["r", "u", "b", "f", "fr", "rf", "rb", "br"]

    private static func scan(_ ns: NSString, kind: Kind) -> [Token] {
        let count = ns.length
        var tokens: [Token] = []
        tokens.reserveCapacity(min(count / 6, 8_000))
        var index = 0
        var expectName = false

        func character(_ offset: Int) -> unichar {
            ns.character(at: offset)
        }
        func isIdentStart(_ value: unichar) -> Bool {
            (value >= 65 && value <= 90) || (value >= 97 && value <= 122) || value == 95
        }
        func isIdent(_ value: unichar) -> Bool {
            isIdentStart(value) || (value >= 48 && value <= 57)
        }
        func consumeString(from start: Int, quote: unichar, triple: Bool) -> Int {
            var cursor = start + (triple ? 3 : 1)
            while cursor < count {
                let value = character(cursor)
                if value == 92 && cursor + 1 < count {
                    cursor += 2
                    continue
                }
                if triple {
                    if value == quote && cursor + 2 < count && character(cursor + 1) == quote && character(cursor + 2) == quote {
                        return cursor + 3
                    }
                } else if value == quote {
                    return cursor + 1
                } else if !triple && (value == 10 || value == 13) {
                    return cursor
                }
                cursor += 1
            }
            return cursor
        }

        while index < count {
            let value = character(index)
            if value == 10 || value == 13 {
                expectName = false
                index += 1
                continue
            }
            if value == 32 || value == 9 {
                index += 1
                continue
            }

            if kind.hashComments && value == 35 {
                let start = index
                while index < count && character(index) != 10 { index += 1 }
                tokens.append(Token(range: NSRange(location: start, length: index - start), color: comment))
                continue
            }
            if !kind.hashComments && kind != .json && value == 47 && index + 1 < count {
                let next = character(index + 1)
                if next == 47 {
                    let start = index
                    while index < count && character(index) != 10 { index += 1 }
                    tokens.append(Token(range: NSRange(location: start, length: index - start), color: comment))
                    continue
                }
                if next == 42 {
                    let start = index
                    index += 2
                    while index + 1 < count && !(character(index) == 42 && character(index + 1) == 47) {
                        index += 1
                    }
                    index = min(count, index + 2)
                    tokens.append(Token(range: NSRange(location: start, length: index - start), color: comment))
                    continue
                }
            }

            if value == 34 || value == 39 {
                if kind == .json && value == 39 {
                    index += 1
                    continue
                }
                let triple = (kind == .python || kind == .swift)
                    && index + 2 < count
                    && character(index + 1) == value
                    && character(index + 2) == value
                let start = index
                index = consumeString(from: index, quote: value, triple: triple)
                tokens.append(Token(range: NSRange(location: start, length: index - start), color: string))
                expectName = false
                continue
            }

            if value == 64 && (kind == .python || kind == .swift) {
                let start = index
                index += 1
                while index < count && isIdent(character(index)) { index += 1 }
                tokens.append(Token(range: NSRange(location: start, length: index - start), color: decorator))
                continue
            }

            let digit = value >= 48 && value <= 57
            let dotted = value == 46 && index + 1 < count && character(index + 1) >= 48 && character(index + 1) <= 57
            if digit || dotted {
                let start = index
                index += 1
                while index < count {
                    let next = character(index)
                    let hex = (next >= 65 && next <= 70) || (next >= 97 && next <= 102)
                    if (next >= 48 && next <= 57) || next == 46 || next == 95 || next == 120 || next == 88 || hex {
                        index += 1
                    } else {
                        break
                    }
                }
                tokens.append(Token(range: NSRange(location: start, length: index - start), color: number))
                expectName = false
                continue
            }

            if isIdentStart(value) {
                let start = index
                index += 1
                while index < count && isIdent(character(index)) { index += 1 }
                let word = ns.substring(with: NSRange(location: start, length: index - start))
                if kind == .python,
                   prefixes.contains(word.lowercased()),
                   index < count,
                   character(index) == 34 || character(index) == 39 {
                    let quote = character(index)
                    let triple = index + 2 < count && character(index + 1) == quote && character(index + 2) == quote
                    index = consumeString(from: index, quote: quote, triple: triple)
                    tokens.append(Token(range: NSRange(location: start, length: index - start), color: string))
                    expectName = false
                    continue
                }
                if expectName {
                    tokens.append(Token(range: NSRange(location: start, length: index - start), color: declaration))
                    expectName = false
                } else if kind.keywords.contains(word) {
                    tokens.append(Token(range: NSRange(location: start, length: index - start), color: keyword))
                    expectName = kind.declarations.contains(word)
                } else if kind.builtins.contains(word) {
                    tokens.append(Token(range: NSRange(location: start, length: index - start), color: builtin))
                    expectName = false
                } else {
                    expectName = false
                }
                continue
            }

            expectName = false
            index += 1
        }
        return tokens
    }
}
