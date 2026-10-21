// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift
import Foundation

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }
private let eyes = [CornerTangents(left: 1.7321, right: 1, bottom: 1.1918, top: 1),
                    CornerTangents(left: 1, right: 1.7321, bottom: 1.1918, top: 1)]
private func overlaps(_ a: CornerChart.Rect, _ b: CornerChart.Rect) -> Bool {
    a.x0 < b.x1 - 1e-9 && b.x0 < a.x1 - 1e-9 && a.y0 < b.y1 - 1e-9 && b.y0 < a.y1 - 1e-9
}
private func testGeometry() {
    expectEqual(CornerChart.ringPercents, Array(stride(from: 100, through: 50, by: -5)), "rings include 50")
    expectEqual(CornerChart.cutPercents, Array(stride(from: 100, through: 30, by: -5)), "cuts reach 30")
    expectEqual(CornerSpokes.count, 8, "eight marks")
    expectEqual((0..<8).map(CornerSpokes.degText), ["0", "45", "90", "135", "180", "225", "270", "315"], "walk order")
    for t in eyes {
        for k in [1, 3, 5, 7] { for pct in CornerChart.cutPercents {
            let line = CornerChart.cut(spoke: k, pct: pct)
            let sign = CornerSpokes.unit(k), p = Double(pct) / 100
            expect(near(abs(line.a.x) + abs(line.a.y), 2 * p), "cut start on C_p")
            expect(near(abs(line.b.x) + abs(line.b.y), 2 * p), "cut end on C_p")
            expect(near((line.b.x - line.a.x) * sign.u + (line.b.y - line.a.y) * sign.v, 0), "perpendicular to diagonal")
            expect(near((line.a.x + line.b.x) / 2, p * sign.u) && near((line.a.y + line.b.y) / 2, p * sign.v), "touches ring p corner")
            for a in [line.a, line.b] { expect(abs(a.x) <= 1 && abs(a.y) <= 1, "clipped to drawable") }
        } }
        let scale: CornerChart.LocalScale = { _, _ in (0.25, 0.25) }
        expect(near(CornerChart.strokePx(scale(1, 1)), 12), "0.25 physical/logical needs 12 logical px")
        let labels = CornerChart.labels(t, widthPx: 6261, heightPx: 5023, localScale: scale)
        expectEqual(labels.count, 4 * (CornerChart.ringPercents.count + CornerChart.cutPercents.count), "axis rings and diagonal cuts only")
        for (i, a) in labels.enumerated() {
            let charHeight = (a.rect.y1 - a.rect.y0) * 5023 / 2 / (a.vertical ? Double(a.text.count) * 1.25 - 0.25 : 1)
            expect(charHeight * 0.25 >= 24 - 1e-8, "24 physical px per character")
            expect(a.rect.x0 >= -1 && a.rect.x1 <= 1 && a.rect.y0 >= -1 && a.rect.y1 <= 1, "label in drawable")
            for b in labels.dropFirst(i + 1) { expect(!overlaps(a.rect, b.rect), "labels do not overlap: \(a.spoke)/\(a.pct) and \(b.spoke)/\(b.pct)") }
        }
        let q = CornerChart.geometry(t, eye: .left, widthPx: 6261, heightPx: 5023, selected: (1, 70), status: "L 45 70", localScale: scale)
        expect(!q.isEmpty, "geometry emitted")
        expect(q.allSatisfy { $0.vertices.allSatisfy { $0.x >= -1 && $0.x <= 1 && $0.y >= -1 && $0.y <= 1 } }, "all vertices clipped")
        // Selected diagonal is a straight white cut, not two rectangle edges.
        let white = q.filter { $0.color == SIMD4<Float>(1, 1, 1, 1) && $0.vertices[0].x != $0.vertices[1].x && $0.vertices[0].y != $0.vertices[1].y }
        expect(!white.isEmpty, "white highlight follows cut")
        let base = CornerChart.geometry(t, eye: .left, widthPx: 6261, heightPx: 5023, selected: nil, status: "", localScale: scale)
        expect(base.allSatisfy { min(($0.rect.x1 - $0.rect.x0) * 6261 / 2, ($0.rect.y1 - $0.rect.y0) * 5023 / 2) >= 12 - 1e-8 }, "every stroke at least 3 physical px")
    }
}
private func testLowestScaleLabels() {
    for t in eyes {
        let labels = CornerChart.labels(t, widthPx: 6261, heightPx: 5023, localScale: { _, _ in (0.2, 0.2) })
        for k in CornerSpokes.axes {
            let axis = t.ndc(x: 0, y: 0)
            let ringLabels = labels.filter { $0.spoke == k }
            expectEqual(ringLabels.map(\.pct), CornerChart.ringPercents, "every ring still labelled")
            for label in ringLabels {
                let positive = (100 - label.pct) % 10 == 0
                if k == 0 || k == 4 {
                    expect(positive ? label.rect.y0 > axis.y : label.rect.y1 < axis.y, "alternate above/below horizontal axis")
                } else {
                    expect(positive ? label.rect.x0 > axis.x : label.rect.x1 < axis.x, "alternate right/left of vertical axis")
                }
            }
        }
        for (i, a) in labels.enumerated() {
            for b in labels.dropFirst(i + 1) { expect(!overlaps(a.rect, b.rect), "0.2 scale labels do not overlap: \(a.spoke)/\(a.pct) and \(b.spoke)/\(b.pct)") }
            expect(!overlaps(a.rect, CornerChart.glyphRect(t, widthPx: 6261, heightPx: 5023)), "label clear of eye glyph")
            expect(!overlaps(a.rect, CornerChart.statusRect(t, "L 315 30", widthPx: 6261, heightPx: 5023)), "label clear of status")
        }
    }
}
private func testVaryingScale() {
    let scale: CornerChart.LocalScale = { x, y in
        let peripheral = abs(x) > 0.5 || abs(y) > 0.5
        return peripheral ? (0.2, 0.25) : (1, 1)
    }
    for t in eyes {
        let labels = CornerChart.labels(t, widthPx: 6261, heightPx: 5023, localScale: scale)
        for (i, a) in labels.enumerated() {
            for b in labels.dropFirst(i + 1) { expect(!overlaps(a.rect, b.rect), "varying-scale labels do not overlap") }
        }
        let q = CornerChart.geometry(t, eye: .right, widthPx: 6261, heightPx: 5023, selected: (7, 30), status: "r 315 30", localScale: scale)
        expect(q.allSatisfy { $0.vertices.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 } }, "varying-scale geometry clipped")
    }
}
private func testSessionAndLogs() {
    let s = CornerChartSession(mode: .both)
    expect(s.lit(.left) && s.lit(.right), "both lit")
    for _ in 0..<20 { _ = s.apply(.inward) }
    expectEqual(s.pct, 50, "side floor 50")
    _ = s.apply(.record)
    for _ in 0..<20 { _ = s.apply(.inward) }
    expectEqual(s.pct, 30, "cut floor 30")
    for _ in 0..<8 { _ = s.apply(.outward) }
    expectEqual(s.statusText, "L 45 70", "status")
    _ = s.apply(.back)
    expectEqual(s.pct, 70, "back preserves valid selection")
    _ = s.apply(.record)
    for k in 1..<8 {
        let events = s.apply(.record)
        expectEqual(events.first, .mark(.left, k, 70), "mark in order")
        expectEqual(CornerSpokes.kind(k), k % 2 == 0 ? "side" : "cut", "mark kind")
        if k == 7 { expect(events.contains(.summary(.left)), "summary after eight") }
    }
    expectEqual(s.eye, .right, "R after eight L marks")
    for _ in 0..<8 { _ = s.apply(.record) }
    expectEqual(s.statusText, "donE", "done")
    _ = s.apply(.back)
    expectEqual(s.spoke, 7, "back from done")
    expect(!CornerChartSession(mode: .left).lit(.right), "monocular")
    let line = Diag.line(topic: "corner", tMs: 7, fields: CornerChart.markFields(.left, 1, 70, eyes[0]))
    expect(line.contains("eye=L pos_deg=45 ring_pct=70 kind=cut tan_x=0.7000 tan_y=0.7000"), "cut log: \(line)")
    expect(Diag.line(topic: "corner", tMs: 7, fields: CornerChart.markFields(.left, 0, 50, eyes[0])).contains("kind=side"), "side log")
    expectEqual(CornerEye(viewOffsetX: -0.03), .left, "eye from offset")
    expectEqual(CornerEye(viewOffsetX: 0.03), .right, "eye from offset")
    expect(CornerEye.left.color == SIMD4<Float>(0, 1, 1, 1) && CornerEye.right.color == SIMD4<Float>(1, 0, 1, 1), "eye colours")
}
private func testArea() {
    for (side, cut, area) in [(100, 100, 1.0), (100, 75, 0.875), (100, 50, 0.5), (55, 55, 0.3025), (55, 100, 0.3025)] {
        let marks = Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, $0 % 2 == 0 ? side : cut) })
        expect(near(CornerChart.visibleAreaFraction(marks: marks)!, area), "octagon area \(side)/\(cut)")
        let log = Diag.line(topic: "corner_summary", tMs: 1, fields: CornerChart.summaryFields(.left, eyes[0], marks: marks))
        expect(log.contains("shape=octagon") && log.contains("sides=\(side),\(side),\(side),\(side)") && log.contains("cuts=\(cut),\(cut),\(cut),\(cut)") && log.contains(String(format: "visible_area_frac=%.4f", area)), "raw octagon summary: \(log)")
        expect(log.contains("diag_floor=\(cut <= 50)"), "diag floor at 50")
    }
    expect(CornerChart.visibleAreaFraction(marks: [0: 100]) == nil, "incomplete")
    // Unequal sides: only q1 loses a triangle of legs .3; full side rectangle area is 2.55.
    let unequal = [0: 100, 1: 75, 2: 80, 3: 100, 4: 70, 5: 100, 6: 70, 7: 100]
    expect(near(CornerChart.visibleAreaFraction(marks: unequal)!, (2.55 - 0.045) / 4), "unequal sides")
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

    // Argument parsing (-c: check the arguments and exit, before any build, capture or folder creation).
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("capture-mirror-args-\(getpid())").path
    func run(_ args: [String]) -> (status: Int32, text: String) {
        let q = Process(), pipe = Pipe()
        q.executableURL = URL(fileURLWithPath: "/bin/sh")
        q.arguments = [script] + args + ["-o", out, "-c"]
        q.standardOutput = pipe
        q.standardError = pipe
        try? q.run()
        q.waitUntilExit()
        return (q.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    for args in [[], ["-i", "0.5"], ["-i", "10"], ["-i", ".25"], ["-i", "2."], ["-n", "0"], ["-n", "12"], ["-i", "1.5", "-n", "3"]] {
        let r = run(args)
        expectEqual(r.status, 0, "valid \(args): \(r.text)")
    }
    let ok = run(["-i", "0.5", "-n", "3"])
    expect(ok.text.contains("interval=0.5") && ok.text.contains("count=3"), "-c prints the parsed values: \(ok.text)")
    for (args, says) in [(["-n", "1.5"], "-n"), (["-n", "abc"], "-n"), (["-n", ""], "-n"), (["-n", "-1"], "-n"), (["-n", "1e3"], "-n"),
                         (["-i", "0"], "-i"), (["-i", "0.0"], "-i"), (["-i", "1.2.3"], "-i"), (["-i", "."], "-i"), (["-i", "abc"], "-i"),
                         (["-i", ""], "-i"), (["-i", "1e3"], "-i"), (["-i", "-2"], "-i"), (["-i", "2", "-n", "x"], "-n"), (["-i", "x", "-n", "2"], "-i")] {
        let r = run(args)
        expectEqual(r.status, 2, "invalid \(args) exits 2: \(r.text)")
        expect(r.text.contains("Error: \(says) "), "invalid \(args) names \(says): \(r.text)")
    }
    expect(!FileManager.default.fileExists(atPath: out), "-c creates nothing")

    // All scratch (Swift source, binary, compiler temp, module cache, logs) lives under <output>/.scratch.
    let text = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
    expect(text.contains("work=\"$out/.scratch\""), "scratch under the output folder")
    expect(!text.contains("mktemp"), "no system temp dir")
    expect(text.contains("TMPDIR=\"$work/tmp\"") && text.contains("-module-cache-path \"$work/mc\"") && text.contains("CLANG_MODULE_CACHE_PATH=\"$work/mc\""),
           "compiler temp and module cache under the scratch")
}

@main enum CornerChartTests {
    static func main() {
        testGeometry(); testLowestScaleLabels(); testVaryingScale(); testSessionAndLogs(); testArea(); testMirrorScript()
        finishTests("CornerChartTests")
    }
}
