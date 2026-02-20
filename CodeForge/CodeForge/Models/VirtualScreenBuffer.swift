import AppKit
import Foundation

/// Attributes for a single terminal cell.
nonisolated struct CellStyle: Sendable, Equatable {
    var foreground: TermColor = .default
    var background: TermColor = .defaultBackground
    var bold: Bool = false
    var underline: Bool = false

    static let plain = CellStyle()
}

/// Terminal color: default, 8/16 standard colors, or 256-color palette index.
nonisolated enum TermColor: Sendable, Equatable {
    case `default`
    case defaultBackground
    case standard(UInt8)   // 0-7 standard, 8-15 bright
    case palette(UInt8)    // 0-255 (256-color)
    case rgb(UInt8, UInt8, UInt8)

    /// Convert to NSColor for rendering.
    var nsColor: NSColor {
        switch self {
        case .default:
            return NSColor(white: 0.85, alpha: 1.0)
        case .defaultBackground:
            return NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        case .standard(let idx):
            return Self.standardColor(idx)
        case .palette(let idx):
            return Self.paletteColor(idx)
        case .rgb(let r, let g, let b):
            return NSColor(
                red: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        }
    }

    private static func standardColor(_ idx: UInt8) -> NSColor {
        switch idx {
        case 0:  return NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)       // Black
        case 1:  return NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0)       // Red
        case 2:  return NSColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1.0)       // Green
        case 3:  return NSColor(red: 0.8, green: 0.8, blue: 0.2, alpha: 1.0)       // Yellow
        case 4:  return NSColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1.0)       // Blue
        case 5:  return NSColor(red: 0.8, green: 0.3, blue: 0.8, alpha: 1.0)       // Magenta
        case 6:  return NSColor(red: 0.2, green: 0.8, blue: 0.8, alpha: 1.0)       // Cyan
        case 7:  return NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)    // White
        case 8:  return NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)       // Bright Black
        case 9:  return NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)       // Bright Red
        case 10: return NSColor(red: 0.3, green: 1.0, blue: 0.3, alpha: 1.0)       // Bright Green
        case 11: return NSColor(red: 1.0, green: 1.0, blue: 0.3, alpha: 1.0)       // Bright Yellow
        case 12: return NSColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 1.0)       // Bright Blue
        case 13: return NSColor(red: 1.0, green: 0.5, blue: 1.0, alpha: 1.0)       // Bright Magenta
        case 14: return NSColor(red: 0.3, green: 1.0, blue: 1.0, alpha: 1.0)       // Bright Cyan
        case 15: return NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)       // Bright White
        default: return NSColor(white: 0.85, alpha: 1.0)
        }
    }

    private static func paletteColor(_ idx: UInt8) -> NSColor {
        if idx < 16 {
            return standardColor(idx)
        } else if idx < 232 {
            // 6x6x6 color cube (indices 16-231)
            let adjusted = Int(idx) - 16
            let r = adjusted / 36
            let g = (adjusted % 36) / 6
            let b = adjusted % 6
            return NSColor(
                red: r == 0 ? 0 : CGFloat(r * 40 + 55) / 255.0,
                green: g == 0 ? 0 : CGFloat(g * 40 + 55) / 255.0,
                blue: b == 0 ? 0 : CGFloat(b * 40 + 55) / 255.0,
                alpha: 1.0
            )
        } else {
            // Grayscale ramp (indices 232-255)
            let gray = CGFloat(Int(idx - 232) * 10 + 8) / 255.0
            return NSColor(white: gray, alpha: 1.0)
        }
    }
}

/// A single cell in the terminal grid.
nonisolated struct Cell: Sendable, Equatable {
    var character: Character = " "
    var style: CellStyle = .plain
}

