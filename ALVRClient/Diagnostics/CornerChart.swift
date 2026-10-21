//
//  CornerChart.swift
//
// Corner chart (GM decision 65): measures where each eye's visible area ends and its shape (rectangle, rounded or
// ellipse), for the render corner trim (decision 60). Per eye, in that eye's own tangent space, 16 spokes every 22.5
// degrees (0 = right, counter-clockwise) with rings at 100 ... 75% of the eye's tangent extent along each spoke. Spoke
// angles are in drawable-normalised space (each quadrant scaled by its own tangent extents), so the diagonals end at
// the drawable corners and every ring is the nested rectangle at that percentage. The wearer keeps the head still,
// looks along each spoke and steps the highlighted ring until it is the outermost one still seen; the marks give the
// visible tangent polygon and the shape. Geometry is NDC quads (x right, y up), drawn without a projection by
// CornerChartRenderer. Foundation-only so it is unit tested on macOS (tests/swift/CornerChartTests.swift).
//

import Foundation

enum CornerEye: String { case left = "L", right = "R" }

enum CornerChartMode: String, CaseIterable {
    case off = "Off", both = "Both eyes", left = "Left only", right = "Right only"

    init(setting: String) { self = CornerChartMode(rawValue: setting) ?? .off }
}

enum CornerSpokes {
    static let count = 16
    static let axes = [0, 4, 8, 12]
    // Diagonal spoke -> its quadrant's (horizontal, vertical) axis spokes.
    static let diagonals: [(spoke: Int, x: Int, y: Int)] = [(2, 0, 4), (6, 8, 4), (10, 8, 12), (14, 0, 12)]

    static func degrees(_ k: Int) -> Double { Double(k) * 360 / Double(count) }

    static func degText(_ k: Int) -> String {
        let d = degrees(k)
        return d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
    }

    // The spoke's 100% point in normalised drawable units (the drawable is [-1, 1] on both axes).
    static func unit(_ k: Int) -> (u: Double, v: Double) {
        let a = degrees(k) * Double.pi / 180
        let m = max(abs(cos(a)), abs(sin(a)))
        func snap(_ x: Double) -> Double { abs(x) < 1e-9 ? 0 : abs(abs(x) - 1) < 1e-9 ? (x < 0 ? -1 : 1) : x }
        return (snap(cos(a) / m), snap(sin(a) / m))
    }

    // Outward normal of the drawable edge the spoke ends on (both components at a corner).
    static func normal(_ k: Int) -> (x: Double, y: Double) {
        let p = unit(k)
        return (abs(p.u) == 1 ? p.u : 0, abs(p.v) == 1 ? p.v : 0)
    }
}

// Tangent magnitudes of one view, in gimmeTangents order (left, right, bottom, top).
struct CornerTangents: Equatable {
    let left, right, bottom, top: Double

    init(left: Double, right: Double, bottom: Double, top: Double) {
        (self.left, self.right, self.bottom, self.top) = (left, right, bottom, top)
    }

    init(simd t: SIMD4<Float>) { self.init(left: Double(t.x), right: Double(t.y), bottom: Double(t.z), top: Double(t.w)) }

    // Signed tangent of a spoke's ring point.
    func point(spoke k: Int, pct: Double) -> (x: Double, y: Double) {
        let p = pct / 100, n = CornerSpokes.unit(k)
        return (p * n.u * (n.u < 0 ? left : right), p * n.v * (n.v < 0 ? bottom : top))
    }

    func point(spoke k: Int, pct: Int) -> (x: Double, y: Double) { point(spoke: k, pct: Double(pct)) }

    // The view's projection: tangent -left..right -> NDC -1..1, -bottom..top -> -1..1.
    func ndc(x: Double, y: Double) -> (x: Double, y: Double) {
        ((2 * x - right + left) / (left + right), (2 * y - top + bottom) / (bottom + top))
    }
}

