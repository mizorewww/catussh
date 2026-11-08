import CatusshDesign
import SwiftUI

/// Where the caret is, for a status line.
public struct EditorCaret: Equatable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

#if os(iOS)
import Runestone
import TreeSitterBashRunestone
import TreeSitterCPPRunestone
import TreeSitterCRunestone
import TreeSitterCSSRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterLuaRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPerlRunestone
import TreeSitterPHPRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone
import UIKit

extension EditorLanguage {
    var treeSitter: TreeSitterLanguage? {
        switch self {
        case .plain: return nil
        case .bash: return .bash
        case .c: return .c
        case .cpp: return .cpp
        case .css: return .css
        case .go: return .go
        case .html: return .html
        case .java: return .java
        case .javaScript: return .javaScript
        case .json: return .json
        case .lua: return .lua
        case .markdown: return .markdown
        case .perl: return .perl
        case .php: return .php
        case .python: return .python
        case .ruby: return .ruby
        case .rust: return .rust
        case .sql: return .sql
        case .swift: return .swift
        case .toml: return .toml
        case .typeScript: return .typeScript
        case .yaml: return .yaml
        }
    }
}

public struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    let language: EditorLanguage
    let wrapsLines: Bool
    let fontSize: CGFloat
    let onCaretChange: (EditorCaret) -> Void

    public init(
        text: Binding<String>,
        language: EditorLanguage,
        wrapsLines: Bool = false,
        fontSize: CGFloat = 13,
        onCaretChange: @escaping (EditorCaret) -> Void = { _ in }
    ) {
        _text = text
        self.language = language
        self.wrapsLines = wrapsLines
        self.fontSize = fontSize
        self.onCaretChange = onCaretChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.backgroundColor = .clear
        view.editorDelegate = context.coordinator
        view.showLineNumbers = true
        view.lineSelectionDisplayType = .line
        view.gutterLeadingPadding = 12
        view.gutterTrailingPadding = 8
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        view.lineHeightMultiplier = 1.2
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.characterPairs = [Pair("(", ")"), Pair("[", "]"), Pair("{", "}"), Pair("\"", "\""), Pair("'", "'")]
        view.isFindInteractionEnabled = true
        view.verticalOverscrollFactor = 0.4
        view.isLineWrappingEnabled = wrapsLines
        switch EditorIndentation.detect(in: text) {
        case .tabs: view.indentStrategy = .tab(length: 4)
        case let .spaces(width): view.indentStrategy = .space(length: width)
        }
        context.coordinator.load(text, into: view)
        return view
    }

    public func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        if view.isLineWrappingEnabled != wrapsLines { view.isLineWrappingEnabled = wrapsLines }
        if text != context.coordinator.lastText || fontSize != context.coordinator.lastFontSize {
            context.coordinator.load(text, into: view)
        } else if language != context.coordinator.lastLanguage {
            context.coordinator.lastLanguage = language
            if context.coordinator.inFlightLoads == 0 {
                view.setLanguageMode(language.treeSitter.map { TreeSitterLanguageMode(language: $0) } ?? PlainTextLanguageMode())
            }
        }
    }

    public final class Coordinator: NSObject, TextViewDelegate {
        var parent: CodeEditor
        var lastText = ""
        var lastLanguage = EditorLanguage.plain
        var lastFontSize: CGFloat = 13
        private var loads = 0
        private(set) var inFlightLoads = 0

        init(_ parent: CodeEditor) {
            self.parent = parent
            lastFontSize = parent.fontSize
        }

        func load(_ text: String, into view: TextView) {
            lastText = text
            lastLanguage = parent.language
            lastFontSize = parent.fontSize
            let theme = EditorTheme(size: parent.fontSize)
            let loaded = parent.language
            let language = loaded.treeSitter
            nonisolated(unsafe) let weakView = WeakBox(view)
            view.isEditable = false
            loads += 1
            inFlightLoads += 1
            let load = loads
            DispatchQueue.global(qos: .userInitiated).async {
                let state: TextViewState = language.map { TextViewState(text: text, theme: theme, language: $0) }
                    ?? TextViewState(text: text, theme: theme)
                nonisolated(unsafe) let ready = state
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.inFlightLoads = max(0, self.inFlightLoads - 1)
                    guard self.loads == load, let view = weakView.value else { return }
                    view.setState(ready)
                    view.isEditable = true
                    if self.lastLanguage != loaded {
                        view.setLanguageMode(self.lastLanguage.treeSitter.map { TreeSitterLanguageMode(language: $0) } ?? PlainTextLanguageMode())
                    }
                }
            }
        }

        public func textViewDidChange(_ textView: TextView) {
            lastText = textView.text
            parent.text = textView.text
        }

        public func textViewDidChangeSelection(_ textView: TextView) {
            if let location = textView.textLocation(at: textView.selectedRange.location) {
                parent.onCaretChange(EditorCaret(line: location.lineNumber + 1, column: location.column + 1))
            }
        }
    }
}

