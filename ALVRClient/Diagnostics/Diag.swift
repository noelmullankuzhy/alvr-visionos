//
//  Diag.swift
//
// Diagnostics core (GM decision 65). With the Diagnostics setting or ALVR_DIAG on, `Diag.log(topic, [key: value])` writes
//   DIAG <topic> t_ms=<monotonic ms> k=v ...
// to alvr_log at Info and to Documents/diag/diag-<UTC stamp>.log (a new file before one would pass 20 MB), on a serial
// queue off the calling thread. Off: no directory, no file, and the fields are never built (autoclosure).
// Values with spaces, quotes, backslashes, control characters or = are quoted and escaped; keys keep [A-Za-z0-9_.].
// Also the per-second cadence window (M6) and the 5 s GPU window (M9), nearest-rank p50/p95.
// Foundation-only so it is unit tested on macOS (tests/swift/DiagTests.swift).
//

import Foundation

enum Diag {
    static let envKey = "ALVR_DIAG"
    static let maxFileBytes = 20 * 1024 * 1024

    // Set once by start() at launch, before any render thread exists; never reset.
    private static var sink: DiagSink?
    static var isOn: Bool { sink != nil }

    static func enabled(environment: [String: String], setting: Bool) -> Bool {
        setting || ["1", "true", "yes", "on"].contains(environment[envKey]?.lowercased() ?? "")
    }

    // Off creates nothing; on opens the sink once per process (later calls are ignored).
    static func start(enabled: Bool, directory: URL, console: ((String) -> Void)?) {
        guard enabled, sink == nil else { return }
        sink = DiagSink(directory: directory, maxBytes: maxFileBytes, now: { Date() }, console: console)
    }

    static func log(_ topic: String, _ fields: @autoclosure () -> KeyValuePairs<String, Any>) {
        guard let sink else { return }
        sink.write(line(topic: topic, tMs: monotonicMs(), fields: fields()))
    }

    static func flush() {
        sink?.flush()
    }

    static func monotonicMs() -> Int {
        Int(ProcessInfo.processInfo.systemUptime * 1000)
    }

    static func line(topic: String, tMs: Int, fields: KeyValuePairs<String, Any>) -> String {
        var out = "DIAG \(key(topic)) t_ms=\(tMs)"
        for (k, v) in fields {
            out += " \(key(k))=\(value(v))"
        }
        return out
    }

    static func key(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == ".") ? Character(scalar) : "_"
        })
        return cleaned.isEmpty ? "_" : cleaned
    }

    static func value(_ raw: Any) -> String {
        let text: String
        switch raw {
        case let b as Bool: return b ? "true" : "false"
        case let d as Double: return d.isNaN ? "nan" : String(format: "%.3f", d)
        case let f as Float: return f.isNaN ? "nan" : String(format: "%.3f", Double(f))
        default: text = "\(raw)"
        }
        let special = text.isEmpty || text.unicodeScalars.contains { $0 == " " || $0 == "\"" || $0 == "\\" || $0 == "=" || $0.value < 0x20 || $0.value == 0x7f }
        guard special else { return text }
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            default: quoted.unicodeScalars.append(scalar.value < 0x20 || scalar.value == 0x7f ? "?" : scalar)
            }
        }
        return quoted + "\""
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown_\(state.rawValue)"
        }
    }
}

// File + console sink; all I/O on one serial queue. A file is closed before the next line would pass maxBytes
// (a longer line goes alone into its own file); a failed open drops file output, the console keeps the lines.
final class DiagSink {
    private let queue = DispatchQueue(label: "uk.lumenio.alvr.diag", qos: .utility)
    private let directory: URL
    private let maxBytes: Int
    private let now: () -> Date
    private let console: ((String) -> Void)?
    private var handle: FileHandle?
    private var written = 0
    private var fileFailed = false

