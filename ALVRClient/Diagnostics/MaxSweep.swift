import Foundation

// Render-thread state only. Every point gets its own settle and measurement interval;
// late frames advance once, preserving a full measurement at the next point.
struct RQSchedule {
    enum Action: Equatable {
        case none, unsupported, set(Float), finish(Float, next: Float), restore(Float)
    }
    private var points: [Float] = []
    private var index = 0
    private var began: Int?
    private var previous: Float = 0
    private var done = false
    private(set) var active = false
    var step: Float? { active ? points[index] : nil }

    static func make(diagnostics: Bool, enabled: Bool) -> RQSchedule? {
        diagnostics && enabled ? RQSchedule() : nil
    }
    func measuring(now: Int) -> Bool { active && began.map { now - $0 >= 3000 } == true }
    mutating func tick(now: Int, enabled: Bool, streaming: Bool, supported: Bool, previous: Float, maximum: Float) -> Action {
        if active && (!enabled || streaming) {
            active = false; done = true
            return .restore(self.previous)
        }
        guard !done, enabled, !streaming else { return .none }
        guard supported else { done = true; return .unsupported }
        if !active {
            points = [0.5, 0.75, 1].filter { $0 <= maximum }
            guard !points.isEmpty else { done = true; return .none }
            self.previous = previous; began = now; active = true
            return .set(points[0])
        }
        guard let began, now - began >= 23000 else { return .none }
        let finished = points[index]
        index += 1
        self.began = now
        if index == points.count {
            active = false; done = true
            return .finish(finished, next: self.previous)
        }
        return .finish(finished, next: points[index])
    }
}

enum RQReport {
    static func start(defaultQuality: Float, maximum: Float) -> KeyValuePairs<String, Any> {
        ["default": defaultQuality, "max": maximum]
    }
    static func step(step: Float, actual: Float, drawable: Int, view: Int, width: Int, height: Int,
                     screen: String, physical: String, gpu: [Double], missed: Int, frames: Int, footprint: Double?) -> KeyValuePairs<String, Any> {
        let sorted = gpu.sorted()
        func percentile(_ q: Double) -> Any {
            sorted.isEmpty ? "unavailable" : sorted[max(0, Int(ceil(q * Double(sorted.count))) - 1)]
        }
        return ["step": step, "actual": actual, "drawable": drawable, "view": view, "tex_w": width, "tex_h": height,
                "rrm_screen": screen, "rrm_physical": physical, "gpu_ms_p50": percentile(0.5), "gpu_ms_p99": percentile(0.99),
                "missed_deadlines": missed, "frames": frames, "footprint_mb": footprint.map { $0 as Any } ?? "unavailable"]
    }
}

enum CodecAudit {
    enum Result { case status(Int32), refused, unavailable }
    static func lines(hardware: (String) -> Bool, session: (String) -> Result) -> [KeyValuePairs<String, Any>] {
        var lines: [KeyValuePairs<String, Any>] = ["hevc", "av1", "h264"].map { ["type": $0, "hw": hardware($0)] }
        for chroma in ["420", "422", "444"] {
            switch session(chroma) {
            case .status(let code):
                lines.append(["type": "hevc", "chroma": chroma, "bit_depth": 10, "session": code == 0 ? "ok" : String(code)])
            case .refused:
                lines.append(["type": "hevc", "chroma": chroma, "bit_depth": 10, "session": "unavailable", "refused_by_encoder": 1])
            case .unavailable:
                lines.append(["type": "hevc", "chroma": chroma, "bit_depth": 10, "session": "unavailable", "fixture_missing": 1])
            }
        }
        return lines
    }
}
