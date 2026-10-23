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

    /// Stamps every console line (stdout and stderr) with wall-clock and monotonic time when the flag is on.
    static func installConsoleStamp(_ defaults: UserDefaults = .standard) {
        guard consoleStampEnabled(defaults), !consoleStampInstalled else { return }
        consoleStampInstalled = true
        let out = dup(STDOUT_FILENO)
        var fds: [Int32] = [-1, -1]
        if out < 0 || pipe(&fds) != 0 || dup2(fds[1], STDOUT_FILENO) < 0 || dup2(fds[1], STDERR_FILENO) < 0 {
            let err = errno
            if out >= 0 { writeAll(out, Array("CONSOLESTAMP v1 failed errno=\(err)\n".utf8)) }
            return
        }
        close(fds[1])
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
