// SOURCES: ALVRClient/EyeDecodeStats.swift ALVRClient/GlobalSettings.swift ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift
import Foundation

@main enum EyeDecodeStatsTests {
    static let ms: UInt64 = 1_000_000
    static let interval: UInt64 = 10 * ms // 100 fps keeps the arithmetic exact

    static func main() throws {
        // Setting: simulator builds default on, device off (macOS test builds are not the simulator).
        expectEqual(GlobalSettings().eyeDecodeWindows, GlobalSettings.eyeDecodeWindowsDefault, "default follows the build")
        let legacy = try JSONDecoder().decode(GlobalSettings.self, from: Data("{\"hdrPQ\":true}".utf8))
        expectEqual(legacy.eyeDecodeWindows, GlobalSettings.eyeDecodeWindowsDefault, "legacy file gets the default")
        for value in [true, false] {
            var s = GlobalSettings()
            s.eyeDecodeWindows = value
            let back = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(s))
            expectEqual(back.eyeDecodeWindows, value, "explicit \(value) persists")
        }

        // Steady stream: no gaps, no repeats.
        var c = EyeDecodeCounters(frameIntervalNs: interval)
        for i in 0..<10 { c.record(timestampNs: UInt64(i) * interval, nowNs: UInt64(i) * interval) }
        expectEqual(c.frames, 10, "frames")
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
        expectEqual(c.frames, 1, "repeats are not frames")
        c.record(timestampNs: 15 * ms, nowNs: 20 * ms)
        expectEqual(c.gaps, 0, "gap is measured from the repeated timestamp")

        // Backwards timestamp counts as a gap (out of order) and continues from it.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        c.record(timestampNs: 100 * ms, nowNs: 0)
        c.record(timestampNs: 90 * ms, nowNs: 10 * ms)
        expectEqual(c.gaps, 1, "backwards is a gap")
        expectEqual(c.missing, 0, "backwards misses nothing")

        // fps over the last 1 s of arrivals.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        for i in 0..<150 { c.record(timestampNs: UInt64(i) * interval, nowNs: UInt64(i) * interval) } // 100 fps for 1.5 s
        expectEqual(Int(c.fps(nowNs: 149 * interval).rounded()), 100, "fps at 100")
        expectEqual(c.fps(nowNs: 149 * interval + 2_000 * ms), 0, "fps decays to 0 when frames stop")
        expect(c.arrivalsKept <= 1_024, "arrival window stays bounded")

        // Max nits of the last frame; log line once per second in the DIAG key=value style.
        c = EyeDecodeCounters(frameIntervalNs: interval)
        c.record(timestampNs: 0, nowNs: 0)
        c.maxNits = 1000.4
        expect(c.logLine(eye: "L", nowNs: 0) != nil, "first line is due")
        expect(c.logLine(eye: "L", nowNs: 999 * ms) == nil, "not again within 1 s")
        c.record(timestampNs: interval, nowNs: 1_000 * ms)
        expectEqual(c.logLine(eye: "R", nowNs: 1_000 * ms) ?? "",
                    "EYEWIN eye=R frames=2 fps=1.0 gaps=0 repeats=0 max_nits=1000", "line format")

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
