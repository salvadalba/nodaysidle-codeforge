import Foundation
import OSLog

/// Parses ANSI escape sequences from terminal output and applies them
/// to a VirtualScreenBuffer. Handles SGR (colors/attributes), cursor
/// movement, erase sequences, and partial escape sequence buffering
/// across data chunk boundaries.
nonisolated struct ANSIParser: Sendable {
    private static let logger = Logger(subsystem: "com.codeforge.app", category: "terminal")

    /// Parser state for tracking partial escape sequences.
    enum State: Sendable, Equatable {
        case ground
        case escape           // saw ESC
        case csiEntry         // saw ESC [
        case oscString        // saw ESC ] (operating system command)
    }

    private(set) var state: State = .ground
    private var paramBuffer: String = ""

    /// Feed raw terminal output data into the parser, updating the screen buffer.
    mutating func feed(_ data: Data, into buffer: inout VirtualScreenBuffer) {
        for byte in data {
            processByte(byte, into: &buffer)
        }
    }

    /// Feed a string (for testing convenience).
    mutating func feed(_ string: String, into buffer: inout VirtualScreenBuffer) {
        feed(Data(string.utf8), into: &buffer)
    }

    private mutating func processByte(_ byte: UInt8, into buffer: inout VirtualScreenBuffer) {
        switch state {
        case .ground:
            processGround(byte, into: &buffer)
        case .escape:
            processEscape(byte, into: &buffer)
        case .csiEntry:
            processCSI(byte, into: &buffer)
        case .oscString:
            processOSC(byte)
        }
    }

    // MARK: - Ground State

    private mutating func processGround(_ byte: UInt8, into buffer: inout VirtualScreenBuffer) {
        switch byte {
        case 0x1B: // ESC
            state = .escape
            paramBuffer = ""
        case 0x07: // BEL — ignore
            break
        case 0x08: // BS
            buffer.writeCharacter("\u{08}")
        case 0x09: // Tab
            buffer.writeCharacter("\t")
        case 0x0A, 0x0B, 0x0C: // LF, VT, FF
            buffer.lineFeed()
        case 0x0D: // CR
            buffer.carriageReturn()
        case 0x00...0x06, 0x0E...0x1A, 0x1C...0x1F:
            // Other C0 control characters — ignore
            break
        default:
            // Printable character — decode UTF-8 byte by byte
            // For simplicity, handle ASCII directly; non-ASCII replaced with ?
            if byte < 0x80 {
                buffer.writeCharacter(Character(UnicodeScalar(byte)))
            } else {
                buffer.writeCharacter("?")
            }
        }
    }

    // MARK: - Escape State

    private mutating func processEscape(_ byte: UInt8, into buffer: inout VirtualScreenBuffer) {
        switch byte {
        case 0x5B: // [ → CSI
            state = .csiEntry
            paramBuffer = ""
        case 0x5D: // ] → OSC
            state = .oscString
            paramBuffer = ""
        case 0x4D: // M → Reverse Index (scroll down)
            // Not commonly needed; reset to ground
            state = .ground
        case 0x63: // c → Reset
            buffer = VirtualScreenBuffer(cols: buffer.cols, rows: buffer.rows)
            state = .ground
        default:
            // Unknown escape sequence — ignore and return to ground
            state = .ground
        }
    }

    // MARK: - CSI State

    private mutating func processCSI(_ byte: UInt8, into buffer: inout VirtualScreenBuffer) {
        switch byte {
        case 0x30...0x3F: // 0-9, ;, <, =, >, ?
            paramBuffer.append(Character(UnicodeScalar(byte)))
        case 0x40...0x7E: // Final byte — execute the CSI sequence
            executeCSI(finalByte: byte, into: &buffer)
            state = .ground
        case 0x1B: // New ESC while in CSI — abort current and start new
            state = .escape
            paramBuffer = ""
        default:
            // Intermediate bytes or invalid — collect or ignore
            paramBuffer.append(Character(UnicodeScalar(byte)))
        }
    }

    private mutating func executeCSI(finalByte: UInt8, into buffer: inout VirtualScreenBuffer) {
        let params = parseParams()

        switch finalByte {
        case 0x6D: // m — SGR (Select Graphic Rendition)
            applySGR(params, to: &buffer)
        case 0x48, 0x66: // H, f — CUP (Cursor Position)
            let row = max((params.first ?? 1), 1) - 1
            let col = max((params.count > 1 ? params[1] : 1), 1) - 1
            buffer.setCursor(row: row, col: col)
        case 0x41: // A — CUU (Cursor Up)
            buffer.cursorUp(max(params.first ?? 1, 1))
        case 0x42: // B — CUD (Cursor Down)
            buffer.cursorDown(max(params.first ?? 1, 1))
        case 0x43: // C — CUF (Cursor Forward)
            buffer.cursorForward(max(params.first ?? 1, 1))
        case 0x44: // D — CUB (Cursor Backward)
            buffer.cursorBackward(max(params.first ?? 1, 1))
        case 0x4A: // J — ED (Erase in Display)
            buffer.eraseInDisplay(mode: params.first ?? 0)
        case 0x4B: // K — EL (Erase in Line)
            buffer.eraseInLine(mode: params.first ?? 0)
        case 0x47: // G — CHA (Cursor Horizontal Absolute)
            let col = max((params.first ?? 1), 1) - 1
            buffer.setCursor(row: buffer.cursorRow, col: col)
        case 0x64: // d — VPA (Vertical Position Absolute)
            let row = max((params.first ?? 1), 1) - 1
            buffer.setCursor(row: row, col: buffer.cursorCol)
        case 0x72: // r — DECSTBM (Set Scrolling Region) — basic: ignore
            break
        case 0x68, 0x6C: // h, l — Set/Reset Mode — ignore common ones
            break
        case 0x6E: // n — Device Status Report — ignore
            break
        case 0x50: // P — DCH (Delete Characters) — basic: ignore
            break
        case 0x4C: // L — IL (Insert Lines) — basic: ignore
            break
        case 0x4D: // M — DL (Delete Lines) — basic: ignore
            break
        case 0x40: // @ — ICH (Insert Characters) — basic: ignore
            break
        default:
            Self.logger.debug("Unknown CSI final byte: \(finalByte)")
        }
    }

    private func parseParams() -> [Int] {
        if paramBuffer.isEmpty { return [] }
        // Strip leading '?' for private mode sequences
        let cleaned = paramBuffer.hasPrefix("?")
            ? String(paramBuffer.dropFirst())
            : paramBuffer
        return cleaned.split(separator: ";").compactMap { Int($0) }
    }

    // MARK: - SGR (Select Graphic Rendition)

    private mutating func applySGR(_ params: [Int], to buffer: inout VirtualScreenBuffer) {
        if params.isEmpty {
            buffer.currentStyle = .plain
            return
        }

        var i = 0
        while i < params.count {
            let code = params[i]
            switch code {
            case 0:
                buffer.currentStyle = .plain
            case 1:
                buffer.currentStyle.bold = true
            case 4:
                buffer.currentStyle.underline = true
            case 22:
                buffer.currentStyle.bold = false
            case 24:
                buffer.currentStyle.underline = false

            // Standard foreground colors (30-37)
            case 30...37:
                buffer.currentStyle.foreground = .standard(UInt8(code - 30))
            // Bright foreground colors (90-97)
            case 90...97:
                buffer.currentStyle.foreground = .standard(UInt8(code - 90 + 8))
            // Default foreground
            case 39:
                buffer.currentStyle.foreground = .default

            // Standard background colors (40-47)
            case 40...47:
                buffer.currentStyle.background = .standard(UInt8(code - 40))
            // Bright background colors (100-107)
            case 100...107:
                buffer.currentStyle.background = .standard(UInt8(code - 100 + 8))
            // Default background
            case 49:
                buffer.currentStyle.background = .defaultBackground

            // 256-color / RGB extended foreground: 38;5;n or 38;2;r;g;b
            case 38:
                if i + 1 < params.count, params[i + 1] == 5, i + 2 < params.count {
                    buffer.currentStyle.foreground = .palette(UInt8(clamping: params[i + 2]))
                    i += 2
                } else if i + 1 < params.count, params[i + 1] == 2, i + 4 < params.count {
                    buffer.currentStyle.foreground = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }

            // 256-color / RGB extended background: 48;5;n or 48;2;r;g;b
            case 48:
                if i + 1 < params.count, params[i + 1] == 5, i + 2 < params.count {
                    buffer.currentStyle.background = .palette(UInt8(clamping: params[i + 2]))
                    i += 2
                } else if i + 1 < params.count, params[i + 1] == 2, i + 4 < params.count {
                    buffer.currentStyle.background = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }

            default:
                break
            }
            i += 1
        }
    }

    // MARK: - OSC State

    private mutating func processOSC(_ byte: UInt8) {
        switch byte {
        case 0x07: // BEL — terminates OSC
            state = .ground
        case 0x1B: // ESC — might be ESC \ (ST)
            state = .escape
        default:
            // Collect OSC string (title changes, etc.) — ignore for now
            break
        }
    }

    // MARK: - Reset

    mutating func reset() {
        state = .ground
        paramBuffer = ""
    }
}
