import Foundation
import simd

/// "Crop FOV to outline" (Diagnostics setting, on by default; the user can turn it off): the client reports, per eye, the model lens's inset
/// rectangle (BoundaryDotsLensModel.insetRect at the Boundary dots lens inset: each device frustum edge moved in by the
/// inset) widened by a margin and clamped to the device frustum, instead of the whole device frustum. The server renders
/// that box at the configured render size, so the centre density rises by the tangent-span ratio; the display draws the
/// frame on the sent box (Renderer uniforms.tangents) and the rest of the drawable stays black. docs/lumen/crop-fov.md.
/// Tangents are gimmeTangents magnitudes, slots (left, right, bottom, top).
enum CropFov {
    static let defaultMarginDeg = 2.0
    /// GlobalSettings.cropFovToOutline default: on, so the lens style streams the cropped box; off sends the device frustum.
    static let defaultEnabled = true
    /// No sent edge reaches 90 deg (tan blows up) or goes below the eye axis.
    static let maxEdgeDeg = 89.0

    /// One eye's sent tangents: the inset rectangle of `device`, each side widened by `marginDeg` (in degrees; negative
    /// or non-finite is 0), then no wider than `device` on any side, every side within 0...tan(maxEdgeDeg). Nil for Both.
    static func tangents(eye: BoundaryDotsEye, device: simd_float4, insetDeg: Double, marginDeg: Double) -> simd_float4? {
        let frustum = BoundaryDotsFrustum(left: Double(device.x), right: Double(device.y), bottom: Double(device.z), top: Double(device.w))
        guard let box = BoundaryDotsLensModel.insetRect(eye, frustum: frustum, insetDeg: insetDeg)?.box(eye) else { return nil }
        let margin = marginDeg.isFinite ? max(0, marginDeg) : 0
        func widened(_ t: Double, _ limit: Float) -> Float {
            // The angle is held below maxEdgeDeg before the tan, which turns negative past 90 deg; a negative device side sends 0.
            let angle = min(atan(t) * 180 / .pi + margin, maxEdgeDeg)
            return max(0, min(Float(tan(angle * .pi / 180)), limit))
        }
        return simd_float4(widened(box.left, device.x), widened(box.right, device.y),
                           widened(box.down, device.z), widened(box.up, device.w))
    }

    /// ALVR center_shift_x/y that puts the 1:1 band's centre on the eye axis (tan 0) of the sent boxes. The band spans
    /// eye UV [c0 (1 + s), 1 - c0 (1 - s)], c0 = (1 - c) / 2, so its centre is 0.5 + s c0 (Shaders.metal:152-157;
    /// FFR.swift:88-89 only rounds s to 2r px). Eye UV x runs from the temporal edge (R mirrored, Shaders.metal:136-140)
    /// and y from the top row, so the axis sits at temporal / (temporal + nasal) and up / (up + down), and
    /// s = (that fraction - 0.5) / c0. ALVR has one shift for both eyes: the mean of the two (equal for mirrored eyes).
    static func centerShift(left: simd_float4, right: simd_float4, centerSize: SIMD2<Double>) -> SIMD2<Double> {
        func shift(_ lo: Float, _ hi: Float, _ c: Double) -> Double {
            let c0 = (1 - c) / 2
            guard c0 > 0, lo + hi > 0 else { return 0 }
            return (Double(lo / (lo + hi)) - 0.5) / c0
        }
        let x = (shift(left.x, left.y, centerSize.x) + shift(right.y, right.x, centerSize.x)) / 2
        let y = (shift(left.w, left.z, centerSize.y) + shift(right.w, right.z, centerSize.y)) / 2
        return [x, y]
    }

    /// The per-eye tangents to report and their source: -ALVRDebugEyeTangents first, then the crop, then the device.
    static func choose(device: [simd_float4], debug: [simd_float4]?, crop: Bool, insetDeg: Double,
                       marginDeg: Double) -> (tangents: [simd_float4], source: String) {
        if let debug { return (debug, "debug") }
        guard crop else { return (device, "frustum") }
        let eyes: [BoundaryDotsEye] = [.left, .right]
        let cropped = device.indices.map { i in
            CropFov.tangents(eye: eyes[min(i, 1)], device: device[i],
                             insetDeg: insetDeg, marginDeg: marginDeg) ?? device[i]
        }
        return (cropped, "crop")
    }

    /// Model lens inset last set on the Boundary dots lens slider in this app session, one value for both eyes; 15 until then.
    private static let lock = NSLock()
    private static var stored = BoundaryDotsOutline.defaultInsetDeg

    static var inset: Double {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func recordInset(_ deg: Double) {
        guard deg.isFinite else { return }
        lock.lock()
        stored = deg
        lock.unlock()
    }

    static func resetInset() {
        lock.lock()
        stored = BoundaryDotsOutline.defaultInsetDeg
        lock.unlock()
    }
}
