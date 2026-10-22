// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift ALVRClient/Diagnostics/ResolutionChart.swift
import Foundation

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
// Device values (diag-20261021T135020Z.log, DIAG corner / DIAG rq at quality 1.0).
private let leftEye = CornerTangents(left: 1.7321, right: 1, bottom: 1.1918, top: 1)
private let rightEye = CornerTangents(left: 1, right: 1.7321, bottom: 1.1918, top: 1)
private let w = 6261.0, h = 5023.0

// NDC back to the signed tangent, inverting CornerTangents.ndc.
private func tanX(_ t: CornerTangents, _ ndc: Double) -> Double { (ndc * (t.left + t.right) + t.right - t.left) / 2 }
private func tanY(_ t: CornerTangents, _ ndc: Double) -> Double { (ndc * (t.bottom + t.top) + t.top - t.bottom) / 2 }
private func deg(_ r: Double) -> Double { r * 180 / Double.pi }

private func testAxisAndDensity() {
    let a = RateMapSampling.axis(leftEye, width: w, height: h)
    // x = tan_left / (tan_left + tan_right) * W; y (Metal, top-left origin, y down) = tan_top / (tan_top + tan_bottom) * H.
    expect(near(a.x, 1.7321 / 2.7321 * w), "L axis x \(a.x)")
    expect(near(a.y, 1 / 2.1918 * h), "L axis y \(a.y)")
    expect(a.x > w / 2 && a.y < h / 2, "L axis is nasal (right) of and above the logical centre")
    let r = RateMapSampling.axis(rightEye, width: w, height: h)
    expect(near(r.x, 1 / 2.7321 * w) && r.x < w / 2, "R axis mirrored")
    let k = RateMapSampling.pxPerTan(leftEye, width: w, height: h)
    expect(near(k.x, 2291.6, 0.1) && near(k.y, 2291.7, 0.1), "2291.6 logical px per tangent unit \(k)")
    expect(near(RateMapSampling.logicalPPD(pxPerTan: k.x, deg: 0), 40.0, 0.01), "40 logical px/deg on axis")
    expect(near(RateMapSampling.logicalPPD(pxPerTan: k.x, deg: 30), k.x * Double.pi / 180 / pow(cos(Double.pi / 6), 2), 1e-9),
           "planar projection: sec^2 growth off axis")
    expectEqual(RateMapSampling.degrees, [-40, -30, -20, -10, -5, 0, 5, 10, 20, 30, 40], "sample angles")

    let p20 = RateMapSampling.point(leftEye, width: w, height: h, horizontal: true, deg: 20)!
    expect(near(p20.x, a.x + tan(20 * Double.pi / 180) * k.x) && near(p20.y, a.y), "+deg is screen right on the horizontal line")
    let up10 = RateMapSampling.point(leftEye, width: w, height: h, horizontal: false, deg: 10)!
    expect(near(up10.y, a.y - tan(10 * Double.pi / 180) * k.y) && near(up10.x, a.x), "+deg is up (smaller Metal y) on the vertical line")
    let narrow = CornerTangents(left: 0.5, right: 0.5, bottom: 0.5, top: 0.5)
    expect(RateMapSampling.point(narrow, width: 1000, height: 1000, horizontal: true, deg: 30) == nil, "outside the screen: no sample")
    expect(RateMapSampling.point(narrow, width: 1000, height: 1000, horizontal: false, deg: -26) != nil, "inside the screen")
}

