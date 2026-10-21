import Foundation

// Shared by the CLI and encoder-free tests. A successful callback may contain no image.
enum ClipCallbackResult: Equatable {
    case encoded, dropped, failure(Int32)
}
func classifyClipCallback(status: Int32, hasSample: Bool, frameDropped: Bool) -> ClipCallbackResult {
    if status != 0 { return .failure(status) }
    return frameDropped || !hasSample ? .dropped : .encoded
}

struct ClipCalibrationFailure: Error, CustomStringConvertible {
    let description: String
    let droppedFrames: Int
}

// Inject the encoder/file removal so the actual retry loop can be exercised without VT.
func calibrateClip(bitrate: Int, targeted: Bool, overload: Bool,
                   encode: (Double, Int, Bool) throws -> [String: Any], discard: () throws -> Void,
                   reportRetry: (Double, Int, Double) -> Void = { _, _, _ in }) throws -> [String: Any] {
    var amplitude = 1.0, lower = 0.0, upper = 1.0, encoderRate = bitrate, lastDrops = 0
    var history: [[String: Any]] = []
    for attempt in 1...(targeted ? 8 : 1) {
        var clip = try encode(amplitude, encoderRate, targeted)
        guard let achieved = clip["achievedBitrate"] as? Double, achieved.isFinite, achieved >= 0,
              let drops = clip["droppedFrames"] as? Int, drops >= 0,
              let frames = clip["frames"] as? Int, frames >= 0,
              let requested = clip["requestedFrames"] as? Int, requested > 0, frames + drops == requested else {
            throw ClipCalibrationFailure(description: "invalid encoder frame/bitrate accounting", droppedFrames: 0)
        }
        lastDrops = drops
        history.append(["noiseAmplitude": amplitude, "encoderBitrate": encoderRate,
                        "achievedBitrate": achieved, "droppedFrames": drops])
        clip["overload"] = overload; clip["rateLimited"] = targeted
        clip["rateMode"] = overload ? "overload" : (targeted ? "targeted" : "target-hint")
        clip["bitrateTolerance"] = 0.15; clip["encodeAttempts"] = attempt; clip["calibration"] = history
        // Drops take precedence over rate: even an ALL-dropped, zero-byte trial is over budget.
        if targeted && (drops > 0 || achieved > Double(bitrate) * 1.15) {
            upper = amplitude
            try discard(); reportRetry(achieved, drops, amplitude)
            amplitude = (lower + upper) / 2
            continue
        }
        guard frames > 0, achieved > 0, overload || drops == 0 else {
            try discard()
            throw ClipCalibrationFailure(description: "incomplete non-overload clip or no encoded frames; droppedFrames=\(drops)", droppedFrames: drops)
        }
        if !targeted || abs(achieved / Double(bitrate) - 1) <= 0.15 { return clip }
        try discard(); reportRetry(achieved, drops, amplitude)
        lower = amplitude
        if amplitude < upper { amplitude = (lower + upper) / 2 }
        else { encoderRate = Int(min(Double(Int.max / 4), Double(encoderRate) * min(2, Double(bitrate) / achieved))) }
    }
    throw ClipCalibrationFailure(description: "noise bitrate could not reach ±15% with zero drops after 8 encodes; droppedFrames=\(lastDrops); --stress is uncapped overload", droppedFrames: lastDrops)
}

func pqCode(_ nits: Double) -> UInt16 {
    let p = pow(nits / 10000, 2610.0 / 16384)
    let pq = pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)
    return UInt16((64 + 876 * pq).rounded())
}

// Integer P010 layout and a tiny bitmap alphabet keep labels independent of RGB conversion.
struct SplitClip {
    static let levels: [Double] = [100, 203, 300, 400, 600, 800, 1000, 203]
    let referenceNits: Double
    func gap(width: Int) -> Range<Int> {
        let halfGap = max(1, Int((Double(width) * 0.01).rounded()))
        return (width / 2 - halfGap)..<(width / 2 + halfGap)
    }
    static func digitHeight(height: Int) -> Int { 7 * max(1, Int(ceil(Double(height) * 0.08 / 7))) }
    static func bandHeight(height: Int) -> Int { digitHeight(height: height) + 2 * max(1, height / 50) }
    func patchCode(x: Int, width: Int, step: Int) -> UInt16 {
        if gap(width: width).contains(x) { return 64 }
        return pqCode(x < width / 2 ? referenceNits : Self.levels[min(7, step)])
    }
    func schedule(seconds: Double) -> [[String: Double]] {
        Self.levels.enumerated().filter { Double($0.offset * 5) < seconds }.map {
            let start = Double($0.offset * 5)
            return ["startSeconds": start, "durationSeconds": $0.offset == 7 ? seconds - start : min(5, seconds - start),
                    "nits": $0.element, "lumaCode": Double(pqCode($0.element)),
                    "referenceNits": referenceNits, "referenceLumaCode": Double(pqCode(referenceNits))]
        }
    }
    func labelRows(width: Int, height: Int, step: Int) -> [[UInt16]] {
        let scale = Self.digitHeight(height: height) / 7
        let padding = max(1, height / 50)
        var rows = Array(repeating: Array(repeating: UInt16(64 << 6), count: width), count: Self.bandHeight(height: height))
        let glyphs: [Character: [String]] = [
            "0": ["11111","10001","10011","10101","11001","10001","11111"],
            "1": ["00100","01100","00100","00100","00100","00100","01110"],
            "2": ["11110","00001","00001","11110","10000","10000","11111"],
            "3": ["11110","00001","00001","01110","00001","00001","11110"],
            "4": ["10010","10010","10010","11111","00010","00010","00010"],
            "5": ["11111","10000","10000","11110","00001","00001","11110"],
            "6": ["01111","10000","10000","11110","10001","10001","01110"],
            "7": ["11111","00001","00010","00100","01000","01000","01000"],
            "8": ["01110","10001","10001","01110","10001","10001","01110"],
            "9": ["01110","10001","10001","01111","00001","00001","11110"],
            "R": ["11110","10001","10001","11110","10100","10010","10001"],
            "E": ["11111","10000","10000","11110","10000","10000","11111"],
            "F": ["11111","10000","10000","11110","10000","10000","10000"],
            ".": ["00000","00000","00000","00000","00000","00100","00100"]]
        let ref = referenceNits == referenceNits.rounded() ? String(Int(referenceNits)) : String(referenceNits)
        for (half, text) in ["REF " + ref, String(Int(Self.levels[min(7, step)]))].enumerated() {
            let origin = half * width / 2 + (width / 2 - (text.count * 6 - 1) * scale) / 2
            for (index, character) in text.enumerated() {
                guard let glyph = glyphs[character] else { continue }
                for (gy, line) in glyph.enumerated() {
                    for (gx, bit) in line.enumerated() where bit == "1" {
                        for dy in 0..<scale { for dx in 0..<scale {
                            let x = origin + (index * 6 + gx) * scale + dx
                            if x >= half * width / 2 && x < (half + 1) * width / 2 && !gap(width: width).contains(x) {
                                rows[padding + gy * scale + dy][x] = pqCode(203) << 6
                            }
                        } }
                    }
                }
            }
        }
        return rows
    }
}
