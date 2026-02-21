import AppKit
import Foundation

/// NSRulerView that draws line numbers for an NSTextView.
///
/// Attaches to the scroll view's vertical ruler position.
/// Auto-adjusts width for digit count and highlights the current line.
final class LineNumberGutter: NSRulerView {
    private weak var textView: NSTextView?

    // UI brightness fix: warmer gutter with more contrast
    private let gutterBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)
    private let gutterBorderColor = NSColor(white: 0.22, alpha: 1.0)
    private let lineNumberColor = NSColor(white: 0.48, alpha: 1.0)
    private let currentLineNumberColor = NSColor(white: 0.92, alpha: 1.0)
    private let currentLineHighlightColor = NSColor(white: 1.0, alpha: 0.08)
    private let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let padding: CGFloat = 8.0

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(
            scrollView: scrollView,
            orientation: .verticalRuler
        )
        self.clientView = textView
        self.ruleThickness = 44 // default width, adjusted dynamically

        // Observe text changes to redraw
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func textDidChange(_ notification: Notification) {
        needsDisplay = true
        adjustWidth()
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    /// Adjust gutter width based on the number of digits needed.
    private func adjustWidth() {
        guard let textView else { return }
        let lineCount = textView.string.components(separatedBy: .newlines).count
        let digits = max(3, String(lineCount).count)
        let sampleString = String(repeating: "8", count: digits) as NSString
        let size = sampleString.size(withAttributes: [.font: gutterFont])
        let newWidth = ceil(size.width) + padding * 2 + 4
        if abs(ruleThickness - newWidth) > 1 {
            ruleThickness = newWidth
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        // Fill background
        gutterBackgroundColor.setFill()
        rect.fill()

        // Draw right border for visual separation from editor
        gutterBorderColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: ruleThickness - 0.5, y: rect.minY))
        borderPath.line(to: NSPoint(x: ruleThickness - 0.5, y: rect.maxY))
        borderPath.lineWidth = 1.0
        borderPath.stroke()

        let content = textView.string as NSString
        let visibleRect = scrollView?.documentVisibleRect ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // L4 fix: guard against NSNotFound cursor location
        let rawCursorLocation = textView.selectedRange().location
        let cursorLocation = (rawCursorLocation == NSNotFound) ? 0 : rawCursorLocation
        let currentLine = lineIndex(for: cursorLocation, in: content as String)

        // Walk through visible lines
        let textContainerInset = textView.textContainerInset
        var lineNumber = lineIndex(for: charRange.location, in: content as String)

        var index = lineStart(for: charRange.location, in: content)
        while index <= NSMaxRange(charRange) && index < content.length {
            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            let yPosition = lineRect.origin.y + textContainerInset.height - visibleRect.origin.y
            lineNumber += 1

            // Highlight current line background
            if lineNumber - 1 == currentLine {
                currentLineHighlightColor.setFill()
                NSRect(x: 0, y: yPosition, width: ruleThickness, height: lineRect.height).fill()
            }

            // Draw line number
            let numberString = "\(lineNumber)" as NSString
            let color = (lineNumber - 1 == currentLine) ? currentLineNumberColor : lineNumberColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: gutterFont,
                .foregroundColor: color,
            ]
            let size = numberString.size(withAttributes: attributes)
            let x = ruleThickness - size.width - padding
            let y = yPosition + (lineRect.height - size.height) / 2.0
            numberString.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)

            index = NSMaxRange(lineRange)
        }
    }

    /// Returns 0-based line index for a character position.
    private func lineIndex(for charIndex: Int, in string: String) -> Int {
        let nsString = string as NSString
        let target = min(charIndex, nsString.length)
        var line = 0
        var pos = 0
        while pos < target {
            let range = nsString.lineRange(for: NSRange(location: pos, length: 0))
            line += 1
            pos = NSMaxRange(range)
        }
        return max(0, line)
    }

    /// Returns the start of the line containing the given character index.
    private func lineStart(for charIndex: Int, in nsString: NSString) -> Int {
        let range = nsString.lineRange(for: NSRange(location: min(charIndex, nsString.length), length: 0))
        return range.location
    }
}
