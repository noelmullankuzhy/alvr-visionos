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
    private var offsets: [BoundaryDotsEye: Double] = [:]
    /// Outline style for every eye; a quick right pinch on the centre cross (no cursor) toggles it.
    var shape = BoundaryDotsOutlineShape.lens

    /// Outline inset of the selected eye; set values snap to 0.5 deg within 0...30, non-finite ones are ignored.
    var inset: Double {
        get { insets[eye] ?? BoundaryDotsOutline.defaultInsetDeg }
        set { if newValue.isFinite { insets[eye] = BoundaryDotsOutline.clampInset(newValue) } }
    }

    /// Lens outline offset of the selected eye (positive = outward); snaps to 0.5 deg within -10...+20.
    var offset: Double {
        get { offsets[eye] ?? 0 }
        set { if newValue.isFinite { offsets[eye] = BoundaryDotsOutline.clampOffset(newValue) } }
    }

    /// The value the left-hand slider drives: the offset (lens) or the inset (rect).
    var sliderValue: Double {
        get { shape == .lens ? offset : inset }
        set { if shape == .lens { offset = newValue } else { inset = newValue } }
    }
    var sliderRange: ClosedRange<Double> { shape == .lens ? BoundaryDotsOutline.offsetRange : BoundaryDotsOutline.insetRange }
    /// Hand right moves the outline outward in both styles: the offset up (lens), the inset down (rect).
    var sliderSign: Double { shape == .lens ? 1 : -1 }

    mutating func toggleShape() {
        shape = shape == .lens ? .rect : .lens
    }

    /// Points row for the foveation rect and px/deg readout while no stream is up; a pinch on the fov button cycles it.
    private(set) var foveationPoint = ProjectionFoveation.defaultName
    var foveationRow: ProjectionFoveation {
        ProjectionFoveation.named(foveationPoint) ?? ProjectionFoveation.points[0]
    }

    mutating func nextFoveationPoint() {
        let rows = ProjectionFoveation.points
        let index = rows.firstIndex { $0.name == foveationPoint } ?? -1
        foveationPoint = rows[(index + 1) % rows.count].name
    }

    /// One eye's drawn outline at its own slider value (lens: reference + offset; rect: frustum - inset); nil for Both.
    func outline(_ eye: BoundaryDotsEye, frustum: BoundaryDotsFrustum) -> [BoundaryDot]? {
        guard eye != .both else { return nil }
        return shape == .lens ? BoundaryDotsLensReference.outline(eye, offsetDeg: offsets[eye] ?? 0)
                              : frustum.outline(insetDeg: insets[eye] ?? BoundaryDotsOutline.defaultInsetDeg)
    }

    /// One eye's projection readout; `stream` nil uses the selected points row.
    func projection(_ eye: BoundaryDotsEye, frustum: BoundaryDotsFrustum, stream: ProjectionStream? = nil) -> ProjectionReadout? {
        outline(eye, frustum: frustum).flatMap {
            ProjectionReadout(eye: eye, frustum: frustum, outline: $0, stream: stream ?? .points(foveationRow))
        }
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
    /// Lens lines carry the drawn per-ray eccentricities (reference + offset) on the 24 measured rays. Both styles
    /// end with the projection readout (bbox, foveation rect, px/deg) for `stream` (nil: the selected points row).
    func outlineFields(frustum: BoundaryDotsFrustum, source: String, stream: ProjectionStream? = nil) -> KeyValuePairs<String, Any>? {
        let posix = Locale(identifier: "en_US_POSIX")
        let tangents = String(format: "%.4f,%.4f,%.4f,%.4f", locale: posix, frustum.left, frustum.right, frustum.bottom, frustum.top)
        guard let p = projection(eye, frustum: frustum, stream: stream) else { return nil }
        if shape == .rect {
            guard let limits = frustum.limits(eye: eye, insetDeg: inset) else { return nil }
            return ["eye": eye.rawValue, "shape": shape.rawValue, "inset_deg": inset, "nasal_deg": limits.nasal,
                    "temporal_deg": limits.temporal, "up_deg": limits.up, "down_deg": limits.down,
                    "tangent_source": source, "tangents": tangents,
                    "bbox_deg": p.bboxDeg, "bbox_tan": p.bboxTan, "fov_source": p.stream.source, "foveation": p.foveation,
                    "fov_rect_deg": p.fovRectDeg, "render_px": p.renderPx, "pxdeg_frustum": p.pxdegFrustum, "pxdeg_bbox": p.pxdegBbox]
        }
        guard let limits = BoundaryDotsLensReference.limits(eye, offsetDeg: offset) else { return nil }
        let rays = stride(from: 0.0, to: 360, by: 15).compactMap { ray -> String? in
            BoundaryDotsLensReference.eccDeg(eye, rayDeg: ray).map {
                String(format: "%g:%g", locale: posix, ray, max(0, $0 + offset))
            }
        }.joined(separator: ",")
        return ["eye": eye.rawValue, "shape": shape.rawValue, "offset_deg": offset, "nasal_deg": limits.nasal,
                "temporal_deg": limits.temporal, "up_deg": limits.up, "down_deg": limits.down,
                "tangent_source": source, "tangents": tangents, "reference": BoundaryDotsLensReference.tag, "rays": rays,
                "bbox_deg": p.bboxDeg, "bbox_tan": p.bboxTan, "fov_source": p.stream.source, "foveation": p.foveation,
                "fov_rect_deg": p.fovRectDeg, "render_px": p.renderPx, "pxdeg_frustum": p.pxdegFrustum, "pxdeg_bbox": p.pxdegBbox]
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

    /// Inset outline polygon area in tangent space over the frustum area.
    func areaFraction(insetDeg: Double) -> Double {
        areaFraction(of: outline(insetDeg: insetDeg))
    }

    /// Any closed outline's polygon area in tangent space over the frustum area.
    func areaFraction(of outline: [BoundaryDot]) -> Double {
        let points = outline.map { dot -> SIMD2<Double> in
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

enum BoundaryDotsOutlineShape: String {
    /// The measured seal-on visible field moved radially by an offset (default style).
    case lens
    /// The rendered frustum rectangle moved inwards by an inset (the rendered edge reference).
    case rect
}

enum BoundaryDotsOutline {
    static let defaultInsetDeg = 15.0
    static let maxInsetDeg = 30.0
    static let insetRange = 0.0...maxInsetDeg
    static let offsetRange = -10.0...20.0
    static let lineWidthDeg = 0.3

    static func clamp(_ deg: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, (deg * 2).rounded() / 2))
    }

    static func clampInset(_ deg: Double) -> Double { clamp(deg, to: insetRange) }
    static func clampOffset(_ deg: Double) -> Double { clamp(deg, to: offsetRange) }
}

/// Reference visible field per eye for the lens outline: per-ray boundary eccentricities
/// (deg from the head axis, rays CCW from right). Replace `left` (and set `right`) from a
/// later Boundary dots measurement; rays left out are interpolated.
enum BoundaryDotsLensReference {
    static let tag = "device-20261021"
    static let date = "2026-10-21"
    static let source = "Management/goals/rdr2-vr/evidence/device-20261021/diag-20261021T152509Z.log, seal on: "
        + "dots_summary eye=L (11 rays), the 13 other rays from dots_summary eye=Both"
    // The summaries apply clears: Both 240 is 30 (its later 32.5 mark was cleared), not the last confirm.
    // Caveat: the 13 rays from the eye=Both walk (0, 15, 30, 60, 90, 240, 255, 270, 285, 300, 315, 330, 345)
    // are binocular readings. On the nasal side (around 0) the right eye sees further, so the left eye's
    // own edge is probably narrower than this table says, and the R mirror carries the same error. A later
    // L-only walk replaces `left`/`right` plus `tag`/`date`/`source`, and with them the hand values in
    // BoundaryOutlineTests (the offset 0/+5 limits, the 0.256134 / 0.368449 areas and the `rays=` lines).
    static let left: [Double: Double] = [
        0: 37.5, 15: 35, 30: 35, 45: 35, 60: 30, 75: 30, 90: 30, 105: 32.5,
        120: 32.5, 135: 35, 150: 37.5, 165: 37.5, 180: 40, 195: 42.5, 210: 40, 225: 40,
        240: 30, 255: 32.5, 270: 32.5, 285: 30, 300: 32.5, 315: 32.5, 330: 32.5, 345: 37.5,
    ]
    /// No R measurement yet: R is the mirror of L about the vertical, R(phi) = L(180 - phi).
    static let right: [Double: Double]? = nil

    /// Linear in eccentricity between the nearest measured rays on either side (circular).
    static func interpolate(_ samples: [Double: Double], rayDeg: Double) -> Double {
        let ray = rayDeg.truncatingRemainder(dividingBy: 360) + (rayDeg < 0 ? 360 : 0)
        let rays = samples.keys.sorted()
        guard let first = rays.first, let last = rays.last else { return 0 }
        if let exact = samples[ray] { return exact }
        let below = rays.last(where: { $0 < ray }) ?? last
        let above = rays.first(where: { $0 > ray }) ?? first
        let span = (above - below + 360).truncatingRemainder(dividingBy: 360)
        guard span > 0 else { return samples[below] ?? 0 }
        let t = (ray - below + 360).truncatingRemainder(dividingBy: 360) / span
        return (samples[below] ?? 0) + t * ((samples[above] ?? 0) - (samples[below] ?? 0))
    }

    static func eccDeg(_ eye: BoundaryDotsEye, rayDeg: Double) -> Double? {
        switch eye {
        case .left: return interpolate(left, rayDeg: rayDeg)
        case .right:
            if let right { return interpolate(right, rayDeg: rayDeg) }
            return interpolate(left, rayDeg: 540 - rayDeg)
        case .both: return nil
        }
    }

    /// Closed polygon every 5 deg (all 24 measured rays included) at reference + offset, clamped at 0.
    static func outline(_ eye: BoundaryDotsEye, offsetDeg: Double) -> [BoundaryDot]? {
        guard eye != .both else { return nil }
        return stride(from: 0.0, to: 360, by: 5).map { ray in
            BoundaryDot(rayDeg: ray, eccDeg: max(0, (eccDeg(eye, rayDeg: ray) ?? 0) + offsetDeg))
        }
    }

    /// Side limits read from the polygon at the 0/90/180/270 rays; nasal is the right side for L, left for R.
    static func limits(_ eye: BoundaryDotsEye, offsetDeg: Double) -> BoundaryDotsLimits? {
        func at(_ ray: Double) -> Double { max(0, (eccDeg(eye, rayDeg: ray) ?? 0) + offsetDeg) }
        switch eye {
        case .left: return BoundaryDotsLimits(nasal: at(0), temporal: at(180), up: at(90), down: at(270))
        case .right: return BoundaryDotsLimits(nasal: at(180), temporal: at(0), up: at(90), down: at(270))
        case .both: return nil
        }
    }
}

/// Confirmed/unconfirmed state last painted per layout dot, so a refresh re-assigns
/// materials only for dots whose state changed (not on slider or cursor steps).
struct BoundaryDotsDotStates {
    private var shown: [Bool]?

    mutating func changes(_ session: BoundaryDotsSession) -> [Int] {
        let states = BoundaryDots.layout.map(session.isConfirmed)
        defer { shown = states }
        guard let shown else { return Array(states.indices) }
        return states.indices.filter { states[$0] != shown[$0] }
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

// Left-hand slider for the outline value while no cursor is selected: hand travel
// along the head frame's horizontal axis times `sign` (session `sliderSign`: right =
// outline outward), 1 cm per degree, snapped to 0.5 deg within `range` and relative
// to the value at the grab.
enum BoundaryDotsSliderMap {
    static let metresPerDeg = 0.01

    static func inset(from start: Double, displacement: SIMD3<Double>,
                      range: ClosedRange<Double> = BoundaryDotsOutline.insetRange, sign: Double = 1) -> Double {
        guard displacement.x.isFinite else { return start }
        return BoundaryDotsOutline.clamp(start + sign * displacement.x / metresPerDeg, to: range)
    }
}

/// Which slider updates write a `dots_outline` line: each snapped value change during a slide
/// (one line per 0.5 deg step, not per frame) and the settled value once more at release.
/// `reset()` at every new grab; `logs` is asked after the update is applied to the session.
struct BoundaryDotsSliderLog {
    private var logged: (eye: BoundaryDotsEye, shape: BoundaryDotsOutlineShape, value: Double)?

    mutating func reset() { logged = nil }

    mutating func logs(_ update: BoundaryDotsSliderUpdate?, session: BoundaryDotsSession) -> Bool {
        switch update {
        case .move?:
            if let logged, logged.eye == session.eye, logged.shape == session.shape,
               logged.value == session.sliderValue { return false }
            logged = (session.eye, session.shape, session.sliderValue)
            return true
        case .release?:
            logged = nil
            return true
        case nil:
            return false
        }
    }
}

enum BoundaryDotsSliderUpdate: Equatable {
    case move(Double)
    case release(from: Double, to: Double)
}

/// The inset counterpart of `BoundaryDotsDrag`: one left-hand slide at a time, keyed by
/// spatial event ID, grabbed only while `enabled` (no cursor, a single eye). An inset changed
/// elsewhere re-anchors it and a cancelled slide restores its starting inset. Losing `enabled`
/// mid-slide (a cursor selected) ends it at its value: the pinch stays consumed until release,
/// so it neither moves the inset again nor becomes a cursor drag.
struct BoundaryDotsSlider<ID: Hashable> {
    private struct Grab {
        let id: ID
        var origin: SIMD3<Double>
        var start: Double
        var current: Double
        var ended = false
    }
    private var grab: Grab?
    var active: Bool { grab != nil }

    mutating func update(id: ID, hand: BoundaryDotsHand?, phase: BoundaryDotsPinchPhase,
                         position: SIMD3<Double>, headRotation: simd_quatd,
                         inset: Double, enabled: Bool,
                         range: ClosedRange<Double> = BoundaryDotsOutline.insetRange,
                         sign: Double = 1) -> BoundaryDotsSliderUpdate? {
        guard var active = grab else {
            if phase == .active, hand == .left, enabled, all(position .== position) {
                grab = Grab(id: id, origin: position, start: inset, current: inset)
            }
            return nil
        }
        guard active.id == id else { return nil }
        guard !active.ended, enabled else {
            if phase == .active { active.ended = true; grab = active } else { grab = nil }
            return nil
        }
        guard phase != .cancelled else {
            grab = nil
            return active.current != active.start && inset == active.current ? .move(active.start) : nil
        }
        if inset != active.current {
            active = Grab(id: id, origin: position, start: inset, current: inset)
        } else {
            let displacement = headRotation.inverse.act(position - active.origin)
            active.current = BoundaryDotsSliderMap.inset(from: active.start, displacement: displacement, range: range, sign: sign)
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