    init(directory: URL, maxBytes: Int, now: @escaping () -> Date, console: ((String) -> Void)?) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.now = now
        self.console = console
    }

    func write(_ line: String) {
        queue.async { [self] in
            console?(line)
            let data = Data((line + "\n").utf8)
            if handle == nil || (written > 0 && written + data.count > maxBytes) {
                openNext()
            }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                written += data.count
            } catch {
                try? handle.close()
                self.handle = nil
                fileFailed = true
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func openNext() {
        try? handle?.close()
        handle = nil
        written = 0
        guard !fileFailed else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now())
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            fileFailed = true
            return
        }
        // O_EXCL: an existing name (same second) moves on to -1, -2, ...
        for n in 0..<1000 {
            let name = n == 0 ? "diag-\(stamp).log" : "diag-\(stamp)-\(n).log"
            let fd = open(directory.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                return
            }
            if errno != EEXIST { break }
        }
        fileFailed = true
    }
}

enum DiagStats {
    struct Summary: Equatable {
        let p50: Double
        let p95: Double
        let max: Double
    }

    // Nearest rank: the ceil(q * n)-th smallest sample.
    static func summary(_ values: [Double]) -> Summary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func rank(_ q: Double) -> Double { sorted[min(max(Int((q * Double(sorted.count)).rounded(.up)), 1), sorted.count) - 1] }
        return Summary(p50: rank(0.5), p95: rank(0.95), max: sorted[sorted.count - 1])
    }
}

// M6 per-second cadence and the M9 GPU window. frame() on the render thread, completed() from command buffer
// completion; drain() once per frame from the render thread returns a window once a second has passed.
final class DiagCadence {
    struct Window: Equatable {
        let frames, fresh, repeated, missed: Int
        let requestedMs: Double?
        let interval, presentDelta: DiagStats.Summary?
    }

    private let lock = NSLock()
    private var windowStartMs: Int?
    private var lastPresentNs: UInt64?
    private var intervals: [Double] = []
    private var presentDeltas: [Double] = []
    private var frames = 0
    private var fresh = 0
    private var missed = 0
    private var gpuMs: [Double] = []

    // presentNs: the drawable's presentation time; predictedNs: the frame's predictTiming() presentation time.
    func frame(presentNs: UInt64, predictedNs: UInt64, fresh isFresh: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastPresentNs, presentNs > last {
            intervals.append(Double(presentNs - last) / 1e6)
        }
        lastPresentNs = presentNs
        presentDeltas.append((Double(presentNs) - Double(predictedNs)) / 1e6)
        frames += 1
        if isFresh { fresh += 1 }
    }

    // late: GPU completion after the frame's presentation time (a missed deadline).
    func completed(gpuNs: UInt64, late: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if late { missed += 1 }
        if gpuNs > 0 && gpuMs.count < 4096 { gpuMs.append(Double(gpuNs) / 1e6) }
    }

    func drain(nowMs: Int, requestedHz: Double) -> Window? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = windowStartMs else {
            windowStartMs = nowMs
            return nil
        }
        guard nowMs - start >= 1000 || nowMs < start else { return nil }
        let window = Window(frames: frames, fresh: fresh, repeated: frames - fresh, missed: missed,
                            requestedMs: requestedHz > 0 ? 1000.0 / requestedHz : nil,
                            interval: DiagStats.summary(intervals), presentDelta: DiagStats.summary(presentDeltas))
        windowStartMs = nowMs
        intervals.removeAll(keepingCapacity: true)
        presentDeltas.removeAll(keepingCapacity: true)
        frames = 0
        fresh = 0
        missed = 0
        return window
    }

    func drainGpu() -> DiagStats.Summary? {
        lock.lock()
        defer { lock.unlock() }
        let summary = DiagStats.summary(gpuMs)
        gpuMs.removeAll(keepingCapacity: true)
        return summary
    }

    static func fields(_ w: Window) -> KeyValuePairs<String, Any> {
        func v(_ x: Double?) -> Any { x.map { $0 as Any } ?? "unavailable" }
        return ["requested_ms": v(w.requestedMs),
                "interval_p50_ms": v(w.interval?.p50), "interval_p95_ms": v(w.interval?.p95), "interval_max_ms": v(w.interval?.max),
                "present_delta_p50_ms": v(w.presentDelta?.p50), "present_delta_p95_ms": v(w.presentDelta?.p95),
                "present_delta_max_ms": v(w.presentDelta?.max),
                "frames": w.frames, "fresh": w.fresh, "repeated": w.repeated, "missed": w.missed]
    }
}