// Boundary shape from the marks, in normalised drawable units (axis spokes reach 1 at 100%, diagonals sqrt 2).
// Per quadrant with axis radii a, b: a rectangle's corner is at sqrt(a^2 + b^2), an ellipse through the axis points
// crosses the diagonal at 1 / sqrt((1/a^2 + 1/b^2) / 2). rectangle: diagonals >= 0.95 of the rectangle corner;
// ellipse: <= 1.05 of the ellipse radius; rounded between. superellipse_n solves 2 (r / (sqrt2 a))^n = 1 on the means
// (2 = ellipse, infinite = rectangle).
struct CornerShape {
    let radii: [Double]
    let axisR, diagR, rectR, ellipseR, ratio, rectRatio, ellipseRatio, superellipseN, diagPctMean: Double
    let diagFloor: Bool
    let label: String

    static func radius(_ k: Int, pct: Double) -> Double {
        let n = CornerSpokes.unit(k)
        return pct / 100 * (n.u * n.u + n.v * n.v).squareRoot()
    }

    static func classify(_ pcts: [Int: Double]) -> CornerShape? {
        guard (CornerSpokes.axes + CornerSpokes.diagonals.map(\.spoke)).allSatisfy({ pcts[$0] != nil }) else { return nil }
        func r(_ k: Int) -> Double { radius(k, pct: pcts[k]!) }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        let axisR = mean(CornerSpokes.axes.map(r))
        let diagR = mean(CornerSpokes.diagonals.map { r($0.spoke) })
        let rectR = mean(CornerSpokes.diagonals.map { (r($0.x) * r($0.x) + r($0.y) * r($0.y)).squareRoot() })
        let ellipseR = mean(CornerSpokes.diagonals.map { 1 / ((1 / (r($0.x) * r($0.x)) + 1 / (r($0.y) * r($0.y))) / 2).squareRoot() })
        let corner = 2.0.squareRoot() * axisR
        let n = diagR >= corner ? Double.infinity : log(2) / log(corner / diagR)
        let label = diagR >= 0.95 * rectR ? "rectangle" : diagR <= 1.05 * ellipseR ? "ellipse" : "rounded"
        let diagPcts = CornerSpokes.diagonals.map { pcts[$0.spoke]! }
        return CornerShape(radii: (0..<CornerSpokes.count).compactMap { k in pcts[k].map { radius(k, pct: $0) } },
                           axisR: axisR, diagR: diagR, rectR: rectR, ellipseR: ellipseR, ratio: diagR / axisR,
                           rectRatio: rectR / axisR, ellipseRatio: ellipseR / axisR, superellipseN: n, diagPctMean: mean(diagPcts),
                           diagFloor: diagPcts.contains { $0 <= Double(CornerChart.ringPercents.last!) }, label: label)
    }
}

enum CornerChart {
    static let ringPercents = [100, 98, 96, 94, 92, 90, 88, 85, 80, 75]
    static let linePx = 3.0, padPx = 2.0, maxLabelPx = 48.0, minLabelPx = 6.0

    struct Rect: Equatable { var x0, y0, x1, y1: Double }
    struct Quad { let rect: Rect; let color: SIMD4<Float> }
    struct Label { let pct: Int; let spoke: Int; let text: String; let rect: Rect; let vertical: Bool }

    static let palette: [SIMD4<Float>] = [[1, 1, 1, 1], [1, 1, 0, 1], [0, 1, 1, 1], [1, 0, 1, 1], [0, 1, 0, 1],
                                          [1, 0.5, 0, 1], [0.4, 0.6, 1, 1], [1, 0.3, 0.3, 1], [1, 1, 1, 1], [1, 1, 0, 1]]

    static func ringRect(_ t: CornerTangents, pct: Int) -> Rect {
        let p = Double(pct) / 100
        let lo = t.ndc(x: -p * t.left, y: -p * t.bottom), hi = t.ndc(x: p * t.right, y: p * t.top)
        return Rect(x0: lo.x, y0: lo.y, x1: hi.x, y1: hi.y)
    }

