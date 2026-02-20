import Darwin
import Foundation
import OSLog

/// Actor managing a pseudoterminal shell subprocess via forkpty().
///
/// Spawns $SHELL, reads output into an AsyncStream, writes input,
/// handles resize via TIOCSWINSZ, and performs graceful cleanup
/// (SIGHUP → 2s → SIGKILL).
actor TerminalActor {
    private let logger = Logger(subsystem: "com.codeforge.app", category: "terminal")

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var isRunning = false
    private var readTask: Task<Void, Never>?
    private var parser = ANSIParser()

    private var outputContinuation: AsyncStream<VirtualScreenBuffer>.Continuation?

    /// Stream of buffer snapshots after each output chunk is parsed.
    nonisolated let outputStream: AsyncStream<VirtualScreenBuffer>

    /// The current screen buffer dimensions.
    private var cols: Int = 80
    private var rows: Int = 24
    private var buffer: VirtualScreenBuffer

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        self.buffer = VirtualScreenBuffer(cols: cols, rows: rows)

        var continuation: AsyncStream<VirtualScreenBuffer>.Continuation!
        outputStream = AsyncStream { continuation = $0 }
        self.outputContinuation = continuation

        logger.info("TerminalActor initialized (\(cols)x\(rows))")
    }

    // MARK: - Spawn

    /// Spawn a shell subprocess via forkpty().
    func spawn() throws {
        guard !isRunning else {
            logger.warning("Shell already running")
            return
        }

        var winSize = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &winSize)

        guard pid >= 0 else {
            let errMsg = String(cString: strerror(errno))
            logger.error("forkpty failed: \(errMsg)")
            throw TerminalError.forkFailed(errMsg)
        }

        if pid == 0 {
            // Child process — exec the shell
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            setupChildEnvironment()
            let arg0 = strdup(shell)
            let arg1 = strdup("--login")
            var args: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
            execv(shell, &args)
            // execv only returns on failure — free allocations before exit
            free(arg0)
            free(arg1)
            _exit(1)
        }

        // Parent process
        self.masterFD = masterFD
        self.childPID = pid
        self.isRunning = true

        logger.info("Spawned shell (PID \(pid), fd \(masterFD))")

        startReading()
    }

    private func setupChildEnvironment() {
        let inherited = ["PATH", "HOME", "SHELL", "USER", "LANG"]
        var env: [String: String] = [:]
        for key in inherited {
            if let val = ProcessInfo.processInfo.environment[key] {
                env[key] = val
            }
        }
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "\(cols)"
        env["LINES"] = "\(rows)"

        // Clear existing environment, then set only inherited vars
        for (key, _) in ProcessInfo.processInfo.environment {
            unsetenv(key)
        }
        for (key, value) in env {
            setenv(key, value, 1)
        }
    }

    // MARK: - Reading Output

    private func startReading() {
        let fd = masterFD
        let bufferSize = 4096
        readTask = Task.detached { [weak self] in
            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { readBuffer.deallocate() }

            while !Task.isCancelled {
                let bytesRead = read(fd, readBuffer, bufferSize)
                if bytesRead <= 0 {
                    break
                }
                let data = Data(bytes: readBuffer, count: bytesRead)
                await self?.handleOutput(data)
            }
            await self?.handleChildExit()
        }
    }

    private func handleOutput(_ data: Data) {
        parser.feed(data, into: &buffer)
        outputContinuation?.yield(buffer)
    }

    private func handleChildExit() {
        isRunning = false
        logger.info("Shell process exited")
        outputContinuation?.finish()
    }

    // MARK: - Writing Input

    /// Write data to the shell's stdin.
    func write(_ data: Data) {
        guard isRunning, masterFD >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let baseAddr = ptr.baseAddress else { return }
            _ = Darwin.write(masterFD, baseAddr, ptr.count)
        }
    }

    /// Write a string to the shell's stdin.
    func write(_ string: String) {
        write(Data(string.utf8))
    }

    // MARK: - Resize

    /// Resize the terminal, sending TIOCSWINSZ to the PTY.
    func resize(cols newCols: Int, rows newRows: Int) {
        guard isRunning, masterFD >= 0 else { return }

        self.cols = newCols
        self.rows = newRows
        buffer.resize(cols: newCols, rows: newRows)

        var winSize = winsize(
            ws_row: UInt16(newRows),
            ws_col: UInt16(newCols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let result = ioctl(masterFD, TIOCSWINSZ, &winSize)
        if result != 0 {
            logger.warning("TIOCSWINSZ ioctl failed: \(errno)")
        }

        // Send SIGWINCH to child to notify of resize
        if childPID > 0 {
            kill(childPID, SIGWINCH)
        }

        logger.debug("Resized to \(newCols)x\(newRows)")
    }

    // MARK: - Cleanup

    /// Gracefully stop the shell: SIGHUP → 2s wait → SIGKILL.
    func stop() async {
        guard isRunning, childPID > 0 else { return }

        readTask?.cancel()
        readTask = nil

        // Send SIGHUP
        kill(childPID, SIGHUP)
        logger.info("Sent SIGHUP to PID \(self.childPID)")

        // Wait up to 2 seconds for exit
        let exited = await waitForExit(timeout: .seconds(2))

        if !exited {
            kill(childPID, SIGKILL)
            logger.info("Sent SIGKILL to PID \(self.childPID)")
            _ = await waitForExit(timeout: .seconds(1))
        }

        // Clean up
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        childPID = -1
        isRunning = false
        outputContinuation?.finish()
    }

    private func waitForExit(timeout: Duration) async -> Bool {
        let pid = childPID
        return await withCheckedContinuation { cont in
            Task.detached {
                let deadline = ContinuousClock.now + timeout
                while ContinuousClock.now < deadline {
                    var status: Int32 = 0
                    let result = waitpid(pid, &status, WNOHANG)
                    if result > 0 || result == -1 {
                        cont.resume(returning: true)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                cont.resume(returning: false)
            }
        }
    }

    deinit {
        if masterFD >= 0 {
            close(masterFD)
        }
        if childPID > 0 {
            kill(childPID, SIGKILL)
        }
        outputContinuation?.finish()
    }
}

// MARK: - Errors

enum TerminalError: Error, LocalizedError, Sendable {
    case forkFailed(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .forkFailed(let msg): "Failed to spawn shell: \(msg)"
        case .notRunning: "Terminal is not running"
        }
    }
}
