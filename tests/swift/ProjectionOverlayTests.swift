// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/BoundaryDotsLensModel.swift ALVRClient/Diagnostics/ProjectionOverlay.swift
import Foundation
import simd

@main
enum ProjectionOverlayTests {
    static func main() {
        func near(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-6) {
            expect(abs(a - b) < tolerance, "\(message): \(a) vs \(b)")
        }
        func nearBox(_ box: ProjectionBox?, _ want: [Double], _ message: String, tolerance: Double = 1e-6) {
            guard let box else { return expect(false, "\(message): no box") }
            for (side, (got, value)) in zip(["left", "right", "up", "down"], zip(box.tangents, want)) {
                near(got, value, "\(message) \(side)", tolerance: tolerance)
            }
        }
        func deg(_ t: Double) -> Double { atan(t) * 180 / .pi }
        func tand(_ d: Double) -> Double { tan(d * .pi / 180) }
        func cosd(_ d: Double) -> Double { cos(d * .pi / 180) }
        func sind(_ d: Double) -> Double { sin(d * .pi / 180) }
        let left = BoundaryDotsFrustum.device(.left)!, right = BoundaryDotsFrustum.device(.right)!

        // Frustum box: the m5_view tangents themselves (bottom -> down, top -> up).
        expectEqual(ProjectionBox(left), ProjectionBox(left: 1.7321, right: 1, up: 1, down: 1.1918), "frustum box")

        // Lens bbox, L offset 0 (21 Oct table), by hand: the extreme vertex of the 5-deg polygon on each side.
        //   left:  ray 195, ecc 42.5: tan 42.5 * -cos 195 = 0.916331 * 0.965926 = 0.885108 (41.512 deg; ray 180 gives only tan 40 = 0.839)
        //   right: ray 0,   ecc 37.5: tan 37.5 = 0.767327 (37.5 deg)
        //   up:    ray 105, ecc 32.5: tan 32.5 * sin 105 = 0.637070 * 0.965926 = 0.615363 (31.607 deg; ray 90 gives tan 30 = 0.577)
        //   down:  ray 270, ecc 32.5: tan 32.5 = 0.637070 (32.5 deg)
        let lens0 = ProjectionOverlay.bbox(BoundaryDotsLensReference.outline(.left, offsetDeg: 0)!)
        nearBox(lens0, [tand(42.5) * -cosd(195), tand(37.5), tand(32.5) * sind(105), tand(32.5)], "L lens 0 bbox")
        nearBox(lens0, [0.885108, 0.767327, 0.615363, 0.637070], "L lens 0 bbox in numbers", tolerance: 1e-6)
        let lens0Deg = lens0?.degrees ?? []
        for (got, want) in zip(lens0Deg, [41.5123, 37.5, 31.6066, 32.5]) { near(got, want, "L lens 0 bbox deg", tolerance: 1e-4) }
        // R mirrors L about the vertical: left and right swap.
        nearBox(ProjectionOverlay.bbox(BoundaryDotsLensReference.outline(.right, offsetDeg: 0)!),
                [0.767327, 0.885108, 0.615363, 0.637070], "R lens 0 bbox mirrored")
        // Offset +5 moves every edge outward by 5 deg: exactly on the 0/270 rays (right, down); the left and up
        // extremes sit off-axis (rays 195, 105), so they move by atan(tan 47.5 cos 15) - 41.512 = 4.997 and
        // atan(tan 37.5 sin 105) - 31.607 = 4.939 deg.
        let lens5 = ProjectionOverlay.bbox(BoundaryDotsLensReference.outline(.left, offsetDeg: 5)!)
        nearBox(lens5, [tand(47.5) * -cosd(195), tand(42.5), tand(37.5) * sind(105), tand(37.5)], "L lens +5 bbox")
        for (side, (a, b)) in zip(["left", "right", "up", "down"], zip(lens0Deg, lens5?.degrees ?? [])) {
            near(b - a, 5, "+5 moves the \(side) edge by 5 deg", tolerance: 0.1)
        }
        near((lens5?.degrees[1] ?? 0) - lens0Deg[1], 5, "right on the axis ray: exactly 5", tolerance: 1e-9)
        near((lens5?.degrees[3] ?? 0) - lens0Deg[3], 5, "down on the axis ray: exactly 5", tolerance: 1e-9)
        // The rect style's bbox boxes its drawn polygon: inset 0 is the frustum.
        nearBox(ProjectionOverlay.bbox(left.outline(insetDeg: 0)), [1.7321, 1, 1, 1.1918], "rect inset 0 bbox = frustum", tolerance: 1e-9)
        expect(ProjectionOverlay.bbox([]) == nil, "no polygon, no box")

        // Points rows compiled from tools/fov-matrix/points-chart-avp.tsv (fov_scale 1 rows).
        expectEqual(ProjectionFoveation.points.map(\.name),
                    ["a100-asrun", "a100-centred", "a100-wider", "a100-axis-C", "a100-axis-A", "a100-wider-A"], "a100 rows")
        expectEqual(ProjectionFoveation.defaultName, "a100-axis-C")
        let axisC = ProjectionFoveation.named("a100-axis-C")!
        expectEqual(axisC, ProjectionFoveation(name: "a100-axis-C", renderScale: 1.1447, centerSize: [0.5, 0.45],
                                               shift: [0.536, -0.159], edgeRatio: [3, 3]), "a100-axis-C row")
        // Render size as fovmatrix.py render_size: round(3648 s) x round(2912 s).
        let renderC = ProjectionRender(scale: axisC.renderScale)
        expectEqual(renderC, ProjectionRender(width: 4176, height: 3333), "1.1447 x 3648x2912")

        // Foveation band (FFR.swift:79-89 alignment, Shaders.metal:152-157 bounds), by hand for a100-axis-C at 4176x3333:
        //   x: edge 4176 - 0.5*4176 = 2088 = 348 * 6 -> c 0.5; shift ceil(0.536*2088/6 = 186.528) = 187 -> 187*6/2088 = 0.537356;
        //      c0 = 0.25: band [0.25 * 1.537356, 1 - 0.25 * 0.462644] = [0.384339, 0.884339]
        //   y: edge 3333 - 0.45*3333 = 1833.15 -> ceil(/6) 306 -> 1836, c = 1 - 1836/3333 = 0.449145; shift ceil(-0.159*306 =
        //      -48.654) = -48 -> -288/1836 = -0.156863; c0 = 0.275428: band [0.232223, 0.681368]
        let bandX = ProjectionOverlay.band(centerSize: 0.5, shift: 0.536, edgeRatio: 3, pixels: 4176)
        near(bandX.lo, 0.25 * (1 + 1122.0 / 2088), "x band lo", tolerance: 1e-6)
        near(bandX.hi, 1 - 0.25 * (1 - 1122.0 / 2088), "x band hi", tolerance: 1e-6)
        let bandY = ProjectionOverlay.band(centerSize: 0.45, shift: -0.159, edgeRatio: 3, pixels: 3333)
        let cy = 1 - 1836.0 / 3333, c0y = (1 - cy) / 2, shy = -288.0 / 1836
        near(bandY.lo, c0y * (1 + shy), "y band lo", tolerance: 1e-6)
        near(bandY.hi, 1 - c0y * (1 - shy), "y band hi", tolerance: 1e-6)
        // Eye UV x runs from the temporal edge (L: left, R: right, mirrored), y from the top:
        //   L left = 1.7321 - 0.384339 * 2.7321 = 0.682047, right = 0.884339 * 2.7321 - 1.7321 = 0.684003,
        //   up = 1 - 0.232223 * 2.1918 = 0.491013, down = 0.681368 * 2.1918 - 1 = 0.493423 (34.30/34.37/26.15/26.26 deg).
        let fovL = ProjectionOverlay.foveationRect(eye: .left, frustum: left, foveation: axisC, render: renderC)
        nearBox(fovL, [1.7321 - bandX.lo * 2.7321, bandX.hi * 2.7321 - 1.7321, 1 - bandY.lo * 2.1918, bandY.hi * 2.1918 - 1], "L fov rect formula")
        nearBox(fovL, [0.682047, 0.684003, 0.491013, 0.493423], "L fov rect a100-axis-C by hand", tolerance: 2e-6)
        nearBox(ProjectionOverlay.foveationRect(eye: .right, frustum: right, foveation: axisC, render: renderC),
                [0.684003, 0.682047, 0.491013, 0.493423], "R fov rect mirrored", tolerance: 2e-6)
        expect(ProjectionOverlay.foveationRect(eye: .both, frustum: left, foveation: axisC, render: renderC) == nil, "per eye only")

        // px/deg on the eye axis (avp-sharpness.py "centre": render px over the tan span, x pi/180, inside the 1:1 band;
        // the lower of horizontal and vertical). a100-axis-C at 4176x3333, by hand:
        //   frustum: h 4176 / 2.7321 = 1528.48 px/tan = 26.677 px/deg, v 3333 / 2.1918 = 1520.67 = 26.541 -> 26.541
        //   bbox:    h 4176 / (0.885108 + 0.767327) = 2527.18 = 44.108, v 3333 / (0.615363 + 0.637070) = 2661.24 = 46.447 -> 44.108
        let pxFrustum = ProjectionOverlay.pxPerDegAxis(render: renderC, box: ProjectionBox(left))
        let pxBbox = ProjectionOverlay.pxPerDegAxis(render: renderC, box: lens0!)
        near(pxFrustum, 3333 / 2.1918 * .pi / 180, "frustum px/deg formula", tolerance: 1e-9)
        near(pxFrustum, 26.541, "frustum px/deg a100-axis-C", tolerance: 1e-3)
        near(pxBbox, 4176 / (0.885108 + 0.767327) * .pi / 180, "bbox px/deg formula", tolerance: 1e-4)
        near(pxBbox, 44.108, "bbox px/deg a100-axis-C", tolerance: 1e-3)

        // Fixture shared with test_boundary_outline_report.py: the same inputs give the same numbers in Python.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/diag/fixtures/projection-overlay.json").standardized
        if let data = try? Data(contentsOf: fixture),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cases = root["cases"] as? [[String: Any]], !cases.isEmpty {
            for item in cases {
                let name = item["name"] as? String ?? "?"
                guard let eye = BoundaryDotsEye(rawValue: item["eye"] as? String ?? ""),
                      let t = item["tangents"] as? [Double], t.count == 4,
                      let fv = item["foveation"] as? [Double], fv.count == 6,
                      let px = item["render_px"] as? [Int], px.count == 2,
                      let want = item["expect"] as? [String: Any] else {
                    expect(false, "fixture case \(name) malformed")
                    continue
                }
                let frustum = BoundaryDotsFrustum(left: t[0], right: t[1], bottom: t[2], top: t[3])
                let box: ProjectionBox?
                switch item["shape"] as? String {
                case "lens":
                    // The model lens's bbox is its inset rectangle.
                    box = BoundaryDotsLensModel.insetRect(eye, frustum: frustum, insetDeg: item["inset_deg"] as? Double ?? .nan)?.box(eye)
                case "measured":
                    box = ProjectionOverlay.bbox(BoundaryDotsLensReference.outline(eye, offsetDeg: item["offset_deg"] as? Double ?? .nan) ?? [])
                default:
                    box = ProjectionOverlay.bbox(frustum.outline(insetDeg: item["inset_deg"] as? Double ?? .nan))
                }
                let foveation = ProjectionFoveation(name: "fixture", renderScale: 1, centerSize: [fv[0], fv[1]],
                                                    shift: [fv[4], fv[5]], edgeRatio: [fv[2], fv[3]])
                let render = ProjectionRender(width: px[0], height: px[1])
                nearBox(box, want["bbox_tan"] as? [Double] ?? [], "fixture \(name) bbox", tolerance: 1e-3)
                nearBox(ProjectionOverlay.foveationRect(eye: eye, frustum: frustum, foveation: foveation, render: render),
                        want["fov_rect_tan"] as? [Double] ?? [], "fixture \(name) fov rect", tolerance: 1e-3)
                near(ProjectionOverlay.pxPerDegAxis(render: render, box: ProjectionBox(frustum)),
                     want["pxdeg_frustum"] as? Double ?? .nan, "fixture \(name) px/deg frustum", tolerance: 0.1)
                near(box.map { ProjectionOverlay.pxPerDegAxis(render: render, box: $0) } ?? .nan,
                     want["pxdeg_bbox"] as? Double ?? .nan, "fixture \(name) px/deg bbox", tolerance: 0.1)
            }
        } else {
            expect(false, "fixture \(fixture.path) readable with cases")
        }

        // Colours: L cyan, R orange at equal relative luminance (within 3%); the foveation rect white.
        let hueL = ProjectionOverlay.hue(.left), hueR = ProjectionOverlay.hue(.right)
        let yL = ProjectionOverlay.luminance(hueL), yR = ProjectionOverlay.luminance(hueR)
        expect(abs(yL - yR) / max(yL, yR) < 0.03, "equal brightness: \(yL) vs \(yR)")
        expect(hueL.z > hueL.x && hueR.x > hueR.z, "L cyan-ish, R orange-ish")
        expectEqual(ProjectionOverlay.hue(.both), ProjectionOverlay.white, "Both (shared cross) is white")
        expect(ProjectionOverlay.width.frustum > ProjectionOverlay.width.bbox, "bbox thinner than the frustum rectangle")

        // A box drawn as a closed tangent-space path: corners included, edges split, every point on the box.
        let path = ProjectionBox(left).path(step: 0.1)
        for corner in [SIMD2(-1.7321, 1.0), SIMD2(1.0, 1.0), SIMD2(1.0, -1.1918), SIMD2(-1.7321, -1.1918)] {
            expect(path.contains { simd_distance($0, corner) < 1e-12 }, "path corner \(corner)")
        }
        expect(zip(path, path.dropFirst() + path.prefix(1)).allSatisfy { simd_distance($0, $1) <= 0.1 + 1e-12 }, "path steps <= 0.1 tan")
        expect(path.allSatisfy { p in abs(p.x + 1.7321) < 1e-12 || abs(p.x - 1) < 1e-12 || abs(p.y - 1) < 1e-12 || abs(p.y + 1.1918) < 1e-12 },
               "path on the box")
        let ring = ProjectionOverlay.axisCircle
        expect(ring.count >= 24 && ring.allSatisfy { abs($0.eccDeg - 0.5) < 1e-12 }, "axis circle 0.5 deg radius")

        // The bbox is drawn dashed: short dashes of equal tangent length along the closed path, gaps between them,
        // every point on the box, the first dash from the top-left corner.
        let dash = ProjectionOverlay.bboxDash
        expect(dash.dash > 0 && dash.dash <= 0.03 && dash.gap > 0 && dash.gap <= 0.03, "short dashes: \(dash)")
        func length(_ points: [SIMD2<Double>]) -> Double { zip(points, points.dropFirst()).map { simd_distance($0, $1) }.reduce(0, +) }
        let fine = ProjectionBox(left).path(step: 0.05)
        let perimeter = 2 * (1.7321 + 1 + 1 + 1.1918)
        let dashes = ProjectionOverlay.dashes(fine, dash: 0.02, gap: 0.02)
        expectEqual(dashes.count, Int((perimeter / 0.04).rounded(.up)), "dash count")
        expect(dashes.dropLast().allSatisfy { abs(length($0) - 0.02) < 1e-9 }, "full dashes 0.02 tan")
        expect(dashes.last.map { length($0) <= 0.02 + 1e-9 && length($0) > 0 } ?? false, "last dash no longer than 0.02")
        near(dashes.map(length).reduce(0, +), perimeter / 2, "dashes cover half the perimeter", tolerance: 0.02)
        expect(dashes.allSatisfy { $0.count >= 2 }, "every dash has two ends")
        expect(dashes.first?.first.map { simd_distance($0, SIMD2(-1.7321, 1.0)) < 1e-12 } ?? false, "first dash at the top-left corner")
        expect(dashes.joined().allSatisfy { p in abs(p.x + 1.7321) < 1e-9 || abs(p.x - 1) < 1e-9 || abs(p.y - 1) < 1e-9 || abs(p.y + 1.1918) < 1e-9 },
               "dashes on the box")
        // A dash across a corner keeps the corner.
        let corner = ProjectionOverlay.dashes([[0, 0], [1, 0], [1, 1], [0, 1]], dash: 1.5, gap: 0.5)
        expectEqual(corner.first ?? [], [[0, 0], [1, 0], [1, 0.5]], "dash bends at the corner")
        expectEqual(corner.count, 2, "two dashes on a perimeter of 4")
        expectEqual(corner.last ?? [], [[1, 1], [0, 1], [0, 0.5]], "second dash from 2.0 to 3.5, on the closing edge")

        // The points table matches tools/diag/fixtures/projection-points.json, which test_projection_points_table.py
        // checks against tools/fov-matrix/points-chart-avp.tsv.
        let pointsFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/diag/fixtures/projection-points.json").standardized
        if let data = try? Data(contentsOf: pointsFixture),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = root["rows"] as? [[String: Any]] {
            expectEqual(rows.map { $0["name"] as? String ?? "?" }, ProjectionFoveation.points.map(\.name), "points fixture names")
            for (row, point) in zip(rows, ProjectionFoveation.points) {
                let v = point
                expectEqual(row["render_scale"] as? Double, v.renderScale, "points fixture \(v.name) render_scale")
                expectEqual(row["foveation"] as? [Double], [v.centerSize.x, v.centerSize.y, v.edgeRatio.x, v.edgeRatio.y, v.shift.x, v.shift.y],
                            "points fixture \(v.name) foveation")
            }
        } else {
            expect(false, "fixture \(pointsFixture.path) readable with rows")
        }

        // Readout and log fields for one eye: L lens offset 0, the default points row, device frustum.
        let stream = ProjectionStream.points(axisC)
        expectEqual(stream.source, "a100-axis-C")
        expectEqual(stream.render, renderC)
        let readout = ProjectionReadout(eye: .left, frustum: left, outline: BoundaryDotsLensReference.outline(.left, offsetDeg: 0)!,
                                        stream: stream)!
        expect(!stream.live, "a points row is a preset")
        expectEqual(readout.lines, [
            "L bbox L 41.5 R 37.5 U 31.6 D 32.5 deg  tan 0.885/0.767/0.615/0.637",
            "L fov a100-axis-C (preset, not live)  rect L 34.3 R 34.4 U 26.2 D 26.3 deg  4176x3333",
            "L px/deg axis: frustum 26.5 → bbox 44.1 (×1.66)",
        ], "readout lines")
        expectEqual(readout.bboxDeg, "41.512,37.500,31.607,32.500")
        expectEqual(readout.bboxTan, "0.8851,0.7673,0.6154,0.6371")
        expectEqual(readout.fovRectDeg, "34.296,34.372,26.152,26.263")
        expectEqual(readout.renderPx, "4176,3333")
        near(readout.pxdegFrustum, 26.541, "readout frustum px/deg", tolerance: 1e-3)
        near(readout.pxdegBbox, 44.108, "readout bbox px/deg", tolerance: 1e-3)
        expect(ProjectionReadout(eye: .both, frustum: left, outline: [], stream: stream) == nil, "readout per eye")

        // Live stream: the session's per-eye render and raw FFR settings (aligned like FFR.swift); no foveation = "off".
        let live = ProjectionStream.live(width: 4176, height: 3333, centerSize: [0.5, 0.45], shift: [0.536, -0.159], edgeRatio: [3, 3])
        expectEqual(live.source, "live")
        expect(live.live, "the stream's settings are live")
        let liveReadout = ProjectionReadout(eye: .left, frustum: left, outline: BoundaryDotsLensReference.outline(.left, offsetDeg: 0)!,
                                            stream: live)!
        expectEqual(liveReadout.lines[1], "L fov (live)  rect L 34.3 R 34.4 U 26.2 D 26.3 deg  4176x3333")
        expectEqual(liveReadout.fovLive, "yes")
        expectEqual(readout.fovLive, "no")
        nearBox(ProjectionOverlay.foveationRect(eye: .left, frustum: left, foveation: live.foveation!, render: live.render),
                [0.682047, 0.684003, 0.491013, 0.493423], "live settings give the same rect", tolerance: 2e-6)
        let off = ProjectionStream.live(width: 3648, height: 2912, centerSize: nil, shift: nil, edgeRatio: nil)
        let offReadout = ProjectionReadout(eye: .left, frustum: left, outline: BoundaryDotsLensReference.outline(.left, offsetDeg: 0)!,
                                           stream: off)!
        expectEqual(offReadout.fovRectDeg, "off")
        expectEqual(offReadout.lines[1], "L fov (live)  rect off  3648x2912")

        // Model lens (style lens): the bbox is the inset rectangle itself, and the readout's px/deg uses it.
        // L inset 15 on the device frustum: 45.001/30/30/35.001 deg; a100-axis-C 4176x3333, by hand:
        //   h 4176 / (1.000025 + 0.577350) = 2647.43 px/tan = 46.206 px/deg, v 3333 / (0.577350 + 0.700236) = 2608.80 = 45.533 -> 45.533
        let rectL = BoundaryDotsLensModel.insetRect(.left, frustum: left, insetDeg: 15)!
        let lensOutline = BoundaryDotsLensModel.outline(.left, frustum: left, insetDeg: 15)!
        let lensReadout = ProjectionReadout(eye: .left, frustum: left, outline: lensOutline, stream: stream, bbox: rectL.box(.left))!
        expectEqual(lensReadout.bbox, rectL.box(.left), "lens bbox = inset rect")
        near(lensReadout.pxdegBbox, 3333 / (tand(30) + rectL.bD) * .pi / 180, "lens bbox px/deg formula", tolerance: 1e-9)
        near(lensReadout.pxdegBbox, 45.533, "lens bbox px/deg a100-axis-C", tolerance: 1e-3)
        expectEqual(lensReadout.lines[0], "L bbox L 45.0 R 30.0 U 30.0 D 35.0 deg  tan 1.000/0.577/0.577/0.700", "lens readout line")
        // One rectangle for the lens (the inset rect, solid), plus the axes; no dashed bbox on top of it.
        expectEqual(ProjectionOverlay.layers(.lens), [.frustum, .outline, .rect, .axes, .foveation, .circle], "lens layers")
        expectEqual(ProjectionOverlay.layers(.rect), [.frustum, .outline, .bbox, .foveation, .circle], "rect layers (W36)")
        expectEqual(ProjectionOverlay.layers(.measured), [.frustum, .outline, .bbox, .foveation, .circle], "measured layers (W36)")
        // The axes: through the eye axis, spanning the rectangle (horizontal left..right at y 0, vertical up..down at x 0).
        let axes = ProjectionOverlay.axes(rectL.box(.left)!, step: 0.05)
        expectEqual(axes.count, 2, "two axes")
        expectEqual(axes.first?.first, SIMD2(-rectL.aT, 0), "horizontal from the L temporal (left) edge")
        expectEqual(axes.first?.last, SIMD2(rectL.aN, 0), "to the nasal (right) edge")
        expectEqual(axes.last?.first, SIMD2(0, rectL.bU), "vertical from the top edge")
        expectEqual(axes.last?.last, SIMD2(0, -rectL.bD), "to the bottom edge")
        expect(axes[0].allSatisfy { $0.y == 0 } && axes[1].allSatisfy { $0.x == 0 }, "axes through the eye axis")
        expect(axes.allSatisfy { zip($0, $0.dropFirst()).allSatisfy { simd_distance($0, $1) <= 0.05 + 1e-12 } }, "axes split <= 0.05 tan")
        expect(ProjectionOverlay.width.rect < ProjectionOverlay.width.lens, "the rectangle thinner than the lens line")

        // Session: the selected points row cycles; the dots_outline line carries the projection fields.
        var session = BoundaryDotsSession()
        expectEqual(session.foveationPoint, "a100-axis-C", "default row")
        session.nextFoveationPoint()
        expectEqual(session.foveationPoint, "a100-axis-A", "next row")
        for _ in 0..<5 { session.nextFoveationPoint() }
        expectEqual(session.foveationPoint, "a100-axis-C", "cycles through the six rows")
        session.eye = .left
        let lensLine = Diag.line(topic: "dots_outline", tMs: 1, fields: session.outlineFields(frustum: left, source: "device_default")!)
        expect(lensLine.hasSuffix(" bbox_deg=45.001,30.000,30.000,35.001 bbox_tan=1.0000,0.5774,0.5774,0.7002 fov_source=a100-axis-C"
                                  + " fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=45.533"),
               "lens projection fields on dots_outline: \(lensLine)")
        session.shape = .measured
        let line = Diag.line(topic: "dots_outline", tMs: 1, fields: session.outlineFields(frustum: left, source: "device_default")!)
        expect(line.hasSuffix(" bbox_deg=41.512,37.500,31.607,32.500 bbox_tan=0.8851,0.7673,0.6154,0.6371 fov_source=a100-axis-C"
                              + " fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=44.108"),
               "projection fields on dots_outline: \(line)")
        session.eye = .right
        session.offset = 5
        expect(session.outline(.left, frustum: left)?.first?.eccDeg == 37.5, "L keeps offset 0 while R is +5")
        expect(session.outline(.right, frustum: right)?.first?.eccDeg == 45, "R at its own +5")
        expect(session.outline(.both, frustum: left) == nil, "no Both outline")

        finishTests("ProjectionOverlayTests")
    }
}
