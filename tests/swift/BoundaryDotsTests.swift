// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/BoundaryDotsLensModel.swift ALVRClient/Diagnostics/ProjectionOverlay.swift ALVRClient/EntryEnterPolicy.swift ALVRClient/AutoEnterPolicy.swift
import Foundation
import simd

@main
enum BoundaryDotsTests {
    static func main() {
        func near(_ a: Double, _ b: Double, _ message: String) {
            expect(abs(a - b) < 1e-9, "\(message): \(a) vs \(b)")
        }
        let dots = BoundaryDots.layout
        expectEqual(dots.count, 24 * 25 + 24 * 21, "24 main rays from 10 deg, 24 intermediate rays from 20 deg")
        expectEqual(Set(dots).count, dots.count, "unique targets")
        near(BoundaryDots.radius, 10, "metres")
        near(BoundaryDots.visualDiameterDeg, 0.5, "visual diameter")
        near(BoundaryDots.collisionDiameterDeg, 2.2, "collision diameter")
        near(BoundaryDots.rayStepDeg, 7.5, "ray spacing")
        near(2 * asin(BoundaryDots.visualRadius / 10) * 180 / .pi, 0.5, "sphere angular diameter")
        for ray in 0..<48 {
            let rayDeg = Double(ray) * 7.5
            let first = ray % 2 == 0 ? 10.0 : 20.0
            near(BoundaryDots.minEccDeg(rayDeg: rayDeg), first, "first ring on ray \(rayDeg)")
            let points = dots.filter { $0.rayDeg == rayDeg }
            expectEqual(points.count, ray % 2 == 0 ? 25 : 21, "ray \(rayDeg)")
            for (i, dot) in points.enumerated() {
                near(dot.eccDeg, first + 2.5 * Double(i), "radial spacing")
                near(simd_length(dot.direction), 1, "unit direction")
                near(acos(-dot.direction.z) * 180 / .pi, dot.eccDeg, "polar eccentricity")
                near(tan(dot.yawDeg * .pi / 180), dot.direction.x / -dot.direction.z, "horizontal tangent angle")
                near(tan(dot.pitchDeg * .pi / 180), dot.direction.y / -dot.direction.z, "vertical tangent angle")
                near(atan2(dot.direction.y, dot.direction.x) * 180 / .pi + (ray > 24 ? 360 : 0), dot.rayDeg, "CCW from right")
            }
        }
        // Exhaustive pairwise geometry, including inner-ring neighbours on different rays.
        var closest = Double.infinity
        for i in dots.indices {
            for j in dots.indices where j > i {
                closest = min(closest, simd_distance(dots[i].direction, dots[j].direction) * BoundaryDots.radius)
            }
        }
        expect(closest > 2 * BoundaryDots.collisionRadius, "collision spheres never overlap")
        let right = BoundaryDot(rayDeg: 0, eccDeg: 30)
        near(right.yawDeg, 30, "right positive")
        near(right.pitchDeg, 0, "right on horizontal")
        near(BoundaryDot(rayDeg: 90, eccDeg: 30).pitchDeg, 30, "up positive")
        near(BoundaryDot(rayDeg: 180, eccDeg: 30).yawDeg, -30, "left negative")
        near(BoundaryDot(rayDeg: 270, eccDeg: 30).pitchDeg, -30, "down negative")
        let diagonal = BoundaryDot(rayDeg: 45, eccDeg: 60)
        near(diagonal.yawDeg, atan(tan(.pi / 3) / sqrt(2)) * 180 / .pi, "diagonal yaw")
        near(diagonal.pitchDeg, diagonal.yawDeg, "diagonal projected pitch")

        var session = BoundaryDotsSession()
        let outer = BoundaryDot(rayDeg: 0, eccDeg: 32.5)
        expectEqual(session.eye, .both)
        expectEqual(session.step(outward: true), nil, "no cursor means no step")
        expectEqual(session.confirm(), nil, "no cursor means no confirmation")
        expectEqual(session.select(right), "cursor")
        expectEqual(session.cursor, right)
        expect(!session.isConfirmed(right), "selection does not confirm")
        expectEqual(session.step(outward: true), outer)
        expectEqual(session.step(outward: false), right)
        expectEqual(session.confirm(), right)
        _ = session.step(outward: true)
        expectEqual(session.confirm(), outer)
        expect(!session.isConfirmed(right), "confirm replaces same ray")
        expectEqual(session.outermost(.both), [outer])
        let other = BoundaryDot(rayDeg: 135, eccDeg: 47.5)
        _ = session.select(other)
        _ = session.confirm()
        expectEqual(session.outermost(.both), [outer, other], "other rays remain")
        expectEqual(session.select(outer), "clear")
        expect(!session.isConfirmed(outer), "pinch confirmed dot clears")
        expectEqual(session.cursor, other, "clearing does not move cursor")
        session.eye = .left
        expectEqual(session.cursor, nil, "cursor belongs to eye")
        _ = session.select(right)
        _ = session.confirm()
        session.eye = .both
        expectEqual(session.cursor, other)
        expect(session.isConfirmed(other), "eye confirms persist")
        expect(!session.isConfirmed(right), "eye confirms are independent")
        _ = session.select(BoundaryDot(rayDeg: 135, eccDeg: 70))
        expectEqual(session.step(outward: true), nil, "70 degree ceiling")
        expectEqual(session.cursor?.eccDeg, 70)
        _ = session.select(BoundaryDot(rayDeg: 135, eccDeg: 10))
        expectEqual(session.step(outward: false), nil, "10 degree floor")
        expectEqual(session.cursor?.eccDeg, 10)
        for action in ["cursor", "step_out", "step_in", "confirm", "clear"] {
            let via = action.hasPrefix("step") || action == "confirm" ? "step" : "gaze"
            expectEqual(Diag.line(topic: "dots", tMs: 123, fields: session.markFields(right, action: action, via: via)),
                        "DIAG dots t_ms=123 eye=Both action=\(action) ray_deg=0.000 ecc_deg=30.000 yaw_deg=30.000 pitch_deg=0.000 via=\(via)")
        }
        expectEqual(Diag.line(topic: "dots_summary", tMs: 124, fields: session.summaryFields(.both)),
                    "DIAG dots_summary t_ms=124 eye=Both points=1 rays=135:47.5")
        expectEqual(Diag.line(topic: "dots_summary", tMs: 125, fields: session.summaryFields(.right)),
                    "DIAG dots_summary t_ms=125 eye=R points=0 rays=none")
        near(BoundaryDots.cursorDiameterDeg, 1.6, "cursor ring diameter")

        var pinches = BoundaryDotsPinches<Int>()
        for hand in [BoundaryDotsHand.left, .right] {
            for duration in [0.499, 0.5, 0.8] {
                expectEqual(pinches.update(id: 1, hand: hand, phase: .active, timestamp: 0, target: "dot_0"), nil)
                // Updates and gaze drift must not reset the duration or starting target.
                _ = pinches.update(id: 1, hand: hand, phase: .active, timestamp: 0.25, target: "backdrop")
                let result = pinches.update(id: 1, hand: hand, phase: .ended, timestamp: duration, target: "backdrop")
                expectEqual(result, BoundaryDotsPinch(hand: hand, held: duration >= 0.5, target: "dot_0"))
                expectEqual(pinches.update(id: 1, hand: hand, phase: .ended, timestamp: duration, target: nil), nil, "no double dispatch")
            }
        }
        _ = pinches.update(id: 2, hand: .left, phase: .active, timestamp: 1, target: nil)
        _ = pinches.update(id: 3, hand: .right, phase: .active, timestamp: 1, target: "backdrop")
        expectEqual(pinches.update(id: 2, hand: .left, phase: .ended, timestamp: 1.2, target: nil)?.hand, .left)
        expectEqual(pinches.update(id: 3, hand: .right, phase: .ended, timestamp: 1.6, target: nil)?.held, true)
        _ = pinches.update(id: 4, hand: .right, phase: .active, timestamp: 1, target: nil)
        expectEqual(pinches.update(id: 4, hand: .right, phase: .cancelled, timestamp: 2, target: nil), nil)
        expectEqual(pinches.update(id: 4, hand: .right, phase: .ended, timestamp: 2, target: nil), nil)
        _ = pinches.update(id: 5, hand: nil, phase: .active, timestamp: 1, target: nil)
        expectEqual(pinches.update(id: 5, hand: nil, phase: .ended, timestamp: 2, target: nil), nil, "unknown hand ignored")

        // Left-hand drag mapping: head-frame displacement (x right, y up) projected on the ray, 1 cm per dot step.
        near(BoundaryDotsDragMap.metresPerStep, 0.01, "gain: 1 cm per dot step")
        for ray in 0..<24 {
            let rayDeg = Double(ray * 15)
            let start = BoundaryDot(rayDeg: rayDeg, eccDeg: 40)
            let out = BoundaryDotsDragMap.outward(rayDeg: rayDeg)
            near(simd_length(out), 1, "unit outward ray \(ray)")
            near(atan2(out.y, out.x) * 180 / .pi + (ray > 12 ? 360 : 0), rayDeg, "outward matches ray \(ray)")
            let along = SIMD3<Double>(out.x, out.y, 0), across = SIMD3<Double>(-out.y, out.x, 0)
            expectEqual(BoundaryDotsDragMap.target(from: start, displacement: along * 0.03),
                        BoundaryDot(rayDeg: rayDeg, eccDeg: 47.5), "outward 3 steps ray \(ray)")
            expectEqual(BoundaryDotsDragMap.target(from: start, displacement: along * -0.03),
                        BoundaryDot(rayDeg: rayDeg, eccDeg: 32.5), "inward 3 steps ray \(ray)")
            expectEqual(BoundaryDotsDragMap.target(from: start, displacement: across * 0.05), start, "across ray \(ray) ignored")
            expectEqual(BoundaryDotsDragMap.target(from: start, displacement: [0, 0, -0.05]), start, "depth ignored ray \(ray)")
            expectEqual(BoundaryDotsDragMap.target(from: start, displacement: along * 0.02 + across * 0.04 + [0, 0, 0.03]),
                        BoundaryDot(rayDeg: rayDeg, eccDeg: 45), "only the ray component counts ray \(ray)")
        }
        let horizontal = BoundaryDot(rayDeg: 180, eccDeg: 30)
        expectEqual(BoundaryDotsDragMap.target(from: horizontal, displacement: [-0.02, 0, 0]).eccDeg, 35, "hand left moves 180 deg ray outward")
        expectEqual(BoundaryDotsDragMap.target(from: horizontal, displacement: [0.02, 0, 0]).eccDeg, 25, "hand right moves 180 deg ray inward")
        expectEqual(BoundaryDotsDragMap.target(from: BoundaryDot(rayDeg: 90, eccDeg: 30), displacement: [0, 0.02, 0]).eccDeg, 35, "up moves 90 deg ray outward")
        expectEqual(BoundaryDotsDragMap.target(from: BoundaryDot(rayDeg: 270, eccDeg: 30), displacement: [0, 0.02, 0]).eccDeg, 25, "up moves 270 deg ray inward")
        let diagonalStart = BoundaryDot(rayDeg: 45, eccDeg: 30)
        expectEqual(BoundaryDotsDragMap.target(from: diagonalStart, displacement: [0.02, 0, 0]).eccDeg, 32.5,
                    "2 cm right is 1.41 cm along the 45 deg ray")
        for (metres, steps) in [(0.0049, 0), (0.0051, 1), (0.0149, 1), (0.0151, 2), (-0.0049, 0), (-0.0051, -1), (-0.0151, -2)] {
            expectEqual(BoundaryDotsDragMap.target(from: horizontal, displacement: [-metres, 0, 0]).eccDeg, 30 + 2.5 * Double(steps),
                        "snap \(metres) m to \(steps) steps")
        }
        expectEqual(BoundaryDotsDragMap.target(from: BoundaryDot(rayDeg: 0, eccDeg: 65), displacement: [0.2, 0, 0]).eccDeg, 70, "clamp at 70")
        expectEqual(BoundaryDotsDragMap.target(from: BoundaryDot(rayDeg: 0, eccDeg: 15), displacement: [-0.2, 0, 0]).eccDeg, 10, "clamp at 10")
        expectEqual(BoundaryDotsDragMap.target(from: horizontal, displacement: [.nan, 0, 0]), horizontal, "non-finite displacement ignored")
        expectEqual(BoundaryDotsDragMap.target(from: BoundaryDot(rayDeg: 7.5, eccDeg: 25), displacement: [-0.2, 0, 0]).eccDeg, 20,
                    "intermediate rays clamp at their first ring")
        var intermediate = BoundaryDotsSession()
        _ = intermediate.select(BoundaryDot(rayDeg: 187.5, eccDeg: 20))
        expectEqual(intermediate.step(outward: false), nil, "20 degree floor on intermediate rays")
        expect(intermediate.place(BoundaryDot(rayDeg: 187.5, eccDeg: 22.5)), "place on an intermediate ray")

        // Drag tracker: world hand positions, head rotation, cursor re-anchoring and release.
        let level = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        var drag = BoundaryDotsDrag<Int>()
        let start = BoundaryDot(rayDeg: 0, eccDeg: 40)
        let origin = SIMD3<Double>(0.2, 1.1, -0.4)
        expectEqual(drag.update(id: 1, hand: .left, phase: .active, position: origin, headRotation: level, cursor: nil), nil, "no cursor, no drag")
        expectEqual(drag.update(id: 1, hand: .left, phase: .active, position: origin + [0.03, 0, 0], headRotation: level, cursor: nil), nil)
        expectEqual(drag.update(id: 1, hand: .left, phase: .ended, position: origin, headRotation: level, cursor: nil), nil)
        // A quick left pinch without movement does nothing.
        expectEqual(drag.update(id: 2, hand: .left, phase: .active, position: origin, headRotation: level, cursor: start), nil)
        expectEqual(drag.update(id: 2, hand: .left, phase: .active, position: origin + [0.001, 0.002, 0.004], headRotation: level, cursor: start), nil)
        expectEqual(drag.update(id: 2, hand: .left, phase: .ended, position: origin, headRotation: level, cursor: start), nil, "quick left pinch reserved")
        expectEqual(drag.update(id: 3, hand: .right, phase: .active, position: origin, headRotation: level, cursor: start), nil)
        expectEqual(drag.update(id: 3, hand: .right, phase: .active, position: origin + [0.05, 0, 0], headRotation: level, cursor: start), nil, "right hand never drags")
        expectEqual(drag.update(id: 3, hand: .right, phase: .ended, position: origin, headRotation: level, cursor: start), nil)
        // No drift: back and forth in many small moves returns exactly to the starting dot.
        var cursor = start
        func feed(_ id: Int, _ position: SIMD3<Double>, _ phase: BoundaryDotsPinchPhase = .active,
                  hand: BoundaryDotsHand? = .left, head: simd_quatd = level) -> BoundaryDotsDragUpdate? {
            let result = drag.update(id: id, hand: hand, phase: phase, position: position, headRotation: head, cursor: cursor)
            if case .move(let dot)? = result { cursor = dot }
            return result
        }
        expectEqual(feed(4, origin), nil)
        for i in 1...40 { _ = feed(4, origin + [0.001 * Double(i), 0.0003 * Double(i % 3), 0]) }
        expectEqual(cursor, BoundaryDot(rayDeg: 0, eccDeg: 50), "4 cm out is 4 steps")
        for i in stride(from: 39, through: 0, by: -1) { _ = feed(4, origin + [0.001 * Double(i), 0, 0]) }
        expectEqual(cursor, start, "dragging back returns exactly")
        expectEqual(feed(4, origin + [0.021, 0, 0]), .move(BoundaryDot(rayDeg: 0, eccDeg: 45)))
        expectEqual(feed(4, origin + [0.022, 0, 0]), nil, "same dot is not re-sent")
        expectEqual(feed(4, origin + [0.022, 0, 0], .ended), .release(from: start, to: cursor), "release leaves the snapped dot")
        expectEqual(feed(4, origin + [0.022, 0, 0], .ended), nil, "no double release")
        // The next drag is relative to the new hand position and the dot the cursor is on.
        expectEqual(feed(5, origin + [0.1, 0, 0]), nil)
        expectEqual(feed(5, origin + [0.09, 0, 0]), .move(BoundaryDot(rayDeg: 0, eccDeg: 42.5)), "relative to new grab")
        expectEqual(feed(5, origin + [0.1, 0, 0], .ended), .move(BoundaryDot(rayDeg: 0, eccDeg: 45)),
                    "released back at the grab: cursor returns, no release action")
        // Head rotation: displacement is taken in the current head frame.
        let yawLeft = simd_quatd(angle: .pi / 2, axis: [0, 1, 0])
        cursor = BoundaryDot(rayDeg: 0, eccDeg: 40)
        expectEqual(feed(6, origin, head: yawLeft), nil)
        expectEqual(feed(6, origin + [0, 0, -0.03], head: yawLeft), .move(BoundaryDot(rayDeg: 0, eccDeg: 47.5)),
                    "world -Z is head right after a 90 deg left yaw")
        expectEqual(feed(6, origin + [0, 0, -0.03], .cancelled, head: yawLeft), .move(BoundaryDot(rayDeg: 0, eccDeg: 40)), "cancel restores")
        expectEqual(feed(6, origin, .ended, head: yawLeft), nil)
        // A right-hand select (or eye switch) moving the cursor mid-drag re-anchors the drag.
        expectEqual(feed(7, origin), nil)
        expectEqual(feed(7, origin + [0.01, 0, 0]), .move(BoundaryDot(rayDeg: 0, eccDeg: 42.5)))
        cursor = BoundaryDot(rayDeg: 90, eccDeg: 20)
        expectEqual(feed(7, origin + [0.03, 0, 0]), nil, "re-anchor at the new cursor")
        expectEqual(feed(7, origin + [0.03, 0.02, 0]), .move(BoundaryDot(rayDeg: 90, eccDeg: 25)))
        cursor = BoundaryDot(rayDeg: 90, eccDeg: 20)
        expectEqual(feed(7, origin + [0.03, 0.02, 0], .ended), nil, "cursor moved elsewhere: nothing to release")
        // Only one drag at a time; a concurrent second left pinch is ignored.
        expectEqual(feed(8, origin), nil)
        expectEqual(feed(9, origin), nil)
        expectEqual(feed(9, origin + [0, 0.05, 0]), nil, "second pinch ignored")
        expectEqual(feed(9, origin, .ended), nil)
        expectEqual(feed(8, origin + [0, 0.01, 0], hand: nil), .move(BoundaryDot(rayDeg: 90, eccDeg: 22.5)), "id keeps the drag")
        expectEqual(feed(8, origin + [0, 0.01, 0], .ended, hand: nil), .release(from: BoundaryDot(rayDeg: 90, eccDeg: 20), to: cursor))

        var placing = BoundaryDotsSession()
        expect(!placing.place(BoundaryDot(rayDeg: 0, eccDeg: 30)), "place needs a cursor")
        _ = placing.select(BoundaryDot(rayDeg: 0, eccDeg: 30))
        expect(placing.place(BoundaryDot(rayDeg: 0, eccDeg: 45)), "place on the cursor ray")
        expectEqual(placing.cursor, BoundaryDot(rayDeg: 0, eccDeg: 45))
        expect(!placing.place(BoundaryDot(rayDeg: 15, eccDeg: 45)), "place never changes ray")
        expect(!placing.place(BoundaryDot(rayDeg: 0, eccDeg: 71)), "place stays on the layout")
        expectEqual(placing.cursor, BoundaryDot(rayDeg: 0, eccDeg: 45))

        for diagnostics in [false, true] {
            for connected in [false, true] {
                for streaming in [false, true] {
                    expectEqual(EntryEnterPolicy.boundaryDotsVisible(diagnostics: diagnostics, connected: connected, streaming: streaming),
                                diagnostics && !connected && !streaming, "offline button gating")
                }
            }
        }
        var ownership = OfflineDiagnosticsLifecycle()
        expect(!ownership.begin(space: .boundaryDots, diagnostics: true, connected: false, streaming: false, onlineShowing: true), "online owns slot")
        for first in [OfflineDiagnosticsLifecycle.Space.metal, .boundaryDots] {
            expect(ownership.begin(space: first, diagnostics: true, connected: false, streaming: false), "reserve either offline space")
            expectEqual(ownership.space, first)
            for second in [OfflineDiagnosticsLifecycle.Space.metal, .boundaryDots] {
                expect(!ownership.begin(space: second, diagnostics: true, connected: false, streaming: false), "offline spaces exclude each other")
            }
            var autoEnter = AutoEnterPolicy(enabled: true)
            _ = autoEnter.update(connected: true, showing: true)
            expect(ownership.connectionArrived(connected: true, streaming: false), "connection dismisses either owner")
            expect(ownership.ownsSpace, "retain slot during awaited dismissal")
            expect(!ownership.begin(space: .boundaryDots, diagnostics: true, connected: false, streaming: false), "cannot enter while dismissing")
            ownership.dismissed()
            expectEqual(ownership.space, nil)
            expect(!autoEnter.update(connected: true, showing: false), "connection does not auto-open online")
        }
        expect(ownership.begin(space: .boundaryDots, diagnostics: true, connected: false, streaming: false), "reenter")
        ownership.dismissed()
        expect(!ownership.ownsSpace, "manual leave resets flag")
        finishTests("BoundaryDotsTests")
    }
}
