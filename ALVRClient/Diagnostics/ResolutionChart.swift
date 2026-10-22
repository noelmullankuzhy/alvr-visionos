//
//  ResolutionChart.swift
//
// Resolution measurement (Diagnostics + the Resolution chart setting; ResolutionChartRenderer.swift draws it):
// 1. Rate-map sampling, 20 s: a fixation dot steps centre, 20° left, 20° right, 15° up, 15° down (4 s each) while each
//    view's rasterization rate map is sampled once per second (DIAG rrm) along the horizontal and vertical lines
//    through the eye axis, as physical px per degree.
// 2. Grating chart: square-wave patches at 10-35 cycles/deg, vertical and horizontal bars, at the eye axis and 20°
//    temporal, judged seen / not seen (DIAG grating), at render quality 0.5, 0.75 and 1.0.
// Logical screen coordinates are Metal's (origin top left, y down). Angles: +x right, +y up; patch positions are
// temporal / up so they mirror between eyes. Directions use Fick angles (tan x = tan az, tan y = tan el / cos az),
// so sizes are true angles off the axis too. Foundation-only; the renderer injects the frame's logical -> physical map.
//

import Foundation

enum RateMapSampling {
    static let degrees: [Double] = [-40, -30, -20, -10, -5, 0, 5, 10, 20, 30, 40]
    static let sweepMs = 20_000, fixationMs = 4_000

    struct Fixation: Equatable { let name: String; let xDeg: Double; let yDeg: Double }
    static let fixations = [Fixation(name: "centre", xDeg: 0, yDeg: 0), Fixation(name: "left20", xDeg: -20, yDeg: 0),
                            Fixation(name: "right20", xDeg: 20, yDeg: 0), Fixation(name: "up15", xDeg: 0, yDeg: 15),
                            Fixation(name: "down15", xDeg: 0, yDeg: -15)]

    static func fixation(elapsedMs: Int) -> Fixation? {
        elapsedMs >= 0 && elapsedMs < sweepMs ? fixations[elapsedMs / fixationMs] : nil
    }

    // Sample s is due from s + 0.5 s (mid-second, half a second after each dot step); a late frame takes the current one.
    static func dueSample(elapsedMs: Int, taken: Int) -> Int? {
        guard elapsedMs >= 500 else { return nil }
        let s = min((elapsedMs - 500) / 1000, sweepMs / 1000 - 1)
        return s > taken ? s : nil
    }

    // The eye axis (tangent 0, 0) in the view's logical screen.
    static func axis(_ t: CornerTangents, width: Double, height: Double) -> (x: Double, y: Double) {
        (t.left / (t.left + t.right) * width, t.top / (t.top + t.bottom) * height)
    }

    static func pxPerTan(_ t: CornerTangents, width: Double, height: Double) -> (x: Double, y: Double) {
        (width / (t.left + t.right), height / (t.bottom + t.top))
    }

    // Logical px per degree at `deg` along a line through the axis: d(tan)/d(deg) = sec^2 * pi / 180.
    static func logicalPPD(pxPerTan: Double, deg: Double) -> Double {
        let c = cos(deg * Double.pi / 180)
        return pxPerTan * Double.pi / 180 / (c * c)
    }

    // Logical point `deg` from the axis on its horizontal (+ right) or vertical (+ up) line; nil off the screen.
    static func point(_ t: CornerTangents, width: Double, height: Double, horizontal: Bool, deg: Double) -> (x: Double, y: Double)? {
        let a = axis(t, width: width, height: height), k = pxPerTan(t, width: width, height: height)
        let d = tan(deg * Double.pi / 180)
        let p = horizontal ? (x: a.x + d * k.x, y: a.y) : (x: a.x, y: a.y - d * k.y)
        return p.x >= 0 && p.x <= width && p.y >= 0 && p.y <= height ? p : nil
    }

    // View-local logical (x, y) -> physical (x, y) of the frame's rate map.
    typealias Mapping = (Double, Double) -> (x: Double, y: Double)

    // Physical per logical px along one axis: central difference over +-step logical px, clamped to the screen.
    static func rate(_ map: Mapping, x: Double, y: Double, horizontal: Bool, width: Double, height: Double, step: Double = 2) -> Double? {
        let lo = horizontal ? max(0, x - step) : max(0, y - step)
        let hi = horizontal ? min(width, x + step) : min(height, y + step)
        guard hi > lo else { return nil }
        let a = horizontal ? map(lo, y) : map(x, lo), b = horizontal ? map(hi, y) : map(x, hi)
        let r = ((horizontal ? b.x - a.x : b.y - a.y)) / (hi - lo)
        return r.isFinite ? r : nil
    }

    struct Sample: Equatable { let deg, rate, ppd: Double }

