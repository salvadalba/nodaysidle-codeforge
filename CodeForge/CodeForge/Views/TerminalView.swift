import AppKit
import SwiftUI

/// SwiftUI view wrapping an NSTextView for terminal output rendering
/// with keyboard forwarding to the TerminalActor.
struct TerminalView: NSViewRepresentable {
    @Bindable var model: TerminalModel
    let terminalActor: TerminalActor

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        // UI brightness fix: match editor background tone
        scrollView.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)

        let textView = TerminalTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)
        textView.insertionPointColor = NSColor(red: 0.4, green: 0.9, blue: 0.5, alpha: 1.0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Monospace font
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor(white: 0.90, alpha: 1.0),
        ]

        // No line wrap
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        // Wire keyboard handler
        textView.keyHandler = { [terminalActor] event in
            Self.handleKeyEvent(event, actor: terminalActor)
        }

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.font = font

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TerminalTextView else { return }
        let coord = context.coordinator

        let font = coord.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrString = model.attributedOutput(font: font, showScrollback: true)

        textView.textStorage?.setAttributedString(attrString)

        // Snap to bottom on new output
        if model.snapToBottom {
            textView.scrollToEndOfDocument(nil)
        }

        // Detect size changes and trigger resize
        let viewWidth = scrollView.contentSize.width
        let charWidth = font.advancement(forGlyph: font.glyph(withName: "M")).width
        let lineHeight = font.ascender - font.descender + font.leading
        let viewHeight = scrollView.contentSize.height

        if charWidth > 0, lineHeight > 0 {
            let newCols = max(Int(viewWidth / charWidth), 1)
            let newRows = max(Int(viewHeight / lineHeight), 1)

            if newCols != coord.lastCols || newRows != coord.lastRows {
                coord.lastCols = newCols
                coord.lastRows = newRows
                let actor = terminalActor
                Task {
                    await actor.resize(cols: newCols, rows: newRows)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Keyboard Handling

    private static func handleKeyEvent(_ event: NSEvent, actor: TerminalActor) {
        var data: Data?

        if event.modifierFlags.contains(.control) {
            // Ctrl+key → send control character
            if let chars = event.charactersIgnoringModifiers, let char = chars.first {
                let code = char.asciiValue.map { $0 & 0x1F }
                if let code {
                    data = Data([code])
                }
            }
        } else if let specialKey = event.specialKey {
            // Arrow keys and special keys → ANSI escape sequences
            switch specialKey {
            case .upArrow:    data = Data("\u{1b}[A".utf8)
            case .downArrow:  data = Data("\u{1b}[B".utf8)
            case .rightArrow: data = Data("\u{1b}[C".utf8)
            case .leftArrow:  data = Data("\u{1b}[D".utf8)
            case .home:       data = Data("\u{1b}[H".utf8)
            case .end:        data = Data("\u{1b}[F".utf8)
            case .pageUp:     data = Data("\u{1b}[5~".utf8)
            case .pageDown:   data = Data("\u{1b}[6~".utf8)
            case .deleteForward: data = Data("\u{1b}[3~".utf8)
            case .tab:        data = Data([0x09])
            default: break
            }
        } else if let chars = event.characters {
            // Regular characters
            if chars == "\r" {
                data = Data([0x0D]) // Enter → CR
            } else if chars == "\u{7F}" {
                data = Data([0x7F]) // Delete/Backspace
            } else {
                data = Data(chars.utf8)
            }
        }

        if let data {
            Task { await actor.write(data) }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        weak var textView: TerminalTextView?
        weak var scrollView: NSScrollView?
        var font: NSFont?
        var lastCols: Int = 0
        var lastRows: Int = 0
    }
}

/// NSTextView subclass that captures keyboard events for terminal forwarding.
final class TerminalTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let handler = keyHandler {
            handler(event)
        } else {
            super.keyDown(with: event)
        }
    }

    // Prevent the system beep on key press
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler != nil {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
