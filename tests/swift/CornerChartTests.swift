// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift
// Corner chart (GM decision 65): 16 spokes every 22.5 degrees per eye (0 = right, counter-clockwise) with rings at a
// percentage of that eye's own tangent extent along the spoke (diagonals end at the drawable corner), for asymmetric
// and canted frusta; labels inside the drawable and their own ring; the per-eye walk with its marks; the visible
// tangent polygon; the boundary shape classification (rectangle / rounded / ellipse); the DIAG corner line formats;
// per-eye colour and L / R glyph (decision 65a).
import Foundation

private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

// AVP-like eyes: asymmetric (nasal side smaller), and a canted right eye whose own frustum is strongly lopsided.
private let leftEye = CornerTangents(left: 1.394, right: 1.10, bottom: 1.292, top: 1.05)
private let cantedEye = CornerTangents(left: 0.80, right: 1.70, bottom: 1.40, top: 0.95)

private func testSpokes() {
    expectEqual(CornerChart.ringPercents, [100, 98, 96, 94, 92, 90, 88, 85, 80, 75], "ring set")
    expectEqual(CornerSpokes.count, 16, "16 spokes")
    expectEqual((0..<16).map(CornerSpokes.degText), ["0", "22.5", "45", "67.5", "90", "112.5", "135", "157.5", "180",
                                                     "202.5", "225", "247.5", "270", "292.5", "315", "337.5"], "every 22.5 degrees from right, CCW")
    let tan225 = tan(22.5 * Double.pi / 180)
    for t in [leftEye, cantedEye] {
        func at(_ k: Int, _ pct: Int) -> (x: Double, y: Double) { t.point(spoke: k, pct: pct) }
        expect(near(at(0, 100).x, t.right) && near(at(0, 100).y, 0), "0 deg: right edge on the axis")
        expect(near(at(4, 100).x, 0) && near(at(4, 100).y, t.top), "90 deg: top")
        expect(near(at(8, 100).x, -t.left) && near(at(8, 100).y, 0), "180 deg: left")
        expect(near(at(12, 100).x, 0) && near(at(12, 100).y, -t.bottom), "270 deg: bottom")
        // Diagonals end at the drawable corner, whatever the asymmetry.
        expect(near(at(2, 100).x, t.right) && near(at(2, 100).y, t.top), "45 deg: TR corner")
        expect(near(at(6, 100).x, -t.left) && near(at(6, 100).y, t.top), "135 deg: TL corner")
        expect(near(at(10, 100).x, -t.left) && near(at(10, 100).y, -t.bottom), "225 deg: BL corner")
        expect(near(at(14, 100).x, t.right) && near(at(14, 100).y, -t.bottom), "315 deg: BR corner")
        expect(near(at(1, 100).x, t.right) && near(at(1, 100).y, tan225 * t.top), "22.5 deg: right edge, tan 22.5 of the way up")
        expect(near(at(5, 100).x, -tan225 * t.left) && near(at(5, 100).y, t.top), "112.5 deg: top edge, left of centre")
        for k in 0..<16 {
            for pct in CornerChart.ringPercents {
                let p = Double(pct) / 100, a = at(k, pct), full = at(k, 100)
                expect(near(a.x, p * full.x) && near(a.y, p * full.y), "spoke \(k) ring \(pct): along the spoke from the axis")
                // The ring point lies on that ring's rectangle.
                let n = t.ndc(x: a.x, y: a.y), r = CornerChart.ringRect(t, pct: pct)
                let onEdge = near(n.x, r.x0) || near(n.x, r.x1) || near(n.y, r.y0) || near(n.y, r.y1)
                expect(onEdge && n.x >= r.x0 - 1e-9 && n.x <= r.x1 + 1e-9 && n.y >= r.y0 - 1e-9 && n.y <= r.y1 + 1e-9, "spoke \(k) ring \(pct) on its ring")
            }
        }
        let c = t.ndc(x: at(2, 90).x, y: at(2, 90).y)
        expect(near(c.x, (2 * 0.9 * t.right - t.right + t.left) / (t.left + t.right)) && near(c.y, (2 * 0.9 * t.top - t.top + t.bottom) / (t.bottom + t.top)),
               "90% on the TR diagonal in NDC")
        let full = CornerChart.ringRect(t, pct: 100)
        expect(near(full.x0, -1) && near(full.x1, 1) && near(full.y0, -1) && near(full.y1, 1), "100% is the drawable edge")
    }
    // Canted: the 45 deg spoke is not a 45 deg tangent direction; it follows each quadrant's own extent.
    let d = cantedEye.point(spoke: 6, pct: 100)
    expect(near(d.x, -0.80) && near(d.y, 0.95), "canted TL corner")
    expect(CornerTangents(simd: SIMD4<Float>(1.5, 1.25, 1.0, 0.75)) == CornerTangents(left: 1.5, right: 1.25, bottom: 1.0, top: 0.75),
           "gimmeTangents order (left, right, bottom, top)")
}

