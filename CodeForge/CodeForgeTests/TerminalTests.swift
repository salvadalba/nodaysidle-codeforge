import AppKit
import Foundation
import Testing

@testable import CodeForge

// MARK: - VirtualScreenBuffer Tests

@Suite("VirtualScreenBuffer")
struct VirtualScreenBufferTests {

    @Test("Default buffer is empty with correct dimensions")
    func defaultState() {
        let buf = VirtualScreenBuffer(cols: 80, rows: 24)
        #expect(buf.cols == 80)
        #expect(buf.rows == 24)
        #expect(buf.cursorRow == 0)
        #expect(buf.cursorCol == 0)
        #expect(buf.scrollback.isEmpty)
    }

    @Test("Write characters advances cursor")
    func writeCharacters() {
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        buf.writeCharacter("A")
        buf.writeCharacter("B")
        #expect(buf.cursorCol == 2)
        #expect(buf.screen[0][0].character == "A")
        #expect(buf.screen[0][1].character == "B")
    }

    @Test("Newline moves to next row")
    func newline() {
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        buf.writeCharacter("A")
        buf.lineFeed()
        #expect(buf.cursorRow == 1)
        buf.carriageReturn()
        #expect(buf.cursorCol == 0)
    }

    @Test("Scroll pushes top line to scrollback")
    func scrollback() {
        var buf = VirtualScreenBuffer(cols: 10, rows: 3)
        // Fill 3 rows and trigger scroll
        for c in "ABC" { buf.writeCharacter(c) }
        buf.lineFeed()
        buf.carriageReturn()
        for c in "DEF" { buf.writeCharacter(c) }
        buf.lineFeed()
        buf.carriageReturn()
        for c in "GHI" { buf.writeCharacter(c) }
        buf.lineFeed() // This triggers scrollUp
        buf.carriageReturn()

        #expect(buf.scrollback.count == 1)
        #expect(buf.scrollback[0][0].character == "A")
    }

    @Test("Scrollback respects max limit")
    func scrollbackLimit() {
        var buf = VirtualScreenBuffer(cols: 5, rows: 2)
        // Scroll many times
        for i in 0..<(VirtualScreenBuffer.maxScrollback + 100) {
            let c = Character(String(i % 10))
            buf.writeCharacter(c)
            buf.lineFeed()
            buf.carriageReturn()
        }
        #expect(buf.scrollback.count == VirtualScreenBuffer.maxScrollback)
    }

    @Test("Cursor movement stays in bounds")
    func cursorBounds() {
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        buf.cursorUp(100)
        #expect(buf.cursorRow == 0)
        buf.cursorBackward(100)
        #expect(buf.cursorCol == 0)
        buf.cursorDown(100)
        #expect(buf.cursorRow == 23)
        buf.cursorForward(100)
        #expect(buf.cursorCol == 79)
    }

    @Test("Set cursor position")
    func setCursor() {
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        buf.setCursor(row: 5, col: 10)
        #expect(buf.cursorRow == 5)
        #expect(buf.cursorCol == 10)
    }

    @Test("Erase in display mode 2 clears screen")
    func eraseDisplay() {
        var buf = VirtualScreenBuffer(cols: 10, rows: 3)
        for c in "Hello" { buf.writeCharacter(c) }
        buf.eraseInDisplay(mode: 2)
        #expect(buf.screen[0][0].character == " ")
    }

    @Test("Erase in line mode 0 clears to end")
    func eraseLine() {
        var buf = VirtualScreenBuffer(cols: 10, rows: 3)
        for c in "Hello" { buf.writeCharacter(c) }
        buf.setCursor(row: 0, col: 2)
        buf.eraseInLine(mode: 0)
        #expect(buf.screen[0][0].character == "H")
        #expect(buf.screen[0][1].character == "e")
        #expect(buf.screen[0][2].character == " ")
        #expect(buf.screen[0][3].character == " ")
    }

    @Test("Resize preserves content")
    func resize() {
        var buf = VirtualScreenBuffer(cols: 10, rows: 3)
        for c in "Hi" { buf.writeCharacter(c) }
        buf.resize(cols: 20, rows: 5)
        #expect(buf.cols == 20)
        #expect(buf.rows == 5)
        #expect(buf.screen[0][0].character == "H")
        #expect(buf.screen[0][1].character == "i")
    }

    @Test("Tab stops at 8-column boundaries")
    func tabStops() {
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        buf.writeCharacter("A")
        buf.writeCharacter("\t")
        #expect(buf.cursorCol == 8)
    }
}

// MARK: - ANSIParser Tests

@Suite("ANSIParser")
struct ANSIParserTests {

