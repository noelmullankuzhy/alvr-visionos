//
//  CornerChart.swift
//
// Corner chart (GM decision 65): measures where each eye's visible area ends, for the render corner trim (decision 60).
// Per eye, in that eye's own tangent space, nested outlines at 100 ... 75% of the drawable's tangent extent on each
// side, numbered at every corner and edge midpoint. The wearer keeps the head still, looks into each corner/edge and
// steps the highlighted ring until it is the outermost one still seen; the marks give the visible tangent polygon.
// Geometry is NDC quads (x right, y up) so it is drawn without a projection; the device side is CornerChartRenderer.
// Foundation-only so it is unit tested on macOS (tests/swift/CornerChartTests.swift).
//

import Foundation

enum CornerEye: String { case left = "L", right = "R" }

// Walking order: clockwise from top left.
enum CornerPos: String, CaseIterable {
    case TL, T, TR, R, BR, B, BL, L

    // Outward direction (x right, y up).
    var dir: (x: Double, y: Double) {
        switch self {
        case .TL: return (-1, 1)
        case .T: return (0, 1)
        case .TR: return (1, 1)
        case .R: return (1, 0)
        case .BR: return (1, -1)
        case .B: return (0, -1)
        case .BL: return (-1, -1)
        case .L: return (-1, 0)
        }
    }
}

enum CornerChartMode: String, CaseIterable {
    case off = "Off", both = "Both eyes", left = "Left only", right = "Right only"

    init(setting: String) { self = CornerChartMode(rawValue: setting) ?? .off }
}

// Tangent magnitudes of one view, in gimmeTangents order (left, right, bottom, top).
struct CornerTangents: Equatable {
    let left, right, bottom, top: Double

    init(left: Double, right: Double, bottom: Double, top: Double) {
        (self.left, self.right, self.bottom, self.top) = (left, right, bottom, top)
    }

    init(simd t: SIMD4<Float>) { self.init(left: Double(t.x), right: Double(t.y), bottom: Double(t.z), top: Double(t.w)) }

    // Signed tangent of a ring's corner or edge midpoint.
    func point(_ pos: CornerPos, pct: Int) -> (x: Double, y: Double) {
        let p = Double(pct) / 100
        let d = pos.dir
        let x = d.x < 0 ? -p * left : d.x > 0 ? p * right : p * (right - left) / 2
        let y = d.y < 0 ? -p * bottom : d.y > 0 ? p * top : p * (top - bottom) / 2
        return (x, y)
    }

    // The view's projection: tangent -left..right -> NDC -1..1, -bottom..top -> -1..1.
    func ndc(x: Double, y: Double) -> (x: Double, y: Double) {
        ((2 * x - right + left) / (left + right), (2 * y - top + bottom) / (bottom + top))
    }
}

enum CornerChart {
    static let ringPercents = [100, 98, 96, 94, 92, 90, 88, 85, 80, 75]
    static let polygonOrder: [CornerPos] = [.BL, .B, .BR, .R, .TR, .T, .TL, .L]
    static let linePx = 3.0, padPx = 2.0, maxLabelPx = 48.0, minLabelPx = 6.0

    struct Rect: Equatable { var x0, y0, x1, y1: Double }
    struct Quad { let rect: Rect; let color: SIMD4<Float> }
    struct Label { let pct: Int; let pos: CornerPos; let text: String; let rect: Rect; let vertical: Bool }

    static let palette: [SIMD4<Float>] = [[1, 1, 1, 1], [1, 1, 0, 1], [0, 1, 1, 1], [1, 0, 1, 1], [0, 1, 0, 1],
                                          [1, 0.5, 0, 1], [0.4, 0.6, 1, 1], [1, 0.3, 0.3, 1], [1, 1, 1, 1], [1, 1, 0, 1]]

    static func ringRect(_ t: CornerTangents, pct: Int) -> Rect {
        let p = Double(pct) / 100
        let lo = t.ndc(x: -p * t.left, y: -p * t.bottom), hi = t.ndc(x: p * t.right, y: p * t.top)
        return Rect(x0: lo.x, y0: lo.y, x1: hi.x, y1: hi.y)
    }

    // 7-segment glyph widths: 0.55 h per character, 0.2 h between (horizontal) or 0.25 h between rows (vertical).
    static func textSize(_ text: String, h: Double, vertical: Bool) -> (w: Double, h: Double) {
        let n = Double(text.count)
        return vertical ? (0.55 * h, n * h + (n - 1) * 0.25 * h) : (n * 0.55 * h + (n - 1) * 0.2 * h, h)
    }