private func inside(_ a: CornerChart.Rect, _ b: CornerChart.Rect) -> Bool {
    a.x0 >= b.x0 - 1e-12 && a.x1 <= b.x1 + 1e-12 && a.y0 >= b.y0 - 1e-12 && a.y1 <= b.y1 + 1e-12
}

private func overlaps(_ a: CornerChart.Rect, _ b: CornerChart.Rect) -> Bool {
    a.x0 < b.x1 && b.x0 < a.x1 && a.y0 < b.y1 && b.y0 < a.y1
}

private func testLabels() {
    for (t, w, h) in [(leftEye, 1888.0, 1792.0), (cantedEye, 2400.0, 2200.0)] {
        let labels = CornerChart.labels(t, widthPx: w, heightPx: h)
        expectEqual(labels.count, CornerChart.ringPercents.count * CornerSpokes.count, "a label per ring on every spoke")
        let drawable = CornerChart.Rect(x0: -1, y0: -1, x1: 1, y1: 1)
        for label in labels {
            expect(inside(label.rect, drawable), "\(label.pct) spoke \(label.spoke) inside the drawable")
            expect(inside(label.rect, CornerChart.ringRect(t, pct: label.pct)), "\(label.pct) spoke \(label.spoke) inside its own ring")
            expect((label.rect.y1 - label.rect.y0) * h / 2 >= 6, "\(label.pct) spoke \(label.spoke) at least 6 px")
            expectEqual(label.text, "\(label.pct)", "label text")
        }
        var clashes = 0
        for i in 0..<labels.count { for j in (i + 1)..<labels.count where overlaps(labels[i].rect, labels[j].rect) { clashes += 1 } }
        expectEqual(clashes, 0, "no two labels overlap")
        let top100 = labels.first { $0.spoke == 4 && $0.pct == 100 }!.rect
        let top75 = labels.first { $0.spoke == 4 && $0.pct == 75 }!.rect
        expect(top75.y1 - top75.y0 > top100.y1 - top100.y0, "inner labels larger")
        for k in 0..<16 {
            for pct in [100, 75] {
                let quads = CornerChart.geometry(t, eye: .left, widthPx: w, heightPx: h, selected: (k, pct), status: "L 22.5 94")
                expect(quads.allSatisfy { inside($0.rect, drawable) }, "all chart geometry inside the drawable, spoke \(k) \(pct) selected")
                expect(quads.count > labels.count, "rings, labels, spokes, selection and status")
            }
        }
    }
}

