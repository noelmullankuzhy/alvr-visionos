//
//  CornerChart.swift
//
// Head-locked octagon chart (decision 65g): four rectangle sides and four straight corner cuts per eye.
// Geometry stays Foundation-only; the renderer injects physical/logical pixel scales from the frame's rate map.

import Foundation

enum CornerEye: String {
    case left = "L", right = "R"

    // The view's x offset in the device frame: left eye at -x (0 counts as left).
    init(viewOffsetX x: Double) { self = x <= 0 ? .left : .right }

    var color: SIMD4<Float> { self == .left ? [0, 1, 1, 1] : [1, 0, 1, 1] }
}

enum CornerChartMode: String, CaseIterable {
    case off = "Off", both = "Both eyes", left = "Left only", right = "Right only"

    init(setting: String) { self = CornerChartMode(rawValue: setting) ?? .off }
}

enum CornerSpokes {
    static let count = 8
    static let axes = [0, 2, 4, 6]
    // Diagonal spoke -> its quadrant's (horizontal, vertical) axis spokes.
    static let diagonals: [(spoke: Int, x: Int, y: Int)] = [(1, 0, 2), (3, 4, 2), (5, 4, 6), (7, 0, 6)]

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

    static func kind(_ k: Int) -> String { k % 2 == 0 ? "side" : "cut" }


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

enum CornerChart {
    static let ringPercents = Array(stride(from: 100, through: 50, by: -5))
    static let cutPercents = Array(stride(from: 100, through: 30, by: -5))
    static let linePx = 3.0, padPx = 2.0, maxLabelPx = 48.0, minLabelPx = 24.0
    // NDC location -> physical pixels per logical pixel on each screen axis.
    typealias LocalScale = (Double, Double) -> (x: Double, y: Double)
    static func strokePx(_ scale: (x: Double, y: Double)) -> Double { linePx / min(scale.x, scale.y) }

    struct Rect: Equatable { var x0, y0, x1, y1: Double }
    struct Point { var x, y: Double }
    struct Quad {
        let rect: Rect
        let color: SIMD4<Float>
        var corners: [Point]? = nil
        var vertices: [Point] {
            corners ?? [Point(x: rect.x0, y: rect.y0), Point(x: rect.x1, y: rect.y0),
                        Point(x: rect.x0, y: rect.y1), Point(x: rect.x1, y: rect.y1)]
        }
    }
    struct Label { let pct: Int; let spoke: Int; let text: String; let rect: Rect; let vertical: Bool }

    // In each quadrant |x| + |y| = 2p, clipped to the unit rectangle. At 100% it is a single point.
    static func cut(spoke: Int, pct: Int) -> (a: Point, b: Point) {
        let p = Double(pct) / 100, n = CornerSpokes.unit(spoke)
        let lo = max(0, 2 * p - 1), hi = min(1, 2 * p)
        return (Point(x: lo * n.u, y: hi * n.v), Point(x: hi * n.u, y: lo * n.v))
    }

    static func normalisedNdc(_ t: CornerTangents, _ p: Point) -> Point {
        let n = t.ndc(x: p.x * (p.x < 0 ? t.left : t.right), y: p.y * (p.y < 0 ? t.bottom : t.top))
        return Point(x: n.x, y: n.y)
    }

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

