//
//  HDRPipeline.swift
//
//  HDR10 (PQ, BT.2020) display maths, GM decision 63 h2 (pure Foundation/simd, tests/swift/HDRPipelineTests.swift).
//
//  PQ shader path (Shaders.metal videoFrameFragmentShader_YpCbCrBiPlanar with HDR_PQ): explicit 10-bit planes ->
//  yuvToRGB (BT.2020 NCL, limited) -> R'G'B' -> ST 2084 EOTF -> absolute nits -> / reference white (SDR white = 1.0,
//  linear BT.2020) -> sourceToOutput (output primaries) -> rollOff above the EDR headroom -> rgba16Float drawable.
//
//  EDR headroom: visionOS has no public query. UIScreen.currentEDRHeadroom is API_UNAVAILABLE(visionos), and
//  CompositorServices (LayerRenderer) and RealityKit expose no headroom (checked against the visionOS 27 SDK). The
//  renderer therefore uses assumedHeadroom, overridable with UserDefaults ALVRHDRHeadroom. The device has to measure it.
//

import Foundation
import simd

enum HDRPipeline {
    // hdr.reference_white_nits default shared with the server (decision 63; ITU-R BT.2408): PQ 203 nits = EDR 1.0.
    static let referenceWhiteNits: Double = 203

    // Assumed display headroom (peak / SDR white) until the device measures it; ALVRHDRHeadroom overrides it.
    static let assumedHeadroom: Float = 4
    static let headroomDefaultsKey = "ALVRHDRHeadroom"

    static func headroom(defaultsValue: Double) -> Float {
        defaultsValue >= 1 ? Float(defaultsValue) : assumedHeadroom
    }

    // SMPTE ST 2084 constants.
    private static let m1 = 2610.0 / 16384
    private static let m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096
    private static let c2 = 2413.0 / 4096 * 32
    private static let c3 = 2392.0 / 4096 * 32

    // Non-linear PQ signal [0, 1] -> absolute luminance in nits (cd/m^2), clamped to the signal range.
    static func pqEOTF(_ e: Double) -> Double {
        let ep = pow(min(max(e, 0), 1), 1 / m2)
        return 10000 * pow(max(ep - c1, 0) / (c2 - c3 * ep), 1 / m1)
    }

    static func pqInverseEOTF(_ nits: Double) -> Double {
        let y = pow(min(max(nits, 0), 10000) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    // Soft roll-off of an EDR value: identity up to the knee (0.75 x headroom), then an exponential shoulder with slope
    // 1 at the knee that approaches the headroom and never exceeds it. Headroom below 1 is treated as 1.
    static func rollOff(_ x: Float, headroom: Float) -> Float {
        let h = max(headroom, 1)
        let knee = 0.75 * h
        if x <= knee { return x }
        return h - (h - knee) * exp(-(x - knee) / (h - knee))
    }

    // Colour roll-off on max(R, G, B), so highlights keep their hue. Mirrored by Shaders.metal EDRRollOff.
    static func rollOff(_ rgb: simd_float3, headroom: Float) -> simd_float3 {
        let m = max(rgb.x, max(rgb.y, rgb.z))
        if m <= 0.75 * max(headroom, 1) { return rgb }
        return rgb * (rollOff(m, headroom: headroom) / m)
    }

    // PQ needs the explicit 10-bit plane path (the private *_sRGB YCbCr samplers apply the sRGB EOTF themselves).
    // transfer is the CMFormatDescription TransferFunction extension value.
    static func requiresExplicitPlanes(transfer: String?) -> Bool {
        transfer == "SMPTE_ST_2084_PQ"
    }

    // Swift mirror of the video fragment shader for the Metal renderer (no chroma key): sample = float4(Y, Cb, Cr, 1).
    static func shade(sample: simd_float4, selection: ColourSelection, encodingGamma: Float, headroom: Float) -> simd_float3 {
        let rgb = selection.yuvToRGB * sample
        if selection.isPQ {
            let scale = Float(10000 / referenceWhiteNits)
            func edr(_ e: Float) -> Float { Float(pqEOTF(Double(e)) / 10000) * scale }
            return rollOff(selection.sourceToOutput * simd_float3(edr(rgb.x), edr(rgb.y), edr(rgb.z)), headroom: headroom)
        }
        let lin = simd_float3(ColourPipeline.srgbEOTF(rgb.x), ColourPipeline.srgbEOTF(rgb.y), ColourPipeline.srgbEOTF(rgb.z))
        let src = simd_float3(ColourPipeline.encodingGammaToLinear(lin.x, gamma: encodingGamma),
                              ColourPipeline.encodingGammaToLinear(lin.y, gamma: encodingGamma),
                              ColourPipeline.encodingGammaToLinear(lin.z, gamma: encodingGamma))
        return selection.sourceToOutput * src
    }

    // Y'CbCr codes at the selection's plane depth -> absolute nits per channel (linear BT.2020, before the output
    // matrix and roll-off), as the oracle compares them.
    static func decodeNits(codes: simd_double3, selection: ColourSelection) -> simd_double3 {
        let bits = selection.planeBitDepth
        let sample = simd_float4(ColourPipeline.sampleValue(code: codes.x, bitDepth: bits),
                                 ColourPipeline.sampleValue(code: codes.y, bitDepth: bits),
                                 ColourPipeline.sampleValue(code: codes.z, bitDepth: bits), 1)
        let rgb = selection.yuvToRGB * sample
        return simd_double3(pqEOTF(Double(rgb.x)), pqEOTF(Double(rgb.y)), pqEOTF(Double(rgb.z)))
    }

    // Oracle log (decision 63): env ALVR_HDR_PROBE=1|true|yes|on, or the UserDefaults bool of the same name
    // (also settable as the launch argument `-ALVR_HDR_PROBE YES`).
    static let probeKey = "ALVR_HDR_PROBE"

    static func probeEnabled(environment: [String: String], defaultsValue: Bool?) -> Bool {
        if let value = environment[probeKey] {
            return ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        return defaultsValue ?? false
    }

    static func probeLine(tMs: Int, eye: String, code: simd_double3, nits: simd_double3) -> String {
        "HDRPROBE t_ms=\(tMs) eye=\(eye) code=\(Int(code.x.rounded())),\(Int(code.y.rounded())),\(Int(code.z.rounded()))"
            + String(format: " nits=%.1f,%.1f,%.1f", nits.x, nits.y, nits.z)
    }
}

// Probe cadence: at most one sample per 250 ms, measured from the last sample taken.
struct HDRProbeClock {
    static let intervalMs = 250
    private var lastMs: Int?

    mutating func shouldSample(nowMs: Int) -> Bool {
        if let last = lastMs, nowMs - last < HDRProbeClock.intervalMs { return false }
        lastMs = nowMs
        return true
    }
}
