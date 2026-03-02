import Foundation
import Darwin.POSIX

// Access fork() via C interop since Swift marks it unavailable
@_silgen_name("fork") private func c_fork() -> pid_t

/// Manages a pseudo-terminal (PTY) connected to the user's default shell.
final class PTY {
    let masterFD: Int32
    let slaveFD: Int32
    let childPID: pid_t

    private init(masterFD: Int32, slaveFD: Int32, childPID: pid_t) {
        self.masterFD = masterFD
        self.slaveFD = slaveFD
        self.childPID = childPID
    }

    deinit {
        close(masterFD)
        close(slaveFD)
        kill(childPID, SIGHUP)
    }

    /// Spawn a new PTY running the user's default shell with the given size.
    static func spawn(rows: UInt16, cols: UInt16) throws -> PTY {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PTYError.openFailed }
        guard grantpt(master) == 0 else { throw PTYError.grantFailed }
        guard unlockpt(master) == 0 else { throw PTYError.unlockFailed }

        guard let slavePath = ptsname(master) else { throw PTYError.ptsnameFailed }
        let slave = open(slavePath, O_RDWR)
        guard slave >= 0 else { throw PTYError.slaveOpenFailed }

        // Set initial window size
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(master, TIOCSWINSZ, &ws)

        let pid = c_fork()
        guard pid >= 0 else { throw PTYError.forkFailed }

        if pid == 0 {
            // Child process
            close(master)
            setsid()

            // Set controlling terminal
            _ = ioctl(slave, TIOCSCTTY, 0)

            dup2(slave, STDIN_FILENO)
            dup2(slave, STDOUT_FILENO)
            dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO { close(slave) }

            // Set TERM for color support
            setenv("TERM", "xterm-256color", 1)

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(shell), strdup("-l"), nil
            ]
            execv(shell, argv)
            _exit(1)
        }

        // Parent
        return PTY(masterFD: master, slaveFD: slave, childPID: pid)
    }

    /// Write data to the PTY (sends to the shell).
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(masterFD, ptr + offset, remaining)
                if n <= 0 { break }
                offset += n
                remaining -= n
            }
        }
    }

    /// Write a string to the PTY.
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    /// Resize the PTY window.
    func resize(rows: UInt16, cols: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    enum PTYError: Error {
        case openFailed, grantFailed, unlockFailed
        case ptsnameFailed, slaveOpenFailed, forkFailed
    }
}
