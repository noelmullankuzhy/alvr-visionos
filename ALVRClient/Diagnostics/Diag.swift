//
//  Diag.swift
//
// Diagnostics core (GM decision 65). With the Diagnostics setting or ALVR_DIAG on, `Diag.log(topic, [key: value])` writes
//   DIAG <topic> t_ms=<monotonic ms> k=v ...
// to alvr_log at Info and to Documents/diag/diag-<UTC stamp>.log (a new file before one would pass 20 MB), on a serial
// queue off the calling thread. Off: no directory, no file, and the fields are never built (autoclosure).
// Values with spaces, quotes, backslashes, control characters or = are quoted and escaped; keys keep [A-Za-z0-9_.].
// File errors (e.g. a handle revoked while suspended) drop lines and retry the open each second; the first line
// after recovery reports how many were dropped. Diag.background runs percentiles, formatting and resource queries
// on the Diag queue, so render threads only append to bounded buffers (DiagCadence) and check a DiagSchedule.
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

    static func capture<T>(enabled: Bool, _ value: @autoclosure () -> T) -> T? {
        enabled ? value() : nil
    }

    static func enabled(environment: [String: String], setting: Bool) -> Bool {
        setting || ["1", "true", "yes", "on"].contains(environment[envKey]?.lowercased() ?? "")
    }

    // Off creates nothing; on opens the sink once per process (later calls are ignored).
    static func start(enabled: Bool, directory: URL, console: ((String) -> Void)?) {
        guard enabled, sink == nil else { return }
        sink = DiagSink(directory: directory, maxBytes: maxFileBytes, now: { Date() }, console: console)
    }

    static func log(_ topic: String, tMs: Int? = nil, _ fields: @autoclosure () -> KeyValuePairs<String, Any>) {
        guard let sink else { return }
        let values = fields()
        if topic == "corner" {
            let dict = Dictionary(values.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
            if let eye = dict["eye"] as? String, let pct = dict["ring_pct"] as? Int,
               let degrees = dict["pos_deg"].flatMap({ Double(String(describing: $0)) }) {
                DiagCaptureRequests.shared.mark(eye: eye, spoke: 0, pct: pct, positionDegrees: degrees)
            }
        }
        sink.write(line(topic: topic, tMs: tMs ?? monotonicMs(), fields: values))
    }

    // Work for the Diag queue (off when Diagnostics is off: never queued).
    static func background(_ work: @escaping () -> Void) {
        sink?.async(work)
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
// (a longer line goes alone into its own file). A failed open or write drops the line and retries the open at most
// once per retryInterval; the console keeps every line.
final class DiagSink {
    static let retryInterval: TimeInterval = 1
    private let queue = DispatchQueue(label: "uk.lumenio.alvr.diag", qos: .utility)
    private let directory: URL
    private let maxBytes: Int
    private let now: () -> Date
    private let console: ((String) -> Void)?
    private let opener: (String) -> Int32
    private var handle: FileHandle?
    private var written = 0
    private var retryAt: Date?
    private var dropped = 0

    // opener: open(2) with O_CREAT | O_EXCL; replaceable to simulate suspension in tests.
    init(directory: URL, maxBytes: Int, now: @escaping () -> Date, console: ((String) -> Void)?, opener: ((String) -> Int32)? = nil) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.now = now
        self.console = console
        self.opener = opener ?? { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
    }

    func write(_ line: String) {
        queue.async { [self] in
            console?(line)
            writeFile(Data((line + "\n").utf8))
        }
    }

    func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func flush() {
        queue.sync {}
    }

    private func writeFile(_ data: Data) {
        if handle == nil || (written > 0 && written + data.count > maxBytes) {
            if handle == nil, let retryAt, now() < retryAt {
                dropped += 1
                return
            }
            openNext()
            guard handle != nil else { return fail() }
            retryAt = nil
            if dropped > 0 {
                let count = dropped
                dropped = 0
                guard append(Data("DIAG diag t_ms=\(Diag.monotonicMs()) file_recovered=true dropped_lines=\(count)\n".utf8)) else {
                    dropped = count
                    return fail()
                }
            }
        }
        if !append(data) { fail() }
    }

    private func fail() {
        dropped += 1
        retryAt = now().addingTimeInterval(Self.retryInterval)
    }

    private func append(_ data: Data) -> Bool {
        guard let handle else { return false }
        do {
            try handle.write(contentsOf: data)
            written += data.count
            return true
        } catch {
            try? handle.close()
            self.handle = nil
            return false
        }
    }

    private func openNext() {
        try? handle?.close()
        handle = nil
        written = 0
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now())
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        // O_EXCL: an existing name (same second) moves on to -1, -2, ...
        for n in 0..<1000 {
            let name = n == 0 ? "diag-\(stamp).log" : "diag-\(stamp)-\(n).log"
            let fd = opener(directory.appendingPathComponent(name).path)
            if fd >= 0 {
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                return
            }
            if errno != EEXIST { return }
        }
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

// Periodic sampling on a monotonic ms clock without overflow: the first call fires (fireOnFirst) or only starts the
// period; a clock that steps back fires and restarts the period.
struct DiagSchedule {
    let periodMs: Int
    let fireOnFirst: Bool
    private var lastMs: Int?

    init(periodMs: Int, fireOnFirst: Bool) {
        self.periodMs = periodMs
        self.fireOnFirst = fireOnFirst
    }

    mutating func due(nowMs: Int) -> Bool {
        guard let last = lastMs else {
            lastMs = nowMs
            return fireOnFirst
        }
        if nowMs >= last {
            let elapsed = nowMs.subtractingReportingOverflow(last)
            guard elapsed.overflow || elapsed.partialValue >= periodMs else { return false }
        }
        lastMs = nowMs
        return true
    }
}

// M6 per-second cadence and the M9 GPU samples. The render thread calls frame() and take(), command buffer completion
// calls completed(); each is O(1) under the lock, appending to buffers preallocated at `capacity` (samples beyond it
// are dropped and counted in overflow; GPU samples beyond it are dropped). window() and the percentiles run on the
// Diag queue.
// Times: targetNs is the drawable's frameTiming.presentationTime, the compositor's target for this frame, and
// predictedNs the frame's predictTiming() presentation time, both on the layer clock; the actual photon time is not
// exposed by CompositorServices and is logged as unavailable. Command buffer times are host times, moved to the layer
// clock with the offset sampled on the render thread (layer now - host now).
final class DiagCadence {
    final class Raw {
        var targetIntervalsMs: [Double]
        var targetMinusPredictedMs: [Double]
        var frames = 0, fresh = 0, repeated = 0, blank = 0, missedRenderDeadline = 0, callbackAfterTarget = 0, overflow = 0
        var clockOffsetMs: Double?

        init(capacity: Int) {
            targetIntervalsMs = []
            targetIntervalsMs.reserveCapacity(capacity)
            targetMinusPredictedMs = []
            targetMinusPredictedMs.reserveCapacity(capacity)
        }
    }

    struct Window: Equatable {
        let frames, fresh, repeated, blank, missedRenderDeadline, callbackAfterTarget, overflow: Int
        let requestedMs: Double?
        let targetInterval, targetMinusPredicted: DiagStats.Summary?
        let clockOffsetMs: Double?
    }

    private let capacity: Int
    private let windows: DiagDoubleBuffer<Raw>
    private let gpu: DiagDoubleBuffer<DiagSamples>
    private var lastTargetNs: UInt64?
    private var lastSourceId: UInt64?

    init(capacity: Int = 1024) {
        self.capacity = max(capacity, 1)
        windows = DiagDoubleBuffer(Raw(capacity: self.capacity), Raw(capacity: self.capacity))
        gpu = DiagDoubleBuffer(DiagSamples(capacity: self.capacity), DiagSamples(capacity: self.capacity))
    }

    // sourceId: the video frame actually encoded into this frame's drawables; nil when none was (idle, or rejected).
    func frame(targetNs: UInt64, predictedNs: UInt64, sourceId: UInt64?, clockOffsetNs offset: Int64) {
        windows.withActive { raw in
            if let last = lastTargetNs, targetNs > last {
                if !Self.append(&raw.targetIntervalsMs, Double(targetNs - last) / 1e6, capacity) { raw.overflow += 1 }
            }
            lastTargetNs = targetNs
            if !Self.append(&raw.targetMinusPredictedMs, (Double(targetNs) - Double(predictedNs)) / 1e6, capacity) { raw.overflow += 1 }
            raw.frames += 1
            if let sourceId {
                if sourceId == lastSourceId { raw.repeated += 1 } else { raw.fresh += 1 }
                lastSourceId = sourceId
            } else {
                raw.blank += 1
            }
            raw.clockOffsetMs = Double(offset) / 1e6
        }
    }

    // Offset belongs to this submission, even if another frame updates the layer/host clock mapping.
    func completed(gpuStartHostNs: UInt64, gpuEndHostNs: UInt64, renderingDeadlineNs: UInt64, targetNs: UInt64, callbackHostNs: UInt64, clockOffsetNs: Int64) {
        let offset = Double(clockOffsetNs)
        windows.withActive { raw in
            if gpuEndHostNs > gpuStartHostNs && gpuStartHostNs > 0 {
                if Double(gpuEndHostNs) + offset > Double(renderingDeadlineNs) { raw.missedRenderDeadline += 1 }
                gpu.withActive { _ = Self.append(&$0.values, Double(gpuEndHostNs - gpuStartHostNs) / 1e6, capacity) }
            }
            if Double(callbackHostNs) + offset > Double(targetNs) { raw.callbackAfterTarget += 1 }
        }
    }

    // A slow consumer retains its buffer; skip the swap until it returns rather than allocating on render.
    func take() -> Raw? { windows.take() }
    func takeGpu() -> DiagSamples? { gpu.take() }
    func recycle(_ raw: Raw) {
        windows.recycle(raw) {
            $0.targetIntervalsMs.removeAll(keepingCapacity: true)
            $0.targetMinusPredictedMs.removeAll(keepingCapacity: true)
            $0.frames = 0; $0.fresh = 0; $0.repeated = 0; $0.blank = 0
            $0.missedRenderDeadline = 0; $0.callbackAfterTarget = 0; $0.overflow = 0; $0.clockOffsetMs = nil
        }
    }
    func recycleGpu(_ samples: DiagSamples) { gpu.recycle(samples) { $0.values.removeAll(keepingCapacity: true) } }

    private static func append(_ buffer: inout [Double], _ value: Double, _ capacity: Int) -> Bool {
        guard buffer.count < capacity else { return false }
        buffer.append(value)
        return true
    }

    static func window(_ raw: Raw, requestedHz: Double) -> Window {
        Window(frames: raw.frames, fresh: raw.fresh, repeated: raw.repeated, blank: raw.blank,
               missedRenderDeadline: raw.missedRenderDeadline, callbackAfterTarget: raw.callbackAfterTarget, overflow: raw.overflow,
               requestedMs: requestedHz > 0 ? 1000.0 / requestedHz : nil,
               targetInterval: DiagStats.summary(raw.targetIntervalsMs), targetMinusPredicted: DiagStats.summary(raw.targetMinusPredictedMs),
               clockOffsetMs: raw.clockOffsetMs)
    }

    static func fields(_ w: Window) -> KeyValuePairs<String, Any> {
        func v(_ x: Double?) -> Any { x.map { $0 as Any } ?? "unavailable" }
        return ["requested_interval_ms": v(w.requestedMs),
                "target_interval_p50_ms": v(w.targetInterval?.p50), "target_interval_p95_ms": v(w.targetInterval?.p95),
                "target_interval_max_ms": v(w.targetInterval?.max),
                "target_minus_predicted_p50_ms": v(w.targetMinusPredicted?.p50), "target_minus_predicted_p95_ms": v(w.targetMinusPredicted?.p95),
                "target_minus_predicted_max_ms": v(w.targetMinusPredicted?.max), "actual_presentation": "unavailable",
                "frames": w.frames, "fresh": w.fresh, "repeated": w.repeated, "blank": w.blank,
                "missed_render_deadline": w.missedRenderDeadline, "callback_after_target": w.callbackAfterTarget,
                "clock_offset_ms": v(w.clockOffsetMs), "overflow": w.overflow]
    }
}

// Two owned, preallocated snapshots. Only the producer mutates active; a consumer returns its lease after logging.
// The reset happens on the consumer, and no collection is copied during a swap (avoids Array copy-on-write).
final class DiagDoubleBuffer<Value> {
    private let lock = NSLock()
    private var active: Value
    private var spare: Value?
    init(_ first: Value, _ second: Value) { active = first; spare = second }
    func withActive(_ body: (Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(active) }
    func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let next = spare else { return nil }
        let result = active; active = next; spare = nil
        return result
    }
    func recycle(_ value: Value, reset: (Value) -> Void) {
        reset(value)
        lock.lock(); defer { lock.unlock() }
        spare = value
    }
}

final class DiagSamples {
    var values: [Double] = []
    init(capacity: Int) { values.reserveCapacity(capacity) }
}

// Bounded compositor view/map snapshots: storage is shared with the Foundation-only allocation regression test.
final class DiagDrawableSnapshot<View, Map> {
    var views: [View] = []
    var maps: [Map] = []
    init() { views.reserveCapacity(32); maps.reserveCapacity(64) }
    func reset() { views.removeAll(keepingCapacity: true); maps.removeAll(keepingCapacity: true) }
}

// Process-wide capture admission, also fed by the existing corner mark log event.
// Marks are bounded and retain their event state even when several arrive between frames.
final class DiagCaptureRequests {
    struct Request {
        let number: Int
        let reason: String   // start_timer, corner_mark (idle); request_file, after_ms (streaming)
        let eye: String?
        let spoke: Int?
        let pct: Int?
        let positionDegrees: Double?
    }
    static let shared = DiagCaptureRequests(acceptsMarks: false)
    private let lock = NSLock()
    private var acceptsMarks: Bool
    init(acceptsMarks: Bool = true) { self.acceptsMarks = acceptsMarks }

    func setAcceptsMarks(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        acceptsMarks = enabled
        if !enabled { marks.removeAll(keepingCapacity: true) }
    }

    private var firstIdleMs: Int?
    private var firstStreamMs: Int?
    private var afterMs: Int?
    private var afterTaken = false
    private var filePending = false
    private var timerTaken = false
    private var count = 0
    private var marks: [(String, Int, Int, Double?)] = []

    func mark(eye: String, spoke: Int, pct: Int, positionDegrees: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if acceptsMarks && count + marks.count < 24 { marks.append((eye, spoke, pct, positionDegrees)) }
    }

    // Streaming triggers. Both only ever fire on a frame where stream content was composited (`streamFrame`).
    func configureAfterMs(_ ms: Int?) {
        lock.lock(); defer { lock.unlock() }
        afterMs = ms
        firstStreamMs = nil; afterTaken = false   // a new session (reconnect, immersive space reopened) starts a new stream
    }

    // Bounded: any number of requests before the next stream frame collapse to one capture.
    func requestStreaming() {
        lock.lock(); defer { lock.unlock() }
        filePending = true
    }

    var streamingPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return filePending
    }

    func take(nowMs: Int, idle: Bool, streamFrame: Bool = false) -> Request? {
        lock.lock(); defer { lock.unlock() }
        guard count < 24 else { return nil }
        guard idle else {
            guard streamFrame else { return nil }
            if firstStreamMs == nil { firstStreamMs = nowMs }
            let reason: String
            if filePending {
                filePending = false; reason = "request_file"
            } else if let afterMs, !afterTaken, nowMs - firstStreamMs! >= afterMs {
                afterTaken = true; reason = "after_ms"
            } else {
                return nil
            }
            count += 1
            return Request(number: count, reason: reason, eye: nil, spoke: nil, pct: nil, positionDegrees: nil)
        }
        firstStreamMs = nil; afterTaken = false   // idle = no stream: the next stream gets its own after_ms capture
        if firstIdleMs == nil { firstIdleMs = nowMs }
        var mark: (String, Int, Int, Double?)?
        if !marks.isEmpty {
            mark = marks.removeFirst()
        } else if !timerTaken, nowMs - firstIdleMs! >= 3000 {
            timerTaken = true
        } else {
            return nil
        }
        count += 1
        return Request(number: count, reason: mark == nil ? "start_timer" : "corner_mark", eye: mark?.0, spoke: mark?.1, pct: mark?.2, positionDegrees: mark?.3)
    }
}

// One capture in flight: next() hands out a request only when the previous capture has finished writing. A request that
// arrives meanwhile stays pending (not dropped) and is reported as .busy so the session can log why nothing happened.
final class DiagCaptureGate {
    enum Outcome {
        case none
        case request(DiagCaptureRequests.Request)
        case busy(pendingStreaming: Bool)
        case waiting(String)
    }
    let requests: DiagCaptureRequests
    private let lock = NSLock()
    private var busy = false
    // With a slot: wait (requests stay pending) while another readback holds it; hold it from a request to finished().
    private let slot: DiagReadbackSlot?
    init(requests: DiagCaptureRequests, slot: DiagReadbackSlot? = nil) { self.requests = requests; self.slot = slot }

    func next(nowMs: Int, idle: Bool, streamFrame: Bool) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        if busy { return .busy(pendingStreaming: requests.streamingPending) }
        if let slot, !slot.acquire(Self.slotName) { return .waiting("readback_in_flight") }
        if let request = requests.take(nowMs: nowMs, idle: idle, streamFrame: streamFrame) {
            busy = true
            return .request(request)
        }
        slot?.release(Self.slotName)
        if !idle && !streamFrame && requests.streamingPending { return .waiting("no_stream_frame") }
        return .none
    }

    func finished() {
        lock.lock(); busy = false; slot?.release(Self.slotName); lock.unlock()
    }

    static let slotName = "frame_capture"
}

// One full drawable readback in flight per process (the frame-capture session and the resolution chart's auto capture
// each read back whole drawables, up to ~500 MB with foveation off): held from submit until the write finishes.
final class DiagReadbackSlot {
    static let shared = DiagReadbackSlot()
    private let lock = NSLock()
    private var owner: String?

    var holder: String? { lock.lock(); defer { lock.unlock() }; return owner }

    func acquire(_ who: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return false }
        owner = who
        return true
    }

    // Only the holder releases.
    func release(_ who: String) {
        lock.lock(); if owner == who { owner = nil }; lock.unlock()
    }
}

// Documents/diag/capture.request: any content; deleted when the request is taken. poll() is for a background timer (never
// the render thread) and touches the filesystem at most once per second. Diagnostics off (enabled: false) never looks.
final class DiagCaptureRequestFile {
    static let name = "capture.request"
    static let afterMsKey = "ALVR_DIAG_CAPTURE_AFTER_MS"
    let url: URL
    private let enabled: Bool
    private let exists: (URL) -> Bool
    private let remove: (URL) -> Void
    private var lastPollMs: Int?

    init(enabled: Bool, directory: URL,
         exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
         remove: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.enabled = enabled
        self.url = directory.appendingPathComponent(Self.name)
        self.exists = exists
        self.remove = remove
    }

    func poll(nowMs: Int) -> Bool {
        guard enabled else { return false }
        if let lastPollMs, nowMs - lastPollMs < 1000 { return false }
        lastPollMs = nowMs
        guard exists(url) else { return false }
        remove(url)
        return true
    }

    static func afterMs(environment: [String: String]) -> Int? {
        environment[afterMsKey].flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
    }
}