    static func spokeNdc(_ t: CornerTangents, _ k: Int, _ pct: Int) -> (x: Double, y: Double) {
        let p = t.point(spoke: k, pct: pct)
        return t.ndc(x: p.x, y: p.y)
    }

    // 7-segment glyph widths: 0.55 h per character, 0.2 h between (horizontal) or 0.25 h between rows (vertical).
    static func textSize(_ text: String, h: Double, vertical: Bool) -> (w: Double, h: Double) {
        let n = Double(text.count)
        return vertical ? (0.55 * h, n * h + (n - 1) * 0.25 * h) : (n * 0.55 * h + (n - 1) * 0.2 * h, h)
    }

    // Every ring's number on every spoke, just inside its own line and clear of the next ring in (band-limited
    // size, capped); numbers on the left/right edges stack vertically so they fit the narrow side bands.
    static func labels(_ t: CornerTangents, widthPx w: Double, heightPx h: Double) -> [Label] {
        let dx = 2 / w, dy = 2 / h, inset = linePx + padPx
        var out: [Label] = []
        for (i, pct) in ringPercents.enumerated() {
            let r = ringRect(t, pct: pct)
            let next = i + 1 < ringPercents.count ? ringRect(t, pct: ringPercents[i + 1]) : nil
            func avail(_ bandNdc: Double?, _ scale: Double) -> Double { bandNdc.map { $0 / scale - linePx - 2 * padPx } ?? .infinity }
            let side = (l: avail(next.map { $0.x0 - r.x0 }, dx), r: avail(next.map { r.x1 - $0.x1 }, dx),
                        b: avail(next.map { $0.y0 - r.y0 }, dy), t: avail(next.map { r.y1 - $0.y1 }, dy))
            for k in 0..<CornerSpokes.count {
                let d = CornerSpokes.normal(k), p = spokeNdc(t, k, pct)
                let vertical = d.y == 0
                let fit = vertical ? (d.x < 0 ? side.l : side.r) / 0.55 : (d.y > 0 ? side.t : side.b)
                let size = textSize("\(pct)", h: max(min(fit, maxLabelPx), minLabelPx), vertical: vertical)
                let (sw, sh) = (size.w * dx, size.h * dy)
                func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
                let x0 = d.x < 0 ? r.x0 + inset * dx : d.x > 0 ? r.x1 - inset * dx - sw : clamp(p.x - sw / 2, r.x0 + inset * dx, r.x1 - inset * dx - sw)
                let y0 = d.y < 0 ? r.y0 + inset * dy : d.y > 0 ? r.y1 - inset * dy - sh : clamp(p.y - sh / 2, r.y0 + inset * dy, r.y1 - inset * dy - sh)
                out.append(Label(pct: pct, spoke: k, text: "\(pct)", rect: Rect(x0: x0, y0: y0, x1: x0 + sw, y1: y0 + sh), vertical: vertical))
            }
        }
        return out
    }

    // Segments a top, b upper right, c lower right, d bottom, e lower left, f upper left, g middle, p decimal point.
    private static let segments: [Character: String] = [
        "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg", "5": "acdfg", "6": "acdefg", "7": "abc",
        "8": "abcdefg", "9": "abcdfg", "L": "def", "r": "eg", "d": "bcdeg", "o": "cdeg", "n": "ceg", "E": "adefg",
        "-": "g", ".": "p"]

