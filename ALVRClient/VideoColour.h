//
//  VideoColour.h
//
//  Video colour conversion shared by Shaders.metal and the macOS GPU golden test (tests/swift/HDRGPUKernel.metal,
//  GM decision 63c (5)). Metal only.
//
#ifndef VideoColour_h
#define VideoColour_h

#include <metal_stdlib>
using namespace metal;

// sRGB EOTF extended to negative and >1 inputs by odd symmetry (as extended sRGB does): f(-x) = -f(x).
// Out-of-range values come from limited-range codes outside 64..940 and 4:2:0 chroma at saturated edges; they stay
// unclipped, and pow only ever sees non-negative bases, so no NaN reaches the gamut matrix.
// Mirrored by ColourPipeline.srgbEOTF (tests/swift/ColourPipelineTests.swift).
inline float3 NonlinearToLinearRGB(float3 color) {
    const float DIV12 = 1. / 12.92;
    const float DIV1 = 1. / 1.055;
    const float THRESHOLD = 0.04045;
    const float3 GAMMA = float3(2.4);

    float3 magnitude = abs(color);
    float3 lowValues = magnitude * DIV12;
    float3 highValues = pow((magnitude + 0.055) * DIV1, GAMMA);
    return sign(color) * select(highValues, lowValues, magnitude < THRESHOLD);
}

// Inverse of the server's encoding gamma, odd-symmetric like the EOTF above (pow on |x| only).
// Mirrored by ColourPipeline.encodingGammaToLinear.
inline float3 EncodingNonlinearToLinearRGB(float3 color, float gamma) {
    return sign(color) * pow(abs(color), float3(gamma));
}

// SMPTE ST 2084 EOTF: non-linear signal -> luminance / 10000 nits. Mirrored by HDRPipeline.pqEOTF.
inline float3 PQToLinear(float3 e) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = 2523.0 / 4096.0 * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = 2413.0 / 4096.0 * 32.0;
    const float c3 = 2392.0 / 4096.0 * 32.0;
    float3 ep = pow(clamp(e, 0.0, 1.0), float3(1.0 / m2));
    return pow(max(ep - c1, 0.0) / (c2 - c3 * ep), float3(1.0 / m1));
}

// Soft roll-off on max(R, G, B): identity up to 0.75 x headroom, then approaches the headroom without reaching past it.
// Mirrored by HDRPipeline.rollOff.
inline float3 EDRRollOff(float3 rgb, float headroom) {
    float h = max(headroom, 1.0);
    float knee = 0.75 * h;
    float m = max(rgb.r, max(rgb.g, rgb.b));
    if (m <= knee) {
        return rgb;
    }
    float rolled = h - (h - knee) * exp(-(m - knee) / (h - knee));
    return rgb * (rolled / m);
}

// Explicit-plane sample float4(Y, Cb, Cr, 1) -> linear light in the stream's primaries. yuvTransform from
// ColourPipeline.yuvToRGBMatrix. PQ: R'G'B' -> ST 2084 -> EDR (pqScale = 10000 / reference white nits, so reference
// white is 1.0; no sRGB EOTF or encoding gamma). SDR: sRGB EOTF, then the server's encoding gamma.
inline float3 VideoYCbCrToLinear(float4 ycbcr, float4x4 yuvTransform, bool hdrPQ, float pqScale, float encodingGamma) {
    float3 rgb = (yuvTransform * ycbcr).rgb;
    if (hdrPQ) {
        return PQToLinear(rgb) * pqScale;
    }
    return EncodingNonlinearToLinearRGB(NonlinearToLinearRGB(rgb), encodingGamma);
}

// Linear source -> drawable values: the output-primaries matrix when applied, then the EDR roll-off for PQ.
inline float3 VideoLinearToOutput(float3 linearSource, float3x3 gamutToOutput, bool applyGamut, bool hdrPQ, float headroom) {
    float3 color = applyGamut ? gamutToOutput * linearSource : linearSource;
    if (hdrPQ) {
        color = EDRRollOff(color, headroom);
    }
    return color;
}

#endif /* VideoColour_h */