private func testSession() {
    let s = CornerChartSession(mode: .left)
    expectEqual(s.eye, .left, "left only measures L")
    expect(s.lit(.left) && !s.lit(.right), "left only: right eye black")
    expectEqual(s.spoke, 0, "starts at 0 deg")
    expectEqual(s.pct, 100, "starts at the drawable edge")
    expect(s.apply(.outward).isEmpty && s.pct == 100, "outermost clamps")
    _ = s.apply(.inward); _ = s.apply(.inward); _ = s.apply(.inward)
    expectEqual(s.pct, 94, "three steps in")
    expectEqual(s.apply(.record), [.mark(.left, 0, 94)], "record logs the mark")
    expectEqual(s.spoke, 1, "then the next spoke")
    expectEqual(s.statusText, "L 22.5 94", "status: eye, spoke degrees, ring")
    _ = s.apply(.back)
    expectEqual(s.spoke, 0, "back to re-record")
    _ = s.apply(.inward)
    _ = s.apply(.record)
    expectEqual(s.marks[.left]?[0], 92, "re-recorded mark wins")
    var events: [CornerChartSession.Event] = []
    for _ in 1..<CornerSpokes.count { events += s.apply(.record) }
    expectEqual(events.suffix(2), [.summary(.left), .done], "after L the summary, left only ends")
    expect(s.eye == nil && s.statusText == "donE", "done")

    let both = CornerChartSession(mode: .both)
    expect(both.lit(.left) && both.lit(.right), "both eyes lit")
    for _ in 0..<CornerSpokes.count { _ = both.apply(.record) }
    expectEqual(both.eye, .right, "both: R after L")
    expectEqual(CornerChartSession(mode: .right).eye, .right, "right only measures R")
    expect(!CornerChartSession(mode: .right).lit(.left), "right only: left eye black")

    let t = CornerTangents(left: 1.0, right: 2.0, bottom: 1.0, top: 1.0)
    var marks: [Int: Int] = [:]
    for k in 0..<16 { marks[k] = 100 }
    marks[6] = 80
    let poly = CornerChart.polygon(t, marks: marks)!
    expectEqual(poly.count, 16, "16 vertices, CCW from 0 deg")
    expect(near(poly[0].x, 2) && near(poly[0].y, 0), "0 deg first")
    expect(near(poly[6].x, -0.8) && near(poly[6].y, 0.8), "TL corner from its mark")
    let full = CornerChart.polygon(t, marks: Dictionary(uniqueKeysWithValues: (0..<16).map { ($0, 100) }))!
    expect(near(CornerChart.area(full), 6.0), "full rect area")
    expect(CornerChart.area(poly) < 6.0, "a cut corner loses area")
    marks[3] = nil
    expect(CornerChart.polygon(t, marks: marks) == nil, "no polygon until all 16 are marked")
}

private func axesAnd(diag: Double, axis: Double = 100) -> [Int: Double] {
    var m: [Int: Double] = [:]
    for k in 0..<16 { m[k] = k % 4 == 2 ? diag : axis }
    return m
}

private func testShape() {
    // Normalised drawable units: axis spokes reach 1 at 100%, diagonals sqrt(2) at the corner.
    let rect = CornerShape.classify(axesAnd(diag: 100))!
    expect(near(rect.axisR, 1) && near(rect.diagR, 2.0.squareRoot()) && near(rect.ratio, 2.0.squareRoot()), "full rectangle radii")
    expect(near(rect.rectRatio, 2.0.squareRoot()) && near(rect.ellipseRatio, 1), "predictions for equal axes")
    expectEqual(rect.label, "rectangle", "diagonals reach the corner")
    expect(rect.superellipseN.isInfinite, "rectangle: superellipse exponent infinite")
    expectEqual(CornerShape.classify(axesAnd(diag: 96))!.label, "rectangle", ">= 0.95 of the corner is still a rectangle")
    let ellipse = CornerShape.classify(axesAnd(diag: 100 / 2.0.squareRoot()))!
    expect(near(ellipse.ratio, 1, 1e-9) && near(ellipse.superellipseN, 2, 1e-6), "ellipse through the axis points: ratio 1, n = 2")
    expectEqual(ellipse.label, "ellipse", "ellipse")
    expectEqual(CornerShape.classify(axesAnd(diag: 73))!.label, "ellipse", "within 1.05 of the ellipse prediction")
    let rounded = CornerShape.classify(axesAnd(diag: 85))!
    expectEqual(rounded.label, "rounded", "between")
    expect(rounded.superellipseN > 2 && rounded.superellipseN.isFinite, "a squircle exponent")
    expect(near(rounded.diagPctMean, 85), "raw diagonal ring mean")
    // Unequal axes: rectangle and ellipse predictions per quadrant from that quadrant's axis radii.
    var m = axesAnd(diag: 100)
    m[4] = 80; m[12] = 80
    let wide = CornerShape.classify(m)!
    expect(near(wide.axisR, 0.9) && near(wide.rectR, (1 + 0.64).squareRoot()), "axes 1 / 0.8: rect corner sqrt(1 + 0.64)")
    expect(near(wide.ellipseR, 1 / ((1 + 1 / 0.64) / 2).squareRoot()), "ellipse radius at the diagonal")
    expect(CornerShape.classify([0: 100, 4: 100]) == nil, "needs the 4 axis and 4 diagonal spokes")
    expect(!CornerShape.classify(axesAnd(diag: 80))!.diagFloor && CornerShape.classify(axesAnd(diag: 75))!.diagFloor,
           "a diagonal at the innermost ring is flagged (the true edge may be further in)")
}