/// A fixed-size grid of terminal cells with scrollback buffer.
///
/// The screen has `rows` visible rows and `cols` columns.
/// When content scrolls off the top, it goes into the scrollback buffer
/// (up to `maxScrollback` lines). The cursor position is tracked
/// within the visible screen area.
nonisolated struct VirtualScreenBuffer: Sendable {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0

    /// The visible screen grid (rows x cols).
    private(set) var screen: [[Cell]]

    /// Scrollback buffer — most recent lines at the end.
    private(set) var scrollback: [[Cell]] = []

    /// Maximum scrollback lines.
    static let maxScrollback = 10_000

    /// Current style applied to new characters.
    var currentStyle: CellStyle = .plain

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.screen = Self.makeEmptyGrid(cols: self.cols, rows: self.rows)
    }

    private static func makeEmptyGrid(cols: Int, rows: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }

    // MARK: - Cell Access

    /// Write a character at the cursor position, advancing the cursor.
    mutating func writeCharacter(_ char: Character) {
        if char == "\n" {
            lineFeed()
            return
        }
        if char == "\r" {
            carriageReturn()
            return
        }
        if char == "\u{08}" { // Backspace
            if cursorCol > 0 { cursorCol -= 1 }
            return
        }
        if char == "\t" {
            // Tab to next 8-column stop
            let nextTab = ((cursorCol / 8) + 1) * 8
            cursorCol = min(nextTab, cols - 1)
            return
        }

        guard cursorRow >= 0, cursorRow < rows else { return }

        if cursorCol >= cols {
            // Auto-wrap
            lineFeed()
            carriageReturn()
        }

        screen[cursorRow][cursorCol] = Cell(character: char, style: currentStyle)
        cursorCol += 1
    }

    /// Line feed: move cursor down. If at bottom, scroll up.
    mutating func lineFeed() {
        if cursorRow < rows - 1 {
            cursorRow += 1
        } else {
            scrollUp()
        }
    }

    /// Carriage return: move cursor to column 0.
    mutating func carriageReturn() {
        cursorCol = 0
    }

    /// Scroll the screen up by one line, moving the top line to scrollback.
    mutating func scrollUp() {
        scrollback.append(screen[0])
        if scrollback.count > Self.maxScrollback {
            scrollback.removeFirst()
        }
        screen.removeFirst()
        screen.append(Array(repeating: Cell(), count: cols))
    }

    // MARK: - Cursor Movement

    /// Set cursor to absolute position (0-indexed).
    mutating func setCursor(row: Int, col: Int) {
        cursorRow = max(0, min(row, rows - 1))
        cursorCol = max(0, min(col, cols - 1))
    }

    /// Move cursor up by n rows.
    mutating func cursorUp(_ n: Int = 1) {
        cursorRow = max(0, cursorRow - n)
    }

    /// Move cursor down by n rows.
    mutating func cursorDown(_ n: Int = 1) {
        cursorRow = min(rows - 1, cursorRow + n)
    }

    /// Move cursor forward by n columns.
    mutating func cursorForward(_ n: Int = 1) {
        cursorCol = min(cols - 1, cursorCol + n)
    }

    /// Move cursor backward by n columns.
    mutating func cursorBackward(_ n: Int = 1) {
        cursorCol = max(0, cursorCol - n)
    }

    // MARK: - Erase

    /// Erase in display (ED).
    /// - mode 0: from cursor to end of screen
    /// - mode 1: from beginning of screen to cursor
    /// - mode 2: entire screen
    mutating func eraseInDisplay(mode: Int) {
        switch mode {
        case 0:
            // Cursor to end
            eraseLine(from: cursorCol, to: cols, row: cursorRow)
            for r in (cursorRow + 1)..<rows {
                eraseLine(from: 0, to: cols, row: r)
            }
        case 1:
            // Beginning to cursor
            for r in 0..<cursorRow {
                eraseLine(from: 0, to: cols, row: r)
            }
            eraseLine(from: 0, to: cursorCol + 1, row: cursorRow)
        case 2:
            // Entire screen
            screen = Self.makeEmptyGrid(cols: cols, rows: rows)
        default:
            break
        }
    }

    /// Erase in line (EL).
    /// - mode 0: from cursor to end of line
    /// - mode 1: from beginning of line to cursor
    /// - mode 2: entire line
    mutating func eraseInLine(mode: Int) {
        guard cursorRow >= 0, cursorRow < rows else { return }
        switch mode {
        case 0:
            eraseLine(from: cursorCol, to: cols, row: cursorRow)
        case 1:
            eraseLine(from: 0, to: cursorCol + 1, row: cursorRow)
        case 2:
            eraseLine(from: 0, to: cols, row: cursorRow)
        default:
            break
        }
    }

    private mutating func eraseLine(from startCol: Int, to endCol: Int, row: Int) {
        guard row >= 0, row < rows else { return }
        let start = max(0, startCol)
        let end = min(cols, endCol)
        for c in start..<end {
            screen[row][c] = Cell()
        }
    }

    // MARK: - Resize

    /// Resize the buffer to new dimensions.
    mutating func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(newCols, 1)
        let newRows = max(newRows, 1)

        var newScreen = Self.makeEmptyGrid(cols: newCols, rows: newRows)

        // Copy over as much of the existing screen as fits
        let copyRows = min(rows, newRows)
        let copyCols = min(cols, newCols)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                newScreen[r][c] = screen[r][c]
            }
        }

        screen = newScreen
        cols = newCols
        rows = newRows
        cursorRow = min(cursorRow, newRows - 1)
        cursorCol = min(cursorCol, newCols - 1)
    }

    // MARK: - Rendering

    /// Total lines available (scrollback + screen).
    var totalLines: Int { scrollback.count + rows }

    /// Get all lines (scrollback + screen) for rendering.
    var allLines: [[Cell]] { scrollback + screen }
}
