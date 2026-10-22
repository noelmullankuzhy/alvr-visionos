// SOURCES: ALVRClient/BrightTrace.swift ALVRClient/HDRPipeline.swift ALVRClient/ColourPipeline.swift
// Brightness trace core (BrightTrace.swift): grid math, transfer-exponent fit, levels, per-frame state annotation,
// jump detector, 1 Hz summary and the jsonl record encoding.
import Foundation

private func close(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

private func testGridMath() {
    let xs = BrightTrace.gridCoordinates(origin: 100, length: 160, count: 16)
    expectEqual(xs.count, 16, "16 grid columns")
    expect(close(xs.first, 105) && close(xs.last, 255), "cell centres: origin + (i + 0.5) * length / count")
    let points = BrightTrace.planePoints(width: 3840, height: 1920, eye: 1, eyes: 2)
    expectEqual(points.count, 256, "16x16 points per eye")
    expectEqual(points[0].x, 1920 + 60, "right eye starts in the right half")
    expectEqual(points[0].y, 60, "first row at a half cell")
    expectEqual(points[255].x, 1920 + 1860, "last column")
    expect(points.allSatisfy { $0.x >= 1920 && $0.x < 3840 && $0.y < 1920 }, "every point inside its eye")
    let grid = (0..<256).map(Double.init)
    expectEqual(BrightTrace.fixed(grid), [4 * 16 + 4, 4 * 16 + 11, 11 * 16 + 4, 11 * 16 + 11].map(Double.init), "fixed cells, row-major")
    expect(close(BrightTrace.codeSignal(64, bits: 10, fullRange: false), 0) && close(BrightTrace.codeSignal(940, bits: 10, fullRange: false), 1),
           "10-bit video range: 64..940 -> 0..1")
    expect(close(BrightTrace.codeSignal(1023, bits: 10, fullRange: true), 1) && close(BrightTrace.codeSignal(16, bits: 8, fullRange: false), 0),
           "full range 10-bit and 8-bit video range")
    expect(close(BrightTrace.codeSignal(1000, bits: 10, fullRange: false), 1), "clamped to [0, 1]")
    let white = HDRPipeline.pqInverseEOTF(203)
    expect(close(BrightTrace.inputLinear(signal: white, pq: true, referenceWhiteNits: 203), 1, 1e-6), "PQ 203 nits = 1.0 (SDR white)")
    expect(close(BrightTrace.inputLinear(signal: 0.5, pq: false, referenceWhiteNits: 203), pow(0.5, 2.2)), "SDR: gamma 2.2")
    expect(close(BrightTrace.outputLuma(r: 1, g: 1, b: 1), 1, 1e-12), "white luma 1")
    expect(close(BrightTrace.srgbToLinear(1), 1) && close(BrightTrace.srgbToLinear(0.5), 0.21404, 1e-4), "sRGB decode")
}

private func testExponentFit() {
    let input = (1...256).map { 0.01 + Double($0) / 256 }
    for k in [1.0, 1.27] {
        let output = input.map { 0.8 * pow($0, k) }
        let fit = BrightTrace.exponent(input: input, output: output)
        expect(close(fit?.slope, k, 1e-9), "log-log slope recovers exponent \(k)")
        expect(close(fit?.logGain, log(0.8), 1e-9), "intercept is the log gain")
    }
    // Rank pairing: a spatial shuffle of the output does not change the fit.
    let shuffled = input.map { pow($0, 1.25) }.reversed()
    expect(close(BrightTrace.exponent(input: input, output: Array(shuffled))?.slope, 1.25, 1e-9), "quantile pairing ignores position")
    // Points at or below the floor (black borders) are excluded.
    let borders = input.enumerated().map { $0.offset < 40 ? 0 : $0.element }
    expect(close(BrightTrace.exponent(input: borders, output: borders)?.slope, 1, 1e-9), "black pairs excluded")
    expect(BrightTrace.exponent(input: [0.5, 0.5, 0.5], output: [0.2, 0.2, 0.2]) == nil, "flat input: no slope")
    expect(BrightTrace.exponent(input: [0.5], output: [0.2]) == nil, "too few points")
    expect(BrightTrace.exponent(input: [0.1, 0.2], output: [0.1]) == nil, "length mismatch")
}

private func testLevels() {
    expectEqual(BrightTrace.levels([]).count, 0, "no values, no levels")
    expectEqual(BrightTrace.levels([1.0, 1.01, 0.99]).count, 1, "one cluster")
    let two = BrightTrace.levels([1.0, 1.27, 1.01, 1.26, 0.99, 1.28])
    expectEqual(two.count, 2, "two clusters")
    expect(close(two.first, 1.0, 1e-9) && close(two.last, 1.27, 1e-9), "cluster centres are means")
}

private func eye(_ name: String = "L", input: Double, k: Double) -> BrightTraceEye {
    let grid = (0..<256).map { input * (0.2 + Double($0) / 320) }
    return BrightTraceEye(eye: name, input: grid, output: grid.map { pow($0, k) })
}

private func record(_ seq: Int, ts: UInt64, input: Double = 0.5, k: Double = 1, fields: [String: String] = [:]) -> BrightTraceRecord {
    var base = ["path": "metal", "pipeline": "biplanar", "binding": "explicit10", "transfer": "pq", "cv_transfer": "SMPTE_ST_2084_PQ",
                "drawable_format": "rgba16Float", "decode": "sync"]
    base.merge(fields) { $1 }
    return BrightTraceRecord(seq: seq, tMs: 1_000 + seq * 11, renderStartS: Double(seq) / 90, presentS: Double(seq) / 90 + 0.02,
                             timestampNs: ts, fields: base, overlayAlpha: 0, eyes: [eye(input: input, k: k)])
}

private func testStateAnnotation() {
    var state = BrightTraceState()
    var a = record(1, ts: 100)
    state.annotate(&a)
    expect(a.isNew && a.generation == 0 && a.changed.isEmpty && !a.attachmentsChanged, "first frame: new, generation 0")
    var b = record(2, ts: 100)
    state.annotate(&b)
    expect(!b.isNew && b.generation == 0, "same timestamp: repeat")
    var c = record(3, ts: 200, fields: ["pipeline": "secret"])
    state.annotate(&c)
    expect(c.isNew && c.generation == 1 && c.changed == ["pipeline"] && !c.attachmentsChanged, "colour field bumps the generation")
    var d = record(4, ts: 300, fields: ["pipeline": "secret", "cv_transfer": "ITU_R_709_2"])
    state.annotate(&d)
    expect(d.generation == 1 && d.changed == ["cv_transfer"] && d.attachmentsChanged, "attachment change flagged, generation kept")
    var e = record(5, ts: 400, fields: ["pipeline": "secret", "cv_transfer": "ITU_R_709_2", "drawable_format": "bgra8Unorm_srgb"])
    state.annotate(&e)
    expect(e.generation == 1 && e.changed == ["drawable_format"] && !e.attachmentsChanged, "output field listed only")
}

private func testJumpDetector() {
    var detector = BrightTraceJumpDetector()
    expect(detector.check(record(1, ts: 1, k: 1), nowMs: 0) == nil, "first frame: nothing to compare")
    expect(detector.check(record(2, ts: 2, k: 1.02), nowMs: 11) == nil, "small exponent change")
    let jump = detector.check(record(3, ts: 3, k: 1.27), nowMs: 22)
    expect(jump?.eye == "L" && jump?.before.seq == 2 && jump?.after.seq == 3, "exponent step with stable input: jump")
    expect(close(jump?.deltaExponent, 0.25, 1e-6), "delta exponent reported")
    expect(detector.check(record(4, ts: 3, k: 1.0), nowMs: 33) == nil, "repeat frames are not compared")
    expect(detector.check(record(5, ts: 5, input: 0.9, k: 1.0), nowMs: 44) == nil, "input change: not a jump")
    // Rate limit: at most jumpsPerSecond in any 1 s window.
    var limited = BrightTraceJumpDetector()
    var emitted = 0
    for i in 0..<20 {
        if limited.check(record(10 + i, ts: UInt64(10 + i), k: i % 2 == 0 ? 1 : 1.27), nowMs: i * 20) != nil { emitted += 1 }
    }
    expectEqual(emitted, BrightTrace.jumpsPerSecond, "rate-limited to 5 per second")
    expectEqual(limited.suppressed, 19 - BrightTrace.jumpsPerSecond, "suppressed jumps counted")
    expect(limited.check(record(40, ts: 40, k: 1.0), nowMs: 2_000) != nil, "window reopens after 1 s")
}

private func testSummary() {
    var summary = BrightTraceSummary()
    expect(summary.take(nowMs: 0, tMs: 5) == nil, "first call starts the window")
    var state = BrightTraceState()
    for (i, k) in [1.0, 1.27, 1.0, 1.27].enumerated() {
        var r = record(i, ts: UInt64(i / 2), k: k, fields: i == 3 ? ["pipeline": "secret"] : [:])
        state.annotate(&r)
        summary.add(r)
    }
    summary.addJump()
    expect(summary.take(nowMs: 500, tMs: 6) == nil, "inside the interval")
    guard let line = summary.take(nowMs: 1_000, tMs: 1_234) else { return expect(false, "line after 1 s") }
    for part in ["BRIGHTTRACE t_ms=1234 ", "frames=4", "new=2", "repeat=2", "levels=2", "gen_changes=1", "jumps=1",
                 "variants=biplanar/explicit10,secret/explicit10", "attach_changes=0", "exp_min=1 ", "exp_max=1.27 "] {
        expect(line.contains(part), "summary has \(part): \(line)")
    }
    expect(summary.take(nowMs: 1_500, tMs: 1_700) == nil, "window restarted")
    guard let empty = summary.take(nowMs: 2_000, tMs: 1_800) else { return expect(false, "empty window still reported") }
    expect(empty.contains("frames=0") && empty.contains("in_min=na"), "empty window: zero counts, na values")
}

private func testRecordEncoding() {
    var state = BrightTraceState()
    var r = record(7, ts: 123_456_789_012, k: 1.25, fields: ["cv_mastering": "00ff"])
    r.eyes.append(BrightTraceEye(eye: "R", input: nil, output: nil))
    state.annotate(&r)
    let line = r.line()
    expect(!line.contains("\n") && !line.contains(" "), "one compact line")
    guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        return expect(false, "valid JSON: \(line.prefix(200))")
    }
    expectEqual(json["seq"] as? Int, 7, "seq")
    expectEqual((json["ts_ns"] as? NSNumber)?.uint64Value, 123_456_789_012, "video timestamp")
    expectEqual(json["new"] as? Bool, true, "new flag")
    expectEqual(json["gen"] as? Int, 0, "generation")
    expectEqual((json["fields"] as? [String: String])?["cv_mastering"], "00ff", "fields map")
    expectEqual(json["changed"] as? [String], [], "changed list")
    guard let eyes = json["eyes"] as? [[String: Any]], eyes.count == 2 else { return expect(false, "two eyes") }
    expectEqual((eyes[0]["in"] as? [Double])?.count, 256, "input grid")
    expectEqual((eyes[0]["in_fixed"] as? [Double])?.count, 4, "input fixed points")
    expect(close(eyes[0]["exp"] as? Double, 1.25, 1e-3), "exponent encoded")
    expect(eyes[1]["in"] is NSNull && eyes[1]["exp"] is NSNull, "missing samples encode as null")
    expectEqual(BrightTraceJSON.encode([0.7, 1.235e-05, Double.nan, "a\"b\\c\n"] as [Any]), #"[0.7,1.235e-05,null,"a\"b\\c\n"]"#, "number and string encoding")
    expectEqual(BrightTrace.rounded(0.123456), 0.1235, "4 significant digits")
    expectEqual(BrightTrace.rounded(1.234567e-5), 1.235e-5, "small values keep 4 significant digits")
    let jumpLine = BrightTraceJumpDetector.Jump(eye: "L", before: r, after: r, deltaExponent: 0.25).line(tMs: 99)
    expect(jumpLine.hasPrefix("BRIGHTTRACE JUMP t_ms=99 eye=L d_exp=0.25 before={") && jumpLine.contains(" after={"), "jump line: \(jumpLine.prefix(80))")
}

@main
enum BrightTraceTests {
    static func main() {
        testGridMath()
        testExponentFit()
        testLevels()
        testStateAnnotation()
        testJumpDetector()
        testSummary()
        testRecordEncoding()
        finishTests("BrightTrace")
    }
}