private struct Pair: CharacterPair {
    let leading: String
    let trailing: String
    init(_ leading: String, _ trailing: String) {
        self.leading = leading
        self.trailing = trailing
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

#elseif os(macOS)
import AppKit

/// Native AppKit code editor with line numbers gutter, language-aware syntax highlighting,
/// line wrapping toggle, find bar (⌘F), and live caret line/column tracking.
public struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: EditorLanguage
    let wrapsLines: Bool
    let fontSize: CGFloat
    let onCaretChange: (EditorCaret) -> Void

    public init(
        text: Binding<String>,
        language: EditorLanguage,
        wrapsLines: Bool = false,
        fontSize: CGFloat = 13,
        onCaretChange: @escaping (EditorCaret) -> Void = { _ in }
    ) {
        _text = text
        self.language = language
        self.wrapsLines = wrapsLines
        self.fontSize = fontSize
        self.onCaretChange = onCaretChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor(Color.rxInk)
        textView.insertionPointColor = NSColor(Color.rxAccent)

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : [.width, .height]
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = wrapsLines

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView, fontSize: fontSize)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.rulerView = ruler
        context.coordinator.applyContent(text, language: language, fontSize: fontSize, to: textView)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if scrollView.hasHorizontalScroller == wrapsLines {
            scrollView.hasHorizontalScroller = !wrapsLines
            textView.isHorizontallyResizable = !wrapsLines
            textView.textContainer?.widthTracksTextView = wrapsLines
            textView.textContainer?.containerSize = NSSize(
                width: wrapsLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        if text != context.coordinator.lastText
            || language != context.coordinator.lastLanguage
            || fontSize != context.coordinator.lastFontSize
        {
            context.coordinator.applyContent(text, language: language, fontSize: fontSize, to: textView)
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        var lastText = ""
        var lastLanguage: EditorLanguage = .plain
        var lastFontSize: CGFloat = 13
        private var isUpdating = false

        init(_ parent: CodeEditor) {
            self.parent = parent
            lastFontSize = parent.fontSize
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusFindBar),
                name: Notification.Name("me.mizorewww.rayon.focusEditorFind"),
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func focusFindBar() {
            guard let textView, textView.window?.isKeyWindow == true else { return }
            let item = NSMenuItem()
            item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            textView.performFindPanelAction(item)
        }

        func applyContent(_ newText: String, language: EditorLanguage, fontSize: CGFloat, to textView: NSTextView) {
            isUpdating = true
            defer { isUpdating = false }
            let selectedRanges = textView.selectedRanges
            if textView.string != newText {
                textView.string = newText
            }
            lastText = newText
            lastLanguage = language
            lastFontSize = fontSize
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.font = font
            rulerView?.fontSize = fontSize
            highlight(textView: textView, language: language, font: font)
            if let first = selectedRanges.first?.rangeValue, first.location + first.length <= (newText as NSString).length {
                textView.selectedRanges = selectedRanges
            }
            rulerView?.needsDisplay = true
        }

        public func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            let current = textView.string
            lastText = current
            parent.text = current
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            highlight(textView: textView, language: parent.language, font: font)
            rulerView?.needsDisplay = true
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            let nsString = textView.string as NSString
            let clamped = min(max(0, location), nsString.length)
            let prefix = nsString.substring(to: clamped)
            var line = 1
            var lastNewlineIndex = 0
            for (idx, ch) in prefix.utf16.enumerated() where ch == 0x0A {
                line += 1
                lastNewlineIndex = idx + 1
            }
            let column = max(1, prefix.utf16.count - lastNewlineIndex + 1)
            parent.onCaretChange(EditorCaret(line: line, column: column))
            rulerView?.needsDisplay = true
        }

        private func highlight(textView: NSTextView, language: EditorLanguage, font: NSFont) {
            guard let storage = textView.textStorage else { return }
            let fullText = textView.string
            let nsLen = (fullText as NSString).length
            guard nsLen > 0, nsLen <= 512 * 1024 else { return }
            let fullRange = NSRange(location: 0, length: nsLen)

            storage.beginEditing()
            storage.setAttributes([
                .font: font,
                .foregroundColor: NSColor(Color.rxInk),
            ], range: fullRange)

            if language != .plain {
                MacSyntaxHighlighter.apply(to: storage, text: fullText, language: language)
            }
            storage.endEditing()
        }
    }
}

/// Draws line numbers in the left gutter of the code editor.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var fontSize: CGFloat {
        didSet {
            if fontSize != oldValue { needsDisplay = true }
        }
    }

