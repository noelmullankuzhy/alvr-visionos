import Foundation
import simd

/// The model lens's inset rectangle in the eye frame (temporal +, up +): each frustum edge angle moved in by the
/// inset, at least 1 deg left. Angles in degrees from the eye axis; a/b are their tangents. L and R share it.
struct BoundaryDotsLensRect: Equatable {
    let temporal, nasal, up, down: Double

    var aT: Double { tan(temporal * .pi / 180) }
    var aN: Double { tan(nasal * .pi / 180) }
    var bU: Double { tan(up * .pi / 180) }
    var bD: Double { tan(down * .pi / 180) }
    var limits: BoundaryDotsLimits { BoundaryDotsLimits(nasal: nasal, temporal: temporal, up: up, down: down) }

    /// The rectangle in the head frame (x right): L's temporal side is its left, R's its right.
    func box(_ eye: BoundaryDotsEye) -> ProjectionBox? {
        switch eye {
        case .left: return ProjectionBox(left: aT, right: aN, up: bU, down: bD)
        case .right: return ProjectionBox(left: aN, right: aT, up: bU, down: bD)
        case .both: return nil
        }
    }
}

/// Boundary dots style `.lens`: the Frustum Pixel Map diagram's model lens (vBoundary). A per-quadrant superellipse
/// inscribed in the inset rectangle: rho = 1 / ((|c| / a)^n + (|s| / b)^n)^(1/n), a = a_T or a_N by the sign of
/// cos phi, b = b_U or b_D by the sign of sin phi, n by quadrant (upper-nasal 2, upper-temporal 3, lower-nasal 1.5,
/// lower-temporal 4). tools/diag/lens_model.py is the same model; fixtures/lens-model.json pins both.
enum BoundaryDotsLensModel {
    static let tag = "superellipse(2,3,1.5,4)"
    static let pointCount = 480
    static let minEdgeDeg = 1.0

    static func insetRect(_ eye: BoundaryDotsEye, frustum: BoundaryDotsFrustum? = nil, insetDeg: Double) -> BoundaryDotsLensRect? {
        guard let f = frustum ?? BoundaryDotsFrustum.device(eye) else { return nil }
        func edge(_ tangent: Double) -> Double { max(minEdgeDeg, atan(tangent) * 180 / .pi - insetDeg) }
        switch eye {
        case .left: return BoundaryDotsLensRect(temporal: edge(f.left), nasal: edge(f.right), up: edge(f.top), down: edge(f.bottom))
        case .right: return BoundaryDotsLensRect(temporal: edge(f.right), nasal: edge(f.left), up: edge(f.top), down: edge(f.bottom))
        case .both: return nil
        }
    }

    static func exponent(c: Double, s: Double) -> Double {
        s >= 0 ? (c >= 0 ? 3 : 2) : (c >= 0 ? 4 : 1.5)
    }

    /// The lens point at `phiDeg` (CCW from temporal) in the eye frame, tangent units.
    static func point(_ rect: BoundaryDotsLensRect, phiDeg: Double) -> SIMD2<Double> {
        let phi = phiDeg * .pi / 180, c = cos(phi), s = sin(phi)
        let a = c >= 0 ? rect.aT : rect.aN, b = s >= 0 ? rect.bU : rect.bD, n = exponent(c: c, s: s)
        let rho = 1 / pow(pow(abs(c) / a, n) + pow(abs(s) / b, n), 1 / n)
        return [rho * c, rho * s]
    }

    /// Eye frame to head frame (x right, y up): L's temporal is head left.
    static func head(_ eye: BoundaryDotsEye, _ p: SIMD2<Double>) -> SIMD2<Double> {
        eye == .left ? [-p.x, p.y] : p
    }

    static func lensPoints(_ eye: BoundaryDotsEye, frustum: BoundaryDotsFrustum? = nil, insetDeg: Double,
                           count: Int = pointCount) -> [SIMD2<Double>]? {
        guard let rect = insetRect(eye, frustum: frustum, insetDeg: insetDeg) else { return nil }
        return (0..<count).map { point(rect, phiDeg: 360 * Double($0) / Double(count)) }
    }

    /// The lens as a closed head-frame outline (ray CCW from right, eccentricity), for the ribbon and bbox code.
    static func outline(_ eye: BoundaryDotsEye, frustum: BoundaryDotsFrustum? = nil, insetDeg: Double) -> [BoundaryDot]? {
        lensPoints(eye, frustum: frustum, insetDeg: insetDeg)?.map { p in
            let h = head(eye, p)
            let ray = atan2(h.y, h.x) * 180 / .pi
            return BoundaryDot(rayDeg: ray < 0 ? ray + 360 : ray, eccDeg: atan(simd_length(h)) * 180 / .pi)
        }
    }

    /// The 480-point polygon's area in tangent space over the frustum's.
    static func areaFraction(_ eye: BoundaryDotsEye, frustum: BoundaryDotsFrustum? = nil, insetDeg: Double) -> Double? {
        guard let f = frustum ?? BoundaryDotsFrustum.device(eye),
              let lens = outline(eye, frustum: f, insetDeg: insetDeg) else { return nil }
        return f.areaFraction(of: lens)
    }
}
