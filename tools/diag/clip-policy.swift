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
