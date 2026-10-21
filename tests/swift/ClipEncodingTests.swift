// SOURCES: tools/diag/clip-policy.swift
import Foundation

@main enum ClipEncodingTests {
    static func main() throws {
        expectEqual(classifyClipCallback(status: 0, hasSample: false, frameDropped: false), .dropped, "success + nil sample is a drop")
        expectEqual(classifyClipCallback(status: 0, hasSample: false, frameDropped: true), .dropped, "flagged nil drop")
        expectEqual(classifyClipCallback(status: 0, hasSample: true, frameDropped: true), .dropped, "drop flag takes precedence over sample")
        expectEqual(classifyClipCallback(status: 0, hasSample: true, frameDropped: false), .encoded, "ordinary output")
        expectEqual(classifyClipCallback(status: -12903, hasSample: false, frameDropped: false), .failure(-12903), "encoder errors remain errors")
        expectEqual(classifyClipCallback(status: -12903, hasSample: true, frameDropped: true), .failure(-12903), "error takes precedence over drop")
        func output(_ rate: Double, _ drops: Int = 0) -> [String: Any] {
            ["achievedBitrate": rate, "frames": 180 - drops, "requestedFrames": 180, "droppedFrames": drops]
        }
        // Even a rate inside tolerance, below tolerance, or zero (ALL frames dropped)
        // must lower entropy rather than accept or raise the rate hint.
        for (rate, drops) in [(150e6, 1), (30e6, 12), (0.0, 180)] {
            var amplitudes: [Double] = [], hints: [Int] = [], discarded = 0
            let result = try calibrateClip(bitrate: 150_000_000, targeted: true, overload: false, encode: { amplitude, hint, limited in
                amplitudes.append(amplitude); hints.append(hint)
                expect(limited, "target applies data rate limit")
                return amplitudes.count == 1 ? output(rate, drops) : output(150e6)
            }, discard: { discarded += 1 })
            expectEqual(amplitudes, [1, 0.5], "drops force lower amplitude")
            expectEqual(hints, [150_000_000, 150_000_000], "drops never increase bitrate hint")
            expectEqual(discarded, 1, "incomplete trial removed")
            expectEqual(result["droppedFrames"] as? Int, 0, "only complete target published")
            expectEqual(result["frames"] as? Int, 180, "all requested frames published")
            expectEqual(result["encodeAttempts"] as? Int, 2, "retry counted")
            let history = result["calibration"] as! [[String: Any]]
            expectEqual(history[0]["droppedFrames"] as? Int, drops, "dropped trial remains visible in manifest")
        }
        var calls = 0, discarded = 0
        do {
            _ = try calibrateClip(bitrate: 300_000_000, targeted: true, overload: false, encode: { _, _, _ in
                calls += 1; return output(300e6, 1)
            }, discard: { discarded += 1 })
            expect(false, "never publish a target with persistent drops")
        } catch let error as ClipCalibrationFailure {
            expectEqual(error.droppedFrames, 1, "refusal retains dropped count")
        }
        expectEqual(calls, 8, "retry bound")
        expectEqual(discarded, 8, "all failed files removed")
        calls = 0
        let stress = try calibrateClip(bitrate: 150_000_000, targeted: false, overload: true, encode: { amplitude, _, limited in
            calls += 1; expect(!limited, "stress never enables DataRateLimits"); expectEqual(amplitude, 1, "stress remains full entropy")
            return output(900e6, 7)
        }, discard: { expect(false, "valid overload need not retry") })
        expectEqual(calls, 1, "stress keeps overload output")
        expectEqual(stress["droppedFrames"] as? Int, 7, "stress records drops")
        expectEqual(stress["rateMode"] as? String, "overload", "stress labelled")
        // Rate-only misses still follow the original bisection / hint correction.
        var rates = [300e6, 50e6, 150e6], amplitudes: [Double] = []
        _ = try calibrateClip(bitrate: 150_000_000, targeted: true, overload: false, encode: { amplitude, _, _ in
            amplitudes.append(amplitude); return output(rates.removeFirst())
        }, discard: {})
        expectEqual(amplitudes, [1, 0.5, 0.75], "rate-only bracket preserved")
        struct EncoderFailure: Error {}
        do {
            _ = try calibrateClip(bitrate: 150_000_000, targeted: true, overload: false, encode: { _, _, _ in throw EncoderFailure() }, discard: {})
            expect(false, "encoder error must propagate")
        } catch is EncoderFailure { expect(true, "real errors are not drop feedback") }
        finishTests("ClipEncoding")
    }
}
