import Foundation
import simd

/// Debug launch argument `-ALVRDebugEyeTangents "L:l,r,d,u;R:l,r,d,u"` (|tan| per eye, screen sides): the client reports
/// these per-eye tangents (x fovRenderScale) to the server as its view FOV instead of the drawable's, so the simulator can
/// stand in for another headset's asymmetric frustum (e.g. the Vision Pro's). Reprojection keeps the drawable's own
/// projection. Absent or malformed: off, and the reported FOV is the drawable's as before. The values fill the gimmeTangents
/// slots (left, right, bottom, top), so the FOV sent is right only with the W32 up/down fix (ViewLayout.fovAngles: up = .w).
enum DebugEyeTangents {
    static let defaultsKey = "ALVRDebugEyeTangents"

    /// Read once per launch; debug and simulator builds only.
    static let current: (argument: String, tangents: [simd_float4])? = {
        #if DEBUG || targetEnvironment(simulator)
        let text = UserDefaults.standard.string(forKey: defaultsKey)
        if let text, let tangents = parse(text) { return (text, tangents) }
        #endif
        return nil
    }()

    /// [left eye, right eye] in gimmeTangents slot order (x left, y right, z bottom, w top), or nil unless both eyes carry
    /// four finite positive values.
    static func parse(_ text: String?) -> [simd_float4]? {
        guard let text else { return nil }
        var eyes: [String: simd_float4] = [:]
        for part in text.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, ["L", "R"].contains(pair[0]), eyes[pair[0]] == nil else { return nil }
            let v = pair[1].split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4, v.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            eyes[pair[0]] = simd_float4(v[0], v[1], v[2], v[3])
        }
        guard let l = eyes["L"], let r = eyes["R"] else { return nil }
        return [l, r]
    }

    /// capture.json `debug_eye_tangents`: requested (the argument) and reported (sent to the server) |tan| L,R,D,U per eye.
    /// reportedAngles: the AlvrFov sent per eye as (left, right, up, down) signed radians.
    static func captureRecord(argument: String, requested: [simd_float4], fovRenderScale: Float,
                              reportedAngles: [simd_float4]) -> [String: Any] {
        let eyes = ["L", "R"]
        var req: [String: [Double]] = [:], rep: [String: [Double]] = [:]
        for (i, eye) in eyes.enumerated() where i < requested.count && i < reportedAngles.count {
            let t = requested[i], a = reportedAngles[i]
            req[eye] = [t.x, t.y, t.z, t.w].map { Double($0) }
            rep[eye] = [a.x, a.y, a.w, a.z].map { Double(tan(abs($0))) }
        }
        return ["argument": argument, "fov_render_scale": Double(fovRenderScale), "requested": req, "reported": rep]
    }
}
