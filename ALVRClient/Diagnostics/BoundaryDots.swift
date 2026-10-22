import Foundation
import simd

enum BoundaryDotsEye: String, CaseIterable {
    case left = "L", right = "R", both = "Both"
}

struct BoundaryDot: Hashable {
    let rayDeg: Double
    let eccDeg: Double

    // Head coordinates: right +X, up +Y, forward -Z. Eccentricity is the
    // great-circle angle from forward; ray azimuth is CCW from right.
    var direction: SIMD3<Double> {
        let ray = rayDeg * .pi / 180, ecc = eccDeg * .pi / 180
        return [sin(ecc) * cos(ray), sin(ecc) * sin(ray), -cos(ecc)]
    }

    // Projected horizontal/vertical angles, so tan(yaw)=x/-z and
    // tan(pitch)=y/-z. Pitch here is not the spherical elevation asin(y).
    var yawDeg: Double { atan2(direction.x, -direction.z) * 180 / .pi }
    var pitchDeg: Double { atan2(direction.y, -direction.z) * 180 / .pi }
}

enum BoundaryDots {
    static let radius = 10.0
    static let visualDiameterDeg = 1.0
    static let cursorDiameterDeg = 1.6
    static let collisionDiameterDeg = 2.2
    static let visualRadius = radius * sin(visualDiameterDeg * .pi / 360)
    static let collisionRadius = radius * sin(collisionDiameterDeg * .pi / 360)
    static let layout: [BoundaryDot] = (0..<24).flatMap { ray in
        (0..<25).map { ring in BoundaryDot(rayDeg: Double(ray * 15), eccDeg: 10 + Double(ring) * 2.5) }
    }
}

struct BoundaryDotsSession {
    var eye = BoundaryDotsEye.both
    private var cursors: [BoundaryDotsEye: BoundaryDot] = [:]
    var cursor: BoundaryDot? { cursors[eye] }
    private(set) var marks: [BoundaryDotsEye: Set<BoundaryDot>] = [:]

    func isConfirmed(_ dot: BoundaryDot) -> Bool { marks[eye]?.contains(dot) == true }

    mutating func select(_ dot: BoundaryDot) -> String {
        if isConfirmed(dot) {
            marks[eye]?.remove(dot)
            return "clear"
        }
        cursors[eye] = dot
        return "cursor"
    }

    mutating func step(outward: Bool) -> BoundaryDot? {
        guard let dot = cursor else { return nil }
        let ecc = min(70, max(10, dot.eccDeg + (outward ? 2.5 : -2.5)))
        guard ecc != dot.eccDeg else { return nil }
        let next = BoundaryDot(rayDeg: dot.rayDeg, eccDeg: ecc)
        cursors[eye] = next
        return next
    }

    /// Moves the cursor along its own ray (left-hand drag); never changes ray or leaves the layout.
    mutating func place(_ dot: BoundaryDot) -> Bool {
        guard let current = cursor, current.rayDeg == dot.rayDeg, BoundaryDots.layout.contains(dot) else { return false }
        cursors[eye] = dot
        return true
    }

    mutating func confirm() -> BoundaryDot? {
        guard let dot = cursor else { return nil }
        marks[eye] = Set((marks[eye] ?? []).filter { $0.rayDeg != dot.rayDeg })
        marks[eye, default: []].insert(dot)
        return dot
    }

    func outermost(_ eye: BoundaryDotsEye) -> [BoundaryDot] {
        var rays: [Double: BoundaryDot] = [:]
        for dot in marks[eye] ?? [] where dot.eccDeg > (rays[dot.rayDeg]?.eccDeg ?? 0) {
            rays[dot.rayDeg] = dot
        }
        return rays.values.sorted { $0.rayDeg < $1.rayDeg }
    }

    func markFields(_ dot: BoundaryDot, action: String, via: String) -> KeyValuePairs<String, Any> {
        ["eye": eye.rawValue, "action": action, "ray_deg": dot.rayDeg, "ecc_deg": dot.eccDeg,
         "yaw_deg": dot.yawDeg, "pitch_deg": dot.pitchDeg, "via": via]
    }

    func summaryFields(_ eye: BoundaryDotsEye) -> KeyValuePairs<String, Any> {
        func compact(_ value: Double) -> String { String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value) }
        let rays = outermost(eye).map { "\(compact($0.rayDeg)):\(compact($0.eccDeg))" }.joined(separator: ",")
        return ["eye": eye.rawValue, "points": marks[eye]?.count ?? 0, "rays": rays.isEmpty ? "none" : rays]
    }
}