private func testLogFormats() {
    let t = CornerTangents(left: 1.394, right: 1.1, bottom: 1.292, top: 1.05)
    expectEqual(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.markFields(.left, 6, 94, t)),
                "DIAG corner t_ms=7 eye=L pos_deg=135 ring_pct=94 tan_x=-1.3104 tan_y=0.9870", "mark line")
    expect(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.markFields(.right, 1, 100, t)).contains(" eye=R pos_deg=22.5 ring_pct=100 tan_x=1.1000 tan_y=0.4349"),
           "half-degree spokes")
    expectEqual(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.viewFields(.right, view: 1, t, drawableW: 1888, drawableH: 1792, viewport: "0,0,1888,1792")),
                "DIAG corner t_ms=7 eye=R view=1 tan_left=1.3940 tan_right=1.1000 tan_bottom=1.2920 tan_top=1.0500 drawable_w=1888 drawable_h=1792 viewport=0,0,1888,1792",
                "per-eye projection and drawable once per session")
    var marks: [Int: Int] = [:]
    for k in 0..<16 { marks[k] = 100 }
    let line = Diag.line(topic: "corner_summary", tMs: 7, fields: CornerChart.summaryFields(.left, t, marks: marks))
    expect(line.hasPrefix("DIAG corner_summary t_ms=7 eye=L marks=16 polygon=1.1000,0.0000;"), "summary polygon from 0 deg: \(line)")
    for field in [" area_frac=1.0000", " r=1.0000,1.0824,1.4142,", " axis_r=1.0000", " diag_r=1.4142", " rect_r=1.4142", " ellipse_r=1.0000",
                  " ratio=1.4142", " rect_ratio=1.4142", " ellipse_ratio=1.0000", " superellipse_n=inf", " diag_pct_mean=100.00",
                  " diag_floor=false", " shape=rectangle"] {
        expect(line.contains(field), "summary has\(field): \(line)")
    }
    marks[3] = nil
    expect(Diag.line(topic: "corner_summary", tMs: 7, fields: CornerChart.summaryFields(.left, t, marks: marks)).contains("polygon=incomplete"),
           "incomplete marks say so")
    expectEqual(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.apiFields),
                "DIAG corner t_ms=7 api=unavailable sdk=xros27.0 searched=CompositorServices,ARKit,RealityKit,RealityFoundation stencil_mask=progressive_only",
                "no visible-area API in the SDK")
    expectEqual(CornerChartMode(setting: "Left only"), .left, "setting names")
    expectEqual(CornerChartMode(setting: "garbage"), .off, "unknown setting is off")
}