private func testRates() {
    let a = RateMapSampling.axis(leftEye, width: w, height: h)
    let k = RateMapSampling.pxPerTan(leftEye, width: w, height: h)
    // Piecewise-linear logical -> physical map: 0.25 left of x = 3000, 0.5 right of it; y at 0.4 throughout.
    let map: RateMapSampling.Mapping = { x, y in (x < 3000 ? 0.25 * x : 750 + 0.5 * (x - 3000), 0.4 * y) }
    expect(near(RateMapSampling.rate(map, x: 2000, y: 100, horizontal: true, width: w, height: h)!, 0.25), "finite difference left")
    expect(near(RateMapSampling.rate(map, x: 4000, y: 100, horizontal: true, width: w, height: h)!, 0.5), "finite difference right")
    expect(near(RateMapSampling.rate(map, x: 0, y: 0, horizontal: false, width: w, height: h)!, 0.4), "clamped at the screen edge")
    let hp = RateMapSampling.profile(leftEye, width: w, height: h, horizontal: true, map: map)
    expectEqual(hp.map(\.deg), RateMapSampling.degrees, "every angle is inside the device screen")
    let zero = hp.first { $0.deg == 0 }!
    expect(near(zero.rate, 0.5) && near(zero.ppd, 0.5 * RateMapSampling.logicalPPD(pxPerTan: k.x, deg: 0)), "physical px/deg = rate x logical px/deg")
    let temporal = hp.first { $0.deg == -40 }!
    expect(a.x - tan(40 * Double.pi / 180) * k.x < 3000 && near(temporal.rate, 0.25), "temporal 40 deg in the low-rate band")
    let none = RateMapSampling.profile(leftEye, width: w, height: h, horizontal: false, map: nil)
    expect(none.allSatisfy { $0.rate == 1 }, "no rate map: physical = logical")
    expectEqual(RateMapSampling.list(Array(hp.prefix(2)), \.rate, digits: 3), "-40:0.250,-30:0.250", "compact deg:value list")

    // A full-rate plateau centred 10 deg right of the axis: the peak follows it.
    let c = a.x + tan(10 * Double.pi / 180) * k.x
    let fovea: RateMapSampling.Mapping = { x, y in
        let lo = c - 300, hi = c + 300
        let px = x < lo ? 0.5 * x : x < hi ? 0.5 * lo + (x - lo) : 0.5 * lo + 600 + 0.5 * (x - hi)
        return (px, y)
    }
    let peak = RateMapSampling.peak(leftEye, width: w, height: h, horizontal: true, map: fovea)!
    expect(abs(peak - 10) <= 1, "peak follows the plateau \(peak)")
    expect(RateMapSampling.peak(leftEye, width: w, height: h, horizontal: true, map: { x, y in (x, y) }).map { abs($0) <= 1 } ?? false,
           "uniform map: plateau centre is the axis")
    expect(RateMapSampling.hash(Data([1, 2, 3])) != RateMapSampling.hash(Data([1, 2, 4])), "hash changes with the map")
}

private func testSchedule() {
    let names = [0, 3999, 4000, 8000, 12000, 16000, 19999].map { RateMapSampling.fixation(elapsedMs: $0)!.name }
    expectEqual(names, ["centre", "centre", "left20", "right20", "up15", "down15", "down15"], "4 s per fixation")
    expect(RateMapSampling.fixation(elapsedMs: 20000) == nil, "sweep ends at 20 s")
    let left = RateMapSampling.fixation(elapsedMs: 5000)!, up = RateMapSampling.fixation(elapsedMs: 13000)!
    expect(left.xDeg == -20 && left.yDeg == 0 && up.xDeg == 0 && up.yDeg == 15, "fixation angles (+x right, +y up)")
    expect(RateMapSampling.dueSample(elapsedMs: 499, taken: -1) == nil, "first sample mid-second")
    expect(RateMapSampling.dueSample(elapsedMs: 500, taken: -1) == 0, "sample 0")
    expect(RateMapSampling.dueSample(elapsedMs: 900, taken: 0) == nil, "once per second")
    expect(RateMapSampling.dueSample(elapsedMs: 4600, taken: 2) == 4, "late frames take the current second")
    expect(RateMapSampling.dueSample(elapsedMs: 20400, taken: 18) == 19, "last sample")
    expect(RateMapSampling.dueSample(elapsedMs: 20600, taken: 19) == nil, "20 samples")
}

