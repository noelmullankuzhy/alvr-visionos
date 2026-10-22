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

// Which immersive space a layer configuration is for.
enum LayerEntry { case diagnostics, stream, other }

enum GratingChart {
    // Up to 20 cpd, the on-axis logical Nyquist at render quality 1.0 (40 logical px/deg); finer cannot be drawn.
    static let cyclesPerDegree = [8, 10, 12, 14, 17, 20]
    // Patch column per cpd level, degrees temporal from its set's position: coarsest there, finer alternating outward.
    static let columnDeg = [0.0, 2, -2, 4, -4, 6]
    static let qualities: [Float] = [0.5, 0.75, 1.0]
    static let patchDeg = 1.5, labelDeg = 0.4, labelGapDeg = 0.05
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

    // Walk order: axis set then temporal set; per set vertical bars then horizontal; cpd ascending, i.e. outward
    // from the set's position (columnDeg).
    static let patches: [Patch] = [Position.axis, .temporal20].flatMap { pos in
        [Orientation.vertical, .horizontal].flatMap { o in
            cyclesPerDegree.enumerated().map { i, cpd in
                Patch(position: pos, cpd: cpd, orientation: o,
                      temporalDeg: pos.temporalDeg + columnDeg[i],
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
    // Auto capture: no frame (highlight false) and its own status.
    static func geometry(_ t: CornerTangents, eye: CornerEye, session: GratingSession, fixation: RateMapSampling.Fixation?,
                         highlight: Bool = true, status: String? = nil) -> [CornerChart.Quad] {
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
            if highlight && session.finished == false && i == session.index { out += frame(p).map { quad(t, eye: eye, $0, color: yellow) } }
        }
        let status = status ?? session.statusText
        text(status, statusRect(status), white)
        return out
    }

    // Logical Nyquist (half the logical px/deg across the bars) at the patch centre, from the view tangents and the
    // logical screen size. V bars: horizontal ppd = k.x sec^2(az); H bars: vertical ppd = k.y sec^2(el) / cos(az) (Fick).
    static func nyquistLogical(_ t: CornerTangents, width: Double, height: Double, eye: CornerEye, patch p: Patch) -> Double {
        let k = RateMapSampling.pxPerTan(t, width: width, height: height), c = screen(patchRect(p), eye: eye)
        let az = (c.t0 + c.t1) / 2 * Double.pi / 180, el = (c.u0 + c.u1) / 2 * Double.pi / 180
        let ppd = p.orientation == .vertical ? k.x / (cos(az) * cos(az)) : k.y / (cos(el) * cos(el) * cos(az))
        return ppd * Double.pi / 180 / 2
    }

    // Above Nyquist the bars alias on the render grid; 0.1 % slack keeps 20 cpd at the 4-digit tangents' 19.998.
    static func aboveNyquist(cpd: Int, nyquist: Double) -> Bool { Double(cpd) > nyquist * 1.001 }

    static func fields(eye: String, patch p: Patch, seen: Bool, requested: Float, actual: Float?, foveation: Bool,
                       nyquist: Double?) -> KeyValuePairs<String, Any> {
        ["eye": eye, "pos": p.position.rawValue, "cpd": p.cpd, "orient": p.orientation.rawValue, "seen": seen ? "yes" : "no",
         "rq": actual.map { String(format: "%.3f", $0) } ?? "unavailable", "rq_set": String(format: "%.3f", requested),
         "fov": foveation ? "on" : "off", "nyquist_logical_cpd": nyquist.map { String(format: "%.2f", $0) } ?? "unavailable",
         "above_nyquist": nyquist.map { aboveNyquist(cpd: p.cpd, nyquist: $0) ? "yes" : "no" } ?? "unknown",
         "temporal_deg": String(format: "%.1f", p.temporalDeg),
         "up_deg": String(format: "%.1f", p.upDeg), "size_deg": String(format: "%.1f", patchDeg)]
    }

    // The layer configuration drops foveation only for this diagnostic, when chosen, in the offline diagnostics space
    // with no stream connected; every other entry keeps production's choice.
    static func foveationDisabled(diagnostics: Bool, chart: String, foveation: Bool, entry: LayerEntry, connected: Bool) -> Bool {
        diagnostics && ResolutionChartSetting.mode(chart) != .off && !foveation && entry == .diagnostics && !connected
    }
}

// The Resolution chart setting: the corner chart's eye modes plus Auto capture (both eyes lit, no input).
enum ResolutionChartSetting {
    static let autoCapture = "Auto capture"
    static let choices = CornerChartMode.allCases.map(\.rawValue) + [autoCapture]
    static func isAuto(_ setting: String) -> Bool { setting == autoCapture }
    static func mode(_ setting: String) -> CornerChartMode { isAuto(setting) ? .both : CornerChartMode(setting: setting) }
}

// Auto capture: the drawn chart read back from each eye's drawable (physical texture, through the rate map), with the
// patch rectangles in logical and physical pixels, for diag-report.py to count the bars. Pixels: origin top left, y down.
enum ChartCapture {
    struct Rect: Equatable { var x0, y0, x1, y1: Double }

    struct View {
        let eye: CornerEye, view, slice, textureIndex: Int, tangents: CornerTangents
        // Logical viewport x, y, w, h; rate-map screen and physical sizes (the texture's when there is no map).
        let viewport: [Double], screen, physical: [Int]
        let map: RateMapSampling.Mapping?
    }

    // The patch's NDC quad (exact Fick corners) in view-local logical pixels.
    static func logicalRect(_ t: CornerTangents, width: Double, height: Double, eye: CornerEye, patch p: GratingChart.Patch) -> Rect {
        let n = GratingChart.quad(t, eye: eye, GratingChart.patchRect(p), color: [1, 1, 1, 1]).rect
        return Rect(x0: (n.x0 + 1) / 2 * width, y0: (1 - n.y1) / 2 * height, x1: (n.x1 + 1) / 2 * width, y1: (1 - n.y0) / 2 * height)
    }

    // Corners through the frame's logical -> physical map (separable, so the corners bound the rect); nil map: 1:1.
    static func physicalRect(_ r: Rect, map: RateMapSampling.Mapping?) -> Rect {
        guard let map else { return r }
        let c = [map(r.x0, r.y0), map(r.x1, r.y0), map(r.x0, r.y1), map(r.x1, r.y1)]
        return Rect(x0: c.map(\.x).min()!, y0: c.map(\.y).min()!, x1: c.map(\.x).max()!, y1: c.map(\.y).max()!)
    }

    // Half the physical px/deg across the bars at the patch centre: logical Nyquist x the map's rate there.
    static func nyquistPhysical(_ t: CornerTangents, width: Double, height: Double, eye: CornerEye, patch p: GratingChart.Patch,
                                map: RateMapSampling.Mapping?) -> Double? {
        let r = logicalRect(t, width: width, height: height, eye: eye, patch: p)
        let rate = map.map { RateMapSampling.rate($0, x: (r.x0 + r.x1) / 2, y: (r.y0 + r.y1) / 2, horizontal: p.orientation == .vertical,
                                                  width: width, height: height) } ?? 1
        return rate.map { $0 * GratingChart.nyquistLogical(t, width: width, height: height, eye: eye, patch: p) }
    }

    static func expectedBars(_ p: GratingChart.Patch) -> Int { GratingChart.bars(p).count }

    static func patches(_ v: View) -> [[String: Any]] {
        let w = v.viewport[2], h = v.viewport[3], t = v.tangents
        return GratingChart.patches.map { p in
            let l = logicalRect(t, width: w, height: h, eye: v.eye, patch: p), ph = physicalRect(l, map: v.map)
            return ["position": p.position.rawValue, "cpd": p.cpd, "orientation": p.orientation.rawValue,
                    "temporal_deg": p.temporalDeg, "up_deg": p.upDeg, "expected_bars": expectedBars(p),
                    "logical_rect": [l.x0, l.y0, l.x1, l.y1], "physical_rect": [ph.x0, ph.y0, ph.x1, ph.y1],
                    "nyquist_logical_cpd": GratingChart.nyquistLogical(t, width: w, height: h, eye: v.eye, patch: p),
                    "nyquist_physical_cpd": nyquistPhysical(t, width: w, height: h, eye: v.eye, patch: p, map: v.map) as Any? ?? NSNull()]
        }
    }

    static func viewRecord(_ v: View) -> [String: Any] {
        let t = v.tangents
        return ["eye": v.eye.rawValue, "view": v.view, "slice": v.slice, "texture_index": v.textureIndex,
                "tangents": [t.left, t.right, t.bottom, t.top], "viewport": v.viewport, "screen": v.screen, "physical": v.physical,
                "mapped": v.map != nil, "patches": patches(v)]
    }

    static func quality(_ q: Float?) -> String { q.map { String(format: "%.3f", $0) } ?? "unavailable" }

    // capture.json "chart_capture".
    static func metadata(views: [View], requested: Float, actual: Float?, confirmed: Bool, foveation: Bool, frames: Int) -> [String: Any] {
        ["mode": "auto", "rq": quality(actual), "rq_set": quality(requested), "rq_confirmed": confirmed, "fov": foveation ? "on" : "off",
         "settle_frames": frames, "patch_deg": GratingChart.patchDeg, "views": views.map(viewRecord)]
    }

    static func fields(eye: CornerEye, requested: Float, actual: Float?, confirmed: Bool, foveation: Bool, dir: String, slice: Int,
                       physical: [Int]) -> KeyValuePairs<String, Any> {
        ["eye": eye.rawValue, "rq": quality(actual), "rq_set": quality(requested), "confirmed": confirmed ? "yes" : "no",
         "fov": foveation ? "on" : "off", "dir": dir, "slice": slice, "physical": physical.map(String.init).joined(separator: "x"),
         "patches": GratingChart.patches.count]
    }

    static func directoryName(stamp: String, quality: Float, foveation: Bool) -> String {
        String(format: "chart-%@-rq%.2f-fov%@", stamp, quality, foveation ? "on" : "off")
    }
}

// Auto capture walk, one frame at a time: per render quality, set it, wait for the read-back to match (the layer's
// maximum clamps it) for settleFrames frames, capture once and wait for the write. No read-back: capture
// unconfirmed after timeoutFrames. A failed capture (no encoder, failed write) still moves on, so the walk always
// reaches done, which carries the quality to restore.
final class AutoCaptureSession {
    enum Step: Equatable { case setQuality(Float), capture(quality: Float, confirmed: Bool, frames: Int), done(restore: Float?) }
    static let settleFrames = 30, timeoutFrames = 600

    let restore: Float?
    private(set) var index = 0
    private(set) var finished = false
    private(set) var captures = 0, failures = 0
    private var requested = false, inFlight = false
    private var frames = 0, confirmedFrames = 0

    init(restore: Float?) { self.restore = restore }

    var quality: Float? { index < GratingChart.qualities.count ? GratingChart.qualities[index] : nil }
    var statusText: String { quality.map { String(format: "%.2f", $0) } ?? "donE" }

    func frame(actual: Float?, max: Float?) -> Step? {
        guard !finished, !inFlight else { return nil }
        guard let q = quality else { finished = true; return .done(restore: restore) }
        guard requested else { requested = true; frames = 0; confirmedFrames = 0; return .setQuality(q) }
        frames += 1
        let target = Swift.min(q, max ?? q)
        if let actual, abs(actual - target) < 0.005 { confirmedFrames += 1 }
        if confirmedFrames >= Self.settleFrames { inFlight = true; return .capture(quality: q, confirmed: true, frames: frames) }
        if frames >= Self.timeoutFrames { inFlight = true; return .capture(quality: q, confirmed: false, frames: frames) }
        return nil
    }

    // The capture was written (ok) or failed: the next quality.
    func captured(ok: Bool) {
        guard inFlight else { return }
        if ok { captures += 1 } else { failures += 1 }
        inFlight = false
        requested = false
        index += 1
    }

    // The readback slot is busy: offer the same capture again next frame.
    func deferCapture() { inFlight = false }
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
