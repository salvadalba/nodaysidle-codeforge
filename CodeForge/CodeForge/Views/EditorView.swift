import AppKit
import SwiftTreeSitter
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
        let gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
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

        guard let textStorage = textView.textStorage else { return }

        textStorage.beginEditing()

        for range in model.highlightRanges {
            // Convert byte offsets to String.Index
            guard let startIndex = utf8.index(utf8.startIndex, offsetBy: range.startByte, limitedBy: utf8.endIndex),
                  let endIndex = utf8.index(utf8.startIndex, offsetBy: range.endByte, limitedBy: utf8.endIndex) else {
                continue
            }

            let startUTF16 = String(decoding: utf8[utf8.startIndex..<startIndex], as: UTF8.self).utf16.count
            let length = String(decoding: utf8[startIndex..<endIndex], as: UTF8.self).utf16.count
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
        /// Whether any tree edits were applied since last re-parse.
        private var hasTreeEdits = false

        init(model: EditorModel, parsingActor: ParsingActor) {
            self.model = model
            self.parsingActor = parsingActor
        }

        // MARK: - NSTextViewDelegate

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isUpdatingFromSwiftUI else { return true }
            guard let replacementString else { return true }

            // Compute byte offsets and apply edit to the tree immediately
            let source = textView.string
            let utf16 = source.utf16

            guard let rangeStart = utf16.index(
                utf16.startIndex,
                offsetBy: affectedCharRange.location,
                limitedBy: utf16.endIndex
            ) else { return true }

            guard let rangeEnd = utf16.index(
                rangeStart,
                offsetBy: affectedCharRange.length,
                limitedBy: utf16.endIndex
            ) else { return true }

            let startByte = UInt32(source.utf8.distance(from: source.utf8.startIndex, to: rangeStart))
            let oldEndByte = UInt32(source.utf8.distance(from: source.utf8.startIndex, to: rangeEnd))
            let newEndByte = startByte + UInt32(replacementString.utf8.count)

            let startPoint = computePoint(at: rangeStart, in: source)
            let oldEndPoint = computePoint(at: rangeEnd, in: source)
            let newEndPoint = computeNewEndPoint(from: startPoint, replacement: replacementString)

            let actor = parsingActor
            hasTreeEdits = true
            Task {
                await actor.applyEdit(
                    startByte: startByte,
                    oldEndByte: oldEndByte,
                    newEndByte: newEndByte,
                    startPoint: startPoint,
                    oldEndPoint: oldEndPoint,
                    newEndPoint: newEndPoint
                )
            }

            return true
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

            // Trigger debounced re-parse (incremental if tree edits were applied)
            scheduleReparse(source: textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            model.selection = textView.selectedRange()
            model.cursorPosition = textView.selectedRange().location
            gutter?.needsDisplay = true
        }

        // MARK: - Parsing

        private func scheduleReparse(source: String) {
            parseTask?.cancel()
            model.isParsing = true
            let actor = parsingActor
            let incremental = hasTreeEdits
            hasTreeEdits = false
            parseTask = Task {
                // 50ms debounce to coalesce rapid keystrokes
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                if incremental {
                    await actor.reParse(source: source)
                } else {
                    await actor.fullParse(source: source)
                }
            }
        }

        // MARK: - Point Computation

        /// Compute TreeSitter Point (row, column-in-bytes) at a String.Index.
        private nonisolated func computePoint(at index: String.Index, in string: String) -> Point {
            let utf8 = string.utf8
            var row: UInt32 = 0
            var col: UInt32 = 0
            for byte in utf8[utf8.startIndex..<index] {
                if byte == UInt8(ascii: "\n") {
                    row += 1
                    col = 0
                } else {
                    col += 1
                }
            }
            return Point(row: row, column: col)
        }

        /// Compute end point after inserting replacement text at startPoint.
        private nonisolated func computeNewEndPoint(from startPoint: Point, replacement: String) -> Point {
            var row = startPoint.row
            var col = startPoint.column
            for byte in replacement.utf8 {
                if byte == UInt8(ascii: "\n") {
                    row += 1
                    col = 0
                } else {
                    col += 1
                }
            }
            return Point(row: row, column: col)
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