private func testGratingSizing() {
    let patches = GratingChart.patches
    expectEqual(patches.count, 24, "6 cpd x 2 orientations x 2 positions")
    expectEqual(GratingChart.cyclesPerDegree, [8, 10, 12, 14, 17, 20], "cpd levels (<= 20, the on-axis logical Nyquist at 1.0)")
    expectEqual(Array(patches.prefix(6).map(\.cpd)), GratingChart.cyclesPerDegree, "walk: cpd ascending")
    expect(patches.prefix(12).allSatisfy { $0.position == .axis } && patches.suffix(12).allSatisfy { $0.position == .temporal20 }, "axis set first")
    // Coarsest at the set's position, finer levels alternating outward (+ temporal first).
    for o in [GratingChart.Orientation.vertical, .horizontal] {
        expectEqual(patches.filter { $0.position == .axis && $0.orientation == o }.map(\.temporalDeg), [0, 2, -2, 4, -4, 6], "axis set positions")
        expectEqual(patches.filter { $0.position == .temporal20 && $0.orientation == o }.map(\.temporalDeg), [20, 22, 18, 24, 16, 26], "temporal set positions")
    }
    // No two patches or labels overlap (degrees).
    var rects = patches.map { GratingChart.patchRect($0) } + patches.map { GratingChart.labelRect($0) }
    rects.append(GratingChart.statusRect("0.75 24-24"))
    for (i, a) in rects.enumerated() {
        for b in rects.dropFirst(i + 1) {
            expect(!(a.t0 < b.t1 && b.t0 < a.t1 && a.u0 < b.u1 && b.u0 < a.u1), "no overlap \(a) \(b)")
        }
    }
    for p in patches {
        let bars = GratingChart.bars(p)
        let r = GratingChart.patchRect(p)
        expect(near(r.t1 - r.t0, GratingChart.patchDeg) && near(r.u1 - r.u0, GratingChart.patchDeg), "patch is 1.5 deg square")
        expectEqual(bars.count, Int(ceil(GratingChart.patchDeg * Double(p.cpd))), "one white bar per cycle (\(p.cpd))")
        for b in bars {
            expect(b.t0 >= r.t0 - 1e-12 && b.t1 <= r.t1 + 1e-12 && b.u0 >= r.u0 - 1e-12 && b.u1 <= r.u1 + 1e-12, "bars inside patch")
        }
        let first = bars[0], second = bars[1]
        if p.orientation == .vertical {
            expect(near(first.t1 - first.t0, 0.5 / Double(p.cpd)) && near(second.t0 - first.t0, 1 / Double(p.cpd)), "V: half-period bars")
            expect(near(first.u0, r.u0) && near(first.u1, r.u1), "V bars span the patch height")
        } else {
            expect(near(first.u1 - first.u0, 0.5 / Double(p.cpd)) && near(second.u0 - first.u0, 1 / Double(p.cpd)), "H: half-period bars")
        }
    }
    // In each eye's NDC, a 20 cpd vertical bar at the axis subtends exactly 1/40 deg (tangent sizing, not logical px).
    let v20 = patches.first { $0.position == .axis && $0.cpd == 20 && $0.orientation == .vertical }!
    for (eye, t) in [(CornerEye.left, leftEye), (.right, rightEye)] {
        let q = GratingChart.quad(t, eye: eye, GratingChart.bars(v20)[0], color: [1, 1, 1, 1])
        let xs = q.vertices.map { deg(atan(tanX(t, $0.x))) }
        expect(near(xs.max()! - xs.min()!, 1.0 / 40, 1e-9), "\(eye) 20 cpd bar = 0.025 deg")
    }
    // Temporal side: left eye -x, right eye +x; horizontal bars keep their angular height at 20 deg azimuth (Fick).
    let h20 = patches.first { $0.position == .temporal20 && $0.cpd == 20 && $0.orientation == .horizontal }!
    for (eye, t) in [(CornerEye.left, leftEye), (.right, rightEye)] {
        let bar = GratingChart.bars(h20)[3]
        let q = GratingChart.quad(t, eye: eye, bar, color: [1, 1, 1, 1])
        let centre = q.vertices.map { tanX(t, $0.x) }.reduce(0, +) / 4
        expect(eye == .left ? centre < -0.3 : centre > 0.3, "\(eye) temporal is \(eye == .left ? "-x" : "+x")")
        for v in q.vertices {
            let az = atan(tanX(t, v.x)), el = deg(atan(tanY(t, v.y) * cos(az)))
            expect(near(el, bar.u0, 1e-9) || near(el, bar.u1, 1e-9), "Fick elevation at the bar edge \(el)")
        }
    }
}

