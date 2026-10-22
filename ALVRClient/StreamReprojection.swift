//
//  StreamReprojection.swift
//
// The stream quad's reprojection (Renderer.updateGameStateForVideoFrame): a frame rendered at framePose, viewed by the head
// at deviceAnchor through an eye at viewTransform. Rotation only: the stream is at infinity, so both poses drop their
// translation. Shared by the live stream and the golden frame (W35b), so a pinned frame moves exactly as a streamed one.
//

import simd

enum StreamReprojection {
    static func rotationOnly(_ m: simd_float4x4) -> simd_float4x4 {
        var out = m
        out.columns.3 = simd_float4(0.0, 0.0, 0.0, 1.0)
        return out
    }

    static func viewMatrixFrame(framePose: simd_float4x4, deviceAnchor: simd_float4x4, viewTransform: simd_float4x4) -> simd_float4x4 {
        (rotationOnly(framePose).inverse * rotationOnly(deviceAnchor) * viewTransform).inverse
    }

    // RealityKit implicitly applies the view transforms when we draw the quad entity.
    static func viewMatrixFrameRealityKit(framePose: simd_float4x4, deviceAnchor: simd_float4x4) -> simd_float4x4 {
        (rotationOnly(framePose).inverse * rotationOnly(deviceAnchor)).inverse
    }
}