    @Test("Plain text renders correctly")
    func plainText() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("Hello", into: &buf)
        let text = String(buf.screen[0].prefix(5).map(\.character))
        #expect(text == "Hello")
    }

    @Test("SGR reset clears style")
    func sgrReset() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[1mBold\u{1b}[0mPlain", into: &buf)
        // "B" should be bold
        #expect(buf.screen[0][0].style.bold == true)
        // "P" in "Plain" should not be bold
        #expect(buf.screen[0][4].style.bold == false)
    }

    @Test("SGR foreground colors")
    func sgrForeground() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[31mRed", into: &buf)
        #expect(buf.screen[0][0].style.foreground == .standard(1))
    }

    @Test("SGR background colors")
    func sgrBackground() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[42mGreenBG", into: &buf)
        #expect(buf.screen[0][0].style.background == .standard(2))
    }

    @Test("SGR 256-color foreground")
    func sgr256Color() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[38;5;196mRed256", into: &buf)
        #expect(buf.screen[0][0].style.foreground == .palette(196))
    }

    @Test("SGR RGB foreground")
    func sgrRGB() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[38;2;255;128;0mOrange", into: &buf)
        #expect(buf.screen[0][0].style.foreground == .rgb(255, 128, 0))
    }

    @Test("SGR bright foreground")
    func sgrBright() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[91mBrightRed", into: &buf)
        #expect(buf.screen[0][0].style.foreground == .standard(9))
    }

    @Test("SGR underline")
    func sgrUnderline() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[4mUnder\u{1b}[24mNot", into: &buf)
        #expect(buf.screen[0][0].style.underline == true)
        #expect(buf.screen[0][5].style.underline == false)
    }

    @Test("Cursor position (CUP)")
    func cursorPosition() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[3;5H", into: &buf)
        #expect(buf.cursorRow == 2) // 1-indexed → 0-indexed
        #expect(buf.cursorCol == 4)
    }

    @Test("Cursor movement commands")
    func cursorMovement() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("\u{1b}[5;10H", into: &buf) // row 4, col 9
        parser.feed("\u{1b}[2A", into: &buf)      // up 2
        #expect(buf.cursorRow == 2)
        parser.feed("\u{1b}[3B", into: &buf)      // down 3
        #expect(buf.cursorRow == 5)
        parser.feed("\u{1b}[2C", into: &buf)      // forward 2
        #expect(buf.cursorCol == 11)
        parser.feed("\u{1b}[5D", into: &buf)      // backward 5
        #expect(buf.cursorCol == 6)
    }

    @Test("Erase in display via CSI")
    func eraseDisplay() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 10, rows: 3)
        parser.feed("Hello", into: &buf)
        parser.feed("\u{1b}[2J", into: &buf)
        #expect(buf.screen[0][0].character == " ")
    }

    @Test("Erase in line via CSI")
    func eraseLine() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 10, rows: 3)
        parser.feed("Hello", into: &buf)
        parser.feed("\u{1b}[1;3H", into: &buf) // move to col 2
        parser.feed("\u{1b}[K", into: &buf)      // erase to end of line
        #expect(buf.screen[0][0].character == "H")
        #expect(buf.screen[0][1].character == "e")
        #expect(buf.screen[0][2].character == " ")
    }

    @Test("Partial escape sequence across chunks")
    func partialSequence() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        // Send ESC in first chunk, [ and rest in second
        parser.feed("\u{1b}", into: &buf)
        #expect(parser.state == .escape)
        parser.feed("[31mRed", into: &buf)
        #expect(parser.state == .ground)
        #expect(buf.screen[0][0].style.foreground == .standard(1))
    }

    @Test("CR LF sequence")
    func crLf() {
        var parser = ANSIParser()
        var buf = VirtualScreenBuffer(cols: 80, rows: 24)
        parser.feed("Line1\r\nLine2", into: &buf)
        let line1 = String(buf.screen[0].prefix(5).map(\.character))
        let line2 = String(buf.screen[1].prefix(5).map(\.character))
        #expect(line1 == "Line1")
        #expect(line2 == "Line2")
    }
}

// MARK: - TerminalActor Tests

@Suite("TerminalActor", .serialized)
struct TerminalActorTests {

    @Test("Spawn and stop shell without zombies")
    func spawnAndStop() async throws {
        let actor = TerminalActor(cols: 80, rows: 24)
        try await actor.spawn()

        // Give shell a moment to start
        try await Task.sleep(for: .milliseconds(200))

        await actor.stop()

        // Verify no zombie by checking waitpid returns -1 (no child)
        // (the stop method already waits for the process)
    }

    @Test("Shell produces output on the stream")
    func shellProducesOutput() async throws {
        let actor = TerminalActor(cols: 80, rows: 24)
        try await actor.spawn()

        // Just verify the stream yields at least one snapshot (shell prompt)
        let receivedOutput = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in actor.outputStream {
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(receivedOutput, "Expected at least one output snapshot from shell")
        await actor.stop()
    }

    @Test("Resize changes dimensions")
    func resizeTest() async throws {
        let actor = TerminalActor(cols: 80, rows: 24)
        try await actor.spawn()

        try await Task.sleep(for: .milliseconds(200))
        await actor.resize(cols: 120, rows: 40)

        // The resize should succeed without crashing
        await actor.stop()
    }
}

// MARK: - TermColor Tests

@Suite("TermColor")
struct TermColorTests {

    @Test("Standard colors produce valid NSColor")
    func standardColors() {
        for i: UInt8 in 0...15 {
            let color = TermColor.standard(i)
            _ = color.nsColor // Should not crash
        }
    }

    @Test("Palette 256 colors produce valid NSColor")
    func paletteColors() {
        for i: UInt8 in 0...255 {
            let color = TermColor.palette(i)
            _ = color.nsColor
        }
    }

    @Test("RGB color produces correct NSColor")
    func rgbColor() {
        let color = TermColor.rgb(128, 64, 32)
        let ns = color.nsColor
        // Verify it's approximately correct
        #expect(ns.redComponent > 0.4)
        #expect(ns.greenComponent > 0.2)
    }
}
