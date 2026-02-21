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
    private var readWorkItem: DispatchWorkItem?
    private var parser = ANSIParser()

    private var outputContinuation: AsyncStream<VirtualScreenBuffer>.Continuation?

    /// Stream of buffer snapshots after each output chunk is parsed.
    nonisolated let outputStream: AsyncStream<VirtualScreenBuffer>

    /// The current screen buffer dimensions.
    private var cols: Int = 80
    private var rows: Int = 24
    private var buffer: VirtualScreenBuffer

    // C2 fix: use makeStream() instead of IUO continuation
    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        self.buffer = VirtualScreenBuffer(cols: cols, rows: rows)

        let (stream, continuation) = AsyncStream<VirtualScreenBuffer>.makeStream()
        self.outputStream = stream
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

        // H1 fix: pre-compute child environment BEFORE fork to avoid
        // accessing Swift runtime/actor state in the child process
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let childEnv = buildChildEnvironment(shell: shell)

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &winSize)

        guard pid >= 0 else {
            let errMsg = String(cString: strerror(errno))
            logger.error("forkpty failed: \(errMsg)")
            throw TerminalError.forkFailed(errMsg)
        }

        if pid == 0 {
            // Child process — only POSIX-safe calls here (no Swift runtime)
            // Clear existing environment
            var envPtr = environ
            while let entry = envPtr.pointee {
                let key = String(cString: entry).split(separator: "=").first.map(String.init) ?? ""
                unsetenv(key)
                envPtr = envPtr.advanced(by: 1)
            }
            // Set pre-computed environment
            for (key, value) in childEnv {
                setenv(key, value, 1)
            }

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

    /// Build the child environment dictionary before fork.
    /// H1 fix: all Swift runtime access happens here, before forkpty().
    private func buildChildEnvironment(shell: String) -> [(String, String)] {
        let inherited = ["PATH", "HOME", "SHELL", "USER", "LANG"]
        var env: [(String, String)] = []
        for key in inherited {
            if let val = ProcessInfo.processInfo.environment[key] {
                env.append((key, val))
            }
        }
        env.append(("TERM", "xterm-256color"))
        env.append(("COLUMNS", "\(cols)"))
        env.append(("LINES", "\(rows)"))
        return env
    }

    // MARK: - Reading Output

    /// H2 fix: use a dedicated DispatchQueue for blocking read() instead of
    /// Task.detached, which would block a cooperative thread pool thread.
    private func startReading() {
        let fd = masterFD
        let bufferSize = 4096
        let workItem = DispatchWorkItem { [weak self] in
            let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { readBuffer.deallocate() }

            while true {
                let bytesRead = read(fd, readBuffer, bufferSize)
                if bytesRead <= 0 {
                    break
                }
                let data = Data(bytes: readBuffer, count: bytesRead)
                // Bind weak self to local let for @Sendable closure capture
                let actor = self
                Task { @Sendable in await actor?.handleOutput(data) }
            }
            let actor = self
            Task { @Sendable in await actor?.handleChildExit() }
        }
        self.readWorkItem = workItem
        DispatchQueue.global(qos: .userInteractive).async(execute: workItem)
    }

    private func handleOutput(_ data: Data) {
        parser.feed(data, into: &buffer)
        outputContinuation?.yield(buffer)
    }

    private func handleChildExit() {
        guard isRunning else { return }
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

        // H6 fix: close masterFD first to unblock the read() call explicitly,
        // then cancel the work item. This is the documented way to stop blocking I/O.
        let fd = masterFD
        masterFD = -1
        if fd >= 0 {
            close(fd)
        }
        readWorkItem?.cancel()
        readWorkItem = nil

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

        childPID = -1
        isRunning = false
        outputContinuation?.finish()
    }

    /// H7 fix: properly distinguish waitpid results.
    /// Returns true if the child process has exited.
    private func waitForExit(timeout: Duration) async -> Bool {
        let pid = childPID
        guard pid > 0 else { return true }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let deadline = ContinuousClock.now + timeout
                while ContinuousClock.now < deadline {
                    var status: Int32 = 0
                    let result = waitpid(pid, &status, WNOHANG)
                    if result > 0 {
                        // Child exited normally
                        cont.resume(returning: true)
                        return
                    }
                    if result == -1 {
                        // ECHILD: child was already reaped or doesn't exist
                        cont.resume(returning: errno == ECHILD)
                        return
                    }
                    // result == 0: child still running, poll again
                    Thread.sleep(forTimeInterval: 0.05)
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
