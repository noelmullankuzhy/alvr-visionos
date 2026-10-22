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
    static let visualDiameterDeg = 0.5
    static let cursorDiameterDeg = 1.6
    static let collisionDiameterDeg = 2.2
    static let visualRadius = radius * sin(visualDiameterDeg * .pi / 360)
    static let collisionRadius = radius * sin(collisionDiameterDeg * .pi / 360)
    static let rayStepDeg = 7.5
    /// Intermediate rays (odd multiples of 7.5 deg) start at 20 deg so collision spheres never overlap.
    static func minEccDeg(rayDeg: Double) -> Double {
        (rayDeg / 15).rounded() == rayDeg / 15 ? 10 : 20
    }
    static let layout: [BoundaryDot] = (0..<Int(360 / rayStepDeg)).flatMap { ray in
        let rayDeg = Double(ray) * rayStepDeg
        return stride(from: minEccDeg(rayDeg: rayDeg), through: 70, by: 2.5).map { BoundaryDot(rayDeg: rayDeg, eccDeg: $0) }
    }
}

struct BoundaryDotsSession {
    var eye = BoundaryDotsEye.both
    private var cursors: [BoundaryDotsEye: BoundaryDot] = [:]
    var cursor: BoundaryDot? { cursors[eye] }
    private(set) var marks: [BoundaryDotsEye: Set<BoundaryDot>] = [:]
    private var insets: [BoundaryDotsEye: Double] = [:]

    /// Outline inset of the selected eye; set values snap to 0.5 deg within 0...30, non-finite ones are ignored.
    var inset: Double {
        get { insets[eye] ?? BoundaryDotsOutline.defaultInsetDeg }
        set { if newValue.isFinite { insets[eye] = BoundaryDotsOutline.clampInset(newValue) } }
    }

    /// Clears the selected eye's cursor so the left drag moves the outline again.
    mutating func deselect() -> Bool {
        cursors.removeValue(forKey: eye) != nil
    }

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
        let ecc = min(70, max(BoundaryDots.minEccDeg(rayDeg: dot.rayDeg), dot.eccDeg + (outward ? 2.5 : -2.5)))
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

    /// The `dots_outline` line for the selected eye; nil for Both (the outline is monocular).
    func outlineFields(frustum: BoundaryDotsFrustum, source: String) -> KeyValuePairs<String, Any>? {
        guard let limits = frustum.limits(eye: eye, insetDeg: inset) else { return nil }
        let tangents = String(format: "%.4f,%.4f,%.4f,%.4f", locale: Locale(identifier: "en_US_POSIX"),
                              frustum.left, frustum.right, frustum.bottom, frustum.top)
        return ["eye": eye.rawValue, "inset_deg": inset, "nasal_deg": limits.nasal, "temporal_deg": limits.temporal,
                "up_deg": limits.up, "down_deg": limits.down, "tangent_source": source, "tangents": tangents]
    }
}

/// A rendered view frustum as positive tangents in `m5_view` order (left, right, bottom, top).
struct BoundaryDotsFrustum: Equatable {
    let left, right, bottom, top: Double

    // Device m5_view, 21 Oct: L 60 deg temporal (left), 45 nasal, 50 down, 45 up; R mirrored.
    static func device(_ eye: BoundaryDotsEye) -> BoundaryDotsFrustum? {
        let l = BoundaryDotsFrustum(left: 1.7321, right: 1.0, bottom: 1.1918, top: 1.0)
        switch eye {
        case .left: return l
        case .right: return BoundaryDotsFrustum(left: l.right, right: l.left, bottom: l.bottom, top: l.top)
        case .both: return nil
        }
    }

    /// Eccentricity (deg from the head axis) where the ray at `rayDeg` (CCW from right) meets the frustum edge.
    func edgeEccDeg(rayDeg: Double) -> Double {
        let ray = rayDeg * .pi / 180, c = cos(ray), s = sin(ray)
        var reach = Double.infinity
        if c > 1e-12 { reach = min(reach, right / c) }
        if c < -1e-12 { reach = min(reach, left / -c) }
        if s > 1e-12 { reach = min(reach, top / s) }
        if s < -1e-12 { reach = min(reach, bottom / -s) }
        return atan(reach) * 180 / .pi
    }

    /// Closed polygon (last vertex joins the first): rays every 5 deg plus the four corner rays, each at
    /// the edge eccentricity minus `insetDeg`, clamped at 0. Inset 0 traces the frustum rectangle.
    func outline(insetDeg: Double) -> [BoundaryDot] {
        func normalised(_ deg: Double) -> Double { deg < 0 ? deg + 360 : deg }
        let corners = [atan2(top, right), atan2(top, -left), atan2(-bottom, -left), atan2(-bottom, right)]
            .map { normalised($0 * 180 / .pi) }
        var rays: [Double] = []
        for ray in (stride(from: 0.0, to: 360, by: 5) + corners).sorted() where rays.last.map({ ray - $0 > 1e-9 }) ?? true {
            rays.append(ray)
        }
        return rays.map { BoundaryDot(rayDeg: $0, eccDeg: max(0, edgeEccDeg(rayDeg: $0) - insetDeg)) }
    }