    // Every ring's number at every position, just inside its own line and clear of the next ring in (band-limited
    // size, capped); left/right edge numbers stack vertically so they fit the narrow side bands.
    static func labels(_ t: CornerTangents, widthPx w: Double, heightPx h: Double) -> [Label] {
        let dx = 2 / w, dy = 2 / h, inset = linePx + padPx
        var out: [Label] = []
        for (i, pct) in ringPercents.enumerated() {
            let r = ringRect(t, pct: pct)
            let next = i + 1 < ringPercents.count ? ringRect(t, pct: ringPercents[i + 1]) : nil
            func avail(_ bandNdc: Double?, _ scale: Double) -> Double { bandNdc.map { $0 / scale - linePx - 2 * padPx } ?? .infinity }
            let side = (l: avail(next.map { $0.x0 - r.x0 }, dx), r: avail(next.map { r.x1 - $0.x1 }, dx),
                        b: avail(next.map { $0.y0 - r.y0 }, dy), t: avail(next.map { r.y1 - $0.y1 }, dy))
            for pos in CornerPos.allCases {
                let d = pos.dir
                let vertical = d.y == 0
                let fit = vertical ? (d.x < 0 ? side.l : side.r) / 0.55 : (d.y > 0 ? side.t : side.b)
                let size = textSize("\(pct)", h: max(min(fit, maxLabelPx), minLabelPx), vertical: vertical)
                let (sw, sh) = (size.w * dx, size.h * dy)
                let x0 = d.x < 0 ? r.x0 + inset * dx : d.x > 0 ? r.x1 - inset * dx - sw : (r.x0 + r.x1 - sw) / 2
                let y0 = d.y < 0 ? r.y0 + inset * dy : d.y > 0 ? r.y1 - inset * dy - sh : (r.y0 + r.y1 - sh) / 2
                out.append(Label(pct: pct, pos: pos, text: "\(pct)", rect: Rect(x0: x0, y0: y0, x1: x0 + sw, y1: y0 + sh), vertical: vertical))
            }
        }
        return out
    }

    // Segments a top, b upper right, c lower right, d bottom, e lower left, f upper left, g middle.
    private static let segments: [Character: String] = [
        "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg", "5": "acdfg", "6": "acdefg", "7": "abc",
        "8": "abcdefg", "9": "abcdfg", "L": "def", "r": "eg", "t": "defg", "b": "cdefg", "d": "bcdeg", "o": "cdeg",
        "n": "ceg", "E": "adefg", "-": "g"]

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
                default: q = Rect(x0: gx + cw - sv, y0: gy, x1: gx + cw, y1: mid)
                }
                out.append(Quad(rect: q, color: color))
            }
        }
        return out
    }

    // One eye's chart: rings (inner strokes), numbers, the selected ring's highlight + large number, centred status.
    static func geometry(_ t: CornerTangents, widthPx w: Double, heightPx h: Double, selected: (pos: CornerPos, pct: Int)?, status: String) -> [Quad] {
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
        let white: SIMD4<Float> = [1, 1, 1, 1], black: SIMD4<Float> = [0, 0, 0, 1]
        func boxed(_ s: String, centre: (x: Double, y: Double), px: Double) {
            let size = textSize(s, h: px, vertical: false)
            let r = Rect(x0: centre.x - size.w * dx / 2, y0: centre.y - size.h * dy / 2, x1: centre.x + size.w * dx / 2, y1: centre.y + size.h * dy / 2)
            out.append(Quad(rect: Rect(x0: r.x0 - 6 * dx, y0: r.y0 - 6 * dy, x1: r.x1 + 6 * dx, y1: r.y1 + 6 * dy), color: black))
            out += text(s, in: r, vertical: false, color: white)
        }
        if let (pos, pct) = selected {
            let r = ringRect(t, pct: pct), d = pos.dir, th = 3 * linePx
            let ax = d.x < 0 ? r.x0 : d.x > 0 ? r.x1 : (r.x0 + r.x1) / 2, ay = d.y < 0 ? r.y0 : d.y > 0 ? r.y1 : (r.y0 + r.y1) / 2
            let armX = 0.1 * (r.x1 - r.x0), armY = 0.1 * (r.y1 - r.y0)
            // Arms along the ring's edges from the corner (or centred on the edge midpoint), inside the ring.
            if d.y != 0 {
                out.append(Quad(rect: Rect(x0: d.x < 0 ? ax : ax - armX, y0: d.y > 0 ? ay - th * dy : ay,
                                           x1: d.x > 0 ? ax : ax + armX, y1: d.y > 0 ? ay : ay + th * dy), color: white))
            }
            if d.x != 0 {
                out.append(Quad(rect: Rect(x0: d.x > 0 ? ax - th * dx : ax, y0: d.y < 0 ? ay : ay - armY,
                                           x1: d.x > 0 ? ax : ax + th * dx, y1: d.y > 0 ? ay : ay + armY), color: white))
            }
            let size = textSize("\(pct)", h: maxLabelPx, vertical: false), m = th + 40
            boxed("\(pct)", centre: (ax - d.x * (m + size.w / 2) * dx, ay - d.y * (m + size.h / 2) * dy), px: maxLabelPx)
        }
        if !status.isEmpty {
            boxed(status, centre: t.ndc(x: 0, y: 0), px: 0.04 * h)
        }
        return out
    }

    // Visible tangent polygon, counterclockwise from BL; nil until all 8 positions are marked.
    static func polygon(_ t: CornerTangents, marks: [CornerPos: Int]) -> [(x: Double, y: Double)]? {
        var out: [(x: Double, y: Double)] = []
        for pos in polygonOrder {
            guard let pct = marks[pos] else { return nil }
            out.append(t.point(pos, pct: pct))
        }
        return out
    }

    static func area(_ poly: [(x: Double, y: Double)]) -> Double {
        abs(poly.indices.reduce(0.0) { acc, i in
            let a = poly[i], b = poly[(i + 1) % poly.count]
            return acc + a.x * b.y - b.x * a.y
        }) / 2
    }

    private static func f4(_ v: Double) -> String { String(format: "%.4f", v) }

    static func markFields(_ eye: CornerEye, _ pos: CornerPos, _ pct: Int, _ t: CornerTangents) -> KeyValuePairs<String, Any> {
        let p = t.point(pos, pct: pct)
        return ["eye": eye.rawValue, "pos": pos.rawValue, "ring_pct": pct, "tan_x": f4(p.x), "tan_y": f4(p.y)]
    }

    static func viewFields(_ eye: CornerEye, view: Int, _ t: CornerTangents, drawableW: Int, drawableH: Int, viewport: String) -> KeyValuePairs<String, Any> {
        ["eye": eye.rawValue, "view": view, "tan_left": f4(t.left), "tan_right": f4(t.right), "tan_bottom": f4(t.bottom),
         "tan_top": f4(t.top), "drawable_w": drawableW, "drawable_h": drawableH, "viewport": viewport]
    }

    static func summaryFields(_ eye: CornerEye, _ t: CornerTangents, marks: [CornerPos: Int]) -> KeyValuePairs<String, Any> {
        guard let poly = polygon(t, marks: marks) else {
            return ["eye": eye.rawValue, "marks": marks.count, "polygon": "incomplete", "area_frac": "unavailable"]
        }
        return ["eye": eye.rawValue, "marks": marks.count, "polygon": poly.map { "\(f4($0.x)),\(f4($0.y))" }.joined(separator: ";"),
                "area_frac": f4(area(poly) / ((t.left + t.right) * (t.bottom + t.top)))]
    }

    // visionOS 27.0 SDK headers searched for a visible-area / hidden-area / visibility-mask API: none. The only mask is
    // cp_drawable_render_context drawMaskOnStencilAttachment (26+), documented as the full texture in full and mixed
    // immersion (a progressive-immersion portal mask, not the lens edge).
    static var apiFields: KeyValuePairs<String, Any> {
        ["api": "unavailable", "sdk": "xros27.0", "searched": "CompositorServices,ARKit,RealityKit,RealityFoundation", "stencil_mask": "progressive_only"]
    }
}