    // nil map (no foveation): physical = logical.
    static func profile(_ t: CornerTangents, width: Double, height: Double, horizontal: Bool, map: Mapping?,
                        at angles: [Double] = degrees) -> [Sample] {
        let k = pxPerTan(t, width: width, height: height)
        return angles.compactMap { deg in
            guard let p = point(t, width: width, height: height, horizontal: horizontal, deg: deg) else { return nil }
            let r = map.map { rate($0, x: p.x, y: p.y, horizontal: horizontal, width: width, height: height) } ?? 1
            guard let r else { return nil }
            return Sample(deg: deg, rate: r, ppd: r * logicalPPD(pxPerTan: horizontal ? k.x : k.y, deg: deg))
        }
    }

    // Centre (mean angle) of the highest-rate plateau, scanned at 1° within +-40°: where the map is densest.
    static func peak(_ t: CornerTangents, width: Double, height: Double, horizontal: Bool, map: Mapping?) -> Double? {
        let scan = profile(t, width: width, height: height, horizontal: horizontal, map: map,
                           at: Array(stride(from: -40.0, through: 40, by: 1)))
        guard let best = scan.map(\.rate).max(), best > 0 else { return nil }
        let top = scan.filter { $0.rate >= best * 0.99 }
        return top.map(\.deg).reduce(0, +) / Double(top.count)
    }

    static func list(_ samples: [Sample], _ value: KeyPath<Sample, Double>, digits: Int) -> String {
        samples.isEmpty ? "none" : samples.map { String(format: "%.0f:%.\(digits)f", $0.deg, $0[keyPath: value]) }.joined(separator: ",")
    }

    // FNV-1a 32 of the map's parameter bytes: equal hashes mean an unchanged map.
    static func hash(_ bytes: Data) -> String {
        var h: UInt32 = 0x811c9dc5
        for b in bytes { h = (h ^ UInt32(b)) &* 0x01000193 }
        return String(format: "%08x", h)
    }

    struct ViewSample {
        let phase: String, second: Int, fixation: Fixation?, eye: CornerEye, drawable, view, layer: Int
        let quality: Float?, foveation: Bool, mapped: Bool, screen, physical, viewport: String
        let tangents: CornerTangents, axis: (x: Double, y: Double), pxPerTan: (x: Double, y: Double)
        let h, v: [Sample], hPeak, vPeak: Double?, hash: String
    }

    static func fields(_ s: ViewSample) -> KeyValuePairs<String, Any> {
        func f(_ v: Double?, _ d: Int) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "none" }
        let t = s.tangents
        return ["phase": s.phase, "s": s.second, "fix": s.fixation?.name ?? "none",
                "fix_x_deg": f(s.fixation?.xDeg ?? 0, 0), "fix_y_deg": f(s.fixation?.yDeg ?? 0, 0),
                "eye": s.eye.rawValue, "drawable": s.drawable, "view": s.view, "layer": s.layer,
                "rq": f(s.quality.map(Double.init), 3), "fov": s.foveation ? "on" : "off", "map": s.mapped ? "ok" : "none",
                "screen": s.screen, "physical": s.physical, "viewport": s.viewport,
                "tan_left": f(t.left, 4), "tan_right": f(t.right, 4), "tan_bottom": f(t.bottom, 4), "tan_top": f(t.top, 4),
                "axis_x": f(s.axis.x, 1), "axis_y": f(s.axis.y, 1),
                "logical_ppd_x": f(logicalPPD(pxPerTan: s.pxPerTan.x, deg: 0), 3),
                "logical_ppd_y": f(logicalPPD(pxPerTan: s.pxPerTan.y, deg: 0), 3),
                "h_rate": list(s.h, \.rate, digits: 4), "h_ppd": list(s.h, \.ppd, digits: 2),
                "v_rate": list(s.v, \.rate, digits: 4), "v_ppd": list(s.v, \.ppd, digits: 2),
                "h_peak_deg": f(s.hPeak, 1), "v_peak_deg": f(s.vPeak, 1), "map_hash": s.hash]
    }
}

enum GratingChart {
    static let cyclesPerDegree = [10, 15, 20, 25, 30, 35]
    static let qualities: [Float] = [0.5, 0.75, 1.0]
    static let patchDeg = 1.5, pitchDeg = 2.0, labelDeg = 0.4, labelGapDeg = 0.05
    static let statusDeg = 0.5, statusUpDeg = -4.0, dotDeg = 0.5, frameDeg = 0.08, frameGapDeg = 0.12

    enum Orientation: String { case vertical = "V", horizontal = "H" }
    enum Position: String {
        case axis, temporal20
        var temporalDeg: Double { self == .axis ? 0 : 20 }
    }