    /// Outline polygon area in tangent space over the frustum area.
    func areaFraction(insetDeg: Double) -> Double {
        let points = outline(insetDeg: insetDeg).map { dot -> SIMD2<Double> in
            let r = tan(dot.eccDeg * .pi / 180), ray = dot.rayDeg * .pi / 180
            return [r * cos(ray), r * sin(ray)]
        }
        let twice = zip(points, points.dropFirst() + points.prefix(1)).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }
        return abs(twice) / 2 / ((left + right) * (bottom + top))
    }

    /// Side limits in degrees: frustum side minus inset, clamped at 0. Nasal is the right side for L, left for R.
    func limits(eye: BoundaryDotsEye, insetDeg: Double) -> BoundaryDotsLimits? {
        func side(_ tangent: Double) -> Double { max(0, atan(tangent) * 180 / .pi - insetDeg) }
        switch eye {
        case .left: return BoundaryDotsLimits(nasal: side(right), temporal: side(left), up: side(top), down: side(bottom))
        case .right: return BoundaryDotsLimits(nasal: side(left), temporal: side(right), up: side(top), down: side(bottom))
        case .both: return nil
        }
    }
}

struct BoundaryDotsLimits: Equatable {
    let nasal, temporal, up, down: Double
}

enum BoundaryDotsOutline {
    static let defaultInsetDeg = 15.0
    static let maxInsetDeg = 30.0
    static let lineWidthDeg = 0.3

    static func clampInset(_ deg: Double) -> Double {
        min(maxInsetDeg, max(0, (deg * 2).rounded() / 2))
    }
}

/// Latest `m5_view` tangents of drawable 0 (view 0 = L, view 1 = R) in this app session, written from the
/// Diag queue and read on the main actor; the device defaults stand in until a Metal session has run.
enum BoundaryDotsTangents {
    private static let lock = NSLock()
    private static var logged: [BoundaryDotsEye: BoundaryDotsFrustum] = [:]

    static func record(view: Int, left: Double, right: Double, bottom: Double, top: Double) {
        let eye: BoundaryDotsEye
        switch view {
        case 0: eye = .left
        case 1: eye = .right
        default: return
        }
        guard [left, right, bottom, top].allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        lock.lock()
        logged[eye] = BoundaryDotsFrustum(left: left, right: right, bottom: bottom, top: top)
        lock.unlock()
    }

    static func frustum(_ eye: BoundaryDotsEye) -> (frustum: BoundaryDotsFrustum, source: String)? {
        lock.lock()
        let value = logged[eye]
        lock.unlock()
        if let value { return (value, "m5_view") }
        return BoundaryDotsFrustum.device(eye).map { ($0, "device_default") }
    }

    static func reset() {
        lock.lock()
        logged = [:]
        lock.unlock()
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
        let ecc = min(70, max(BoundaryDots.minEccDeg(rayDeg: start.rayDeg), start.eccDeg + 2.5 * (along / metresPerStep).rounded()))
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
    var active: Bool { grab != nil }

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

// Left-hand slider for the outline inset while no cursor is selected: hand travel
// along the head frame's horizontal axis (right = more inset), 1 cm per degree,
// snapped to 0.5 deg within 0...30 and relative to the inset at the grab.
enum BoundaryDotsSliderMap {
    static let metresPerDeg = 0.01

    static func inset(from start: Double, displacement: SIMD3<Double>) -> Double {
        guard displacement.x.isFinite else { return start }
        return BoundaryDotsOutline.clampInset(start + displacement.x / metresPerDeg)
    }
}

enum BoundaryDotsSliderUpdate: Equatable {
    case move(Double)
    case release(from: Double, to: Double)
}

/// The inset counterpart of `BoundaryDotsDrag`: one left-hand slide at a time, keyed by
/// spatial event ID, grabbed only while `enabled` (no cursor, a single eye). Once grabbed
/// it runs to release or cancel; an inset changed elsewhere (eye switch) re-anchors it and
/// a cancelled slide restores its starting inset.
struct BoundaryDotsSlider<ID: Hashable> {
    private struct Grab {
        let id: ID
        var origin: SIMD3<Double>
        var start: Double
        var current: Double
    }
    private var grab: Grab?
    var active: Bool { grab != nil }

    mutating func update(id: ID, hand: BoundaryDotsHand?, phase: BoundaryDotsPinchPhase,
                         position: SIMD3<Double>, headRotation: simd_quatd,
                         inset: Double, enabled: Bool) -> BoundaryDotsSliderUpdate? {
        guard var active = grab else {
            if phase == .active, hand == .left, enabled, all(position .== position) {
                grab = Grab(id: id, origin: position, start: inset, current: inset)
            }
            return nil
        }
        guard active.id == id else { return nil }
        guard phase != .cancelled else {
            grab = nil
            return active.current != active.start && inset == active.current ? .move(active.start) : nil
        }
        if inset != active.current {
            active = Grab(id: id, origin: position, start: inset, current: inset)
        } else {
            let displacement = headRotation.inverse.act(position - active.origin)
            active.current = BoundaryDotsSliderMap.inset(from: active.start, displacement: displacement)
        }
        if phase == .ended {
            grab = nil
            if active.current != active.start { return .release(from: active.start, to: active.current) }
            return active.current != inset ? .move(active.current) : nil
        }
        let moved = active.current != inset
        grab = active
        return moved ? .move(active.current) : nil
    }
}