    static func text(_ s: String, in rect: Rect, vertical: Bool, color: SIMD4<Float>) -> [Quad] {
        let n = Double(s.count)
        let h = vertical ? (rect.y1 - rect.y0) / (n + (n - 1) * 0.25) : rect.y1 - rect.y0
        let cw = vertical ? rect.x1 - rect.x0 : (rect.x1 - rect.x0) / (n * 0.55 + (n - 1) * 0.2) * 0.55
        // Stroke 0.16 h: as a fraction of the glyph height (horizontal bars) and of its 0.55 h width (vertical bars).
        let st = 0.16 * h, sv = 0.16 / 0.55 * cw
        var out: [Quad] = []
        for (k, ch) in s.enumerated() {
            let gx = vertical ? rect.x0 : rect.x0 + Double(k) * cw * 0.75 / 0.55
            let gy = vertical ? rect.y1 - Double(k + 1) * h - Double(k) * 0.25 * h : rect.y0
            let mid = gy + h / 2
            for seg in segments[ch] ?? "" {
                let q: Rect
                switch seg {
                case "a": q = Rect(x0: gx, y0: gy + h - st, x1: gx + cw, y1: gy + h)
                case "d": q = Rect(x0: gx, y0: gy, x1: gx + cw, y1: gy + st)
                case "g": q = Rect(x0: gx, y0: mid - st / 2, x1: gx + cw, y1: mid + st / 2)
                case "f": q = Rect(x0: gx, y0: mid, x1: gx + sv, y1: gy + h)
                case "b": q = Rect(x0: gx + cw - sv, y0: mid, x1: gx + cw, y1: gy + h)
                case "e": q = Rect(x0: gx, y0: gy, x1: gx + sv, y1: mid)
                case "p": q = Rect(x0: gx + (cw - 1.5 * sv) / 2, y0: gy, x1: gx + (cw + 1.5 * sv) / 2, y1: gy + 1.5 * st)
                default: q = Rect(x0: gx + cw - sv, y0: gy, x1: gx + cw, y1: mid)
                }
                out.append(Quad(rect: q, color: color))
            }
        }
        return out
    }

    // One eye's chart: rings (inner strokes), numbers, spoke dots, the selected ring's highlight + large number, status.
    static func geometry(_ t: CornerTangents, widthPx w: Double, heightPx h: Double, selected: (spoke: Int, pct: Int)?, status: String) -> [Quad] {
        let dx = 2 / w, dy = 2 / h, lx = linePx * dx, ly = linePx * dy
        var out: [Quad] = []
        for (i, pct) in ringPercents.enumerated() {
            let r = ringRect(t, pct: pct), c = palette[i]
            out += [Rect(x0: r.x0, y0: r.y0, x1: r.x0 + lx, y1: r.y1), Rect(x0: r.x1 - lx, y0: r.y0, x1: r.x1, y1: r.y1),
                    Rect(x0: r.x0, y0: r.y0, x1: r.x1, y1: r.y0 + ly), Rect(x0: r.x0, y0: r.y1 - ly, x1: r.x1, y1: r.y1)].map { Quad(rect: $0, color: c) }
        }
        for label in labels(t, widthPx: w, heightPx: h) {
            out += text(label.text, in: label.rect, vertical: label.vertical, color: palette[ringPercents.firstIndex(of: label.pct) ?? 0])
        }
        // Spoke direction: dots from 10 to 70% (the selected spoke brighter and larger).
        for k in 0..<CornerSpokes.count {
            let on = selected?.spoke == k, s = on ? 4.0 : 2.0
            for pct in stride(from: 10, through: 70, by: 10) {
                let p = spokeNdc(t, k, pct)
                out.append(Quad(rect: Rect(x0: p.x - s * dx, y0: p.y - s * dy, x1: p.x + s * dx, y1: p.y + s * dy),
                                color: on ? [1, 1, 1, 1] : [0.5, 0.5, 0.5, 1]))
            }
        }
        let white: SIMD4<Float> = [1, 1, 1, 1], black: SIMD4<Float> = [0, 0, 0, 1]
        func boxed(_ s: String, centre: (x: Double, y: Double), px: Double) {
            let size = textSize(s, h: px, vertical: false)
            let r = Rect(x0: centre.x - size.w * dx / 2, y0: centre.y - size.h * dy / 2, x1: centre.x + size.w * dx / 2, y1: centre.y + size.h * dy / 2)
            out.append(Quad(rect: Rect(x0: r.x0 - 6 * dx, y0: r.y0 - 6 * dy, x1: r.x1 + 6 * dx, y1: r.y1 + 6 * dy), color: black))
            out += text(s, in: r, vertical: false, color: white)
        }
        if let (k, pct) = selected {
            let r = ringRect(t, pct: pct), d = CornerSpokes.normal(k), a = spokeNdc(t, k, pct), th = 3 * linePx
            let armX = 0.1 * (r.x1 - r.x0), armY = 0.1 * (r.y1 - r.y0)
            // Along the ring's edges from the corner, or centred on the spoke's point of an edge, inside the ring.
            if d.y != 0 {
                out.append(Quad(rect: Rect(x0: max(d.x < 0 ? a.x : a.x - armX, r.x0), y0: d.y > 0 ? a.y - th * dy : a.y,
                                           x1: min(d.x > 0 ? a.x : a.x + armX, r.x1), y1: d.y > 0 ? a.y : a.y + th * dy), color: white))
            }
            if d.x != 0 {
                out.append(Quad(rect: Rect(x0: d.x > 0 ? a.x - th * dx : a.x, y0: max(d.y < 0 ? a.y : a.y - armY, r.y0),
                                           x1: d.x > 0 ? a.x : a.x + th * dx, y1: min(d.y > 0 ? a.y : a.y + armY, r.y1)), color: white))
            }
            let size = textSize("\(pct)", h: maxLabelPx, vertical: false), m = th + 40
            boxed("\(pct)", centre: (a.x - d.x * (m + size.w / 2) * dx, a.y - d.y * (m + size.h / 2) * dy), px: maxLabelPx)
        }
        if !status.isEmpty {
            boxed(status, centre: t.ndc(x: 0, y: 0), px: 0.04 * h)
        }
        return out
    }

