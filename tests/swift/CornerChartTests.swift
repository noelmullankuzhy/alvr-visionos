// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift
// Corner chart (GM decision 65): rings at a percentage of each eye's own tangent extent per side (asymmetric and canted
// frusta), labels inside the drawable and inside their own ring, the walk through TL..L per eye with its marks, the
// visible tangent polygon from the marks, and the DIAG corner line formats.
import Foundation

private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

// AVP-like eyes: asymmetric (nasal side smaller), and a canted right eye whose own frustum is strongly lopsided.
private let leftEye = CornerTangents(left: 1.394, right: 1.10, bottom: 1.292, top: 1.05)
private let cantedEye = CornerTangents(left: 0.80, right: 1.70, bottom: 1.40, top: 0.95)

private func testRingsInTangentSpace() {
    expectEqual(CornerChart.ringPercents, [100, 98, 96, 94, 92, 90, 88, 85, 80, 75], "ring set")
    for t in [leftEye, cantedEye] {
        let full = CornerChart.ringRect(t, pct: 100)
        expect(near(full.x0, -1) && near(full.x1, 1) && near(full.y0, -1) && near(full.y1, 1), "100% is the drawable edge")
        for pct in CornerChart.ringPercents {
            let p = Double(pct) / 100
            let r = CornerChart.ringRect(t, pct: pct)
            // Each side at p of that side's own tangent, mapped by the view's projection.
            expect(near(r.x0, (2 * -p * t.left - t.right + t.left) / (t.left + t.right)), "left side at \(pct)% of tan_left")
            expect(near(r.x1, (2 * p * t.right - t.right + t.left) / (t.left + t.right)), "right side at \(pct)% of tan_right")
            expect(near(r.y0, (2 * -p * t.bottom - t.top + t.bottom) / (t.bottom + t.top)), "bottom at \(pct)% of tan_bottom")
            expect(near(r.y1, (2 * p * t.top - t.top + t.bottom) / (t.bottom + t.top)), "top at \(pct)% of tan_top")
        }
        let tl = t.point(.TL, pct: 90)
        expect(near(tl.x, -0.9 * t.left) && near(tl.y, 0.9 * t.top), "TL tangent")
        let br = t.point(.BR, pct: 80)
        expect(near(br.x, 0.8 * t.right) && near(br.y, -0.8 * t.bottom), "BR tangent")
        let top = t.point(.T, pct: 50)
        expect(near(top.x, 0.25 * (t.right - t.left)) && near(top.y, 0.5 * t.top), "T is the ring's top edge midpoint")
        let l = t.point(.L, pct: 100)
        expect(near(l.x, -t.left) && near(l.y, (t.top - t.bottom) / 2), "L is the ring's left edge midpoint")
        let n = t.ndc(x: 0, y: 0)
        expect(near(n.x, (t.left - t.right) / (t.left + t.right)) && near(n.y, (t.bottom - t.top) / (t.bottom + t.top)), "tangent origin")
    }
    // A canted frustum is asymmetric in NDC: the 90% ring is 10% of each side's own extent in, not 5% of the width.
    let r = CornerChart.ringRect(cantedEye, pct: 90)
    expect(near(r.x0 + 1, 0.2 * 0.80 / 2.50) && near(1 - r.x1, 0.2 * 1.70 / 2.50), "canted: per-side insets differ")
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
        expectEqual(labels.count, CornerChart.ringPercents.count * CornerPos.allCases.count, "a label per ring at every corner and edge midpoint")
        let drawable = CornerChart.Rect(x0: -1, y0: -1, x1: 1, y1: 1)
        for label in labels {
            expect(inside(label.rect, drawable), "\(label.pct) \(label.pos) inside the drawable")
            expect(inside(label.rect, CornerChart.ringRect(t, pct: label.pct)), "\(label.pct) \(label.pos) inside its own ring")
            expect((label.rect.y1 - label.rect.y0) * h / 2 >= 6, "\(label.pct) \(label.pos) at least 6 px")
            expectEqual(label.text, "\(label.pct)", "label text")
        }
        for pos in CornerPos.allCases {
            let at = labels.filter { $0.pos == pos }
            for i in 0..<at.count { for j in (i + 1)..<at.count {
                expect(!overlaps(at[i].rect, at[j].rect), "\(pos): \(at[i].pct) and \(at[j].pct) do not overlap")
            } }
        }
        // Larger bands carry larger numbers (75/80 vs 100), up to the cap.
        let top100 = labels.first { $0.pos == .T && $0.pct == 100 }!.rect
        let top75 = labels.first { $0.pos == .T && $0.pct == 75 }!.rect
        expect(top75.y1 - top75.y0 > top100.y1 - top100.y0, "inner labels larger")
        let quads = CornerChart.geometry(t, widthPx: w, heightPx: h, selected: (.TL, 94), status: "L tL 94")
        expect(quads.allSatisfy { inside($0.rect, drawable) }, "all chart geometry inside the drawable")
        expect(quads.count > labels.count, "rings, labels, selection and status")
    }
}

