import Foundation

// Immutable attribution captured by asynchronous callbacks for one player item.
struct PQPlaybackContext {
    let clip, path: String
    func statusFields(status: Int, error: String) -> KeyValuePairs<String, Any> {
        ["path": path, "clip": clip, "status": status, "error": error]
    }
    func metadataErrorFields(_ error: String) -> KeyValuePairs<String, Any> {
        ["path": path, "clip": clip, "metadata_error": error]
    }
}

// tools/diag/clip-engine.swift: seven two-second levels, last level held on extension.
enum PQSchedule {
    static func step(time: Double, clip: String) -> Int {
        if clip.contains("split") {
            guard time.isFinite, time >= 0 else { return -1 }
            return Int(min(7, time / 5))
        }
        return step(time: time, isSteps: clip.contains("steps"))
    }

    static func step(time: Double, isSteps: Bool) -> Int {
        guard isSteps, time.isFinite, time >= 0 else { return -1 }
        return Int(min(6, time / 2))
    }
}

enum EDRLayout: String, CaseIterable {
    case onePercent = "1%", tenPercent = "10%", full = "100%", split, checkerboard
    struct Patch {
        let x, y, width, height: Double
        let value: Float
    }
    func patches(value: Float) -> [Patch] {
        if self == .split {
            return [Patch(x: 0, y: 0, width: 0.5, height: 1, value: 1),
                    Patch(x: 0.5, y: 0, width: 0.5, height: 1, value: value)]
        }
        if self == .checkerboard {
            return (0..<64).map { i in
                let column = i % 8, row = i / 8
                let bright = (column + row) % 2 != 0
                return Patch(x: Double(column) / 8, y: Double(row) / 8, width: 0.125, height: 0.125, value: bright ? value : 0)
            }
        }
        let side = sqrt(self == .onePercent ? 0.01 : self == .tenPercent ? 0.1 : 1)
        return [Patch(x: (1 - side) / 2, y: (1 - side) / 2, width: side, height: side, value: value)]
    }
}

struct EDRStep {
    static let values: [Float] = [0, 0.25, 0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 4]
    var startMs: Int
    var automatic: Bool
    var sustained = false
    private(set) var index = 0
    var value: Float { Self.values[index] }
    mutating func next(nowMs: Int) { index = (index + 1) % Self.values.count; startMs = nowMs }
    mutating func tick(nowMs: Int) -> Bool {
        guard automatic, nowMs - startMs >= (sustained ? 60000 : 4000) else { return false }
        next(nowMs: nowMs)
        return true
    }
    func fields(layout: EDRLayout) -> KeyValuePairs<String, Any> {
        ["step": index, "value": value, "layout": layout.rawValue, "mode": automatic ? "auto" : "manual", "hold_s": sustained ? 60 : 4]
    }
    func markFields(layout: EDRLayout) -> KeyValuePairs<String, Any> {
        ["mark": true, "value": value, "layout": layout.rawValue]
    }
}

// Only instantiated by the diagnostic window/scene; one lock for UI and compositor render thread.
final class EDRSession {
    static let shared = EDRSession()
    private let lock = NSLock()
    private var step = EDRStep(startMs: 0, automatic: false)
    private var layout = EDRLayout.onePercent
    private var dirty = true
    private var presented: (EDRStep, EDRLayout)?
    private var runID = UUID()
    var currentRun: UUID {
        lock.lock(); defer { lock.unlock() }
        return runID
    }
    func beginRun() {
        lock.lock(); defer { lock.unlock() }
        runID = UUID()
    }
    var currentValue: Float? {
        lock.lock(); defer { lock.unlock() }
        return presented?.0.value
    }
    func configure(layout: EDRLayout, automatic: Bool, sustained: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.layout = layout
        step.automatic = automatic; step.sustained = sustained; step.startMs = Diag.monotonicMs(); dirty = true
    }
    func next() {
        lock.lock(); defer { lock.unlock() }
        step.next(nowMs: Diag.monotonicMs()); dirty = true
    }
    func frame() -> [EDRLayout.Patch] {
        lock.lock(); defer { lock.unlock() }
        let now = Diag.monotonicMs()
        if dirty { step.startMs = now }
        let changed = step.tick(nowMs: now)
        if dirty || changed { Diag.log("edr", step.fields(layout: layout)); dirty = false }
        presented = (step, layout)
        return layout.patches(value: step.value)
    }
    func mark() {
        lock.lock(); defer { lock.unlock() }
        if let (step, layout) = presented { Diag.log("edr", step.markFields(layout: layout)) }
    }
}