    // Visible tangent polygon, counterclockwise from 0 degrees; nil until all 16 spokes are marked.
    static func polygon(_ t: CornerTangents, marks: [Int: Int]) -> [(x: Double, y: Double)]? {
        var out: [(x: Double, y: Double)] = []
        for k in 0..<CornerSpokes.count {
            guard let pct = marks[k] else { return nil }
            out.append(t.point(spoke: k, pct: pct))
        }
        return out
    }

    static func area(_ poly: [(x: Double, y: Double)]) -> Double {
        abs(poly.indices.reduce(0.0) { acc, i in
            let a = poly[i], b = poly[(i + 1) % poly.count]
            return acc + a.x * b.y - b.x * a.y
        }) / 2
    }

    private static func f4(_ v: Double) -> String { v.isInfinite ? "inf" : String(format: "%.4f", v) }

    static func markFields(_ eye: CornerEye, _ spoke: Int, _ pct: Int, _ t: CornerTangents) -> KeyValuePairs<String, Any> {
        let p = t.point(spoke: spoke, pct: pct)
        return ["eye": eye.rawValue, "pos_deg": CornerSpokes.degText(spoke), "ring_pct": pct, "tan_x": f4(p.x), "tan_y": f4(p.y)]
    }

    static func viewFields(_ eye: CornerEye, view: Int, _ t: CornerTangents, drawableW: Int, drawableH: Int, viewport: String) -> KeyValuePairs<String, Any> {
        ["eye": eye.rawValue, "view": view, "tan_left": f4(t.left), "tan_right": f4(t.right), "tan_bottom": f4(t.bottom),
         "tan_top": f4(t.top), "drawable_w": drawableW, "drawable_h": drawableH, "viewport": viewport]
    }

