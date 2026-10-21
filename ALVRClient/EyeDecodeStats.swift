//
//  EyeDecodeStats.swift
//
// Pure logic (Foundation only) behind the per-eye decode windows: frame counters, the copy throttle and the
// HDR->SDR mapping. Unit tested on macOS: tests/swift/EyeDecodeStatsTests.swift.
//
import Foundation

// Events per second over the last 1 s, bounded.
struct EyeRateWindow {
    private static let maxKept = 1_024 // no decoder or window delivers more than this in one second
    private var times = [UInt64]()

    var kept: Int { times.count }

    mutating func record(nowNs: UInt64) {
        times.append(nowNs)
        var drop = 0
        while drop < times.count && (!Self.inLastSecond(times[drop], nowNs) || times.count - drop > Self.maxKept) { drop += 1 }
        if drop > 0 { times.removeFirst(drop) }
    }

    func rate(nowNs: UInt64) -> Double {
        Double(times.filter { Self.inLastSecond($0, nowNs) }.count)
    }

    private static func inLastSecond(_ t: UInt64, _ nowNs: UInt64) -> Bool { t + 1_000_000_000 > nowNs }
}

// One eye's view of the decoded stream. record() runs once per decoder output (cheap, no pixels), never from the
// window sampler, so no counter below depends on how often the window copies pixels.
//
// Definitions (also in the overlay label and the EYEWIN line):
//   decoded  every decoder output;               decoded_fps its rate over 1 s
//   unique   outputs whose timestamp differs from the previous output's;   unique_fps its rate
//   repeat   output whose timestamp equals the previous output's
//   gap      unique output whose timestamp is > 1.5x the frame interval after the previous (or goes backwards);
//            missing = frames that jump skipped
//   stall    output arriving > 1.5x the frame interval after the previous output (wall clock)
//   shown_fps  window refreshes per second (the sampler), unrelated to the above
// The timestamp is the one the server echoes back (the pose it rendered for), so several outputs can share one when the
// stream runs faster than the client reports poses: repeats then describe the stream, and stalls show decode delivery.
struct EyeDecodeCounters {
    static let gapFactor = 1.5

    var frameIntervalNs: UInt64
    private(set) var decoded = 0
    private(set) var unique = 0
    private(set) var gaps = 0
    private(set) var missing = 0
    private(set) var repeats = 0
    private(set) var stalls = 0
    private(set) var lastIndex = -1   // decoded ordinal of the last output
    private(set) var lastTimestampNs: UInt64?
    var maxNits: Double = 0           // of the last sampled frame; 0 when not yet sampled
    private var decodedRate = EyeRateWindow()
    private var uniqueRate = EyeRateWindow()
    private var shownRate = EyeRateWindow()
    private var lastArrivalNs: UInt64?
    private var lastLogNs: UInt64?

    init(frameIntervalNs: UInt64) {
        self.frameIntervalNs = max(frameIntervalNs, 1)
    }

    var rateKept: Int { decodedRate.kept }

    mutating func record(timestampNs: UInt64, nowNs: UInt64) {
        decoded += 1
        lastIndex += 1
        decodedRate.record(nowNs: nowNs)
        if let last = lastArrivalNs, nowNs >= last, Double(nowNs - last) > Self.gapFactor * Double(frameIntervalNs) { stalls += 1 }
        lastArrivalNs = nowNs
        defer { lastTimestampNs = timestampNs }
        guard let last = lastTimestampNs else {
            unique += 1
            uniqueRate.record(nowNs: nowNs)
            return
        }
        if timestampNs == last {
            repeats += 1
            return
        }
        unique += 1
        uniqueRate.record(nowNs: nowNs)
        if timestampNs < last {
            gaps += 1
        } else if Double(timestampNs - last) > Self.gapFactor * Double(frameIntervalNs) {
            gaps += 1
            missing += max(1, Int((Double(timestampNs - last) / Double(frameIntervalNs)).rounded()) - 1)
        }
    }

    // The window drew a new image.
    mutating func recordShown(nowNs: UInt64) { shownRate.record(nowNs: nowNs) }

    func decodedFps(nowNs: UInt64) -> Double { decodedRate.rate(nowNs: nowNs) }
    func uniqueFps(nowNs: UInt64) -> Double { uniqueRate.rate(nowNs: nowNs) }
    func shownFps(nowNs: UInt64) -> Double { shownRate.rate(nowNs: nowNs) }

    // The once-per-second line for the server log; nil when not due.
    mutating func logLine(eye: String, nowNs: UInt64) -> String? {
        if let last = lastLogNs, nowNs < last + 1_000_000_000 { return nil }
        lastLogNs = nowNs
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        return "EYEWIN eye=\(eye) decoded=\(decoded) decoded_fps=\(f(decodedFps(nowNs: nowNs)))"
            + " unique=\(unique) unique_fps=\(f(uniqueFps(nowNs: nowNs))) gaps=\(gaps) missing=\(missing) repeats=\(repeats)"
            + " stalls=\(stalls) shown_fps=\(f(shownFps(nowNs: nowNs))) max_nits=\(Int(maxNits.rounded()))"
    }

    // Overlay text for the window label.
    static let definitions = "decoded=decoder outputs; unique=new timestamp; repeat=same timestamp as previous output; "
        + "gap=new timestamp >1.5x interval after previous; stall=output >1.5x interval after previous output"
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
