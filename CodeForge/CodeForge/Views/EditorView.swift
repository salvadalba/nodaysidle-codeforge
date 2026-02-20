import AppKit
import SwiftUI

/// NSViewRepresentable wrapping an NSTextView (TextKit 1) for code editing.
///
/// Uses a Coordinator to relay text changes back to EditorModel without
/// creating infinite update loops. Supports monospace font, no line wrap,
/// coalesced undo grouping, and syntax highlight application.
/// Triggers debounced re-parses on text changes via ParsingActor.
struct EditorView: NSViewRepresentable {
    @Bindable var model: EditorModel
    let parsingActor: ParsingActor

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = CodeTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Monospace font
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor(white: 0.85, alpha: 1.0),
        ]

        // No line wrap — horizontal scrolling instead
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        // Dark editor background
        textView.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        textView.insertionPointColor = NSColor.white
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(white: 0.3, alpha: 0.5)
        ]

        scrollView.documentView = textView

        // Line number gutter
        let gutter = LineNumberGutter(textView: textView)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // Coordinator setup
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.gutter = gutter

        // Set initial content
        if !model.content.isEmpty {
            textView.string = model.content
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        let coordinator = context.coordinator

        // Update content if changed externally (e.g. file open)
        if coordinator.isUpdatingModel { return }

        if textView.string != model.content {
            coordinator.isUpdatingFromSwiftUI = true
            let selectedRange = textView.selectedRange()
            textView.string = model.content
            textView.setSelectedRange(selectedRange)
            coordinator.isUpdatingFromSwiftUI = false
        }

        // Apply syntax highlights
        applyHighlights(to: textView, coordinator: coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, parsingActor: parsingActor)
    }

    // MARK: - Highlight Application

    private func applyHighlights(to textView: NSTextView, coordinator: Coordinator) {
        guard !model.highlightRanges.isEmpty else { return }
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let source = textView.string
        let utf8 = source.utf8

        // Only highlight visible range + 100-line buffer
        let visibleRect = textView.enclosingScrollView?.documentVisibleRect ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Expand by ~100 lines
        let bufferSize = 100
        let startLine = max(0, lineNumber(for: visibleCharRange.location, in: source) - bufferSize)
        let endLine = lineNumber(for: NSMaxRange(visibleCharRange), in: source) + bufferSize
        let bufferedStart = characterOffset(forLine: startLine, in: source)
        let bufferedEnd = characterOffset(forLine: endLine, in: source)

        let textStorage = textView.textStorage!

        textStorage.beginEditing()

        for range in model.highlightRanges {
            // Convert byte offsets to String.Index
            guard let startIndex = utf8.index(utf8.startIndex, offsetBy: range.startByte, limitedBy: utf8.endIndex),
                  let endIndex = utf8.index(utf8.startIndex, offsetBy: range.endByte, limitedBy: utf8.endIndex) else {
                continue
            }

            let startUTF16 = String(utf8[utf8.startIndex..<startIndex])!.utf16.count
            let length = String(utf8[startIndex..<endIndex])!.utf16.count
            let nsRange = NSRange(location: startUTF16, length: length)

            // Skip ranges outside our buffer
            if NSMaxRange(nsRange) < bufferedStart || nsRange.location > bufferedEnd {
                continue
            }

            // Clamp to text storage bounds
            let clampedRange = NSIntersectionRange(
                nsRange,
                NSRange(location: 0, length: textStorage.length)
            )
            guard clampedRange.length > 0 else { continue }

            textStorage.addAttribute(
                .foregroundColor,
                value: range.tokenType.nsColor,
                range: clampedRange
            )
        }

        textStorage.endEditing()
    }

    private func lineNumber(for characterIndex: Int, in string: String) -> Int {
        let target = string.utf16.index(string.utf16.startIndex, offsetBy: min(characterIndex, string.utf16.count))
        return string[string.startIndex..<target].filter { $0 == "\n" }.count
    }

    private func characterOffset(forLine line: Int, in string: String) -> Int {
        var currentLine = 0
        for (i, char) in string.utf16.enumerated() {
            if currentLine >= line { return i }
            if char == 0x0A { currentLine += 1 } // \n
        }
        return string.utf16.count
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: EditorModel
        let parsingActor: ParsingActor
        weak var textView: CodeTextView?
        weak var gutter: LineNumberGutter?

        /// Guard to prevent SwiftUI -> NSTextView -> EditorModel feedback loops.
        var isUpdatingFromSwiftUI = false
        /// Guard to prevent EditorModel -> NSTextView -> SwiftUI feedback loops.
        var isUpdatingModel = false

        private var undoCoalescingTimer: Timer?
        private static let undoCoalescingInterval: TimeInterval = 0.3

        private var parseTask: Task<Void, Never>?

        init(model: EditorModel, parsingActor: ParsingActor) {
            self.model = model
            self.parsingActor = parsingActor
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI else { return }
            guard let textView else { return }

            isUpdatingModel = true
            model.content = textView.string
            model.isDirty = true
            isUpdatingModel = false

            // Coalesce undo groups for rapid typing
            coalesceUndoGroup(for: textView)

            // Update gutter
            gutter?.needsDisplay = true

            // Trigger debounced re-parse
            scheduleReparse(source: textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            model.selection = textView.selectedRange()
            model.cursorPosition = textView.selectedRange().location
            gutter?.needsDisplay = true
        }

        private func scheduleReparse(source: String) {
            parseTask?.cancel()
            model.isParsing = true
            let actor = parsingActor
            parseTask = Task {
                // 50ms debounce to coalesce rapid keystrokes
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await actor.fullParse(source: source)
            }
        }

        private func coalesceUndoGroup(for textView: NSTextView) {
            undoCoalescingTimer?.invalidate()
            undoCoalescingTimer = Timer.scheduledTimer(
                withTimeInterval: Self.undoCoalescingInterval,
                repeats: false
            ) { [weak textView] _ in
                textView?.breakUndoCoalescing()
            }
        }
    }
}

/// Subclass of NSTextView for customization hooks.
final class CodeTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    /// Break undo coalescing to start a new undo group.
    override func breakUndoCoalescing() {
        super.breakUndoCoalescing()
    }
}
