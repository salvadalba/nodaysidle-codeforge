import AppKit
import Foundation

/// Observable model backing the terminal view.
///
/// Holds the virtual screen buffer, converts it to NSAttributedString
/// for rendering, and tracks terminal dimensions and run state.
/// C6 fix: @MainActor isolation replaces @unchecked Sendable.
@Observable
@MainActor
final class TerminalModel {
    /// The virtual screen buffer holding all terminal cells.
    var buffer: VirtualScreenBuffer

    /// Whether the terminal panel is visible.
    var isVisible: Bool = false

    /// Whether the shell subprocess is running.
    var isRunning: Bool = false

    /// Terminal title (from OSC sequences).
    var title: String = "Terminal"

    /// Current terminal dimensions.
    var cols: Int { buffer.cols }
    var rows: Int { buffer.rows }

    /// Whether the view should snap to the bottom on new output.
    var snapToBottom: Bool = true

    /// Scroll offset from the bottom (0 = at bottom).
    var scrollOffset: Int = 0

    init(cols: Int = 80, rows: Int = 24) {
        self.buffer = VirtualScreenBuffer(cols: cols, rows: rows)
    }

    /// Convert the visible screen (and optionally scrollback) to NSAttributedString.
    func attributedOutput(font: NSFont, showScrollback: Bool = true) -> NSAttributedString {
        let lines: [[Cell]]
        if showScrollback {
            // M3 fix: clear scrollback viewport calculation
            let scrollbackCount = buffer.scrollback.count
            let maxVisible = min(scrollbackCount, 500)
            // scrollOffset = 0 means at bottom; increasing scrolls up
            let clampedOffset = min(scrollOffset, scrollbackCount)
            let visibleEnd = max(0, scrollbackCount - clampedOffset)
            let visibleStart = max(0, visibleEnd - maxVisible)
            let scrollbackSlice = buffer.scrollback[visibleStart..<visibleEnd]
            lines = Array(scrollbackSlice) + buffer.screen
        } else {
            lines = buffer.screen
        }

        let result = NSMutableAttributedString()

        for (lineIdx, line) in lines.enumerated() {
            if lineIdx > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            // Build runs of same-style characters for efficiency
            var runStart = 0
            while runStart < line.count {
                let style = line[runStart].style
                var runEnd = runStart + 1
                while runEnd < line.count, line[runEnd].style == style {
                    runEnd += 1
                }

                let chars = String(line[runStart..<runEnd].map(\.character))
                let attrs = attributes(for: style, font: font)
                result.append(NSAttributedString(string: chars, attributes: attrs))
                runStart = runEnd
            }
        }

        return result
    }

    private func attributes(for style: CellStyle, font: NSFont) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: style.foreground.nsColor,
            .font: style.bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font,
        ]
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.background != .defaultBackground {
            attrs[.backgroundColor] = style.background.nsColor
        }
        return attrs
    }
}
