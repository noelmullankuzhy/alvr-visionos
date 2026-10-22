// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/ProjectionOverlay.swift
import Foundation
import simd

@main
enum BoundaryOutlineTests {
    static func main() {
        func near(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-9) {
            expect(abs(a - b) < tolerance, "\(message): \(a) vs \(b)")
        }
        func tangent(_ dot: BoundaryDot) -> SIMD2<Double> {
            let d = dot.direction
            return [d.x / -d.z, d.y / -d.z]
        }

        // Device frusta (21 Oct m5_view, left,right,bottom,top): L temporal is its left side; R mirrored.
        guard let left = BoundaryDotsFrustum.device(.left), let right = BoundaryDotsFrustum.device(.right) else {
            expect(false, "device frusta for L and R")
            finishTests("BoundaryOutlineTests")
        }
        expectEqual(left, BoundaryDotsFrustum(left: 1.7321, right: 1.0, bottom: 1.1918, top: 1.0), "L device tangents")
        expectEqual(right, BoundaryDotsFrustum(left: 1.0, right: 1.7321, bottom: 1.1918, top: 1.0), "R mirrored")
        expectEqual(BoundaryDotsFrustum.device(.both), nil, "Both has no single frustum")
        near(left.edgeEccDeg(rayDeg: 0), 45, "L nasal edge", tolerance: 1e-12)
        near(left.edgeEccDeg(rayDeg: 180), atan(1.7321) * 180 / .pi, "L temporal edge")
        near(left.edgeEccDeg(rayDeg: 90), 45, "up edge", tolerance: 1e-12)
        near(left.edgeEccDeg(rayDeg: 270), atan(1.1918) * 180 / .pi, "down edge")
        near(right.edgeEccDeg(rayDeg: 0), atan(1.7321) * 180 / .pi, "R temporal edge is its right side")
        near(left.edgeEccDeg(rayDeg: 45), atan(sqrt(2)) * 180 / .pi, "L upper nasal corner")

        // Inset 0 is the frustum rectangle itself: every vertex on its edge, the four corners included.
        for (name, frustum) in [("L", left), ("R", right)] {
            let outline = frustum.outline(insetDeg: 0)
            let rays = outline.map(\.rayDeg)
            expect(zip(rays, rays.dropFirst()).allSatisfy { $0 < $1 }, "\(name) rays strictly increasing (closed loop, no repeat)")
            expect(rays.allSatisfy { $0 >= 0 && $0 < 360 }, "\(name) rays in [0, 360)")
            expect(Set(stride(from: 0.0, to: 360, by: 5)).isSubset(of: Set(rays)), "\(name) sampled every 5 deg")
            expect(outline.count <= 72 + 4, "\(name) at most four extra corner vertices")
            for corner in [SIMD2(frustum.right, frustum.top), SIMD2(-frustum.left, frustum.top),
                           SIMD2(-frustum.left, -frustum.bottom), SIMD2(frustum.right, -frustum.bottom)] {
                expect(outline.contains { simd_distance(tangent($0), corner) < 1e-9 }, "\(name) corner \(corner) reproduced")
            }
            for dot in outline {
                let p = tangent(dot)
                near(max(p.x / frustum.right, -p.x / frustum.left, p.y / frustum.top, -p.y / frustum.bottom), 1,
                     "\(name) inset 0 lies on the edge at ray \(dot.rayDeg)")
            }
            near(frustum.areaFraction(insetDeg: 0), 1, "\(name) inset 0 covers the frustum", tolerance: 1e-9)
        }

        // Inset 15 on the device frustum: 30 nasal, 45 temporal, 30 up, 35 down (degrees from the head axis).
        let limits = left.limits(eye: .left, insetDeg: 15) ?? BoundaryDotsLimits(nasal: -1, temporal: -1, up: -1, down: -1)
        near(limits.nasal, 30, "L nasal", tolerance: 1e-2)
        near(limits.temporal, 45, "L temporal", tolerance: 1e-2)
        near(limits.up, 30, "L up", tolerance: 1e-2)
        near(limits.down, 35, "L down", tolerance: 1e-2)
        expectEqual(right.limits(eye: .right, insetDeg: 15), limits, "R mirrored limits")
        expectEqual(left.limits(eye: .both, insetDeg: 15), nil, "limits need one eye")
        let inset15 = left.outline(insetDeg: 15)
        for (ray, ecc) in [(0.0, 30.0), (90, 30), (180, 45), (270, 35)] {
            guard let dot = inset15.first(where: { $0.rayDeg == ray }) else { expect(false, "ray \(ray) sampled"); continue }
            near(dot.eccDeg, ecc, "L inset 15 ray \(ray)", tolerance: 1e-2)
        }
        for dot in inset15 {
            near(dot.eccDeg, left.edgeEccDeg(rayDeg: dot.rayDeg) - 15, "inset along each ray \(dot.rayDeg)")
        }
        let area15 = left.areaFraction(insetDeg: 15)
        expect(area15 > 0.3 && area15 < 0.6, "inset 15 area fraction plausible: \(area15)")
        expect(left.areaFraction(insetDeg: 20) < area15, "more inset, less area")
        // Hand check, L device frustum (l=1.7321, r=1, b=1.1918, t=1) at inset 15. Vertices: rays every 5 deg plus
        // the corner rays 45, 150.0007, 214.5306, 309.9989; radius rho = tan(edge_ecc - 15), e.g. ray 0: tan(45-15)=0.57735.
        // Polygon area by fan sectors, 1/2 * sum(rho_i * rho_i+1 * sin(dphi_i)), grouped by the quadrant of phi_i:
        //   [0,90) 0.341113 + [90,180) 0.576945 + [180,270) 0.685372 + [270,360) 0.409327 = 2.012757
        // Frustum area (l+r)(b+t) = 2.7321 * 2.1918 = 5.988217; fraction 2.012757 / 5.988217 = 0.336120.
        near(area15, 2.012757 / 5.988217, "L inset 15 area fraction by hand", tolerance: 1e-6)
        near(area15, 0.336120, "L inset 15 area fraction", tolerance: 1e-6)

        // Clamping: limits and outline never go below 0 deg; inset snaps to 0.5 and stays in 0...30.
        let narrow = BoundaryDotsFrustum(left: 0.2, right: 0.2, bottom: 0.2, top: 0.2)
        expectEqual(narrow.limits(eye: .left, insetDeg: 30), BoundaryDotsLimits(nasal: 0, temporal: 0, up: 0, down: 0), "limits clamp at 0")
        expect(narrow.outline(insetDeg: 30).allSatisfy { $0.eccDeg == 0 }, "outline clamps at 0")
        near(left.limits(eye: .left, insetDeg: 30)?.nasal ?? -1, 15, "inset 30 nasal", tolerance: 1e-9)
        for (raw, snapped) in [(-3.0, 0.0), (0, 0), (0.24, 0), (0.26, 0.5), (14.74, 14.5), (14.76, 15), (29.9, 30), (42, 30)] {
            expectEqual(BoundaryDotsOutline.clampInset(raw), snapped, "inset \(raw) -> \(snapped)")
        }
        near(BoundaryDotsOutline.defaultInsetDeg, 15, "default inset")
        near(BoundaryDotsOutline.lineWidthDeg, 0.3, "line width")

        // Slider mapping: head-frame horizontal hand travel, 1 cm = 1 deg, snapped 0.5, clamped 0...30.
        near(BoundaryDotsSliderMap.metresPerDeg, 0.01, "gain: 1 cm per degree")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [0.03, 0, 0]), 18, "3 cm right is +3 deg")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [-0.03, 0, 0]), 12, "3 cm left is -3 deg")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [0, 0.05, -0.05]), 15, "vertical and depth ignored")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [0.0024, 0, 0]), 15, "snap below half step")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [0.0026, 0, 0]), 15.5, "snap above half step")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [0.5, 0, 0]), 30, "clamp at 30")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [-0.5, 0, 0]), 0, "clamp at 0")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [.nan, 0, 0]), 15, "non-finite ignored")
        // Hand right = outline outward in both styles: lens offset up (sign +1), rect inset down (sign -1).
        var styles = BoundaryDotsSession()
        expectEqual(styles.sliderSign, 1, "lens: hand right raises the offset")
        styles.shape = .rect
        expectEqual(styles.sliderSign, -1, "rect: hand right lowers the inset")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [0.03, 0, 0], sign: -1), 12, "rect 3 cm right is inset -3 (outward)")
        expectEqual(BoundaryDotsSliderMap.inset(from: 15, displacement: [-0.03, 0, 0], sign: -1), 18, "rect 3 cm left is inset +3 (inward)")
        expectEqual(BoundaryDotsSliderMap.inset(from: 0, displacement: [0.03, 0, 0], range: BoundaryDotsOutline.offsetRange,
                                                sign: 1), 3, "lens 3 cm right is offset +3 (outward)")
        expectEqual(BoundaryDotsSliderMap.inset(from: 1, displacement: [0.05, 0, 0], sign: -1), 0, "rect clamps at inset 0")

        let level = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let yawLeft = simd_quatd(angle: .pi / 2, axis: [0, 1, 0])
        let origin = SIMD3<Double>(0.2, 1.1, -0.4)
        var slider = BoundaryDotsSlider<Int>()
        var inset = 15.0
        func feed(_ id: Int, _ position: SIMD3<Double>, _ phase: BoundaryDotsPinchPhase = .active,
                  hand: BoundaryDotsHand? = .left, head: simd_quatd = level, enabled: Bool = true) -> BoundaryDotsSliderUpdate? {
            let result = slider.update(id: id, hand: hand, phase: phase, position: position, headRotation: head,
                                       inset: inset, enabled: enabled)
            switch result {
            case .move(let value)?: inset = value
            case .release(_, let value)?: inset = value
            case nil: break
            }
            return result
        }
        expectEqual(feed(1, origin, enabled: false), nil, "disabled (cursor selected): no grab")
        expect(!slider.active, "disabled leaves the slider idle")
        expectEqual(feed(1, origin + [0.05, 0, 0], enabled: false), nil)
        expectEqual(feed(1, origin, .ended, enabled: false), nil)
        expectEqual(inset, 15, "disabled drag keeps the inset")
        expectEqual(feed(2, origin, hand: .right), nil)
        expectEqual(feed(2, origin + [0.05, 0, 0], hand: .right), nil, "right hand never slides")
        expectEqual(feed(2, origin, .ended, hand: .right), nil)
        expectEqual(feed(3, origin), nil)
        expect(slider.active, "left pinch grabs the slider")
        expectEqual(feed(3, origin + [0.001, 0.004, 0.003]), nil)
        expectEqual(feed(3, origin, .ended), nil, "quick left pinch changes nothing")
        expect(!slider.active, "released")
        // No drift: many small moves out and back return exactly.
        expectEqual(feed(4, origin), nil)
        for i in 1...40 { _ = feed(4, origin + [0.001 * Double(i), 0.0004 * Double(i % 3), 0]) }
        expectEqual(inset, 19, "4 cm right is +4 deg")
        for i in stride(from: 39, through: 0, by: -1) { _ = feed(4, origin + [0.001 * Double(i), 0, 0]) }
        expectEqual(inset, 15, "dragging back returns exactly")
        expectEqual(feed(4, origin + [-0.021, 0, 0]), .move(13))
        expectEqual(feed(4, origin + [-0.022, 0, 0]), nil, "same value is not re-sent")
        expectEqual(feed(4, origin + [-0.022, 0, 0], .ended), .release(from: 15, to: 13), "release keeps the value")
        expectEqual(inset, 13)
        expectEqual(feed(4, origin, .ended), nil, "no double release")
        // Cancel restores the value at the grab.
        expectEqual(feed(5, origin), nil)
        expectEqual(feed(5, origin + [0.05, 0, 0]), .move(18))
        expectEqual(feed(5, origin + [0.05, 0, 0], .cancelled), .move(13), "cancel restores")
        expect(!slider.active, "cancel ends the slide")
        // A 90 deg left head turn: world -Z is head right; world +X is head backwards (ignored).
        expectEqual(feed(6, origin, head: yawLeft), nil)
        expectEqual(feed(6, origin + [0.04, 0, 0], head: yawLeft), nil, "world +X is depth after the turn")
        expectEqual(feed(6, origin + [0, 0, -0.03], head: yawLeft), .move(16), "world -Z is head right after a 90 deg left yaw")
        expectEqual(feed(6, origin + [0, 0, -0.03], .ended, head: yawLeft), .release(from: 13, to: 16))
        // An inset changed elsewhere (eye switch) re-anchors the slide; one slide at a time.
        expectEqual(feed(7, origin), nil)
        expectEqual(feed(7, origin + [0.01, 0, 0]), .move(17))
        inset = 20
        expectEqual(feed(7, origin + [0.03, 0, 0]), nil, "re-anchor at the new value")
        expectEqual(feed(8, origin), nil)
        expectEqual(feed(8, origin + [0.05, 0, 0]), nil, "second pinch ignored")
        expectEqual(feed(8, origin, .ended), nil)
        expectEqual(feed(7, origin + [0.04, 0, 0], hand: nil), .move(21), "id keeps the slide")
        // A cursor selected mid-slide (enabled false) ends the slide at its value; the pinch stays
        // consumed so it cannot start a cursor drag or move the inset again.
        expectEqual(feed(7, origin + [0.06, 0, 0], enabled: false), nil, "cursor selected: the slider cannot fire")
        expectEqual(inset, 21, "value at the selection is kept")
        expect(slider.active, "the pinch stays with the ended slide until release")
        expectEqual(feed(7, origin + [-0.05, 0, 0], enabled: true), nil, "no resume after the cursor is cleared mid-pinch")
        expectEqual(feed(7, origin + [-0.05, 0, 0], .cancelled, enabled: false), nil, "cancel after the end restores nothing")
        expect(!slider.active, "released")
        expectEqual(inset, 21)
        expectEqual(feed(9, origin), nil)
        expectEqual(feed(9, origin + [0.02, 0, 0]), .move(23))
        expectEqual(feed(9, origin + [0.03, 0, 0], enabled: false), nil)
        expectEqual(feed(9, origin + [0.03, 0, 0], .ended, enabled: false), nil, "ended slide has nothing to release")
        expectEqual(inset, 23)

        // Dot materials: only dots whose confirmed state changed are re-assigned; a slider step changes none.
        var materials = BoundaryDotsDotStates()
        var marked = BoundaryDotsSession()
        expectEqual(materials.changes(marked).count, BoundaryDots.layout.count, "first refresh paints every dot")
        expectEqual(materials.changes(marked), [], "no change, no material")
        marked.eye = .left
        marked.inset = 22
        expectEqual(materials.changes(marked), [], "a slider step touches no dot material")
        let marker = BoundaryDot(rayDeg: 15, eccDeg: 30)
        _ = marked.select(marker)
        expectEqual(materials.changes(marked), [], "a cursor is not a material change")
        _ = marked.confirm()
        let index = BoundaryDots.layout.firstIndex(of: marker)!
        expectEqual(materials.changes(marked), [index], "a confirm repaints one dot")
        marked.eye = .right
        expectEqual(materials.changes(marked), [index], "an eye switch repaints that eye's differences")

        // Session: one inset per eye, deselect, outline log line.
        var session = BoundaryDotsSession()
        expectEqual(session.inset, 15, "Both default")
        session.eye = .left
        expectEqual(session.inset, 15, "L default")
        session.inset = 20.26
        expectEqual(session.inset, 20.5, "setter snaps")
        session.inset = .nan
        expectEqual(session.inset, 20.5, "non-finite ignored")
        session.eye = .right
        expectEqual(session.inset, 15, "insets are per eye")
        session.eye = .left
        expectEqual(session.inset, 20.5)
        expect(!session.deselect(), "nothing to deselect")
        _ = session.select(BoundaryDot(rayDeg: 0, eccDeg: 30))
        expect(session.deselect(), "deselect clears the cursor")
        expectEqual(session.cursor, nil)
        session.inset = 15
        expectEqual(session.shape, .lens, "lens is the default style")
        session.shape = .rect
        expectEqual(Diag.line(topic: "dots_outline", tMs: 1, fields: session.outlineFields(frustum: left, source: "device_default")!),
                    "DIAG dots_outline t_ms=1 eye=L shape=rect inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 bbox_deg=45.001,30.489,30.489,35.058 bbox_tan=1.0000,0.5888,0.5888,0.7017 fov_source=a100-axis-C foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=45.077")
        session.eye = .right
        session.inset = 30
        expectEqual(Diag.line(topic: "dots_outline", tMs: 2, fields: session.outlineFields(frustum: right, source: "m5_view")!),
                    "DIAG dots_outline t_ms=2 eye=R shape=rect inset_deg=30.000 nasal_deg=15.000 temporal_deg=30.001 up_deg=15.000 down_deg=20.001 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000 bbox_deg=18.330,30.001,18.435,21.659 bbox_tan=0.3313,0.5774,0.3333,0.3971 fov_source=a100-axis-C foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.372,34.296,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=79.639")
        session.eye = .both
        expect(session.outlineFields(frustum: left, source: "device_default") == nil, "no outline line for Both")

        // Lens style: the 21 Oct seal-on visible field (diag-20261021T152509Z.log; L rays where measured, else Both),
        // moved radially by offset_deg (positive = outward), -10...+20, default 0, snapped 0.5.
        let reference = BoundaryDotsLensReference.self
        expectEqual(reference.date, "2026-10-21")
        expect(reference.source.contains("diag-20261021T152509Z.log"), "reference names its source log")
        expectEqual(reference.left.count, 24, "24 measured rays")
        expectEqual(reference.left.keys.sorted(), stride(from: 0.0, to: 360, by: 15).map { $0 }, "15 deg apart")
        let lFromL: [Double: Double] = [45: 35, 75: 30, 105: 32.5, 120: 32.5, 135: 35, 150: 37.5, 165: 37.5,
                                        180: 40, 195: 42.5, 210: 40, 225: 40]
        let lFromBoth: [Double: Double] = [0: 37.5, 15: 35, 30: 35, 60: 30, 90: 30, 240: 30, 255: 32.5,
                                           270: 32.5, 285: 30, 300: 32.5, 315: 32.5, 330: 32.5, 345: 37.5]
        expectEqual(reference.left, lFromL.merging(lFromBoth) { l, _ in l }, "L summary rays, gaps from the Both summary")
        // Hand values from the log at the 0/90/180/270 rays (L: nasal = right = 0, temporal = 180).
        let lens0 = reference.limits(.left, offsetDeg: 0)
        expectEqual(lens0, BoundaryDotsLimits(nasal: 37.5, temporal: 40, up: 30, down: 32.5), "L offset 0 reads the log")
        expectEqual(reference.limits(.right, offsetDeg: 0), lens0, "R mirrored")
        expectEqual(reference.limits(.left, offsetDeg: 5), BoundaryDotsLimits(nasal: 42.5, temporal: 45, up: 35, down: 37.5), "L +5")
        expectEqual(reference.limits(.right, offsetDeg: 5), BoundaryDotsLimits(nasal: 42.5, temporal: 45, up: 35, down: 37.5), "R +5")
        expectEqual(reference.limits(.both, offsetDeg: 0), nil, "lens is monocular")
        // R mirrors L about the vertical: R(phi) = L(180 - phi).
        for ray in stride(from: 0.0, to: 360, by: 15) {
            near(reference.eccDeg(.right, rayDeg: ray) ?? -1, reference.left[(540 - ray).truncatingRemainder(dividingBy: 360)]!, "R mirror ray \(ray)")
        }
        near(reference.eccDeg(.right, rayDeg: 0) ?? -1, 40, "R temporal (right) = L temporal")
        near(reference.eccDeg(.right, rayDeg: 315) ?? -1, 40, "R lower right = L lower left 225")
        // Linear interpolation in eccentricity between measured rays, circular across 0.
        near(reference.eccDeg(.left, rayDeg: 7.5) ?? -1, 36.25, "midway 0..15: (37.5 + 35) / 2")
        near(reference.eccDeg(.left, rayDeg: 185) ?? -1, 40 + 2.5 / 3, "a third of 180..195: 40 + 2.5/3")
        near(reference.eccDeg(.left, rayDeg: 355) ?? -1, 37.5, "345..360 both 37.5")
        near(reference.eccDeg(.left, rayDeg: 240) ?? -1, 30, "measured ray exact")
        let sparse: [Double: Double] = [0: 30, 90: 40]
        near(BoundaryDotsLensReference.interpolate(sparse, rayDeg: 45), 35, "missing rays: halfway")
        near(BoundaryDotsLensReference.interpolate(sparse, rayDeg: 30), 30 + 10.0 / 3, "missing rays: a third")
        near(BoundaryDotsLensReference.interpolate(sparse, rayDeg: 270), 40 - 10.0 * 2 / 3, "missing rays wrap 90 -> 360")
        near(BoundaryDotsLensReference.interpolate([10: 33], rayDeg: 200), 33, "one ray is a circle")
        let lensOutline = reference.outline(.left, offsetDeg: 5) ?? []
        expectEqual(lensOutline.map(\.rayDeg), stride(from: 0.0, to: 360, by: 5).map { $0 }, "lens outline every 5 deg")
        for dot in lensOutline {
            near(dot.eccDeg, (reference.eccDeg(.left, rayDeg: dot.rayDeg) ?? -1) + 5, "reference + offset at \(dot.rayDeg)")
        }
        expect(reference.outline(.both, offsetDeg: 0) == nil, "no lens outline for Both")
        let lensArea = left.areaFraction(of: reference.outline(.left, offsetDeg: 0) ?? [])
        // Mean radius tan(34 deg) = 0.67: a circle is pi * 0.67^2 / 5.988 = 0.24 of the frustum.
        expect(lensArea > 0.2 && lensArea < 0.3, "lens area fraction plausible: \(lensArea)")
        // Lens L offset 0, by hand: 72 sectors of 5 deg, rho = tan(ecc) with ecc linear between the 15-deg rays,
        // area = 1/2 * sin(5 deg) * sum(rho_i * rho_i+1) = 1.533787; frustum (1.7321+1)(1.1918+1) = 5.988217;
        // fraction 1.533787 / 5.988217 = 0.256134 (offset +5: 2.206352 / 5.988217 = 0.368449).
        near(lensArea, 1.533787 / 5.988217, "lens L offset 0 area by hand", tolerance: 1e-6)
        near(left.areaFraction(of: reference.outline(.left, offsetDeg: 5) ?? []), 0.368449, "lens L +5 area", tolerance: 1e-6)
        expect(left.areaFraction(of: reference.outline(.left, offsetDeg: 5) ?? []) > lensArea, "outward offset, more area")
        near(left.areaFraction(of: left.outline(insetDeg: 15)), left.areaFraction(insetDeg: 15), "one area routine")
        // Offset clamps and snapping.
        for (raw, snapped) in [(-12.0, -10.0), (-10, -10), (-0.24, 0), (0.26, 0.5), (4.76, 5), (19.9, 20), (25, 20)] {
            expectEqual(BoundaryDotsOutline.clampOffset(raw), snapped, "offset \(raw) -> \(snapped)")
        }
        expectEqual(BoundaryDotsOutline.offsetRange, -10...20)
        expectEqual(BoundaryDotsOutline.insetRange, 0...30)
        expectEqual(BoundaryDotsSliderMap.inset(from: 0, displacement: [-0.5, 0, 0], range: BoundaryDotsOutline.offsetRange), -10, "slider clamps at -10")
        expectEqual(BoundaryDotsSliderMap.inset(from: 0, displacement: [0.5, 0, 0], range: BoundaryDotsOutline.offsetRange), 20, "slider clamps at +20")
        expectEqual(BoundaryDotsSliderMap.inset(from: 0, displacement: [-0.0326, 0, 0], range: BoundaryDotsOutline.offsetRange), -3.5, "snap 0.5")
        var lensSlider = BoundaryDotsSlider<Int>()
        expectEqual(lensSlider.update(id: 1, hand: .left, phase: .active, position: origin, headRotation: level,
                                      inset: 0, enabled: true, range: BoundaryDotsOutline.offsetRange), nil)
        expectEqual(lensSlider.update(id: 1, hand: .left, phase: .active, position: origin + [-0.04, 0, 0], headRotation: level,
                                      inset: 0, enabled: true, range: BoundaryDotsOutline.offsetRange), .move(-4), "negative offsets reachable")
        expectEqual(lensSlider.update(id: 1, hand: .left, phase: .cancelled, position: origin, headRotation: level,
                                      inset: -4, enabled: true, range: BoundaryDotsOutline.offsetRange), .move(0), "cancel restores")
        var rectSlider = BoundaryDotsSlider<Int>()
        expectEqual(rectSlider.update(id: 1, hand: .left, phase: .active, position: origin, headRotation: level,
                                      inset: 15, enabled: true, sign: -1), nil)
        expectEqual(rectSlider.update(id: 1, hand: .left, phase: .active, position: origin + [0.04, 0, 0], headRotation: level,
                                      inset: 15, enabled: true, sign: -1), .move(11), "rect slide right: inset down, outline out")
        expectEqual(rectSlider.update(id: 1, hand: .left, phase: .ended, position: origin + [0.04, 0, 0], headRotation: level,
                                      inset: 11, enabled: true, sign: -1), .release(from: 15, to: 11))

        // Session: per-eye offsets, the slider value follows the style, toggling keeps both values.
        var lens = BoundaryDotsSession()
        lens.eye = .left
        expectEqual(lens.offset, 0, "default offset")
        expectEqual(lens.sliderValue, 0, "lens slider drives the offset")
        expectEqual(lens.sliderRange, BoundaryDotsOutline.offsetRange)
        lens.sliderValue = 5.2
        expectEqual(lens.offset, 5, "snapped")
        lens.offset = .nan
        expectEqual(lens.offset, 5, "non-finite ignored")
        lens.eye = .right
        expectEqual(lens.offset, 0, "offsets are per eye")
        lens.eye = .left
        lens.toggleShape()
        expectEqual(lens.shape, .rect)
        expectEqual(lens.sliderValue, 15, "rect slider drives the inset")
        expectEqual(lens.sliderRange, BoundaryDotsOutline.insetRange)
        lens.toggleShape()
        expectEqual(lens.sliderValue, 5, "offset kept across toggles")
        expectEqual(Diag.line(topic: "dots_outline", tMs: 3, fields: lens.outlineFields(frustum: left, source: "device_default")!),
                    "DIAG dots_outline t_ms=3 eye=L shape=lens offset_deg=5.000 nasal_deg=42.500 temporal_deg=45.000 up_deg=35.000 down_deg=37.500 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays=0:42.5,15:40,30:40,45:40,60:35,75:35,90:35,105:37.5,120:37.5,135:40,150:42.5,165:42.5,180:45,195:47.5,210:45,225:45,240:35,255:37.5,270:37.5,285:35,300:37.5,315:37.5,330:37.5,345:42.5 bbox_deg=46.509,42.500,36.545,37.500 bbox_tan=1.0541,0.9163,0.7412,0.7673 fov_source=a100-axis-C foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=36.989")
        lens.eye = .right
        lens.offset = 5
        expectEqual(Diag.line(topic: "dots_outline", tMs: 4, fields: lens.outlineFields(frustum: right, source: "m5_view")!),
                    "DIAG dots_outline t_ms=4 eye=R shape=lens offset_deg=5.000 nasal_deg=42.500 temporal_deg=45.000 up_deg=35.000 down_deg=37.500 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000 reference=device-20261021 rays=0:45,15:42.5,30:42.5,45:40,60:37.5,75:37.5,90:35,105:35,120:35,135:40,150:40,165:40,180:42.5,195:42.5,210:37.5,225:37.5,240:37.5,255:35,270:37.5,285:37.5,300:35,315:45,330:45,345:47.5 bbox_deg=42.500,46.509,36.545,37.500 bbox_tan=0.9163,1.0541,0.7412,0.7673 fov_source=a100-axis-C foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.372,34.296,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=36.989")

        // Slider logging: one dots_outline line per snapped value change during a slide (not per frame)
        // and one more at release with the settled value; a slide within one 0.5 deg step logs nothing.
        var logged = BoundaryDotsSession()
        logged.eye = .left
        var logSlider = BoundaryDotsSlider<Int>()
        var sliderLog = BoundaryDotsSliderLog()
        var lines: [String] = []
        func slide(_ id: Int, _ dx: Double, _ phase: BoundaryDotsPinchPhase = .active, enabled: Bool = true) {
            if !logSlider.active { sliderLog.reset() }
            let update = logSlider.update(id: id, hand: .left, phase: phase, position: origin + [dx, 0, 0], headRotation: level,
                                          inset: logged.sliderValue, enabled: enabled, range: logged.sliderRange,
                                          sign: logged.sliderSign)
            switch update {
            case .move(let value)?, .release(_, let value)?: logged.sliderValue = value
            case nil: break
            }
            if sliderLog.logs(update, session: logged), let fields = logged.outlineFields(frustum: left, source: "device_default") {
                lines.append(Diag.line(topic: "dots_outline", tMs: 10 + lines.count, fields: fields))
            }
        }
        for dx in [0.0, 0.001, 0.002, 0.006, 0.007, 0.011, 0.012, 0.014, 0.016, 0.017] { slide(1, dx) }
        slide(1, 0.017, .ended)
        expectEqual(lines.count, 4, "three snap steps and a release: four lines")
        expectEqual(lines.map { $0.components(separatedBy: " ").first { $0.hasPrefix("offset_deg=") } ?? "" },
                    ["offset_deg=0.500", "offset_deg=1.000", "offset_deg=1.500", "offset_deg=1.500"], "offsets per step, settled at release")
        expectEqual(lines.last, "DIAG dots_outline t_ms=13 eye=L shape=lens offset_deg=1.500 nasal_deg=39.000 temporal_deg=41.500 up_deg=31.500 down_deg=34.000 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays=0:39,15:36.5,30:36.5,45:36.5,60:31.5,75:31.5,90:31.5,105:34,120:34,135:36.5,150:39,165:39,180:41.5,195:44,210:41.5,225:41.5,240:31.5,255:34,270:34,285:31.5,300:34,315:34,330:34,345:39 bbox_deg=43.008,39.000,33.085,34.000 bbox_tan=0.9328,0.8098,0.6515,0.6745 fov_source=a100-axis-C foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=41.826")
        lines = []
        for dx in [0.0, 0.002, -0.002, 0.0024, 0.0] { slide(2, dx) }
        slide(2, 0.001, .ended)
        expectEqual(lines, [], "a slide within one step logs nothing")
        // Rect: hand right lowers the inset; a cancel restores and logs.
        logged.toggleShape()
        for dx in [0.0, 0.006] { slide(3, dx) }
        expectEqual(logged.inset, 14.5, "rect hand right lowers the inset")
        slide(3, 0.006, .cancelled)
        expectEqual(lines.count, 2, "rect step and cancel")
        expect(lines.allSatisfy { $0.contains("shape=rect") }, "rect slides log rect lines")
        expectEqual(lines.last?.contains("inset_deg=15.000"), true, "cancel logs the restored inset")
        // The same value on another eye is a new line (an eye switch mid-slide re-anchors it).
        lines = []
        for dx in [0.0, 0.006] { slide(4, dx) }
        logged.eye = .right
        for dx in [0.008, 0.014] { slide(4, dx) }
        expectEqual(lines.map { $0.contains("eye=R") }, [false, true], "L 14.5 then R 14.5: two lines")
        slide(4, 0.014, .ended)
        expectEqual(lines.count, 3, "release logs R")
        // A slide ended by a cursor (no release line) does not suppress the next slide's first step.
        lines = []
        for dx in [0.0, 0.006] { slide(5, dx) }
        slide(5, 0.006, enabled: false)
        slide(5, 0.006, .ended, enabled: false)
        logged.inset = 14.5
        for dx in [0.0, 0.006] { slide(6, dx) }
        expectEqual(lines.count, 2, "R 14.0 in both slides: each logs")
        expect(lines.allSatisfy { $0.contains("eye=R") && $0.contains("inset_deg=14.000") }, "R inset 14 twice")

        // Logged tangents (m5_view, drawable 0: view 0 = L, view 1 = R) replace the device defaults.
        BoundaryDotsTangents.reset()
        expectEqual(BoundaryDotsTangents.frustum(.left)?.source, "device_default")
        expectEqual(BoundaryDotsTangents.frustum(.left)?.frustum, left)
        expect(BoundaryDotsTangents.frustum(.both) == nil, "Both has no frustum")
        BoundaryDotsTangents.record(view: 0, left: 1.5, right: 0.9, bottom: 1.1, top: 0.95)
        BoundaryDotsTangents.record(view: 1, left: 0, right: 1, bottom: 1, top: 1)
        BoundaryDotsTangents.record(view: 1, left: .nan, right: 1, bottom: 1, top: 1)
        BoundaryDotsTangents.record(view: 2, left: 1, right: 1, bottom: 1, top: 1)
        expectEqual(BoundaryDotsTangents.frustum(.left)?.source, "m5_view")
        expectEqual(BoundaryDotsTangents.frustum(.left)?.frustum, BoundaryDotsFrustum(left: 1.5, right: 0.9, bottom: 1.1, top: 0.95))
        expectEqual(BoundaryDotsTangents.frustum(.right)?.source, "device_default", "invalid tangents ignored")
        expectEqual(BoundaryDotsTangents.frustum(.right)?.frustum, right)
        BoundaryDotsTangents.reset()
        finishTests("BoundaryOutlineTests")
    }
}
