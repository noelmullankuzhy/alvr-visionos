// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/BoundaryDotsLensModel.swift ALVRClient/Diagnostics/ProjectionOverlay.swift
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
        // Hand right = outline outward in every style: lens and rect inset down (sign -1), measured offset up (sign +1).
        var styles = BoundaryDotsSession()
        expectEqual(styles.sliderSign, -1, "lens: hand right lowers the inset")
        styles.shape = .rect
        expectEqual(styles.sliderSign, -1, "rect: hand right lowers the inset")
        styles.shape = .measured
        expectEqual(styles.sliderSign, 1, "measured: hand right raises the offset")
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
                    "DIAG dots_outline t_ms=1 eye=L shape=rect inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 bbox_deg=45.001,30.489,30.489,35.058 bbox_tan=1.0000,0.5888,0.5888,0.7017 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=45.077")
        session.eye = .right
        session.inset = 30
        expectEqual(Diag.line(topic: "dots_outline", tMs: 2, fields: session.outlineFields(frustum: right, source: "m5_view")!),
                    "DIAG dots_outline t_ms=2 eye=R shape=rect inset_deg=30.000 nasal_deg=15.000 temporal_deg=30.001 up_deg=15.000 down_deg=20.001 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000 bbox_deg=18.330,30.001,18.435,21.659 bbox_tan=0.3313,0.5774,0.3333,0.3971 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.372,34.296,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=79.639")
        session.eye = .both
        expect(session.outlineFields(frustum: left, source: "device_default") == nil, "no outline line for Both")

        // Measured style (W34's lens, now `.measured`): the 21 Oct seal-on visible field (diag-20261021T152509Z.log; L rays where measured, else Both),
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

        // Session: per-eye offsets, the slider value follows the style, cycling keeps every value.
        var lens = BoundaryDotsSession()
        lens.eye = .left
        lens.shape = .measured
        expectEqual(lens.offset, 0, "default offset")
        expectEqual(lens.sliderValue, 0, "measured slider drives the offset")
        expectEqual(lens.sliderRange, BoundaryDotsOutline.offsetRange)
        lens.sliderValue = 5.2
        expectEqual(lens.offset, 5, "snapped")
        lens.offset = .nan
        expectEqual(lens.offset, 5, "non-finite ignored")
        lens.eye = .right
        expectEqual(lens.offset, 0, "offsets are per eye")
        lens.eye = .left
        lens.cycleShape()
        expectEqual(lens.shape, .lens, "measured -> lens")
        expectEqual(lens.sliderValue, 15, "lens slider drives the model inset")
        expectEqual(lens.sliderRange, BoundaryDotsOutline.insetRange)
        lens.cycleShape()
        expectEqual(lens.shape, .rect, "lens -> rect")
        expectEqual(lens.sliderValue, 15, "rect slider drives the inset")
        expectEqual(lens.sliderRange, BoundaryDotsOutline.insetRange)
        lens.cycleShape()
        expectEqual(lens.shape, .measured, "rect -> measured")
        expectEqual(lens.sliderValue, 5, "offset kept across the cycle")
        expectEqual(Diag.line(topic: "dots_outline", tMs: 3, fields: lens.outlineFields(frustum: left, source: "device_default")!),
                    "DIAG dots_outline t_ms=3 eye=L shape=measured offset_deg=5.000 nasal_deg=42.500 temporal_deg=45.000 up_deg=35.000 down_deg=37.500 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays=0:42.5,15:40,30:40,45:40,60:35,75:35,90:35,105:37.5,120:37.5,135:40,150:42.5,165:42.5,180:45,195:47.5,210:45,225:45,240:35,255:37.5,270:37.5,285:35,300:37.5,315:37.5,330:37.5,345:42.5 bbox_deg=46.509,42.500,36.545,37.500 bbox_tan=1.0541,0.9163,0.7412,0.7673 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=36.989")
        lens.eye = .right
        lens.offset = 5
        expectEqual(Diag.line(topic: "dots_outline", tMs: 4, fields: lens.outlineFields(frustum: right, source: "m5_view")!),
                    "DIAG dots_outline t_ms=4 eye=R shape=measured offset_deg=5.000 nasal_deg=42.500 temporal_deg=45.000 up_deg=35.000 down_deg=37.500 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000 reference=device-20261021 rays=0:45,15:42.5,30:42.5,45:40,60:37.5,75:37.5,90:35,105:35,120:35,135:40,150:40,165:40,180:42.5,195:42.5,210:37.5,225:37.5,240:37.5,255:35,270:37.5,285:37.5,300:35,315:45,330:45,345:47.5 bbox_deg=42.500,46.509,36.545,37.500 bbox_tan=0.9163,1.0541,0.7412,0.7673 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.372,34.296,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=36.989")

        // Slider logging: one dots_outline line per snapped value change during a slide (not per frame)
        // and one more at release with the settled value; a slide within one 0.5 deg step logs nothing.
        var logged = BoundaryDotsSession()
        logged.eye = .left
        logged.shape = .measured
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
        expectEqual(lines.last, "DIAG dots_outline t_ms=13 eye=L shape=measured offset_deg=1.500 nasal_deg=39.000 temporal_deg=41.500 up_deg=31.500 down_deg=34.000 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 reference=device-20261021 rays=0:39,15:36.5,30:36.5,45:36.5,60:31.5,75:31.5,90:31.5,105:34,120:34,135:36.5,150:39,165:39,180:41.5,195:44,210:41.5,225:41.5,240:31.5,255:34,270:34,285:31.5,300:34,315:34,330:34,345:39 bbox_deg=43.008,39.000,33.085,34.000 bbox_tan=0.9328,0.8098,0.6515,0.6745 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=41.826")
        lines = []
        for dx in [0.0, 0.002, -0.002, 0.0024, 0.0] { slide(2, dx) }
        slide(2, 0.001, .ended)
        expectEqual(lines, [], "a slide within one step logs nothing")
        // Rect: hand right lowers the inset; a cancel restores and logs.
        logged.shape = .rect
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

        // Model lens (style lens, the default): the Frustum Pixel Map diagram's construction (vBoundary). Each frustum edge
        // angle moves inwards by the inset (at least 1 deg left); a per-quadrant superellipse is inscribed in that rectangle.
        let model = BoundaryDotsLensModel.self
        func tand(_ d: Double) -> Double { tan(d * .pi / 180) }
        func nearPoint(_ got: SIMD2<Double>?, _ want: SIMD2<Double>, _ message: String, tolerance: Double = 1e-9) {
            guard let got else { return expect(false, "\(message): no point") }
            near(got.x, want.x, "\(message) x", tolerance: tolerance)
            near(got.y, want.y, "\(message) y", tolerance: tolerance)
        }
        func nearBox(_ box: ProjectionBox?, _ want: ProjectionBox?, _ message: String, tolerance: Double = 1e-9) {
            guard let box, let want else { return expect(false, "\(message): no box") }
            for (side, (got, value)) in zip(["left", "right", "up", "down"], zip(box.tangents, want.tangents)) {
                near(got, value, "\(message) \(side)", tolerance: tolerance)
            }
        }
        expectEqual(model.tag, "superellipse(2,3,1.5,4)", "model tag")
        expectEqual(model.pointCount, 480, "480 points around")
        expectEqual(BoundaryDotsOutline.defaultInsetDeg, 15, "default inset 15")
        // On the exact 60/45/45/50 frustum (temporal/nasal/up/down), inset 15 is 45/30/30/35.
        let exact = BoundaryDotsFrustum(left: tand(60), right: 1, bottom: tand(50), top: 1)
        let exactRect = model.insetRect(.left, frustum: exact, insetDeg: 15)
        expectEqual(exactRect.map { [$0.temporal, $0.nasal, $0.up, $0.down].map { ($0 * 1e9).rounded() / 1e9 } }, [45, 30, 30, 35],
                    "inset 15 on 60/45/45/50 = 45/30/30/35")
        near(exactRect?.aT ?? -1, 1, "a_T = tan 45")
        near(exactRect?.aN ?? -1, tand(30), "a_N = tan 30")
        near(exactRect?.bU ?? -1, tand(30), "b_U = tan 30")
        near(exactRect?.bD ?? -1, tand(35), "b_D = tan 35")
        // The device frustum (tan 60.0007, 45, 45, 50.0011): 45.0007/30/30/35.0011; R mirrors L (the same eye-frame rect).
        guard let rectL = model.insetRect(.left, frustum: left, insetDeg: 15),
              let rectR = model.insetRect(.right, frustum: right, insetDeg: 15) else {
            expect(false, "inset rect for L and R")
            finishTests("BoundaryOutlineTests")
        }
        for (got, want) in zip([rectL.temporal, rectL.nasal, rectL.up, rectL.down], [45.0, 30, 30, 35]) {
            near(got, want, "L device inset 15", tolerance: 2e-3)
        }
        near(rectL.temporal, atan(1.7321) * 180 / .pi - 15, "temporal = frustum edge - inset")
        expectEqual(rectR, rectL, "R mirrored")
        expectEqual(model.insetRect(.left, insetDeg: 15), rectL, "default frustum: the device's")
        expect(model.insetRect(.both, frustum: left, insetDeg: 15) == nil, "Both has no rect")
        expectEqual(rectL.limits, BoundaryDotsLimits(nasal: rectL.nasal, temporal: rectL.temporal, up: rectL.up, down: rectL.down), "limits")
        // Head frame (x right): L's temporal side is its left, R's its right.
        expectEqual(rectL.box(.left), ProjectionBox(left: rectL.aT, right: rectL.aN, up: rectL.bU, down: rectL.bD), "L box")
        expectEqual(rectR.box(.right), ProjectionBox(left: rectR.aN, right: rectR.aT, up: rectR.bU, down: rectR.bD), "R box")
        // Every edge keeps at least 1 deg.
        let deep = model.insetRect(.left, frustum: exact, insetDeg: 50)
        expectEqual(deep.map { [$0.temporal, $0.nasal, $0.up, $0.down].map { ($0 * 1e9).rounded() / 1e9 } }, [10, 1, 1, 1], "clamped to >= 1 deg")
        // Axis crossings (eye frame: temporal +, up +): phi 0 = (tan 45, 0), 90 = (0, tan 30), 180 = (-tan 30, 0), 270 = (0, -tan 35).
        let exactPoints = model.lensPoints(.left, frustum: exact, insetDeg: 15) ?? []
        expectEqual(exactPoints.count, 480, "480 points")
        nearPoint(exactPoints.first, [1, 0], "phi 0")
        nearPoint(exactPoints.count == 480 ? exactPoints[120] : nil, [0, tand(30)], "phi 90")
        nearPoint(exactPoints.count == 480 ? exactPoints[240] : nil, [-tand(30), 0], "phi 180")
        nearPoint(exactPoints.count == 480 ? exactPoints[360] : nil, [0, -tand(35)], "phi 270")
        // Quadrant exponents: upper-nasal 2, upper-temporal 3, lower-nasal 1.5, lower-temporal 4.
        expectEqual([model.exponent(c: -0.6, s: 0.8), model.exponent(c: 0.6, s: 0.8), model.exponent(c: -0.6, s: -0.8),
                     model.exponent(c: 0.6, s: -0.8)], [2, 3, 1.5, 4], "exponents by quadrant")
        // Phi 45 (upper temporal, n = 3), by hand: rho = 1 / (c^3 + (s / tan 30)^3)^(1/3), c = s = 1/sqrt 2:
        // (0.353553 + 0.353553 x 5.196152)^(1/3) = 2.190671^(1/3) = 1.298750, rho = 0.769971, point 0.544452 each way.
        // Inside the rectangle (0.544 < tan 45 and < tan 30 = 0.577), outside the inscribed ellipse (n = 2):
        // (0.544452 / 1)^2 + (0.544452 / 0.577350)^2 = 0.296428 + 0.889283 = 1.185710 > 1.
        let p45 = exactPoints.count == 480 ? exactPoints[60] : SIMD2<Double>(.nan, .nan)
        let c45 = cos(Double.pi / 4)
        let rho45 = 1 / pow(pow(c45, 3) + pow(c45 / tand(30), 3), 1.0 / 3)
        nearPoint(p45, [rho45 * c45, rho45 * c45], "phi 45 formula", tolerance: 1e-12)
        nearPoint(p45, [0.544452, 0.544452], "phi 45 by hand", tolerance: 1e-6)
        expect(p45.x < 1 && p45.y < tand(30), "phi 45 inside the rectangle")
        expect(pow(p45.x / 1, 2) + pow(p45.y / tand(30), 2) > 1, "phi 45 outside the inscribed ellipse")
        // Every point inside or on the rectangle; the bbox of the drawn lens is the rectangle (within 1e-9).
        for p in model.lensPoints(.left, frustum: left, insetDeg: 15) ?? [] {
            expect(p.x <= rectL.aT + 1e-12 && -p.x <= rectL.aN + 1e-12 && p.y <= rectL.bU + 1e-12 && -p.y <= rectL.bD + 1e-12,
                   "point \(p) inside the rect")
        }
        let lensL = model.outline(.left, frustum: left, insetDeg: 15) ?? []
        expectEqual(lensL.count, 480, "drawn outline: 480 dots")
        nearBox(ProjectionOverlay.bbox(lensL), rectL.box(.left), "bbox(lens L) == inset rect")
        nearBox(ProjectionOverlay.bbox(model.outline(.right, frustum: right, insetDeg: 15) ?? []), rectR.box(.right), "bbox(lens R) == inset rect")
        nearBox(ProjectionOverlay.bbox(model.outline(.left, frustum: left, insetDeg: 7.5) ?? []),
                model.insetRect(.left, frustum: left, insetDeg: 7.5)?.box(.left), "bbox follows the inset")
        expect(model.outline(.both, frustum: left, insetDeg: 15) == nil, "no lens for Both")
        // Head frame: the L lens's temporal crossing is on its left (ray 180), R's on its right (ray 0).
        near(lensL.first?.rayDeg ?? -1, 180, "L phi 0 is head ray 180", tolerance: 1e-9)
        near(lensL.first?.eccDeg ?? -1, rectL.temporal, "L phi 0 at the temporal edge", tolerance: 1e-9)
        near(model.outline(.right, frustum: right, insetDeg: 15)?.first?.rayDeg ?? -1, 0, "R phi 0 is head ray 0", tolerance: 1e-9)
        // Area: the 480-point polygon over the frustum (tangent space); less than the rectangle's, more inset less area.
        let lensArea15 = model.areaFraction(.left, frustum: left, insetDeg: 15) ?? -1
        near(lensArea15, left.areaFraction(of: lensL), "one area routine")
        expect(lensArea15 < (rectL.aT + rectL.aN) * (rectL.bU + rectL.bD) / (2.7321 * 2.1918), "lens inside its rectangle: \(lensArea15)")
        expect((model.areaFraction(.left, frustum: left, insetDeg: 20) ?? 1) < lensArea15, "more inset, less area")

        // Session: style lens by default, its slider sets the model inset (0...30, default 15, 0.5 steps, one value for both eyes).
        var modelSession = BoundaryDotsSession()
        modelSession.eye = .left
        expectEqual(modelSession.shape, .lens, "lens is the default style")
        expectEqual(modelSession.lensInset, 15, "default model inset")
        expectEqual(modelSession.sliderValue, 15, "lens slider drives the model inset")
        expectEqual(modelSession.sliderRange, BoundaryDotsOutline.insetRange, "0...30")
        modelSession.sliderValue = 20.26
        expectEqual(modelSession.lensInset, 20.5, "snapped 0.5")
        modelSession.lensInset = .nan
        expectEqual(modelSession.lensInset, 20.5, "non-finite ignored")
        modelSession.lensInset = 42
        expectEqual(modelSession.lensInset, 30, "clamped at 30")
        modelSession.eye = .right
        expectEqual(modelSession.lensInset, 30, "one model inset for both eyes")
        expectEqual(modelSession.inset, 15, "rect inset separate")
        modelSession.eye = .left
        modelSession.lensInset = 15
        expectEqual(modelSession.outline(.left, frustum: left), lensL, "session draws the model")
        expectEqual(modelSession.projection(.left, frustum: left)?.bbox, rectL.box(.left), "projection bbox = inset rect")
        expectEqual(modelSession.limits(.left, frustum: left), rectL.limits, "limits = inset rect")
        expectEqual(Diag.line(topic: "dots_outline", tMs: 20, fields: modelSession.outlineFields(frustum: left, source: "device_default")!),
                    "DIAG dots_outline t_ms=20 eye=L shape=lens inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000 model=superellipse(2,3,1.5,4) bbox_deg=45.001,30.000,30.000,35.001 bbox_tan=1.0000,0.5774,0.5774,0.7002 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.296,34.372,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=45.533")
        modelSession.eye = .right
        modelSession.lensInset = 10
        expectEqual(Diag.line(topic: "dots_outline", tMs: 21, fields: modelSession.outlineFields(frustum: right, source: "m5_view")!),
                    "DIAG dots_outline t_ms=21 eye=R shape=lens inset_deg=10.000 nasal_deg=35.000 temporal_deg=50.001 up_deg=35.000 down_deg=40.001 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000 model=superellipse(2,3,1.5,4) bbox_deg=35.000,50.001,35.000,40.001 bbox_tan=0.7002,1.1918,0.7002,0.8391 fov_source=a100-axis-C fov_live=no foveation=0.5,0.45,3,3,0.536,-0.159 fov_rect_deg=34.372,34.296,26.152,26.263 render_px=4176,3333 pxdeg_frustum=26.541 pxdeg_bbox=37.790")
        // Cycle: lens -> rect -> measured -> lens.
        var cycle = BoundaryDotsSession()
        var seen: [BoundaryDotsOutlineShape] = []
        for _ in 0..<4 { cycle.cycleShape(); seen.append(cycle.shape) }
        expectEqual(seen, [.rect, .measured, .lens, .rect], "quick right pinch cycles lens -> rect -> measured -> lens")

        // Lens slider: one 0.5 deg step per 0.5 cm (hand right = inset down, outline out), each step logs a line.
        var lensLog = BoundaryDotsSession()
        lensLog.eye = .left
        var lensLogSlider = BoundaryDotsSlider<Int>()
        var lensSliderLog = BoundaryDotsSliderLog()
        var lensLines: [String] = []
        func lensSlide(_ id: Int, _ dx: Double, _ phase: BoundaryDotsPinchPhase = .active) {
            if !lensLogSlider.active { lensSliderLog.reset() }
            let update = lensLogSlider.update(id: id, hand: .left, phase: phase, position: origin + [dx, 0, 0], headRotation: level,
                                              inset: lensLog.sliderValue, enabled: true, range: lensLog.sliderRange,
                                              sign: lensLog.sliderSign)
            switch update {
            case .move(let value)?, .release(_, let value)?: lensLog.sliderValue = value
            case nil: break
            }
            if lensSliderLog.logs(update, session: lensLog), let fields = lensLog.outlineFields(frustum: left, source: "device_default") {
                lensLines.append(Diag.line(topic: "dots_outline", tMs: 30 + lensLines.count, fields: fields))
            }
        }
        lensSlide(1, 0)
        lensSlide(1, 0.006)
        expectEqual(lensLog.lensInset, 14.5, "one step right: inset 15 -> 14.5")
        lensSlide(1, -0.006)
        expectEqual(lensLog.lensInset, 15.5, "back past the grab: 15.5")
        lensSlide(1, -0.006, .ended)
        expectEqual(lensLines.map { $0.components(separatedBy: " ").first { $0.hasPrefix("inset_deg=") } ?? "" },
                    ["inset_deg=14.500", "inset_deg=15.500", "inset_deg=15.500"], "each step and the release logged")
        expect(lensLines.allSatisfy { $0.contains("shape=lens") && $0.contains("model=superellipse(2,3,1.5,4)") }, "lens lines carry the model")
        expect(lensLines.first?.contains("nasal_deg=30.500 temporal_deg=45.501 up_deg=30.500 down_deg=35.501") == true,
               "the rectangle follows the slider: \(lensLines.first ?? "")")

        // Shared fixture with tools/diag/lens_model.py (test_lens_model.py): the same numbers to 1e-6.
        let lensFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/diag/fixtures/lens-model.json").standardized
        if let data = try? Data(contentsOf: lensFixture),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cases = root["cases"] as? [[String: Any]], cases.count == 4 {
            expectEqual(root["model"] as? String, model.tag, "fixture model tag")
            expectEqual(root["count"] as? Int, model.pointCount, "fixture count")
            for item in cases {
                let name = item["name"] as? String ?? "?"
                guard let eye = BoundaryDotsEye(rawValue: item["eye"] as? String ?? ""), let inset = item["inset_deg"] as? Double,
                      let degrees = item["rect_deg"] as? [String: Double], let tangents = item["rect_tan"] as? [String: Double],
                      let box = item["box_tan_LRUD"] as? [Double], box.count == 4,
                      let points = item["points"] as? [[String: Any]], points.count == 24,
                      let area = item["area_fraction"] as? Double,
                      let frustum = BoundaryDotsFrustum.device(eye),
                      let rect = model.insetRect(eye, frustum: frustum, insetDeg: inset) else {
                    expect(false, "lens fixture case \(name) malformed")
                    continue
                }
                for (key, got) in [("temporal", rect.temporal), ("nasal", rect.nasal), ("up", rect.up), ("down", rect.down)] {
                    near(got, degrees[key] ?? .nan, "fixture \(name) \(key) deg", tolerance: 1e-6)
                }
                for (key, got) in [("a_t", rect.aT), ("a_n", rect.aN), ("b_u", rect.bU), ("b_d", rect.bD)] {
                    near(got, tangents[key] ?? .nan, "fixture \(name) \(key)", tolerance: 1e-6)
                }
                nearBox(rect.box(eye), ProjectionBox(left: box[0], right: box[1], up: box[2], down: box[3]), "fixture \(name) box", tolerance: 1e-6)
                for point in points {
                    guard let phi = point["phi_deg"] as? Double, let e = point["eye"] as? [Double], let h = point["head"] as? [Double],
                          e.count == 2, h.count == 2 else { expect(false, "fixture \(name) point malformed"); continue }
                    let p = model.point(rect, phiDeg: phi)
                    nearPoint(p, [e[0], e[1]], "fixture \(name) phi \(phi) eye", tolerance: 1e-6)
                    nearPoint(model.head(eye, p), [h[0], h[1]], "fixture \(name) phi \(phi) head", tolerance: 1e-6)
                }
                near(model.areaFraction(eye, frustum: frustum, insetDeg: inset) ?? .nan, area, "fixture \(name) area", tolerance: 1e-6)
            }
        } else {
            expect(false, "fixture \(lensFixture.path) readable with 4 cases")
        }

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