private func testGratingGeometry() {
    let session = GratingSession(mode: .both)
    for (eye, t) in [(CornerEye.left, leftEye), (.right, rightEye)] {
        let q = GratingChart.geometry(t, eye: eye, session: session, fixation: nil)
        expect(q.count > 24 * 10, "patches drawn")
        expect(q.allSatisfy { $0.vertices.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 } }, "inside the view")
        let dot = GratingChart.geometry(t, eye: eye, session: session, fixation: RateMapSampling.fixations[1])
        expectEqual(dot.count, 1, "sweep: only the fixation dot")
        let cx = dot[0].vertices.map { tanX(t, $0.x) }.reduce(0, +) / 4
        expect(near(deg(atan(cx)), -20, 0.01), "left20 dot is 20 deg left in both eyes")
    }
    let mono = GratingSession(mode: .left)
    expect(GratingChart.geometry(rightEye, eye: .right, session: mono, fixation: nil).isEmpty, "other eye black in Left only")
}

private func testSession() {
    let s = GratingSession(mode: .both)
    expectEqual(s.quality, 0.5, "first quality 0.5")
    expectEqual(s.eyeLabel, "both", "binocular label")
    expectEqual(GratingSession(mode: .right).eyeLabel, "R", "monocular label")
    expect(s.apply(.previous).isEmpty && s.index == 0, "previous stops at the first patch")
    _ = s.apply(.next); expectEqual(s.index, 1, "next")
    expectEqual(s.apply(.seen), [.judged(index: 1, seen: true, quality: 0.5)], "seen logs and advances")
    expectEqual(s.index, 2, "advanced")
    for _ in 2..<23 { _ = s.apply(.notSeen) }
    expectEqual(s.apply(.notSeen), [.judged(index: 23, seen: false, quality: 0.5), .quality(0.75)], "pass complete: next quality")
    expect(s.index == 0 && s.quality == 0.75, "restart walk at 0.75")
    for _ in 0..<24 { _ = s.apply(.seen) }
    expectEqual(s.quality, 1.0, "then 1.0")
    for _ in 0..<23 { _ = s.apply(.seen) }
    expectEqual(s.apply(.seen), [.judged(index: 23, seen: true, quality: 1.0), .done], "done after 1.0")
    expect(s.quality == nil && s.statusText == "donE" && s.apply(.seen).isEmpty, "finished")
    expectEqual(GratingSession(mode: .both).statusText, "0.50 1-24", "status: quality and patch")
}