    // Degree rectangle: temporal (t) / up (u) for the chart, or az / el once placed for an eye.
    struct DegRect: Equatable { var t0, t1, u0, u1: Double }

    struct Patch: Equatable {
        let position: Position, cpd: Int, orientation: Orientation
        // Patch centre, degrees temporal and up from the eye axis.
        let temporalDeg, upDeg: Double
    }

    // Walk order: axis set then temporal set; per set vertical bars then horizontal; cpd ascending (left to right
    // on the chart, i.e. towards temporal for the axis set as well).
    static let patches: [Patch] = [Position.axis, .temporal20].flatMap { pos in
        [Orientation.vertical, .horizontal].flatMap { o in
            cyclesPerDegree.enumerated().map { i, cpd in
                Patch(position: pos, cpd: cpd, orientation: o,
                      temporalDeg: pos.temporalDeg + (Double(i) - Double(cyclesPerDegree.count - 1) / 2) * pitchDeg,
                      upDeg: o == .vertical ? 1.0 : -1.5)
            }
        }
    }

    static func patchRect(_ p: Patch) -> DegRect {
        DegRect(t0: p.temporalDeg - patchDeg / 2, t1: p.temporalDeg + patchDeg / 2, u0: p.upDeg - patchDeg / 2, u1: p.upDeg + patchDeg / 2)
    }

    static func labelRect(_ p: Patch) -> DegRect {
        let r = patchRect(p), text = textDeg("\(p.cpd)", height: labelDeg)
        return DegRect(t0: p.temporalDeg - text / 2, t1: p.temporalDeg + text / 2, u0: r.u0 - labelGapDeg - labelDeg, u1: r.u0 - labelGapDeg)
    }

    // 7-segment text width (CornerChart.textSize) in degrees, for square logical pixels.
    static func textDeg(_ s: String, height: Double) -> Double { CornerChart.textSize(s, h: height, vertical: false).w }

    static func statusRect(_ status: String) -> DegRect {
        let w = textDeg(status, height: statusDeg)
        return DegRect(t0: -w / 2, t1: w / 2, u0: statusUpDeg - statusDeg / 2, u1: statusUpDeg + statusDeg / 2)
    }

    // White bars, starting at the patch's low edge: one per cycle, the last one clipped to the patch.
    static func bars(_ p: Patch) -> [DegRect] {
        let r = patchRect(p), period = 1 / Double(p.cpd)
        let count = Int(ceil(patchDeg * Double(p.cpd) - 1e-9))
        return (0..<count).map { k in
            let a = Double(k) * period, b = min(a + period / 2, patchDeg)
            return p.orientation == .vertical ? DegRect(t0: r.t0 + a, t1: r.t0 + b, u0: r.u0, u1: r.u1)
                                              : DegRect(t0: r.t0, t1: r.t1, u0: r.u0 + a, u1: r.u0 + b)
        }
    }

    // Selection frame: four strips just outside the patch.
    static func frame(_ p: Patch) -> [DegRect] {
        let r = patchRect(p), g = frameGapDeg, s = frameDeg
        let o = DegRect(t0: r.t0 - g - s, t1: r.t1 + g + s, u0: r.u0 - g - s, u1: r.u1 + g + s)
        return [DegRect(t0: o.t0, t1: o.t1, u0: o.u0, u1: o.u0 + s), DegRect(t0: o.t0, t1: o.t1, u0: o.u1 - s, u1: o.u1),
                DegRect(t0: o.t0, t1: o.t0 + s, u0: o.u0, u1: o.u1), DegRect(t0: o.t1 - s, t1: o.t1, u0: o.u0, u1: o.u1)]
    }

    // Temporal is -x for the left eye and +x for the right one.
    static func screen(_ r: DegRect, eye: CornerEye) -> DegRect {
        eye == .left ? DegRect(t0: -r.t1, t1: -r.t0, u0: r.u0, u1: r.u1) : r
    }

    static func ndc(_ t: CornerTangents, azDeg: Double, elDeg: Double) -> CornerChart.Point {
        let az = azDeg * Double.pi / 180, el = elDeg * Double.pi / 180
        let n = t.ndc(x: tan(az), y: tan(el) / cos(az))
        return CornerChart.Point(x: n.x, y: n.y)
    }

    // A chart rectangle (temporal/up) as one quad in the eye's NDC, corners at exact Fick angles.
    static func quad(_ t: CornerTangents, eye: CornerEye, _ r: DegRect, color: SIMD4<Float>) -> CornerChart.Quad {
        quad(t, screen: screen(r, eye: eye), color: color)
    }

