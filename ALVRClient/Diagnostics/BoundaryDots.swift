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
    static let collisionDiameterDeg = 2.2
    static let visualRadius = radius * sin(visualDiameterDeg * .pi / 360)
    static let collisionRadius = radius * sin(collisionDiameterDeg * .pi / 360)
    static let layout: [BoundaryDot] = (0..<24).flatMap { ray in
        (0..<25).map { ring in BoundaryDot(rayDeg: Double(ray * 15), eccDeg: 10 + Double(ring) * 2.5) }
    }
}

struct BoundaryDotsSession {
    var eye = BoundaryDotsEye.both
    private(set) var marks: [BoundaryDotsEye: Set<BoundaryDot>] = [:]

    func isConfirmed(_ dot: BoundaryDot) -> Bool { marks[eye]?.contains(dot) == true }

    mutating func toggle(_ dot: BoundaryDot) -> String {
        if isConfirmed(dot) {
            marks[eye]?.remove(dot)
            return "clear"
        }
        marks[eye, default: []].insert(dot)
        return "confirm"
    }

    func outermost(_ eye: BoundaryDotsEye) -> [BoundaryDot] {
        var rays: [Double: BoundaryDot] = [:]
        for dot in marks[eye] ?? [] where dot.eccDeg > (rays[dot.rayDeg]?.eccDeg ?? 0) {
            rays[dot.rayDeg] = dot
        }
        return rays.values.sorted { $0.rayDeg < $1.rayDeg }
    }

    func markFields(_ dot: BoundaryDot, action: String) -> KeyValuePairs<String, Any> {
        ["eye": eye.rawValue, "action": action, "ray_deg": dot.rayDeg, "ecc_deg": dot.eccDeg,
         "yaw_deg": dot.yawDeg, "pitch_deg": dot.pitchDeg]
    }

    func summaryFields(_ eye: BoundaryDotsEye) -> KeyValuePairs<String, Any> {
        func compact(_ value: Double) -> String { String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value) }
        let rays = outermost(eye).map { "\(compact($0.rayDeg)):\(compact($0.eccDeg))" }.joined(separator: ",")
        return ["eye": eye.rawValue, "points": marks[eye]?.count ?? 0, "rays": rays.isEmpty ? "none" : rays]
    }
}
