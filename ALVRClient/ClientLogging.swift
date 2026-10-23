import Foundation

enum ClientLogging {
    static func defaultFilter(environment: [String: String]) -> String? {
        // Apple's client_core uses env_logger::builder() (from_default_env): without RUST_LOG,
        // env_logger defaults to Error, filtering Info before it can be mirrored to the streamer.
        // Preserve every explicit filter, including an empty string.
        environment["RUST_LOG"] == nil ? "info" : nil
    }
}

/// Inserts a prefix before the first byte of every line; bytes are otherwise copied unchanged.
struct ConsoleLineStamper {
    private var atLineStart = true

    mutating func feed(_ chunk: [UInt8], prefix: () -> String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(chunk.count + 48)
        for byte in chunk {
            if atLineStart { out.append(contentsOf: prefix().utf8); atLineStart = false }
            out.append(byte)
            if byte == 10 { atLineStart = true }
        }
        return out
    }
}

extension ClientLogging {
    static let consoleStampKey = "ALVRConsoleStamp"
    private static var consoleStampInstalled = false

    static func consoleStampEnabled(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: consoleStampKey) }

    static func stampPrefix(wall: Double, mono: Double) -> String {
        String(format: "[TS %.3f %.6f] ", wall, mono)
    }

    private static func clocks() -> (wall: Double, mono: Double) {
        (Date().timeIntervalSince1970, Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9)
    }

    private static func nowPrefix() -> String {
        let t = clocks()
        return stampPrefix(wall: t.wall, mono: t.mono)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return }
            off += n
        }
    }

    /// Reads `readFD` until EOF or error, writing every line to `writeFD` behind `prefix()`.
    static func pumpStamped(readFD: Int32, writeFD: Int32, prefix: () -> String) {
        var stamper = ConsoleLineStamper()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            writeAll(writeFD, stamper.feed(Array(buf[0..<n]), prefix: prefix))
        }
    }

    /// Points fds 1 and 2 at `write`; if either dup2 fails, puts the saved fds back and returns false.
    static func redirectConsole(to write: Int32, savedOut: Int32, savedErr: Int32,
                                dup2Fn: (Int32, Int32) -> Int32 = { dup2($0, $1) }) -> Bool {
        if dup2Fn(write, STDOUT_FILENO) >= 0 && dup2Fn(write, STDERR_FILENO) >= 0 { return true }
        let failure = errno
        if savedOut >= 0 { _ = dup2Fn(savedOut, STDOUT_FILENO) }
        if savedErr >= 0 { _ = dup2Fn(savedErr, STDERR_FILENO) }
        errno = failure
        return false
    }

    /// Stamps every console line (stdout and stderr) with wall-clock and monotonic time when the flag is on.
    static func installConsoleStamp(_ defaults: UserDefaults = .standard) {
        guard consoleStampEnabled(defaults), !consoleStampInstalled else { return }
        consoleStampInstalled = true
        let out = dup(STDOUT_FILENO), err = dup(STDERR_FILENO)
        var fds: [Int32] = [-1, -1]
        guard out >= 0, err >= 0, pipe(&fds) == 0, redirectConsole(to: fds[1], savedOut: out, savedErr: err) else {
            let failure = errno
            if out >= 0 { writeAll(out, Array("CONSOLESTAMP v1 failed errno=\(failure)\n".utf8)) }
            for fd in [out, err] + fds where fd >= 0 { close(fd) }
            return
        }
        close(fds[1])
        close(err)
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        let readFD = fds[0]
        let t = clocks()
        let header = stampPrefix(wall: t.wall, mono: t.mono)
            + String(format: "CONSOLESTAMP v1 wall=%.3f mono=%.6f clock=uptime_raw\n", t.wall, t.mono)
        writeAll(out, Array(header.utf8))
        let thread = Thread { pumpStamped(readFD: readFD, writeFD: out, prefix: nowPrefix) }
        thread.name = "console-stamp"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