    // An az/el rectangle (+ right, + up) as one quad; vertex order as CornerChart.Quad (x0y0, x1y0, x0y1, x1y1).
    static func quad(_ t: CornerTangents, screen s: DegRect, color: SIMD4<Float>) -> CornerChart.Quad {
        let corners = [ndc(t, azDeg: s.t0, elDeg: s.u0), ndc(t, azDeg: s.t1, elDeg: s.u0),
                       ndc(t, azDeg: s.t0, elDeg: s.u1), ndc(t, azDeg: s.t1, elDeg: s.u1)]
        let rect = CornerChart.Rect(x0: corners.map(\.x).min()!, y0: corners.map(\.y).min()!,
                                    x1: corners.map(\.x).max()!, y1: corners.map(\.y).max()!)
        return CornerChart.Quad(rect: rect, color: color, corners: corners)
    }

    // Sweep (fixation given): the dot alone. Grating: patches, labels, the selected patch's frame and the status.
    static func geometry(_ t: CornerTangents, eye: CornerEye, session: GratingSession, fixation: RateMapSampling.Fixation?) -> [CornerChart.Quad] {
        guard session.lit(eye) else { return [] }
        let white: SIMD4<Float> = [1, 1, 1, 1], grey: SIMD4<Float> = [0.6, 0.6, 0.6, 1], yellow: SIMD4<Float> = [1, 1, 0, 1]
        if let f = fixation {
            let d = dotDeg / 2
            return [quad(t, screen: DegRect(t0: f.xDeg - d, t1: f.xDeg + d, u0: f.yDeg - d, u1: f.yDeg + d), color: white)]
        }
        var out: [CornerChart.Quad] = []
        func text(_ s: String, _ r: DegRect, _ color: SIMD4<Float>) {
            let box = quad(t, eye: eye, r, color: color).rect
            out += CornerChart.text(s, in: box, vertical: false, color: color)
        }
        for (i, p) in patches.enumerated() {
            out += bars(p).map { quad(t, eye: eye, $0, color: white) }
            text("\(p.cpd)", labelRect(p), grey)
            if session.finished == false && i == session.index { out += frame(p).map { quad(t, eye: eye, $0, color: yellow) } }
        }
        text(session.statusText, statusRect(session.statusText), white)
        return out
    }

    static func fields(eye: String, patch p: Patch, seen: Bool, requested: Float, actual: Float?, foveation: Bool) -> KeyValuePairs<String, Any> {
        ["eye": eye, "pos": p.position.rawValue, "cpd": p.cpd, "orient": p.orientation.rawValue, "seen": seen ? "yes" : "no",
         "rq": actual.map { String(format: "%.3f", $0) } ?? "unavailable", "rq_set": String(format: "%.3f", requested),
         "fov": foveation ? "on" : "off", "temporal_deg": String(format: "%.1f", p.temporalDeg),
         "up_deg": String(format: "%.1f", p.upDeg), "size_deg": String(format: "%.1f", patchDeg)]
    }

    // The layer configuration drops foveation only for this diagnostic, when chosen; otherwise production's choice.
    static func foveationDisabled(diagnostics: Bool, chart: String, foveation: Bool) -> Bool {
        diagnostics && CornerChartMode(setting: chart) != .off && !foveation
    }
}

// The grating walk: per render quality, every patch in order; seen / not seen records and moves on.
final class GratingSession {
    enum Action { case next, previous, seen, notSeen }
    enum Event: Equatable { case judged(index: Int, seen: Bool, quality: Float), quality(Float), done }

    let mode: CornerChartMode
    private(set) var qualityIndex = 0
    private(set) var index = 0
    private(set) var finished = false

    init(mode: CornerChartMode) { self.mode = mode }

    var quality: Float? { finished ? nil : GratingChart.qualities[qualityIndex] }
    var patch: GratingChart.Patch? { finished ? nil : GratingChart.patches[index] }
    var eyeLabel: String { mode == .left ? "L" : mode == .right ? "R" : "both" }
    func lit(_ e: CornerEye) -> Bool { mode == .both || (mode == .left) == (e == .left) && mode != .off }

    // 7-segment status: quality and patch number ("0.50 3-24"), or "donE".
    var statusText: String {
        guard let quality else { return "donE" }
        return String(format: "%.2f %d-%d", quality, index + 1, GratingChart.patches.count)
    }

    func apply(_ action: Action) -> [Event] {
        guard let quality else { return [] }
        let last = GratingChart.patches.count - 1
        switch action {
        case .next: index = min(index + 1, last); return []
        case .previous: index = max(index - 1, 0); return []
        case .seen, .notSeen:
            var events: [Event] = [.judged(index: index, seen: action == .seen, quality: quality)]
            if index < last { index += 1; return events }
            index = 0
            qualityIndex += 1
            if qualityIndex < GratingChart.qualities.count { events.append(.quality(GratingChart.qualities[qualityIndex])) }
            else { finished = true; events.append(.done) }
            return events
        }
    }
}
