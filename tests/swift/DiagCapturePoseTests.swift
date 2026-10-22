// SOURCES: ALVRClient/Diagnostics/DiagCapturePose.swift
// capture.json additions for the streaming DiagFrameCapture: the sRGB encode applied to linear drawables, the
// render-vs-display head-pose delta (right-handed, yaw +Y, pitch +X, roll +Z, intrinsic Y-X-Z, degrees; delta = display relative to render, R_render^T R_display)
// and the schema of the new "encoding", "source_pixel_format" and "pose" fields.
import Foundation
import simd

@main enum DiagCapturePoseTests {
    static func near(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(a - b) <= eps }

    static func rotation(yaw: Float, pitch: Float, roll: Float) -> simd_float4x4 {
        let y = simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0))
        let x = simd_quatf(angle: pitch, axis: simd_float3(1, 0, 0))
        let z = simd_quatf(angle: roll, axis: simd_float3(0, 0, 1))
        return simd_float4x4(y * x * z)   // intrinsic Y-X-Z: yaw first, then pitch about the new X, then roll about the new Z
    }

    static func main() throws {
        // sRGB encode (IEC 61966-2-1) on known linear values.
        expect(near(Double(DiagCaptureEncoding.srgbEncode(0.0)), 0.0, 1e-7), "linear 0 -> 0")
        expect(near(Double(DiagCaptureEncoding.srgbEncode(0.0031308)), 12.92 * 0.0031308, 1e-6), "linear toe edge uses the 12.92 slope")
        expect(near(Double(DiagCaptureEncoding.srgbEncode(0.06)), 0.27170, 1e-4), "linear 0.06 -> 0.2717 (dim chart background)")
        expect(near(Double(DiagCaptureEncoding.srgbEncode(0.5)), 0.73536, 1e-4), "linear 0.5 -> 0.7354")
        expect(near(Double(DiagCaptureEncoding.srgbEncode(1.0)), 1.0, 1e-6), "linear 1 -> 1")
        expect(DiagCaptureEncoding.srgbEncode(-0.2) == 0 && DiagCaptureEncoding.srgbEncode(.nan) == 0, "negative and NaN clamp to 0")
        expect(DiagCaptureEncoding.srgbEncode(4.0) == 1, "extended range above 1 clamps to 1")
        expectEqual(DiagCaptureEncoding.srgbByte(0.06), 69, "0.06 -> byte 69")
        expectEqual(DiagCaptureEncoding.srgbByte(0.5), 188, "0.5 -> byte 188")
        expectEqual(DiagCaptureEncoding.srgbByte(1.0), 255, "1.0 -> byte 255")
        expectEqual(DiagCaptureEncoding.srgbByte(0.0), 0, "0.0 -> byte 0")

        // Pose convention: positive yaw about +Y, pitch about +X, roll about +Z.
        let deg = 180 / Double.pi
        let yaw = DiagCapturePose.angles(matrix: rotation(yaw: 0.2, pitch: 0, roll: 0), t: 1)
        expect(near(yaw.yawDeg, 0.2 * deg) && near(yaw.pitchDeg, 0) && near(yaw.rollDeg, 0), "yaw about +Y reads as +yaw")
        let pitch = DiagCapturePose.angles(matrix: rotation(yaw: 0, pitch: 0.2, roll: 0), t: 1)
        expect(near(pitch.pitchDeg, 0.2 * deg) && near(pitch.yawDeg, 0) && near(pitch.rollDeg, 0), "pitch about +X reads as +pitch")
        let roll = DiagCapturePose.angles(matrix: rotation(yaw: 0, pitch: 0, roll: 0.2), t: 1)
        expect(near(roll.rollDeg, 0.2 * deg) && near(roll.yawDeg, 0) && near(roll.pitchDeg, 0), "roll about +Z reads as +roll")
        let combined = DiagCapturePose.angles(matrix: rotation(yaw: 0.5, pitch: -0.3, roll: 0.1), t: 1)
        expect(near(combined.yawDeg, 0.5 * deg, 1e-3) && near(combined.pitchDeg, -0.3 * deg, 1e-3)
               && near(combined.rollDeg, 0.1 * deg, 1e-3), "combined Y-X-Z angles round trip")
        var translated = rotation(yaw: 0.2, pitch: 0, roll: 0); translated.columns.3 = simd_float4(1, 2, 3, 1)
        expect(near(DiagCapturePose.angles(matrix: translated, t: 1).yawDeg, 0.2 * deg), "translation does not change the angles")

        // Delta = display orientation in the render camera frame: R_rel = R_render^T * R_display, intrinsic Y-X-Z.
        let rad = Float.pi / 180
        let render = rotation(yaw: 0, pitch: 0, roll: 0)
        let display = rotation(yaw: 0.4 * rad, pitch: 0, roll: 0)
        let delta = DiagCapturePose.delta(render: render, display: display)
        expect(near(delta.yawDeg, 0.4) && near(delta.pitchDeg, 0) && near(delta.rollDeg, 0), "display yaw +0.4 vs render 0 -> delta yaw +0.4")
        let same = DiagCapturePose.delta(render: rotation(yaw: 0.3, pitch: 0.2, roll: -0.1), display: rotation(yaw: 0.3, pitch: 0.2, roll: -0.1))
        expect(near(same.yawDeg, 0) && near(same.pitchDeg, 0) && near(same.rollDeg, 0), "equal poses -> zero delta")
        // Pitched render camera, display yawed by 1 deg about the world Y: in the render camera frame that rotation axis is
        // (0, cos30, -sin30), so yaw 0.866, roll -0.5 (not the world-frame Euler difference, which would say yaw 1, roll 0).
        let pitched = DiagCapturePose.delta(render: rotation(yaw: 0, pitch: 30 * rad, roll: 0), display: rotation(yaw: 1 * rad, pitch: 30 * rad, roll: 0))
        expect(near(pitched.yawDeg, 0.866, 0.002), "pitched render: delta yaw 0.866, got \(pitched.yawDeg)")
        expect(near(pitched.pitchDeg, 0.0, 0.01), "pitched render: delta pitch ~0, got \(pitched.pitchDeg)")
        expect(near(pitched.rollDeg, -0.5, 0.002), "pitched render: delta roll -0.5, got \(pitched.rollDeg)")
        var moved = display; moved.columns.3 = simd_float4(5, 6, 7, 1)
        expect(near(DiagCapturePose.delta(render: render, display: moved).yawDeg, 0.4), "translation ignored in the delta")

        // capture.json schema round trip.
        var json: [String: Any] = ["trigger": ["reason": "request_file"]]
        DiagCapturePose.annotate(&json, sourcePixelFormat: "rgba16Float", render: render, display: display, renderT: 10, displayT: 10.02, simYawDitherRad: 3e-5)
        let object = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) as! [String: Any]
        expectEqual(object["encoding"] as? String, "srgb", "encoding field")
        expectEqual(object["source_pixel_format"] as? String, "rgba16Float", "source_pixel_format field")
        expectEqual((object["trigger"] as? [String: Any])?["reason"] as? String, "request_file", "existing fields kept")
        let pose = object["pose"] as! [String: Any]
        for key in ["render", "display"] {
            let p = pose[key] as! [String: Double]
            expectEqual(Set(p.keys), Set(["yaw_deg", "pitch_deg", "roll_deg", "t"]), "\(key) keys")
        }
        expect(near((pose["display"] as! [String: Double])["yaw_deg"]!, 0.4), "display yaw round trips")
        expect(near((pose["render"] as! [String: Double])["t"]!, 10), "render t round trips")
        let d = pose["delta_deg"] as! [String: Double]
        expectEqual(Set(d.keys), Set(["yaw", "pitch", "roll"]), "delta_deg keys")
        expect(near(d["yaw"]!, 0.4), "delta yaw in the file")
        expect(near(pose["sim_yaw_dither_rad"] as! Double, 3e-5, 1e-9), "sim_yaw_dither_rad number")
        var device: [String: Any] = [:]
        DiagCapturePose.annotate(&device, sourcePixelFormat: "bgra8Unorm_srgb", render: render, display: display, renderT: 10, displayT: 10.02, simYawDitherRad: nil)
        let devicePose = (try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: device)) as! [String: Any])["pose"] as! [String: Any]
        expect(devicePose["sim_yaw_dither_rad"] is NSNull, "sim_yaw_dither_rad is null off the simulator")
        finishTests("DiagCapturePose")
    }
}
