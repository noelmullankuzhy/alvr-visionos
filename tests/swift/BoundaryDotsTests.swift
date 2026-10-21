// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/EntryEnterPolicy.swift ALVRClient/AutoEnterPolicy.swift
import Foundation
import simd

@main
enum BoundaryDotsTests {
    static func main() {
        func near(_ a: Double, _ b: Double, _ message: String) {
            expect(abs(a - b) < 1e-9, "\(message): \(a) vs \(b)")
        }
        let dots = BoundaryDots.layout
        expectEqual(dots.count, 24 * 25, "24 rays with 25 eccentricities")
        expectEqual(Set(dots).count, dots.count, "unique targets")
        near(BoundaryDots.radius, 10, "metres")
        near(BoundaryDots.visualDiameterDeg, 1, "visual diameter")
        near(BoundaryDots.collisionDiameterDeg, 2.2, "collision diameter")
        near(2 * asin(BoundaryDots.visualRadius / 10) * 180 / .pi, 1, "sphere angular diameter")
        for ray in 0..<24 {
            let points = dots.filter { $0.rayDeg == Double(ray * 15) }
            expectEqual(points.count, 25, "ray \(ray)")
            for (i, dot) in points.enumerated() {
                near(dot.eccDeg, 10 + 2.5 * Double(i), "radial spacing")
                near(simd_length(dot.direction), 1, "unit direction")
                near(acos(-dot.direction.z) * 180 / .pi, dot.eccDeg, "polar eccentricity")
                near(tan(dot.yawDeg * .pi / 180), dot.direction.x / -dot.direction.z, "horizontal tangent angle")
                near(tan(dot.pitchDeg * .pi / 180), dot.direction.y / -dot.direction.z, "vertical tangent angle")
                near(atan2(dot.direction.y, dot.direction.x) * 180 / .pi + (ray > 12 ? 360 : 0), dot.rayDeg, "CCW from right")
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