    // Stack digits at side and cut marks: narrow columns remain separate even where foveation enlarges glyphs.
    // Ring labels alternate across their axis (100/90/... and 95/85/...), giving each lane 10% spacing.
    // Cut columns already fit on the diagonals. Clamp at the border, then size at the whole footprint.
    static func labels(_ t: CornerTangents, widthPx w: Double, heightPx h: Double,
                       localScale: LocalScale = { _, _ in (1, 1) }) -> [Label] {
        var out: [Label] = []
        for k in 0..<CornerSpokes.count {
            for pct in (k % 2 == 0 ? ringPercents : cutPercents) {
                let p = spokeNdc(t, k, pct), n = CornerSpokes.unit(k)
                let vertical = n.u != 0
                var sizePx = minLabelPx / localScale(p.x, p.y).y
                var rect = Rect(x0: 0, y0: 0, x1: 0, y1: 0)
                for _ in 0..<4 {
                    let size = textSize("\(pct)", h: sizePx, vertical: vertical)
                    let sw = size.w * 2 / w, sh = size.h * 2 / h
                    let inset = strokePx(localScale(p.x, p.y)) + padPx
                    var x = p.x - sw / 2, y = p.y - sh / 2
                    let gapX = inset * 2 / w, gapY = inset * 2 / h
                    let positiveLane = (100 - pct) % 10 == 0
                    if n.v == 0 {
                        x = n.u > 0 ? p.x - sw - gapX : p.x + gapX
                        y = positiveLane ? p.y + gapY : p.y - sh - gapY
                    }
                    if n.u == 0 {
                        y = n.v > 0 ? p.y - sh - gapY : p.y + gapY
                        x = positiveLane ? p.x + gapX : p.x - sw - gapX
                    }
                    x = max(-1, min(1 - sw, x)); y = max(-1, min(1 - sh, y))
                    rect = Rect(x0: x, y0: y, x1: x + sw, y1: y + sh)
                    let sy = [localScale(x, y).y, localScale(x + sw, y).y,
                              localScale(x, y + sh).y, localScale(x + sw, y + sh).y].min()!
                    if sizePx * sy >= minLabelPx - 1e-8 { break }
                    sizePx = minLabelPx / sy
                }
                out.append(Label(pct: pct, spoke: k, text: "\(pct)", rect: rect, vertical: vertical))
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

    // Space the innermost ring's labels may take inside its line, plus a margin: the glyph and status keep out of it.
    private static let labelBandPx = linePx + 2 * padPx + maxLabelPx + 6
    private static let statusGapPx = 12.0, statusBorderPx = 6.0

    private static func statusPx(_ h: Double) -> Double { 0.04 * h }

    // The eye glyph's box: centred on the tangent origin, 0.2 of the drawable height (0.6 as wide), shrunk so it and
    // the status below it stay inside the innermost ring and clear of that ring's labels.
    static func glyphRect(_ t: CornerTangents, widthPx w: Double, heightPx h: Double) -> Rect {
        let c = t.ndc(x: 0, y: 0), r = ringRect(t, pct: ringPercents.last!)
        let side = min(r.x1 - c.x, c.x - r.x0) * w / 2 - labelBandPx
        let top = (r.y1 - c.y) * h / 2 - labelBandPx
        let bottom = (c.y - r.y0) * h / 2 - labelBandPx - (statusGapPx + statusPx(h) + statusBorderPx)
        let gh = max(min(0.2 * h, 2 * top, 2 * bottom, 2 * side / 0.6), 0), gw = 0.6 * gh
        return Rect(x0: c.x - gw / w, y0: c.y - gh / h, x1: c.x + gw / w, y1: c.y + gh / h)
    }

    // The status box (text plus its black border), centred under the glyph.
    static func statusRect(_ t: CornerTangents, _ status: String, widthPx w: Double, heightPx h: Double) -> Rect {
        let g = glyphRect(t, widthPx: w, heightPx: h), size = textSize(status, h: statusPx(h), vertical: false)
        let cx = (g.x0 + g.x1) / 2, y1 = g.y0 - (statusGapPx - statusBorderPx) * 2 / h
        return Rect(x0: cx - (size.w / 2 + statusBorderPx) * 2 / w, y0: y1 - (size.h + 2 * statusBorderPx) * 2 / h,
                    x1: cx + (size.w / 2 + statusBorderPx) * 2 / w, y1: y1)
    }

    // Block L / R (stroke 0.16 of the height): L = stem and foot; R = stem, top, middle, bowl side and a stepped leg.
    static func eyeGlyph(_ eye: CornerEye, _ t: CornerTangents, widthPx w: Double, heightPx h: Double) -> [Quad] {
        let g = glyphRect(t, widthPx: w, heightPx: h), st = 0.16, sw = 0.16 / 0.6
        func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Quad {
            Quad(rect: Rect(x0: g.x0 + x0 * (g.x1 - g.x0), y0: g.y0 + y0 * (g.y1 - g.y0), x1: g.x0 + x1 * (g.x1 - g.x0), y1: g.y0 + y1 * (g.y1 - g.y0)),
                 color: eye.color)
        }
        if eye == .left { return [box(0, 0, sw, 1), box(0, 0, 1, st)] }
        let leg = (0..<5).map { i -> Quad in
            let x0 = 0.3 + (1 - sw - 0.3) * Double(i) / 4
            return box(x0, 0.5 - Double(i + 1) * 0.1, x0 + sw, 0.5 - Double(i) * 0.1)
        }
        return [box(0, 0, sw, 1), box(0, 1 - st, 1, 1), box(0, 0.5 - st / 2, 1, 0.5 + st / 2), box(1 - sw, 0.5, 1, 1)] + leg
    }

    // Sample long lines in logical pixels so a peripheral section cannot inherit a central stroke width.
    static func geometry(_ t: CornerTangents, eye: CornerEye, widthPx w: Double, heightPx h: Double,
                         selected: (spoke: Int, pct: Int)?, status: String,
                         localScale: LocalScale = { _, _ in (1, 1) }) -> [Quad] {
        var out: [Quad] = []
        func clipped(_ p: Point) -> Point { Point(x: max(-1, min(1, p.x)), y: max(-1, min(1, p.y))) }
        func stroke(_ a: Point, _ b: Point, color: SIMD4<Float>, weight: Double = 1) {
            let vx = (b.x - a.x) * w / 2, vy = (b.y - a.y) * h / 2
            let length = hypot(vx, vy), steps = max(1, Int(ceil(length / 32)))
            for i in 0..<steps {
                let f0 = Double(i) / Double(steps), f1 = Double(i + 1) / Double(steps)
                let start = Point(x: a.x + (b.x - a.x) * f0, y: a.y + (b.y - a.y) * f0)
                let end = Point(x: a.x + (b.x - a.x) * f1, y: a.y + (b.y - a.y) * f1)
                let mid = Point(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                let px = weight * [localScale(start.x, start.y), localScale(mid.x, mid.y), localScale(end.x, end.y)].map(strokePx).max()!
                // Draw border strokes inward so clipping cannot halve their physical thickness.
                let nx = length > 0 ? -vy / length * px / w : px / w
                let ny = length > 0 ? vx / length * px / h : px / h
                var points = [Point(x: start.x + nx, y: start.y + ny), Point(x: end.x + nx, y: end.y + ny),
                              Point(x: start.x - nx, y: start.y - ny), Point(x: end.x - nx, y: end.y - ny)]
                let shiftX = max(0, -1 - points.map(\.x).min()!) - max(0, points.map(\.x).max()! - 1)
                let shiftY = max(0, -1 - points.map(\.y).min()!) - max(0, points.map(\.y).max()! - 1)
                points = points.map { clipped(Point(x: $0.x + shiftX, y: $0.y + shiftY)) }
                out.append(Quad(rect: Rect(x0: points.map(\.x).min()!, y0: points.map(\.y).min()!,
                                           x1: points.map(\.x).max()!, y1: points.map(\.y).max()!), color: color, corners: points))
            }
        }
        func cutStroke(_ k: Int, _ pct: Int, color: SIMD4<Float>, weight: Double = 1) {
            let c = cut(spoke: k, pct: pct)
            stroke(normalisedNdc(t, c.a), normalisedNdc(t, c.b), color: color, weight: weight)
        }
        // Enforce the physical minimum on glyph bars as well as chart lines.
        func glyphs(_ quads: [Quad]) {
            for q in quads {
                let r = q.rect, x = (r.x0 + r.x1) / 2, y = (r.y0 + r.y1) / 2
                let px = [localScale(r.x0, r.y0), localScale(r.x1, r.y1), localScale(x, y)].map(strokePx).max()!
                let rx = max((r.x1 - r.x0) / 2, px / w), ry = max((r.y1 - r.y0) / 2, px / h)
                out.append(Quad(rect: Rect(x0: max(-1, x - rx), y0: max(-1, y - ry), x1: min(1, x + rx), y1: min(1, y + ry)), color: q.color))
            }
        }
        for pct in ringPercents {
            let r = ringRect(t, pct: pct)
            let a = Point(x: r.x0, y: r.y0), b = Point(x: r.x1, y: r.y0)
            let c = Point(x: r.x1, y: r.y1), d = Point(x: r.x0, y: r.y1)
            for (p, q) in [(a,b), (b,c), (c,d), (d,a)] { stroke(p, q, color: eye.color) }
        }
        for k in [1, 3, 5, 7] { for pct in cutPercents { cutStroke(k, pct, color: eye.color) } }
        for label in labels(t, widthPx: w, heightPx: h, localScale: localScale) {
            glyphs(text(label.text, in: label.rect, vertical: label.vertical, color: eye.color))
        }
        glyphs(eyeGlyph(eye, t, widthPx: w, heightPx: h))
        let white: SIMD4<Float> = [1, 1, 1, 1], black: SIMD4<Float> = [0, 0, 0, 1]
        if let (k, pct) = selected {
            if k % 2 == 1 { cutStroke(k, pct, color: white, weight: 3) }
            else {
                let r = ringRect(t, pct: pct), p = spokeNdc(t, k, pct)
                let ax = k % 4 == 0 ? 0 : 0.1 * (r.x1 - r.x0)
                let ay = k % 4 == 0 ? 0.1 * (r.y1 - r.y0) : 0
                stroke(Point(x: p.x - ax, y: p.y - ay), Point(x: p.x + ax, y: p.y + ay), color: white, weight: 3)
            }
        }
        if !status.isEmpty {
            let r = statusRect(t, status, widthPx: w, heightPx: h), b = statusBorderPx
            out.append(Quad(rect: r, color: black))
            glyphs(text(status, in: Rect(x0: r.x0 + b * 2 / w, y0: r.y0 + b * 2 / h,
                                        x1: r.x1 - b * 2 / w, y1: r.y1 - b * 2 / h), vertical: false, color: white))
        }
        return out
    }

    // Clip the measured side rectangle by all four cut half-planes in normalised drawable units.
    // Unlike subtracting four independent triangles, polygon clipping also handles cuts that meet across an axis.
    static func visibleAreaFraction(marks: [Int: Int]) -> Double? {
        guard (0..<8).allSatisfy({ marks[$0] != nil }) else { return nil }
        let right = Double(marks[0]!) / 100, top = Double(marks[2]!) / 100
        let left = Double(marks[4]!) / 100, bottom = Double(marks[6]!) / 100
        var polygon = [Point(x: -left, y: -bottom), Point(x: right, y: -bottom),
                       Point(x: right, y: top), Point(x: -left, y: top)]
        for k in [1, 3, 5, 7] {
            let n = CornerSpokes.unit(k), limit = 2 * Double(marks[k]!) / 100
            func distance(_ p: Point) -> Double { p.x * n.u + p.y * n.v - limit }
            var next: [Point] = []
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count], da = distance(a), db = distance(b)
                if da <= 0 { next.append(a) }
                if (da <= 0) != (db <= 0) {
                    let f = da / (da - db)
                    next.append(Point(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                }
            }
            polygon = next
        }
        guard !polygon.isEmpty else { return 0 }
        return abs(polygon.indices.reduce(0.0) { sum, i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return sum + a.x * b.y - b.x * a.y
        }) / 8 // shoelace / 2, divided by drawable area 4
    }

    private static func f4(_ v: Double) -> String { v.isInfinite ? "inf" : String(format: "%.4f", v) }

    static func markFields(_ eye: CornerEye, _ spoke: Int, _ pct: Int, _ t: CornerTangents) -> KeyValuePairs<String, Any> {
        let p = t.point(spoke: spoke, pct: pct)
        return ["eye": eye.rawValue, "pos_deg": CornerSpokes.degText(spoke), "ring_pct": pct, "kind": CornerSpokes.kind(spoke), "tan_x": f4(p.x), "tan_y": f4(p.y)]
    }

    static func viewFields(_ eye: CornerEye, view: Int, _ t: CornerTangents, drawableW: Int, drawableH: Int, viewport: String) -> KeyValuePairs<String, Any> {
        ["eye": eye.rawValue, "view": view, "tan_left": f4(t.left), "tan_right": f4(t.right), "tan_bottom": f4(t.bottom),
         "tan_top": f4(t.top), "drawable_w": drawableW, "drawable_h": drawableH, "viewport": viewport]
    }

    static func summaryFields(_ eye: CornerEye, _ t: CornerTangents, marks: [Int: Int]) -> KeyValuePairs<String, Any> {
        guard let area = visibleAreaFraction(marks: marks) else {
            return ["eye": eye.rawValue, "marks": marks.count, "shape": "incomplete", "visible_area_frac": "unavailable"]
        }
        return ["eye": eye.rawValue, "shape": "octagon", "marks": marks.count,
                "sides": CornerSpokes.axes.map { String(marks[$0]!) }.joined(separator: ","),
                "cuts": CornerSpokes.diagonals.map { String(marks[$0.spoke]!) }.joined(separator: ","),
                "visible_area_frac": f4(area), "diag_floor": CornerSpokes.diagonals.contains { marks[$0.spoke]! <= ringPercents.last! }]
    }

    // visionOS 27.0 SDK headers searched for a visible-area / hidden-area / visibility-mask API: none. The only mask is
    // cp_drawable_render_context drawMaskOnStencilAttachment (26+), documented as the full texture in full and mixed
    // immersion (a progressive-immersion portal mask, not the lens edge).
    static var apiFields: KeyValuePairs<String, Any> {
        ["api": "unavailable", "sdk": "xros27.0", "searched": "CompositorServices,ARKit,RealityKit,RealityFoundation", "stencil_mask": "progressive_only"]
    }
}

// The measurement walk: per eye (both: L then R), spokes 0 ... 315 degrees; the ring is stepped out/in and recorded.
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
    private var percents: [Int] { spoke % 2 == 0 ? CornerChart.ringPercents : CornerChart.cutPercents }
    var pct: Int { percents[min(ringIndex, percents.count - 1)] }

    // The other eye is black in the monocular modes.
    func lit(_ e: CornerEye) -> Bool { mode == .both || eyes.contains(e) }

    // 7-segment status: eye, spoke degrees, selected ring ("L 45 70"), or "donE".
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
            ringIndex = min(ringIndex + 1, percents.count - 1)
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
                ringIndex = min(ringIndex, percents.count - 1)
            } else {
                events.append(.summary(eye))
                (eyeIndex, spoke) = (eyeIndex + 1, 0)
                ringIndex = min(ringIndex, percents.count - 1)
                if self.eye == nil { events.append(.done) }
            }
            return events
        }
        ringIndex = min(ringIndex, percents.count - 1)
        return []
    }
}
