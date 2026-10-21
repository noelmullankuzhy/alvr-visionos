//
//  EyeDecodeStats.swift
//
// Pure logic (Foundation only) behind the per-eye decode windows: frame counters, the copy throttle and the
// HDR->SDR mapping. Unit tested on macOS: tests/swift/EyeDecodeStatsTests.swift.
//
import Foundation

// One eye's view of the decoded stream. Fed once per decoded frame (cheap, no pixels).
struct EyeDecodeCounters {
    static let gapFactor = 1.5
    // Arrival window is bounded: a decoder cannot legitimately deliver more than this in one second.
    private static let maxArrivals = 1_024

    var frameIntervalNs: UInt64
    private(set) var frames = 0       // distinct timestamps seen
    private(set) var gaps = 0         // jumps above 1.5x the interval, or timestamps going backwards
    private(set) var missing = 0      // frames those jumps skipped
    private(set) var repeats = 0      // a timestamp delivered again
    private(set) var lastIndex = -1   // decoded ordinal of the last new frame
    private(set) var lastTimestampNs: UInt64?
    var maxNits: Double = 0           // of the last sampled frame; 0 when SDR or not yet sampled
    private var arrivals = [UInt64]()
    private var lastLogNs: UInt64?

    init(frameIntervalNs: UInt64) {
        self.frameIntervalNs = max(frameIntervalNs, 1)
    }

    var arrivalsKept: Int { arrivals.count }

    mutating func record(timestampNs: UInt64, nowNs: UInt64) {
        if let last = lastTimestampNs {
            if timestampNs == last {
                repeats += 1
                return
            }
            if timestampNs < last {
                gaps += 1
            } else {
                let delta = timestampNs - last
                if Double(delta) > Self.gapFactor * Double(frameIntervalNs) {
                    gaps += 1
                    missing += max(1, Int((Double(delta) / Double(frameIntervalNs)).rounded()) - 1)
                }
            }
        }
        lastTimestampNs = timestampNs
        frames += 1
        lastIndex += 1
        arrivals.append(nowNs)
        trim(nowNs: nowNs)
    }

    private mutating func trim(nowNs: UInt64) {
        var drop = 0
        while drop < arrivals.count && (!Self.inLastSecond(arrivals[drop], nowNs) || arrivals.count - drop > Self.maxArrivals) { drop += 1 }
        if drop > 0 { arrivals.removeFirst(drop) }
    }

    private static func inLastSecond(_ arrival: UInt64, _ nowNs: UInt64) -> Bool {
        arrival + 1_000_000_000 > nowNs
    }

    // New frames per second over the last 1 s.
    func fps(nowNs: UInt64) -> Double {
        Double(arrivals.filter { Self.inLastSecond($0, nowNs) }.count)
    }

    // The once-per-second line for the server log; nil when not due.
    mutating func logLine(eye: String, nowNs: UInt64) -> String? {
        if let last = lastLogNs, nowNs < last + 1_000_000_000 { return nil }
        lastLogNs = nowNs
        return "EYEWIN eye=\(eye) frames=\(frames) fps=\(String(format: "%.1f", fps(nowNs: nowNs)))"
            + " gaps=\(gaps) repeats=\(repeats) max_nits=\(Int(maxNits.rounded()))"
    }
}

// Admits at most one copy per interval.
struct EyeCopyGate {
    let minIntervalNs: UInt64
    private var lastNs: UInt64?

    init(minIntervalNs: UInt64) { self.minIntervalNs = minIntervalNs }

    mutating func admit(nowNs: UInt64) -> Bool {
        if let last = lastNs, nowNs < last + minIntervalNs { return false }
        lastNs = nowNs
        return true
    }
}

// Window mapping for PQ: linear nits against SDR reference white, clipped, sRGB encoded. BT.2020 values are
// shown as-is (no gamut mapping): this view answers "is the decode right", not "is the colour exact".
enum EyeToneMap {
    static let referenceWhiteNits = 203.0

    static func sdrByte(nits: Double) -> UInt8 {
        let lin = min(max(nits / referenceWhiteNits, 0), 1)
        let enc = lin <= 0.0031308 ? 12.92 * lin : 1.055 * pow(lin, 1 / 2.4) - 0.055
        return UInt8((enc * 255).rounded())
    }
}
