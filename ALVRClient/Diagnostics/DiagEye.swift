import Foundation
import simd

// Persisted independently of Diagnostics. UI writes and render reads share this cache;
// UserDefaults is read only when the shared flag is first accessed.
final class EyeBadgeFlag {
    static let defaultsKey = "ALVREyeBadges"
    // `shared` (launch argument over the settings control) is declared in Entry/EntryControls.swift, the app target only.
    private let lock = NSLock()
    private var cachedEnabled: Bool

    init(defaultsValue: Bool?) {
        cachedEnabled = defaultsValue ?? false
    }

    var enabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedEnabled
    }

    func update(defaultsValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        cachedEnabled = defaultsValue
    }
}

// Shared eye identity for diagnostic overlays (decisions 65a/b), including the pending corner chart.
enum DiagEye: String {
    case left = "L", right = "R"
    // Diagnostics and streaming state do not control the user's badge opt-in.
    static func shouldDraw(badgesEnabled: Bool, isRealityKit: Bool) -> Bool {
        badgesEnabled && !isRealityKit
    }

    var glyph: String { rawValue }
    var colourName: String { self == .left ? "cyan" : "magenta" }
    var colour: SIMD4<Float> { self == .left ? SIMD4(0, 1, 1, 1) : SIMD4(1, 0, 1, 1) }
    // 3x5, row-major, low bit = upper left. Black glyph inside a solid SDR-coloured square.
    var glyphBits: UInt32 { self == .left ? 0b111_001_001_001_001 : 0b101_101_011_101_011 }
    static func assign(view: Int, x: Float) -> (eye: DiagEye, mismatch: Bool) {
        let indexed: DiagEye = view == 0 ? .left : .right
        let eye: DiagEye = x < 0 ? .left : x > 0 ? .right : indexed
        return (eye, eye != indexed)
    }
    struct Placement {
        let tanX, tanY, sizeDegrees: Double
        let rect: SIMD4<Double> // normalized top-left x/y, width/height in this view's viewport
        var areaFraction: Double { rect.z * rect.w }
        func fields(eye: DiagEye, view: Int, mode: String) -> KeyValuePairs<String, Any> {
            ["eye": eye.glyph, "view": view, "colour": eye.colourName, "tan_x": tanX, "tan_y": tanY,
             "size_deg": sizeDegrees, "mode": mode, "area_frac": String(format: "%.6f", areaFraction)]
        }
    }
    static func placement(tangents t: SIMD4<Float>) -> Placement {
        let x = Double(t.y - t.x) / 2, y = Double(t.z) * 0.25, halfAngle = 1.5 * Double.pi / 180
        let x0 = tan(atan(x) - halfAngle), x1 = tan(atan(x) + halfAngle)
        let y0 = tan(atan(y) - halfAngle), y1 = tan(atan(y) + halfAngle)
        let width = Double(t.x + t.y), height = Double(t.z + t.w)
        return Placement(tanX: x, tanY: y, sizeDegrees: 3,
                         rect: SIMD4((x0 + Double(t.x)) / width, (Double(t.z) - y1) / height,
                                     (x1 - x0) / width, (y1 - y0) / height))
    }
    struct LogState {
        private var mode = ""
        private var generation: UInt64?
        private var eyes: UInt8 = 0
        mutating func shouldLog(eye: DiagEye, mode: String, generation: UInt64?) -> Bool {
            if self.mode != mode || self.generation != generation { eyes = 0; self.mode = mode; self.generation = generation }
            let bit: UInt8 = eye == .left ? 1 : 2
            defer { eyes |= bit }
            return eyes & bit == 0
        }
    }
    private static let unsupportedLock = NSLock()
    private static var reportedUnsupported = false
    static func unsupported() {
        guard Diag.isOn else { return }
        unsupportedLock.lock(); defer { unsupportedLock.unlock() }
        guard !reportedUnsupported else { return }
        reportedUnsupported = true
        Diag.log("eye_badge", ["path": "realitykit", "unsupported": 1])
    }
}
