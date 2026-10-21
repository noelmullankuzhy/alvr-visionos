// SOURCES: ALVRClient/EyeDecodeStats.swift ALVRClient/GlobalSettings.swift ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift
import Foundation

@main enum EyeDecodeStatsTests {
    static let ms: UInt64 = 1_000_000
    static let interval: UInt64 = 10 * ms // 100 fps keeps the arithmetic exact

    static func main() throws {
        // Setting: simulator builds default on, device off (macOS test builds are not the simulator).
        // Literal expectation, not the constant against itself: on for the simulator, off otherwise.
#if targetEnvironment(simulator)
        let expectedDefault = true
#else
        let expectedDefault = false
#endif
        expectEqual(GlobalSettings.eyeDecodeWindowsDefault, expectedDefault, "default is on only for the simulator")
        expectEqual(GlobalSettings().eyeDecodeWindows, expectedDefault, "new settings get the default")
        let legacy = try JSONDecoder().decode(GlobalSettings.self, from: Data("{\"hdrPQ\":true}".utf8))
        expectEqual(legacy.eyeDecodeWindows, expectedDefault, "legacy file gets the default")
        for value in [true, false] {
            var s = GlobalSettings()
            s.eyeDecodeWindows = value
            let back = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(s))
            expectEqual(back.eyeDecodeWindows, value, "explicit \(value) persists")
        }

        // Steady stream: no gaps, no repeats.
        var c = EyeDecodeCounters(frameIntervalNs: interval)
        for i in 0..<10 { c.record(timestampNs: UInt64(i) * interval, nowNs: UInt64(i) * interval) }
        expectEqual(c.decoded, 10, "decoded")
        expectEqual(c.unique, 10, "unique")
        expectEqual(c.stalls, 0, "steady stalls")
        expectEqual(c.gaps, 0, "steady gaps")
        expectEqual(c.repeats, 0, "steady repeats")
        expectEqual(c.lastIndex, 9, "index is the decoded ordinal")

        // 1.5x is the threshold: 1.5x is fine, above it is a gap with the missing count.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        c.record(timestampNs: 0, nowNs: 0)
        c.record(timestampNs: 15 * ms, nowNs: 15 * ms)
        expectEqual(c.gaps, 0, "exactly 1.5x is not a gap")
        c.record(timestampNs: 15 * ms + 16 * ms, nowNs: 31 * ms)
        expectEqual(c.gaps, 1, "1.6x is a gap")
        expectEqual(c.missing, 1, "one frame missing")
        c.record(timestampNs: 31 * ms + 40 * ms, nowNs: 71 * ms)
        expectEqual(c.gaps, 2, "4x is a gap")
        expectEqual(c.missing, 4, "three more missing")

        // Repeats: same timestamp again; a repeat is not a gap, and is not a new frame shown.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        c.record(timestampNs: 5 * ms, nowNs: 5 * ms)
        c.record(timestampNs: 5 * ms, nowNs: 10 * ms)
        c.record(timestampNs: 5 * ms, nowNs: 15 * ms)
        expectEqual(c.repeats, 2, "repeats")
        expectEqual(c.gaps, 0, "repeat is no gap")
        expectEqual(c.unique, 1, "repeats are not unique")
        expectEqual(c.decoded, 3, "repeats are still decoded outputs")
        c.record(timestampNs: 15 * ms, nowNs: 20 * ms)
        expectEqual(c.gaps, 0, "gap is measured from the repeated timestamp")

        // Backwards timestamp counts as a gap (out of order) and continues from it.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        c.record(timestampNs: 100 * ms, nowNs: 0)
        c.record(timestampNs: 90 * ms, nowNs: 10 * ms)
        expectEqual(c.gaps, 1, "backwards is a gap")
        expectEqual(c.missing, 0, "backwards misses nothing")

        // Rates over the last 1 s of decoder outputs.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        for i in 0..<150 { c.record(timestampNs: UInt64(i) * interval, nowNs: UInt64(i) * interval) } // 100 fps for 1.5 s
        expectEqual(Int(c.decodedFps(nowNs: 149 * interval).rounded()), 100, "decoded fps at 100")
        expectEqual(Int(c.uniqueFps(nowNs: 149 * interval).rounded()), 100, "unique fps at 100")
        expectEqual(c.decodedFps(nowNs: 149 * interval + 2_000 * ms), 0, "rate decays to 0 when frames stop")
        expect(c.rateKept <= 1_024, "rate window stays bounded")