    init(textView: NSTextView, fontSize: CGFloat) {
        self.textView = textView
        self.fontSize = fontSize
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func boundsDidChange(_: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in _: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        let visibleRect = textView.visibleRect
        let nsString = textView.string as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, fontSize * 0.85), weight: .regular)
        let color = NSColor(Color.rxInkTertiary)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Count lines before charRange.location
        var lineNumber = 1
        if charRange.location > 0 {
            let prefix = nsString.substring(to: charRange.location)
            for ch in prefix.utf16 where ch == 0x0A {
                lineNumber += 1
            }
        }

        var index = charRange.location
        let end = NSMaxRange(charRange)
        let insetY = textView.textContainerInset.height

        while index <= end {
            let lineRange = nsString.lineRange(for: NSRange(location: min(index, nsString.length), length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var lineRect: NSRect
            if glyphIndex < layoutManager.numberOfGlyphs {
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            } else {
                lineRect = layoutManager.extraLineFragmentRect
            }
            if lineRect.height == 0 {
                lineRect = NSRect(x: 0, y: 0, width: bounds.width, height: fontSize * 1.3)
            }
            let y = lineRect.minY + insetY - visibleRect.minY
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let drawPoint = NSPoint(
                x: ruleThickness - size.width - 8,
                y: y + (lineRect.height - size.height) / 2
            )
            label.draw(at: drawPoint, withAttributes: attributes)

            lineNumber += 1
            let nextIndex = NSMaxRange(lineRange)
            if nextIndex <= index { break }
            index = nextIndex
            if index == nsString.length { break }
        }
    }
}

private enum MacSyntaxHighlighter {
    private static let keywordColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.99, green: 0.37, blue: 0.64, alpha: 1)
            : NSColor(srgbRed: 0.61, green: 0.14, blue: 0.58, alpha: 1)
    }

    private static let stringColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.99, green: 0.42, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.77, green: 0.10, blue: 0.09, alpha: 1)
    }

    private static let keyColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.62, green: 0.95, blue: 0.87, alpha: 1)
            : NSColor(srgbRed: 0.24, green: 0.50, blue: 0.53, alpha: 1)
    }

    private static let numberColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.82, green: 0.75, blue: 0.41, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.00, blue: 0.81, alpha: 1)
    }

    private static let commentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.50, green: 0.55, blue: 0.60, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.42, blue: 0.47, alpha: 1)
    }

    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)
    private static let keywordRegex = try! NSRegularExpression(pattern: #"\b(?:if|then|else|elif|fi|for|while|do|done|case|esac|function|return|in|export|local|sudo|set|unset|true|false|null|nil|let|var|func|struct|class|enum|import|from|def|async|await|try|catch|throw|pub|fn|impl|use|mod|package|interface|type|const)\b"#)
    private static let jsonKeyRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"(?=\s*:)"#)

    /// Combined token regex that matches strings and comments in a single pass so `//` or `#` inside a string literal is never mistaken for a comment!
    private static func tokenRegex(for language: EditorLanguage) -> NSRegularExpression? {
        switch language {
        case .json:
            return try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*")"#)
        case .bash, .python, .ruby, .perl, .yaml, .toml:
            return try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|((?m)#.*$)"#)
        case .lua:
            return try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|((?m)--.*$)"#)
        case .sql:
            return try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|((?m)--.*$)"#)
        case .html, .markdown:
            return try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(<!--[\s\S]*?-->)"#)
        default:
            return try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|((?m)//.*$|/\*[\s\S]*?\*/)"#)
        }
    }

    static func apply(to storage: NSTextStorage, text: String, language: EditorLanguage) {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        numberRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let range = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: numberColor, range: range)
        }

        if language != .json {
            keywordRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: keywordColor, range: range)
            }
        }

        if let tokenRx = tokenRegex(for: language) {
            tokenRx.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: stringColor, range: match.range(at: 1))
                } else if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                    storage.addAttribute(.foregroundColor, value: commentColor, range: match.range(at: 2))
                }
            }
        }

        if language == .json {
            jsonKeyRegex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                storage.addAttribute(.foregroundColor, value: keyColor, range: range)
            }
        }
    }
}
#endif
