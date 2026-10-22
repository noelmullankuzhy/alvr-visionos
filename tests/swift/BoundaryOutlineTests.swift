// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift
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
        expectEqual(Diag.line(topic: "dots_outline", tMs: 1, fields: session.outlineFields(frustum: left, source: "device_default")!),
                    "DIAG dots_outline t_ms=1 eye=L inset_deg=15.000 nasal_deg=30.000 temporal_deg=45.001 up_deg=30.000 down_deg=35.001 tangent_source=device_default tangents=1.7321,1.0000,1.1918,1.0000")
        session.eye = .right
        session.inset = 30
        expectEqual(Diag.line(topic: "dots_outline", tMs: 2, fields: session.outlineFields(frustum: right, source: "m5_view")!),
                    "DIAG dots_outline t_ms=2 eye=R inset_deg=30.000 nasal_deg=15.000 temporal_deg=30.001 up_deg=15.000 down_deg=20.001 tangent_source=m5_view tangents=1.0000,1.7321,1.1918,1.0000")
        session.eye = .both
        expect(session.outlineFields(frustum: left, source: "device_default") == nil, "no outline line for Both")

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