    // Polygon, area and the shape with its raw numbers (r = per-spoke normalised radii from 0 degrees, CCW).
    static func summaryFields(_ eye: CornerEye, _ t: CornerTangents, marks: [Int: Int]) -> KeyValuePairs<String, Any> {
        guard let poly = polygon(t, marks: marks), let s = CornerShape.classify(marks.mapValues(Double.init)) else {
            return ["eye": eye.rawValue, "marks": marks.count, "polygon": "incomplete", "area_frac": "unavailable", "shape": "unavailable"]
        }
        return ["eye": eye.rawValue, "marks": marks.count, "polygon": poly.map { "\(f4($0.x)),\(f4($0.y))" }.joined(separator: ";"),
                "area_frac": f4(area(poly) / ((t.left + t.right) * (t.bottom + t.top))), "r": s.radii.map(f4).joined(separator: ","),
                "axis_r": f4(s.axisR), "diag_r": f4(s.diagR), "rect_r": f4(s.rectR), "ellipse_r": f4(s.ellipseR), "ratio": f4(s.ratio),
                "rect_ratio": f4(s.rectRatio), "ellipse_ratio": f4(s.ellipseRatio), "superellipse_n": f4(s.superellipseN),
                "diag_pct_mean": String(format: "%.2f", s.diagPctMean), "diag_floor": s.diagFloor, "shape": s.label]
    }

    // visionOS 27.0 SDK headers searched for a visible-area / hidden-area / visibility-mask API: none. The only mask is
    // cp_drawable_render_context drawMaskOnStencilAttachment (26+), documented as the full texture in full and mixed
    // immersion (a progressive-immersion portal mask, not the lens edge).
    static var apiFields: KeyValuePairs<String, Any> {
        ["api": "unavailable", "sdk": "xros27.0", "searched": "CompositorServices,ARKit,RealityKit,RealityFoundation", "stencil_mask": "progressive_only"]
    }
}

// The measurement walk: per eye (both: L then R), spokes 0 ... 337.5 degrees; the ring is stepped out/in and recorded.
final class CornerChartSession {
    enum Action { case outward, inward, record, back }
    enum Event: Equatable { case mark(CornerEye, Int, Int), summary(CornerEye), done }

    let mode: CornerChartMode
    let eyes: [CornerEye]
    private(set) var eyeIndex = 0
    private(set) var spoke = 0
    private(set) var ringIndex = 0
    private(set) var marks: [CornerEye: [Int: Int]] = [:]

    init(mode: CornerChartMode) {
        self.mode = mode
        eyes = mode == .left ? [.left] : mode == .right ? [.right] : mode == .both ? [.left, .right] : []
    }

    var eye: CornerEye? { eyeIndex < eyes.count ? eyes[eyeIndex] : nil }
    var pct: Int { CornerChart.ringPercents[ringIndex] }

    // The other eye is black in the monocular modes.
    func lit(_ e: CornerEye) -> Bool { mode == .both || eyes.contains(e) }

    // 7-segment status: eye, spoke degrees, selected ring ("L 22.5 94"), or "donE".
    var statusText: String {
        guard let eye else { return "donE" }
        return "\(eye == .left ? "L" : "r") \(CornerSpokes.degText(spoke)) \(pct)"
    }

    func apply(_ action: Action) -> [Event] {
        let last = CornerSpokes.count - 1
        switch action {
        case .outward:
            ringIndex = max(ringIndex - 1, 0)
        case .inward:
            ringIndex = min(ringIndex + 1, CornerChart.ringPercents.count - 1)
        case .back:
            if eye == nil, !eyes.isEmpty {
                (eyeIndex, spoke) = (eyes.count - 1, last)
            } else if spoke > 0 {
                spoke -= 1
            } else if eyeIndex > 0 {
                (eyeIndex, spoke) = (eyeIndex - 1, last)
            }
        case .record:
            guard let eye else { return [] }
            marks[eye, default: [:]][spoke] = pct
            var events: [Event] = [.mark(eye, spoke, pct)]
            if spoke < last {
                spoke += 1
            } else {
                events.append(.summary(eye))
                (eyeIndex, spoke) = (eyeIndex + 1, 0)
                if self.eye == nil { events.append(.done) }
            }
            return events
        }
        return []
    }
}