private func testFieldsAndConfiguration() {
    let p = GratingChart.patches.first { $0.position == .temporal20 && $0.cpd == 20 && $0.orientation == .horizontal }!
    let line = Diag.line(topic: "grating", tMs: 7, fields: GratingChart.fields(eye: "L", patch: p, seen: true, requested: 0.75, actual: 0.75,
                                                                           foveation: true, nyquist: 17.6))
    expect(line.hasPrefix("DIAG grating t_ms=7 eye=L pos=temporal20 cpd=20 orient=H seen=yes rq=0.750 rq_set=0.750 fov=on nyquist_logical_cpd=17.60 above_nyquist=yes temporal_deg=26.0 "), line)
    expect(line.contains(" size_deg=1.5"), line)
    let unknown = Diag.line(topic: "grating", tMs: 7, fields: GratingChart.fields(eye: "L", patch: p, seen: true, requested: 0.75, actual: nil,
                                                                              foveation: true, nyquist: nil))
    expect(unknown.contains(" nyquist_logical_cpd=unavailable above_nyquist=unknown "), unknown)
    let k = RateMapSampling.pxPerTan(leftEye, width: w, height: h)
    let sample = RateMapSampling.ViewSample(phase: "sweep", second: 3, fixation: RateMapSampling.fixations[0], eye: .left,
        drawable: 0, view: 0, layer: 0, quality: 1, foveation: true, mapped: true, screen: "6261x5023", physical: "2432x2368",
        viewport: "0,0,6261,5023", tangents: leftEye, axis: RateMapSampling.axis(leftEye, width: w, height: h), pxPerTan: k,
        h: RateMapSampling.profile(leftEye, width: w, height: h, horizontal: true, map: nil),
        v: RateMapSampling.profile(leftEye, width: w, height: h, horizontal: false, map: nil), hPeak: 0, vPeak: nil, hash: "0badf00d")
    let rrm = Diag.line(topic: "rrm", tMs: 9, fields: RateMapSampling.fields(sample))
    expect(rrm.hasPrefix("DIAG rrm t_ms=9 phase=sweep s=3 fix=centre fix_x_deg=0 fix_y_deg=0 eye=L drawable=0 view=0 layer=0 rq=1.000 fov=on map=ok screen=6261x5023 physical=2432x2368 viewport=0,0,6261,5023 "), rrm)
    expect(rrm.contains(" axis_x=3969.4 axis_y=2291.7 "), rrm)
    expect(rrm.contains(" logical_ppd_x=39.997 ") && rrm.contains(" h_rate=-40:1.0000,"), rrm)
    expect(rrm.contains(" h_ppd=-40:68.16,") && rrm.contains(",0:40.00,"), rrm)
    expect(rrm.contains(" h_peak_deg=0.0 v_peak_deg=none map_hash=0badf00d"), rrm)
    // Foveation off only for the offline diagnostics space with the resolution chart on and no connection; every other
    // entry (streaming spaces, input debug, dummy) keeps the production configuration.
    for diagnostics in [false, true] { for chart in CornerChartMode.allCases { for foveation in [false, true] {
        for entry in [LayerEntry.diagnostics, .stream, .other] { for connected in [false, true] {
            let off = GratingChart.foveationDisabled(diagnostics: diagnostics, chart: chart.rawValue, foveation: foveation,
                                                     entry: entry, connected: connected)
            expectEqual(off, diagnostics && chart != .off && !foveation && entry == .diagnostics && !connected,
                        "foveation off: diag \(diagnostics) chart \(chart) setting \(foveation) entry \(entry) connected \(connected)")
        } }
    } } }
}

// Logical Nyquist (logical_ppd(theta) / 2, from the view tangents) at the three render qualities' logical screens.
private func testNyquist() {
    let screens: [(q: String, w: Double, h: Double, axis: Double)] = [("1.0", 6261, 5023, 20.0), ("0.75", 5479, 4395, 17.5), ("0.5", 4696, 3767, 15.0)]
    for s in screens {
        for (eye, t) in [(CornerEye.left, leftEye), (.right, rightEye)] {
            for o in [GratingChart.Orientation.vertical, .horizontal] {
                let p = GratingChart.patches.first { $0.position == .axis && $0.cpd == 8 && $0.orientation == o }!
                let n = GratingChart.nyquistLogical(t, width: s.w, height: s.h, eye: eye, patch: p)
                expect(near(n, s.axis, 0.02), "\(s.q) \(eye) \(o.rawValue) axis Nyquist \(n)")
            }
            // Off axis the logical grid is finer (sec^2): 20 deg temporal V bars at 1.0 -> 20 / cos^2(20 deg) = 22.65.
            let tv = GratingChart.patches.first { $0.position == .temporal20 && $0.cpd == 8 && $0.orientation == .vertical }!
            let n = GratingChart.nyquistLogical(t, width: s.w, height: s.h, eye: eye, patch: tv)
            expect(near(n, s.axis / pow(cos(20 * Double.pi / 180), 2), 0.05), "\(s.q) \(eye) temporal V Nyquist \(n)")
        }
    }
    expect(GratingChart.aboveNyquist(cpd: 20, nyquist: 17.5) && !GratingChart.aboveNyquist(cpd: 17, nyquist: 17.5), "17.5: 20 above, 17 not")
    expect(!GratingChart.aboveNyquist(cpd: 20, nyquist: 19.998), "20 at the 1.0 axis Nyquist (4-digit tangents) is representable")
}

@main enum ResolutionChartTests {
    static func main() {
        testAxisAndDensity()
        testRates()
        testSchedule()
        testGratingSizing()
        testGratingGeometry()
        testSession()
        testFieldsAndConfiguration()
        testNyquist()
        finishTests("ResolutionChart")
    }
}
