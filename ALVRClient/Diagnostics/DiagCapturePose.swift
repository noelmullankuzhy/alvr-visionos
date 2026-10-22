import Foundation
import simd

// Pure helpers (Foundation/simd only, unit tested on macOS: tests/swift/DiagCapturePoseTests.swift) for the
// extra fields DiagFrameCapture writes into capture.json.

enum DiagCaptureEncoding {
    // IEC 61966-2-1 sRGB transfer function, linear -> encoded. Input clamped to 0...1 (NaN -> 0): the PNG is 8-bit.
    static func srgbEncode(_ linear: Float) -> Float {
        guard !linear.isNaN else { return 0 }
        let c = min(1, max(0, linear))
        if c >= 1 { return 1 }   // exact: powf rounding must not land white on 0.99999994
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    static func srgbByte(_ linear: Float) -> UInt8 {
        UInt8((srgbEncode(linear) * 255).rounded())
    }
}

enum DiagCapturePose {
    // Convention (capture.json "pose"): right-handed, yaw about +Y, pitch about +X, roll about +Z, intrinsic Y-X-Z
    // (R = Ry(yaw) * Rx(pitch) * Rz(roll)), degrees. Positions are ignored.
    //   render  = the tracking pose the server rendered the captured frame for (QueuedFrame.viewParams, converted
    //             by WorldTracker.convertSteamVRViewPose)
    //   display = the pose used to present the drawable (the device anchor at the vsync time, with floor correction)
    //   delta_deg = display relative to render: the display camera orientation expressed in the render camera frame,
    //               R_rel = R_render^T * R_display (rotation parts only), decomposed intrinsic Y-X-Z. It is NOT the axis-by-axis
    //               difference of the world Euler angles (those differ once the render camera is pitched or rolled).
    // Both are in the same world frame (the renderer's reprojection uses them together). t is the layer clock in seconds.
    struct Angles: Equatable {
        var yawDeg: Double, pitchDeg: Double, rollDeg: Double
        var t: Double
    }

    private static func rotation(_ m: simd_float4x4) -> simd_double3x3 {
        simd_double3x3(simd_double3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
                       simd_double3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
                       simd_double3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
    }

    private static func decompose(_ m: simd_double3x3) -> (yawDeg: Double, pitchDeg: Double, rollDeg: Double) {
        let deg = 180 / Double.pi
        return (atan2(m.columns.2.x, m.columns.2.z) * deg, asin(min(1, max(-1, -m.columns.2.y))) * deg, atan2(m.columns.0.y, m.columns.1.y) * deg)
    }

    static func angles(matrix m: simd_float4x4, t: Double) -> Angles {
        let a = decompose(rotation(m))
        return Angles(yawDeg: a.yawDeg, pitchDeg: a.pitchDeg, rollDeg: a.rollDeg, t: t)
    }

    static func delta(render: simd_float4x4, display: simd_float4x4) -> (yawDeg: Double, pitchDeg: Double, rollDeg: Double) {
        decompose(rotation(render).transpose * rotation(display))
    }

    private static func json(_ a: Angles) -> [String: Double] {
        ["yaw_deg": a.yawDeg, "pitch_deg": a.pitchDeg, "roll_deg": a.rollDeg, "t": a.t]
    }

    // "encoding": the PNGs hold sRGB-encoded values (primaries are those of the drawable, untagged); "source_pixel_format":
    // the drawable's Metal pixel format name.
    static func annotateEncoding(_ capture: inout [String: Any], sourcePixelFormat: String) {
        capture["encoding"] = "srgb"
        capture["source_pixel_format"] = sourcePixelFormat
    }

    // Adds "encoding", "source_pixel_format" and "pose" to capture.json; existing keys are untouched.
    // simYawDitherRad: the FakeHeadPose yaw ((sequence mod 1024) x 1e-5 rad) carried by the render pose; nil off the simulator.
    static func annotate(_ capture: inout [String: Any], sourcePixelFormat: String, render: simd_float4x4, display: simd_float4x4,
                         renderT: Double, displayT: Double, simYawDitherRad: Double?) {
        let d = delta(render: render, display: display)
        annotateEncoding(&capture, sourcePixelFormat: sourcePixelFormat)
        capture["pose"] = ["render": json(angles(matrix: render, t: renderT)), "display": json(angles(matrix: display, t: displayT)),
                           "delta_deg": ["yaw": d.yawDeg, "pitch": d.pitchDeg, "roll": d.rollDeg],
                           "sim_yaw_dither_rad": simYawDitherRad as Any? ?? NSNull()] as [String: Any]
    }
}