// The measurement walk: per eye (both: L then R), positions TL..L; the ring is stepped out/in and recorded per position.
final class CornerChartSession {
    enum Action { case outward, inward, record, back }
    enum Event: Equatable { case mark(CornerEye, CornerPos, Int), summary(CornerEye), done }

    let mode: CornerChartMode
    let eyes: [CornerEye]
    private(set) var eyeIndex = 0
    private(set) var posIndex = 0
    private(set) var ringIndex = 0
    private(set) var marks: [CornerEye: [CornerPos: Int]] = [:]

    init(mode: CornerChartMode) {
        self.mode = mode
        eyes = mode == .left ? [.left] : mode == .right ? [.right] : mode == .both ? [.left, .right] : []
    }

    var eye: CornerEye? { eyeIndex < eyes.count ? eyes[eyeIndex] : nil }
    var pos: CornerPos { CornerPos.allCases[posIndex] }
    var pct: Int { CornerChart.ringPercents[ringIndex] }

    // The other eye is black in the monocular modes.
    func lit(_ e: CornerEye) -> Bool { mode == .both || eyes.contains(e) }

    private static let posText: [CornerPos: String] = [.TL: "tL", .T: "t", .TR: "tr", .R: "r", .BR: "br", .B: "b", .BL: "bL", .L: "L"]

    // 7-segment status: eye, position, selected ring ("L tL 94"), or "donE".
    var statusText: String {
        guard let eye else { return "donE" }
        return "\(eye == .left ? "L" : "r") \(Self.posText[pos]!) \(pct)"
    }

    func apply(_ action: Action) -> [Event] {
        let last = CornerPos.allCases.count - 1
        switch action {
        case .outward:
            ringIndex = max(ringIndex - 1, 0)
        case .inward:
            ringIndex = min(ringIndex + 1, CornerChart.ringPercents.count - 1)
        case .back:
            if eye == nil, !eyes.isEmpty {
                (eyeIndex, posIndex) = (eyes.count - 1, last)
            } else if posIndex > 0 {
                posIndex -= 1
            } else if eyeIndex > 0 {
                (eyeIndex, posIndex) = (eyeIndex - 1, last)
            }
        case .record:
            guard let eye else { return [] }
            marks[eye, default: [:]][pos] = pct
            var events: [Event] = [.mark(eye, pos, pct)]
            if posIndex < last {
                posIndex += 1
            } else {
                events.append(.summary(eye))
                (eyeIndex, posIndex) = (eyeIndex + 1, 0)
                if self.eye == nil { events.append(.done) }
            }
            return events
        }
        return []
    }
}
