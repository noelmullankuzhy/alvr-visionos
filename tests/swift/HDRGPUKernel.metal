// macOS compute kernel for tests/swift/HDRGPUTests.swift (decision 63c (5)): runs the video colour conversion that
// Shaders.metal uses, from the shared ALVRClient/VideoColour.h, on the Mac GPU. Plane textures are read like the
// explicit-plane fragment shader samples them: Y from plane 0, CbCr from plane 1, as normalised UNORM values.
#include <metal_stdlib>
#include "../../ALVRClient/VideoColour.h"
using namespace metal;

// Layout matches HDRGPUTests.KernelParams (simd_float4x4, simd_float3x3, 3 x Float, 2 x UInt32).
struct VideoColourTestParams {
    float4x4 yuvTransform;
    float3x3 gamutToOutput;
    float pqScale;
    float encodingGamma;
    float headroom;
    uint hdrPQ;
    uint applyGamut;
};

kernel void videoColourTestKernel(texture2d<float, access::read> lumaPlane [[texture(0)]],
                                  texture2d<float, access::read> chromaPlane [[texture(1)]],
                                  device float4 *out [[buffer(0)]],
                                  constant VideoColourTestParams &p [[buffer(1)]],
                                  uint gid [[thread_position_in_grid]]) {
    float4 ycbcr = float4(lumaPlane.read(uint2(gid, 0)).r, chromaPlane.read(uint2(gid, 0)).rg, 1.0);
    float3 linearSource = VideoYCbCrToLinear(ycbcr, p.yuvTransform, p.hdrPQ != 0, p.pqScale, p.encodingGamma);
    out[gid] = float4(VideoLinearToOutput(linearSource, p.gamutToOutput, p.applyGamut != 0, p.hdrPQ != 0, p.headroom), 0.0);
}
