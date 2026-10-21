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
