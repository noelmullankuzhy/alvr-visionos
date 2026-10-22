//
//  ViewLayout.swift
//
// Maps the compositor's drawable views onto ALVR's two stream eyes.
// On device the compositor gives two views, one per eye. The visionOS simulator gives ONE view
// (a single 3840x2160 drawable view): both server eyes are then built from that view, offset by
// -/+ ipd/2 along its x axis, and the left eye of the side-by-side stream is drawn into it
// (amplification count 1, amp_id 0 -> left half in videoFrameVertexShader).
//
// Pure logic (simd only) so it is unit tested on macOS: tests/swift/ViewLayoutTests.swift.
//
import simd

enum ViewLayout {
    static func isMono(viewCount: Int) -> Bool {
        return viewCount < 2
    }

    // Drawable view index each stream eye (left, right) is built from. Always two entries.
    static func sourceViewIndices(viewCount: Int) -> [Int] {
        return viewCount >= 2 ? [0, 1] : [0, 0]
    }

    // Head-local eye transforms (left, right) to report to the server.
    // Two or more views: the first two view transforms, unchanged.
    // One view: that view moved -/+ ipd/2 along its own x axis.
    static func eyeTransforms(viewTransforms: [simd_float4x4], ipd: Float) -> [simd_float4x4] {
        if viewTransforms.count >= 2 {
            return [viewTransforms[0], viewTransforms[1]]
        }
        guard let view = viewTransforms.first else {
            return [matrix_identity_float4x4, matrix_identity_float4x4]
        }
        return [view * offsetX(-ipd * 0.5), view * offsetX(ipd * 0.5)]
    }

    // ALVR Fov angles (alvr_common::Fov: radians, left and down negative) from gimmeTangents magnitudes, which are
    // ordered (left, right, bottom, top). docs/lumen/fov-updown.md.
    static func fovAngles(tangents t: simd_float4, scale: Float) -> (left: Float, right: Float, up: Float, down: Float) {
        let a = atan(t * scale)
        return (left: -a.x, right: a.y, up: a.w, down: -a.z)
    }

    // DIAG fov_sent fields for one eye's Fov as sent to the server: degrees, ALVR signs.
    static func fovSentFields(eye: String, left: Float, right: Float, up: Float, down: Float) -> KeyValuePairs<String, Any> {
        func deg(_ rad: Float) -> String { String(format: "%.2f", Double(rad) * 180 / Double.pi) }
        return ["eye": eye, "up": deg(up), "down": deg(down), "left": deg(left), "right": deg(right), "units": "deg"]
    }

    private static func offsetX(_ x: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = simd_float4(x, 0, 0, 1)
        return m
    }
}
