// SOURCES: ALVRClient/ViewLayout.swift
// ViewLayout: compositor drawable views -> ALVR's two stream eyes (device: two views; visionOS simulator: one view).
import simd

@main
enum ViewLayoutTests {
    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = simd_float4(x, y, z, 1)
        return m
    }

    static func main() {
        // Mono detection.
        expect(ViewLayout.isMono(viewCount: 1), "one view is mono")
        expect(!ViewLayout.isMono(viewCount: 2), "two views are stereo")

        // Source view per stream eye: always two entries, never out of range.
        expectEqual(ViewLayout.sourceViewIndices(viewCount: 2), [0, 1], "stereo: eye i from view i")
        expectEqual(ViewLayout.sourceViewIndices(viewCount: 1), [0, 0], "mono: both eyes from view 0")
        expectEqual(ViewLayout.sourceViewIndices(viewCount: 3), [0, 1], "extra views ignored")

        // Stereo: eye transforms are the view transforms, unchanged.
        let l = translation(-0.031, 0.0, 0.0)
        let r = translation(0.032, 0.0, 0.0)
        expectEqual(ViewLayout.eyeTransforms(viewTransforms: [l, r], ipd: 0.063), [l, r], "stereo transforms unchanged")

        // Mono: both eyes built from the single view, offset by -/+ ipd/2 along the view's own x axis.
        let centre = translation(0.0, 0.1, 0.0)
        let eyes = ViewLayout.eyeTransforms(viewTransforms: [centre], ipd: 0.064)
        expectEqual(eyes.count, 2, "mono gives two eyes")
        expectEqual(eyes[0].columns.3, simd_float4(-0.032, 0.1, 0.0, 1.0), "mono left eye")
        expectEqual(eyes[1].columns.3, simd_float4(0.032, 0.1, 0.0, 1.0), "mono right eye")
        expect(simd_length(eyes[0].columns.3 - eyes[1].columns.3) - 0.064 < 1e-6, "mono eye separation is the ipd")

        // Mono offset follows the view's orientation (view yawed 90 degrees about y: its x axis is world -z).
        var yawed = matrix_identity_float4x4
        yawed.columns.0 = simd_float4(0, 0, -1, 0)
        yawed.columns.2 = simd_float4(1, 0, 0, 0)
        let yawedEyes = ViewLayout.eyeTransforms(viewTransforms: [yawed], ipd: 0.06)
        expectEqual(yawedEyes[0].columns.3, simd_float4(0, 0, 0.03, 1), "yawed left eye")
        expectEqual(yawedEyes[0].columns.0, yawed.columns.0, "orientation kept")

        // No views (never expected from the compositor): identity eyes rather than a crash.
        expectEqual(ViewLayout.eyeTransforms(viewTransforms: [], ipd: 0.063), [matrix_identity_float4x4, matrix_identity_float4x4], "empty -> identity")
        expectEqual(ViewLayout.sourceViewIndices(viewCount: 0), [0, 0], "empty -> view 0 (caller must not index)")

        finishTests("ViewLayout")
    }
}