        // The simulator case: 100 outputs/s, one new timestamp every 4th output (pose cadence 25/s, 40 ms apart).
        // A 66 ms sampler (shown) and the log must not change what decode counted.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        var sampled = c
        var lines = [String]()
        for i in 0..<200 {
            let now = UInt64(i) * interval
            let ts = UInt64(i / 4) * 40 * ms
            c.record(timestampNs: ts, nowNs: now)
            sampled.record(timestampNs: ts, nowNs: now)
            if i % 7 == 0 { sampled.recordShown(nowNs: now) } // ~70 ms sampler
            if let line = sampled.logLine(eye: "L", nowNs: now) { lines.append(line) }
        }
        expectEqual(sampled.decoded, c.decoded, "sampler leaves decoded alone")
        expectEqual(sampled.unique, c.unique, "sampler leaves unique alone")
        expectEqual(sampled.gaps, c.gaps, "sampler leaves gaps alone")
        expectEqual(sampled.repeats, c.repeats, "sampler leaves repeats alone")
        expectEqual(c.decoded, 200, "all outputs decoded")
        expectEqual(c.unique, 50, "one new timestamp per 4 outputs")
        expectEqual(c.repeats, 150, "three repeats per new timestamp")
        expectEqual(c.gaps, 49, "40 ms steps are 4x the interval: every step is a gap")
        expectEqual(c.missing, 49 * 3, "three frame intervals missing per step")
        expectEqual(c.stalls, 0, "outputs arrive every interval: no stalls")
        expectEqual(Int(c.decodedFps(nowNs: 199 * interval)), 100, "decoded fps counts outputs, not timestamps")
        expectEqual(Int(c.uniqueFps(nowNs: 199 * interval)), 25, "unique fps counts timestamps")
        expect(sampled.shownFps(nowNs: 199 * interval) < 20, "shown fps is the sampler's own rate")
        expectEqual(lines.count, 2, "one log line per second")

        // A stalled decoder: one output arrives 40 ms late.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        c.record(timestampNs: 0, nowNs: 0)
        c.record(timestampNs: interval, nowNs: 10 * ms)
        c.record(timestampNs: 2 * interval, nowNs: 50 * ms)
        expectEqual(c.stalls, 1, "late output is a stall")

        // Max nits of the last frame; log line once per second in the DIAG key=value style.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        c.record(timestampNs: 0, nowNs: 0)
        c.maxNits = 1000.4
        expect(c.logLine(eye: "L", nowNs: 0) != nil, "first line is due")
        expect(c.logLine(eye: "L", nowNs: 999 * ms) == nil, "not again within 1 s")
        c.record(timestampNs: interval, nowNs: 1_000 * ms)
        c.recordShown(nowNs: 1_000 * ms)
        expectEqual(c.logLine(eye: "R", nowNs: 1_000 * ms) ?? "",
                    "EYEWIN eye=R decoded=2 decoded_fps=1.0 unique=2 unique_fps=1.0 gaps=0 missing=0 repeats=0 stalls=1 shown_fps=1.0 max_nits=1000",
                    "line format")

        // Copy gate: one admit per 66 ms.
        var gate = EyeCopyGate(minIntervalNs: 66 * ms)
        expect(gate.admit(nowNs: 1_000 * ms), "first admitted")
        expect(!gate.admit(nowNs: 1_065 * ms), "65 ms later rejected")
        expect(gate.admit(nowNs: 1_066 * ms), "66 ms later admitted")
        expect(!gate.admit(nowNs: 1_067 * ms), "rejected right after")

        // SDR mapping: clip-linear against reference white, sRGB encoded.
        expectEqual(EyeToneMap.sdrByte(nits: 0), 0, "black")
        expectEqual(EyeToneMap.sdrByte(nits: 203), 255, "reference white is full scale")
        expectEqual(EyeToneMap.sdrByte(nits: 10_000), 255, "highlights clip")
        expectEqual(EyeToneMap.sdrByte(nits: -5), 0, "negative clamps")
        expect(EyeToneMap.sdrByte(nits: 20) > 0 && EyeToneMap.sdrByte(nits: 20) < EyeToneMap.sdrByte(nits: 100), "monotonic")

        finishTests("EyeDecodeStats")
    }
}