private func testSessionAndPolygon() {
    let s = CornerChartSession(mode: .left)
    expectEqual(s.eye, .left, "left only measures L")
    expect(s.lit(.left) && !s.lit(.right), "left only: right eye black")
    expectEqual(s.pos, .TL, "starts at TL")
    expectEqual(s.pct, 100, "starts at the drawable edge")
    expect(s.apply(.outward).isEmpty && s.pct == 100, "outermost clamps")
    _ = s.apply(.inward); _ = s.apply(.inward); _ = s.apply(.inward)
    expectEqual(s.pct, 94, "three steps in")
    expectEqual(s.apply(.record), [.mark(.left, .TL, 94)], "record logs the mark")
    expectEqual(s.pos, .T, "then the next position")
    expectEqual(s.statusText, "L t 94", "status: eye, position, ring")
    _ = s.apply(.back)
    expectEqual(s.pos, .TL, "back to re-record")
    _ = s.apply(.inward)
    _ = s.apply(.record)
    expectEqual(s.marks[.left]?[.TL], 92, "re-recorded mark wins")
    var events: [CornerChartSession.Event] = []
    for _ in 1..<CornerPos.allCases.count { events += s.apply(.record) }
    expectEqual(events.suffix(2), [.summary(.left), .done], "after L the summary, left only ends")
    expect(s.eye == nil && s.statusText == "donE", "done")

    let both = CornerChartSession(mode: .both)
    expect(both.lit(.left) && both.lit(.right), "both eyes lit")
    for _ in CornerPos.allCases { _ = both.apply(.record) }
    expectEqual(both.eye, .right, "both: R after L")
    expectEqual(CornerChartSession(mode: .right).eye, .right, "right only measures R")
    expect(!CornerChartSession(mode: .right).lit(.left), "right only: left eye black")

    let t = CornerTangents(left: 1.0, right: 2.0, bottom: 1.0, top: 1.0)
    var marks: [CornerPos: Int] = [:]
    for pos in CornerPos.allCases { marks[pos] = 100 }
    marks[.TL] = 80
    let poly = CornerChart.polygon(t, marks: marks)!
    expectEqual(poly.count, 8, "8 vertices")
    expect(near(poly[0].x, -1) && near(poly[0].y, -1), "starts at BL (counterclockwise)")
    expect(near(poly[6].x, -0.8) && near(poly[6].y, 0.8), "TL from its mark")
    expect(near(poly[5].x, 0.5) && near(poly[5].y, 1.0), "T at the edge midpoint")
    // Full rectangle 3 x 2 = 6; TL cut: corner triangle (L(-1,0) -> TL'(-0.8,0.8) -> T(0.5,1)) vs the full corner.
    let full = CornerChart.polygon(t, marks: Dictionary(uniqueKeysWithValues: CornerPos.allCases.map { ($0, 100) }))!
    expect(near(CornerChart.area(full), 6.0), "full rect area")
    expect(CornerChart.area(poly) < 6.0, "a cut corner loses area")
    marks[.R] = nil
    expect(CornerChart.polygon(t, marks: marks) == nil, "no polygon until all 8 are marked")
}

private func testLogFormats() {
    let t = CornerTangents(left: 1.394, right: 1.1, bottom: 1.292, top: 1.05)
    expectEqual(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.markFields(.left, .TL, 94, t)),
                "DIAG corner t_ms=7 eye=L pos=TL ring_pct=94 tan_x=-1.3104 tan_y=0.9870", "mark line")
    expectEqual(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.viewFields(.right, view: 1, t, drawableW: 1888, drawableH: 1792, viewport: "0,0,1888,1792")),
                "DIAG corner t_ms=7 eye=R view=1 tan_left=1.3940 tan_right=1.1000 tan_bottom=1.2920 tan_top=1.0500 drawable_w=1888 drawable_h=1792 viewport=0,0,1888,1792",
                "per-eye projection and drawable once per session")
    var marks: [CornerPos: Int] = [:]
    for pos in CornerPos.allCases { marks[pos] = 100 }
    let line = Diag.line(topic: "corner_summary", tMs: 7, fields: CornerChart.summaryFields(.left, t, marks: marks))
    expect(line.hasPrefix("DIAG corner_summary t_ms=7 eye=L marks=8 polygon=-1.3940,-1.2920;"), "summary polygon from BL: \(line)")
    expect(line.hasSuffix(" area_frac=1.0000"), "visible area as a fraction of the drawable's tangent rect: \(line)")
    marks[.B] = nil
    expect(Diag.line(topic: "corner_summary", tMs: 7, fields: CornerChart.summaryFields(.left, t, marks: marks)).contains("polygon=incomplete"),
           "incomplete marks say so")
    expectEqual(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.apiFields),
                "DIAG corner t_ms=7 api=unavailable sdk=xros27.0 searched=CompositorServices,ARKit,RealityKit,RealityFoundation stencil_mask=progressive_only",
                "no visible-area API in the SDK")
    expectEqual(CornerChartMode(setting: "Left only"), .left, "setting names")
    expectEqual(CornerChartMode(setting: "garbage"), .off, "unknown setting is off")
}

@main enum CornerChartTests {
    static func main() {
        testRingsInTangentSpace()
        testLabels()
        testSessionAndPolygon()
        testLogFormats()
        finishTests("CornerChartTests")
    }
}