// Independent of SwiftUI so threshold, cancellation and concurrent-hand handling
// can be verified on macOS. Dispatch once on release, using the initial target.
enum BoundaryDotsHand { case left, right }
enum BoundaryDotsPinchPhase { case active, ended, cancelled }
struct BoundaryDotsPinch: Equatable {
    let hand: BoundaryDotsHand
    let held: Bool
    let target: String?
}

struct BoundaryDotsPinches<ID: Hashable> {
    private struct Start {
        let hand: BoundaryDotsHand
        let timestamp: TimeInterval
        let target: String?
    }
    private var starts: [ID: Start] = [:]

    mutating func update(id: ID, hand: BoundaryDotsHand?, phase: BoundaryDotsPinchPhase,
                         timestamp: TimeInterval, target: String?) -> BoundaryDotsPinch? {
        switch phase {
        case .active:
            if starts[id] == nil, let hand, timestamp.isFinite {
                starts[id] = Start(hand: hand, timestamp: timestamp, target: target)
            }
        case .cancelled:
            starts.removeValue(forKey: id)
        case .ended:
            guard let start = starts.removeValue(forKey: id), timestamp.isFinite,
                  timestamp >= start.timestamp else { return nil }
            return BoundaryDotsPinch(hand: start.hand, held: timestamp - start.timestamp >= 0.5,
                                     target: start.target)
        }
        return nil
    }
}

// Left-hand drag: hand displacement since the grab, in the head frame (x right,
// y up), projected on the cursor ray's outward direction in the field plane and
// snapped to whole dot steps from the dot the cursor was on at the grab.
enum BoundaryDotsDragMap {
    static let metresPerStep = 0.01

    static func outward(rayDeg: Double) -> SIMD2<Double> {
        let ray = rayDeg * .pi / 180
        return [cos(ray), sin(ray)]
    }

    static func target(from start: BoundaryDot, displacement: SIMD3<Double>) -> BoundaryDot {
        let along = simd_dot(SIMD2(displacement.x, displacement.y), outward(rayDeg: start.rayDeg))
        guard along.isFinite else { return start }
        let ecc = min(70, max(10, start.eccDeg + 2.5 * (along / metresPerStep).rounded()))
        return BoundaryDot(rayDeg: start.rayDeg, eccDeg: ecc)
    }
}

enum BoundaryDotsDragUpdate: Equatable {
    case move(BoundaryDot)
    case release(from: BoundaryDot, to: BoundaryDot)
}

/// One left-hand drag at a time, keyed by spatial event ID. Positions are world
/// metres; `headRotation` is world-from-head, so head turns during a drag do not
/// count as hand motion. A cursor changed elsewhere (right select, eye switch)
/// re-anchors the drag; a cancelled drag restores its starting dot.
struct BoundaryDotsDrag<ID: Hashable> {
    private struct Grab {
        let id: ID
        var origin: SIMD3<Double>
        var start: BoundaryDot
        var current: BoundaryDot
    }
    private var grab: Grab?

    mutating func update(id: ID, hand: BoundaryDotsHand?, phase: BoundaryDotsPinchPhase,
                         position: SIMD3<Double>, headRotation: simd_quatd,
                         cursor: BoundaryDot?) -> BoundaryDotsDragUpdate? {
        guard var active = grab else {
            if phase == .active, hand == .left, let cursor, all(position .== position) {
                grab = Grab(id: id, origin: position, start: cursor, current: cursor)
            }
            return nil
        }
        guard active.id == id else { return nil }
        guard phase != .cancelled else {
            grab = nil
            return active.current != active.start && cursor == active.current ? .move(active.start) : nil
        }
        guard let cursor else {
            if phase == .ended { grab = nil }
            return nil
        }
        if cursor != active.current {
            active = Grab(id: id, origin: position, start: cursor, current: cursor)
        } else {
            let displacement = headRotation.inverse.act(position - active.origin)
            active.current = BoundaryDotsDragMap.target(from: active.start, displacement: displacement)
        }
        if phase == .ended {
            grab = nil
            if active.current != active.start { return .release(from: active.start, to: active.current) }
            return active.current != cursor ? .move(active.current) : nil
        }
        let moved = active.current != cursor
        grab = active
        return moved ? .move(active.current) : nil
    }
}