// Decision 65a: a mono mirror capture names the eye. Left cyan, right magenta (rings, numbers, spokes) and a large
// L / R at the eye's tangent centre; the eye comes from the view's x offset (<= 0 left) and the monocular modes keep it.
private func testEyeColours() {
    expectEqual(CornerEye(viewOffsetX: -0.032), .left, "negative x offset: left eye")
    expectEqual(CornerEye(viewOffsetX: 0), .left, "zero x offset: left eye (<= 0 rule)")
    expectEqual(CornerEye(viewOffsetX: 0.032), .right, "positive x offset: right eye")
    expect(CornerEye.left.color == SIMD4<Float>(0, 1, 1, 1), "left cyan")
    expect(CornerEye.right.color == SIMD4<Float>(1, 0, 1, 1), "right magenta")
    expectEqual(CornerEye.left.glyph, "L", "left glyph")
    expectEqual(CornerEye.right.glyph, "R", "right glyph")
    expectEqual(CornerEye(viewOffsetX: -0.03).glyph, "L", "glyph follows the offset rule")
    expect(CornerEye(viewOffsetX: 0.03).color == CornerEye.right.color, "colour follows the offset rule")

    let white: SIMD4<Float> = [1, 1, 1, 1], black: SIMD4<Float> = [0, 0, 0, 1]
    let drawable = CornerChart.Rect(x0: -1, y0: -1, x1: 1, y1: 1)
    for (t, w, h) in [(leftEye, 1888.0, 1792.0), (cantedEye, 2400.0, 2200.0)] {
        for eye in [CornerEye.left, .right] {
            let other: CornerEye = eye == .left ? .right : .left
            let quads = CornerChart.geometry(t, eye: eye, widthPx: w, heightPx: h, selected: (3, 94), status: "\(eye.rawValue) 67.5 94")
            let tinted = quads.filter { $0.color != white && $0.color != black }
            expect(!tinted.isEmpty, "\(eye) has tinted geometry")
            expect(tinted.allSatisfy { $0.color == eye.color || $0.color == eye.dimColor }, "\(eye): rings, numbers and spokes in its colour")
            expect(!quads.contains { $0.color == other.color || $0.color == other.dimColor }, "\(eye): none of the other eye's colour")
            let ringQuads = CornerChart.ringPercents.count * 4, labelQuads = CornerChart.labels(t, widthPx: w, heightPx: h).count
            expect(quads.prefix(ringQuads).allSatisfy { $0.color == eye.color }, "\(eye): rings in its colour")
            expect(quads.dropFirst(ringQuads).prefix(labelQuads).allSatisfy { $0.color == eye.color }, "\(eye): numbers in its colour")
            // The glyph: large, at the eye's tangent centre, inside the drawable and the innermost ring, in its colour.
            let g = CornerChart.glyphRect(t, widthPx: w, heightPx: h)
            let c = t.ndc(x: 0, y: 0)
            expect(near((g.x0 + g.x1) / 2, c.x, 1e-12) && near((g.y0 + g.y1) / 2, c.y, 1e-12), "\(eye): glyph centred on the tangent origin")
            expect(inside(g, drawable), "\(eye): glyph inside the drawable")
            expect(inside(g, CornerChart.ringRect(t, pct: 75)), "\(eye): glyph inside the 75 ring")
            expect((g.y1 - g.y0) * h / 2 >= 100, "\(eye): glyph large (>= 100 px)")
            let glyph = CornerChart.eyeGlyph(eye, t, widthPx: w, heightPx: h)
            expect(!glyph.isEmpty && glyph.allSatisfy { inside($0.rect, g) && $0.color == eye.color }, "\(eye): glyph strokes inside its box, in its colour")
            expect(glyph.allSatisfy { q in quads.contains { $0.rect == q.rect && $0.color == q.color } }, "\(eye): chart draws the glyph")
            expect(quads.allSatisfy { inside($0.rect, drawable) }, "\(eye): all geometry inside the drawable")
        }
        // L and R glyphs differ: R has the bowl and leg, L only the stem and foot.
        let l = CornerChart.eyeGlyph(.left, t, widthPx: w, heightPx: h).map(\.rect)
        let r = CornerChart.eyeGlyph(.right, t, widthPx: w, heightPx: h).map(\.rect)
        expect(l != r && r.count > l.count, "L and R glyphs differ")
        let g = CornerChart.glyphRect(t, widthPx: w, heightPx: h)
        expect(l.contains { near($0.y0, g.y0) && near($0.x1, g.x1) }, "L foot reaches the bottom right")
        expect(!l.contains { near($0.y1, g.y1) && near($0.x1, g.x1) }, "L has no top right")
        expect(r.contains { near($0.y1, g.y1) && $0.x1 > (g.x0 + g.x1) / 2 }, "R has a top bar")
        expect(r.contains { near($0.y0, g.y0) && near($0.x1, g.x1) }, "R leg reaches the bottom right")
    }
    // Monocular modes: the lit eye keeps its colour, the other is black (not drawn).
    for (mode, lit) in [(CornerChartMode.left, CornerEye.left), (.right, .right)] {
        let s = CornerChartSession(mode: mode)
        expect(s.lit(lit) && !s.lit(lit == .left ? .right : .left), "\(mode): only \(lit) lit")
        let quads = CornerChart.geometry(leftEye, eye: lit, widthPx: 1888, heightPx: 1792, selected: nil, status: "")
        expect(quads.contains { $0.color == lit.color }, "\(mode): \(lit) keeps its colour")
    }
}

private func testMirrorScript() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = root.appendingPathComponent("tools/diag/capture-mirror.sh").path
    expect(FileManager.default.fileExists(atPath: script), "tools/diag/capture-mirror.sh exists")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-n", script]
    try? p.run()
    p.waitUntilExit()
    expectEqual(p.terminationStatus, 0, "sh -n capture-mirror.sh")
}

@main enum CornerChartTests {
    static func main() {
        testSpokes()
        testLabels()
        testSession()
        testShape()
        testLogFormats()
        testEyeColours()
        testMirrorScript()
        finishTests("CornerChartTests")
    }
}
