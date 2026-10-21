// SOURCES: ALVRClient/ColourPipeline.swift
// ColourPipeline: YCbCr->RGB matrices (H.273 / BT.601, BT.709, BT.2020, full and limited range, 8- and 10-bit code
// ranges), source primaries -> output primaries (sRGB/BT.709 by default, Display P3 opt-in) derived from
// chromaticities, the colour selection parsed from the format description (never inferring BT.2020 from bit depth),
// and the full per-pixel path against the PC source pixels measured on the RDR2 title screen.
import Foundation
import simd

func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }
func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

func expectNear(_ a: Float, _ b: Float, _ tol: Float, _ message: String, file: StaticString = #file, line: UInt = #line) {
    expect(near(a, b, tol), "\(message): expected \(b), got \(a)", file: file, line: line)
}

func expectNear3(_ a: simd_float3, _ b: simd_float3, _ tol: Float, _ message: String, file: StaticString = #file, line: UInt = #line) {
    expect(near(a.x, b.x, tol) && near(a.y, b.y, tol) && near(a.z, b.z, tol), "\(message): expected \(b), got \(a)", file: file, line: line)
}

// Independent reference: ITU-R BT.601/709/2020 luma coefficients.
let referenceKrKb: [(YCbCrMatrix, Double, Double)] = [
    (.bt601, 0.299, 0.114),
    (.bt709, 0.2126, 0.0722),
    (.bt2020, 0.2627, 0.0593),
]

// Independent reference encoder (H.273 eqs. for E'Y/E'PB/E'PR and the full/limited quantisation, unrounded codes).
func referenceEncode(_ rgb: simd_double3, kr: Double, kb: Double, fullRange: Bool, bitDepth: Int) -> simd_double3 {
    let kg = 1 - kr - kb
    let y = kr * rgb.x + kg * rgb.y + kb * rgb.z
    let pb = (rgb.z - y) / (2 * (1 - kb))
    let pr = (rgb.x - y) / (2 * (1 - kr))
    let n = Double(bitDepth)
    if fullRange {
        let m = pow(2, n) - 1
        return simd_double3(m * y, m * pb + pow(2, n - 1), m * pr + pow(2, n - 1))
    }
    let s = pow(2, n - 8)
    return simd_double3(s * (219 * y + 16), s * (224 * pb + 128), s * (224 * pr + 128))
}

// What the explicit planar shader does: transform * float4(y, cb, cr, 1) on normalized texture samples.
func decode(_ codes: simd_double3, _ selection: ColourSelection) -> simd_float3 {
    let bits = selection.planeBitDepth
    let sample = simd_float4(ColourPipeline.sampleValue(code: codes.x, bitDepth: bits),
                             ColourPipeline.sampleValue(code: codes.y, bitDepth: bits),
                             ColourPipeline.sampleValue(code: codes.z, bitDepth: bits), 1)
    let out = selection.yuvToRGB * sample
    return simd_float3(out.x, out.y, out.z)
}

// Independent reference sRGB OETF (IEC 61966-2-1), odd-symmetric like extended sRGB.
func referenceSRGBEncode(_ linear: Double) -> Double {
    let m = abs(linear)
    let v = m <= 0.0031308 ? 12.92 * m : 1.055 * pow(m, 1 / 2.4) - 0.055
    return linear < 0 ? -v : v
}

// The full explicit-path pixel: an 8-bit sRGB source pixel encoded as BT.709 full-range 10-bit YCbCr (rounded codes),
// then what the shader does (yuvToRGB -> sRGB EOTF -> encoding gamma -> gamut step), then the compositor's reading of
// the linear float drawable as extended linear sRGB, re-encoded to 8-bit sRGB (what a screenshot shows).
func referencePixel(_ srgb8: simd_int3, _ selection: ColourSelection, gamma: Float = 1) -> simd_int3 {
    let e = simd_double3(Double(srgb8.x), Double(srgb8.y), Double(srgb8.z)) / 255
    let codes = referenceEncode(e, kr: 0.2126, kb: 0.0722, fullRange: true, bitDepth: 10).rounded(.toNearestOrEven)
    let rgb = decode(codes, selection)
    func toLinear(_ x: Float) -> Float { ColourPipeline.encodingGammaToLinear(ColourPipeline.srgbEOTF(x), gamma: gamma) }
    let linear = selection.sourceToOutput * simd_float3(toLinear(rgb.x), toLinear(rgb.y), toLinear(rgb.z))
    func code(_ x: Float) -> Int32 { Int32((min(max(referenceSRGBEncode(Double(x)), 0), 1) * 255).rounded()) }
    return simd_int3(code(linear.x), code(linear.y), code(linear.z))
}

func expectWithinCodes(_ a: simd_int3, _ b: simd_int3, _ tol: Int32, _ message: String, file: StaticString = #file, line: UInt = #line) {
    let d = abs(a &- b)
    expect(d.x <= tol && d.y <= tol && d.z <= tol, "\(message): expected \(b), got \(a)", file: file, line: line)
}

func selection(_ matrix: YCbCrMatrix, fullRange: Bool, bits: Int) -> ColourSelection {
    let names: [YCbCrMatrix: String] = [.bt601: "ITU_R_601_4", .bt709: "ITU_R_709_2", .bt2020: "ITU_R_2020"]
    return ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: names[matrix], fullRange: fullRange, bitDepth: bits)
}

@main
enum ColourPipelineTests {
    static func main() {
        testSampleContainers()
        testRoundTrips()
        testFullRangeWhiteBlack()
        testLimitedRangeCodes()
        testPublishedLimitedMatrix()
        testPrimariesToDisplayP3()
        testPrimariesToSRGB()
        testOutputPolicy()
        testMeasuredTitleScreenPixels()
        testSelection()
        testLogLineAndFourCC()
        testTransferFunctions()
        testPlaneBitDepth()
        finishTests("ColourPipelineTests")
    }

    // Swift mirror of Shaders.metal NonlinearToLinearRGB / EncodingNonlinearToLinearRGB: finite everywhere,
    // odd-symmetric, continuous at 0 and at the 0.04045 knee, unclipped above 1.
    static func testTransferFunctions() {
        func eotf(_ x: Float) -> Float { ColourPipeline.srgbEOTF(x) }
        for x: Float in [-0.07, 0, 0.04045, 1, 1.2, -1.2, -0.04045] {
            expect(eotf(x).isFinite, "sRGB EOTF finite at \(x), got \(eotf(x))")
            expect(ColourPipeline.encodingGammaToLinear(x, gamma: 1.5).isFinite, "gamma 1.5 finite at \(x)")
            expect(ColourPipeline.encodingGammaToLinear(eotf(x), gamma: 1.5).isFinite, "EOTF+gamma finite at \(x)")
        }
        expectNear(eotf(0), 0, 0, "EOTF(0)")
        expectNear(eotf(1), 1, 1e-6, "EOTF(1)")
        expectNear(eotf(1.2), Float(pow((1.2 + 0.055) / 1.055, 2.4)), 1e-6, "EOTF(1.2) is extended, not clipped")
        expectNear(eotf(0.04045), Float(pow((0.04045 + 0.055) / 1.055, 2.4)), 1e-7, "EOTF at knee uses the power segment")
        expectNear(eotf(-0.07), -eotf(0.07), 0, "EOTF odd at -0.07")
        expect(eotf(-0.07) < 0, "EOTF(-0.07) stays negative")
        let e: Float = 1e-6
        expectNear(eotf(0.04045 - e), eotf(0.04045 + e), 1e-6, "EOTF continuous at knee")
        expectNear(eotf(-0.04045 - e), eotf(-0.04045 + e), 1e-6, "EOTF continuous at negative knee")
        expectNear(eotf(-e), eotf(e), 1e-6, "EOTF continuous at 0")
        expectNear(ColourPipeline.encodingGammaToLinear(-0.07, gamma: 1.5), -Float(pow(0.07, 1.5)), 1e-7, "gamma odd at -0.07")
        expectNear(ColourPipeline.encodingGammaToLinear(0, gamma: 1.5), 0, 0, "gamma(0)")
        expectNear(ColourPipeline.encodingGammaToLinear(1, gamma: 1.5), 1, 1e-7, "gamma(1)")

        // A 4:2:0 blue/red edge sample with G ~ -0.07 stays finite in every channel after the gamut matrix.
        let edge = simd_float3(0.6, -0.07, 0.7)
        let linear = simd_float3(ColourPipeline.encodingGammaToLinear(eotf(edge.x), gamma: 1.5),
                                 ColourPipeline.encodingGammaToLinear(eotf(edge.y), gamma: 1.5),
                                 ColourPipeline.encodingGammaToLinear(eotf(edge.z), gamma: 1.5))
        for output in [ColourOutput.srgb, .p3] {
            let sel = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: false, bitDepth: 10, output: output)
            let out = sel.sourceToOutput * linear
            expect(out.x.isFinite && out.y.isFinite && out.z.isFinite, "edge sample finite, out=\(output), got \(out)")
        }
    }

    // The YCbCr matrix follows the bound plane format, not the stream's BitsPerComponent.
    static func testPlaneBitDepth() {
        let s = ColourPipeline.select(primaries: nil, transfer: nil, matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10, planeBitDepth: 8)
        expectEqual(s.bitDepth, 10, "stream bit depth kept for the log")
        expectEqual(s.planeBitDepth, 8, "plane bit depth")
        expectNear3(decode(simd_double3(255, 128, 128), s), simd_float3(1, 1, 1), 1e-5, "8-bit planes of a 10-bit stream: white")
        let ref8 = ColourPipeline.select(primaries: nil, transfer: nil, matrix: "ITU_R_709_2", fullRange: true, bitDepth: 8)
        expect(s.yuvToRGB == ref8.yuvToRGB, "matrix equals the 8-bit one")
        let s10 = ColourPipeline.select(primaries: nil, transfer: nil, matrix: "ITU_R_709_2", fullRange: true, bitDepth: 8, planeBitDepth: 10)
        expectNear3(decode(simd_double3(1023, 512, 512), s10), simd_float3(1, 1, 1), 1e-5, "10-bit planes of an 8-bit-signalled stream: white")
        expectEqual(ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: true, bitDepth: 10).planeBitDepth, 10, "no plane info: stream depth")
    }

    // 8-bit planes are r8Unorm (code/255); 10-bit x420 planes hold the code in the 10 MSBs of 16 bits (r16Unorm).
    static func testSampleContainers() {
        expectNear(ColourPipeline.sampleValue(code: 255, bitDepth: 8), 1, 1e-7, "8-bit 255 samples as 1")
        expectNear(ColourPipeline.sampleValue(code: 1023, bitDepth: 10), Float(1023.0 * 64.0 / 65535.0), 1e-7, "10-bit 1023 sample is MSB-aligned in 16 bits")
        expectNear(ColourPipeline.sampleValue(code: 512, bitDepth: 10), Float(512.0 * 64.0 / 65535.0), 1e-7, "10-bit 512 sample")
    }

    // Encode R, G, B, white, grey and a mixed colour with the reference, decode with the helper, for every
    // matrix x range x bit depth.
    static func testRoundTrips() {
        let colours: [simd_double3] = [
            simd_double3(1, 0, 0), simd_double3(0, 1, 0), simd_double3(0, 0, 1),
            simd_double3(1, 1, 1), simd_double3(0, 0, 0), simd_double3(0.5, 0.5, 0.5),
            simd_double3(0.8, 0.3, 0.1), simd_double3(0.05, 0.6, 0.9),
        ]
        for (matrix, kr, kb) in referenceKrKb {
            for fullRange in [true, false] {
                for bits in [8, 10] {
                    let sel = selection(matrix, fullRange: fullRange, bits: bits)
                    for c in colours {
                        let codes = referenceEncode(c, kr: kr, kb: kb, fullRange: fullRange, bitDepth: bits)
                        let rgb = decode(codes, sel)
                        expectNear3(rgb, simd_float3(Float(c.x), Float(c.y), Float(c.z)), 2e-5,
                                    "round trip \(matrix) full=\(fullRange) bits=\(bits) rgb=\(c)")
                    }
                }
            }
        }
    }

    static func testFullRangeWhiteBlack() {
        let s8 = selection(.bt709, fullRange: true, bits: 8)
        expectNear3(decode(simd_double3(255, 128, 128), s8), simd_float3(1, 1, 1), 1e-5, "BT.709 full 8-bit white")
        expectNear3(decode(simd_double3(0, 128, 128), s8), simd_float3(0, 0, 0), 1e-5, "BT.709 full 8-bit black")
        let s10 = selection(.bt709, fullRange: true, bits: 10)
        expectNear3(decode(simd_double3(1023, 512, 512), s10), simd_float3(1, 1, 1), 1e-5, "BT.709 full 10-bit white")
        expectNear3(decode(simd_double3(0, 512, 512), s10), simd_float3(0, 0, 0), 1e-5, "BT.709 full 10-bit black")
    }

    static func testLimitedRangeCodes() {
        for matrix in [YCbCrMatrix.bt709, .bt2020] {
            let s10 = selection(matrix, fullRange: false, bits: 10)
            expectNear3(decode(simd_double3(64, 512, 512), s10), simd_float3(0, 0, 0), 1e-5, "\(matrix) 10-bit limited code 64 -> 0")
            expectNear3(decode(simd_double3(940, 512, 512), s10), simd_float3(1, 1, 1), 1e-5, "\(matrix) 10-bit limited code 940 -> 1")
            // Below-black and above-white codes stay outside [0,1] (no clamp before the transfer).
            expect(decode(simd_double3(4, 512, 512), s10).x < 0, "\(matrix) 10-bit code 4 is below black")
            let s8 = selection(matrix, fullRange: false, bits: 8)
            expectNear3(decode(simd_double3(16, 128, 128), s8), simd_float3(0, 0, 0), 1e-5, "\(matrix) 8-bit limited code 16 -> 0")
            expectNear3(decode(simd_double3(235, 128, 128), s8), simd_float3(1, 1, 1), 1e-5, "\(matrix) 8-bit limited code 235 -> 1")
        }
        // Chroma extremes: BT.709 10-bit Cb = 960 is E'PB = +0.5, so B = Y + 2(1-Kb)*0.5 = Y + 0.9278.
        let s = selection(.bt709, fullRange: false, bits: 10)
        expectNear(decode(simd_double3(64, 960, 512), s).z, Float(0.9278), 1e-5, "BT.709 10-bit limited Cb 960")
    }

    // Classic BT.709 limited-range 8-bit matrix on code/255 samples (e.g. Poynton; widely published).
    static func testPublishedLimitedMatrix() {
        let m = selection(.bt709, fullRange: false, bits: 8).yuvToRGB
        expectNear(m.columns.0.x, 1.164384, 1e-5, "Y gain 255/219")
        expectNear(m.columns.2.x, 1.792741, 1e-5, "Cr->R")
        expectNear(m.columns.1.y, -0.213249, 1e-5, "Cb->G")
        expectNear(m.columns.2.y, -0.532909, 1e-5, "Cr->G")
        expectNear(m.columns.1.z, 2.112402, 1e-5, "Cb->B")
        expectNear(m.columns.3.w, 1, 0, "offset column w")
    }

    static func testPrimariesToDisplayP3() {
        // Published BT.709 -> Display P3 (D65, linear): e.g. WebKit/Skia/colour-science.
        let bt709: [[Double]] = [
            [0.822462, 0.177538, 0.000000],
            [0.033194, 0.966806, 0.000000],
            [0.017083, 0.072397, 0.910520],
        ]
        // Published BT.2020 -> Display P3 (D65, linear).
        let bt2020: [[Double]] = [
            [1.343578, -0.282180, -0.061399],
            [-0.065297, 1.075788, -0.010490],
            [0.002822, -0.019598, 1.016777],
        ]
        for (name, primaries, reference) in [("709", ColourPrimaries.bt709, bt709), ("2020", ColourPrimaries.bt2020, bt2020)] {
            let m = ColourPipeline.primariesToDisplayP3(primaries)
            for r in 0..<3 {
                var sum = 0.0
                for c in 0..<3 {
                    sum += m[c][r]
                    expect(near(m[c][r], reference[r][c], 1e-4), "\(name)->P3 [\(r)][\(c)] expected \(reference[r][c]) got \(m[c][r])")
                }
                expect(near(sum, 1, 1e-6), "\(name)->P3 row \(r) sums to 1 (white preserved), got \(sum)")
            }
        }
        let p3 = ColourPipeline.primariesToDisplayP3(.displayP3)
        expect(near(simd_length(p3.columns.0 - simd_double3(1, 0, 0)) + simd_length(p3.columns.1 - simd_double3(0, 1, 0)) + simd_length(p3.columns.2 - simd_double3(0, 0, 1)), 0, 1e-9), "P3->P3 is identity")

        // With the opt-in P3 policy the float matrix the shader gets maps BT.709 white to P3 white, red to P3 red.
        let sel = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10, output: .p3)
        expectNear3(sel.sourceToOutput * simd_float3(1, 1, 1), simd_float3(1, 1, 1), 1e-6, "709 white -> P3 white")
        expectNear3(sel.sourceToOutput * simd_float3(1, 0, 0), simd_float3(0.822462, 0.033194, 0.017083), 1e-4, "709 red -> P3")
    }

    static func testPrimariesToSRGB() {
        // Published BT.2020 -> BT.709 (ITU-R BT.2087-0, linear).
        let bt2020: [[Double]] = [
            [1.6605, -0.5876, -0.0728],
            [-0.1246, 1.1329, -0.0083],
            [-0.0182, -0.1006, 1.1187],
        ]
        let m = ColourPipeline.primariesConversion(from: .bt2020, to: .bt709)
        for r in 0..<3 {
            for c in 0..<3 {
                expect(near(m[c][r], bt2020[r][c], 1e-4), "2020->709 [\(r)][\(c)] expected \(bt2020[r][c]) got \(m[c][r])")
            }
        }
        // P3 -> 709 inverts the published 709 -> P3.
        let p3to709 = ColourPipeline.primariesConversion(from: .displayP3, to: .bt709) * ColourPipeline.primariesToDisplayP3(.bt709)
        expect(near(simd_length(p3to709.columns.0 - simd_double3(1, 0, 0)) + simd_length(p3to709.columns.1 - simd_double3(0, 1, 0)) + simd_length(p3to709.columns.2 - simd_double3(0, 0, 1)), 0, 1e-9), "P3->709 inverts 709->P3")
    }

    // Default output is extended linear sRGB (what the simulator compositor was measured to assume): BT.709 sources are
    // passed through, BT.2020 SDR sources convert in linear light with negatives kept; ALVRDisplayP3Output opts into P3.
    static func testOutputPolicy() {
        let s709 = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10)
        expectEqual(s709.output, .srgb, "default output policy")
        expect(s709.sourceToOutput == matrix_identity_float3x3, "709 -> sRGB output is identity")
        expect(!s709.convertsGamut, "709 -> sRGB output does not convert")
        let unsignalled = ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, bitDepth: 8)
        expect(unsignalled.sourceToOutput == matrix_identity_float3x3, "unsignalled (assumed 709) -> identity")

        let s2020 = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "IEC_sRGB", matrix: "ITU_R_2020", fullRange: true, bitDepth: 10)
        expect(s2020.convertsGamut, "2020 -> sRGB output converts")
        expectNear3(s2020.sourceToOutput * simd_float3(1, 1, 1), simd_float3(1, 1, 1), 1e-5, "2020 white -> 709 white")
        let green = s2020.sourceToOutput * simd_float3(0, 1, 0)
        expectNear3(green, simd_float3(-0.5876, 1.1329, -0.1006), 1e-4, "2020 green -> 709 keeps negatives")

        let p3 = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10, output: .p3)
        expectEqual(p3.output, .p3, "P3 output policy")
        expect(p3.convertsGamut, "709 -> P3 output converts")
        let p3Source = ColourPipeline.select(primaries: "P3_D65", transfer: "IEC_sRGB", matrix: nil, fullRange: true, bitDepth: 8)
        expect(p3Source.convertsGamut, "P3 source -> sRGB output converts")

        expectEqual(ColourOutput(displayP3Default: false), .srgb, "ALVRDisplayP3Output unset/false -> srgb")
        expectEqual(ColourOutput(displayP3Default: true), .p3, "ALVRDisplayP3Output true -> p3")
    }

    // GM evidence (RDR2 title screen): PC capture logo red (203,0,0), snow (205,223,237). Sim before AC5 (no gamut
    // step) showed (202,0,0); after AC5's 709 -> P3 step (186,38,26), which is the P3 values re-read as sRGB.
    static func testMeasuredTitleScreenPixels() {
        let srgb = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10)
        expectWithinCodes(referencePixel(simd_int3(203, 0, 0), srgb), simd_int3(203, 0, 0), 1, "logo red round-trips with sRGB output")
        expectWithinCodes(referencePixel(simd_int3(205, 223, 237), srgb), simd_int3(205, 223, 237), 1, "snow round-trips with sRGB output")
        let p3 = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10, output: .p3)
        // Hand arithmetic from linear 0.597 gives (187,38,26); the full path with 10-bit codes lands on the measurement.
        let p3Red = referencePixel(simd_int3(203, 0, 0), p3)
        expectWithinCodes(p3Red, simd_int3(187, 38, 26), 1, "P3 output re-read as sRGB = hand-computed desaturated red")
        expectWithinCodes(p3Red, simd_int3(186, 38, 26), 0, "P3 output re-read as sRGB = measured sim red")
    }

    static func testSelection() {
        // 10 bits with no primaries/matrix signalled: never BT.2020.
        let s = ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: true, bitDepth: 10)
        expectEqual(s.primaries, .bt709, "unsignalled primaries at 10 bits")
        expectEqual(s.matrix, .bt709, "unsignalled matrix at 10 bits")
        expect(s.primariesAssumed && s.matrixAssumed, "unsignalled fields are marked assumed")
        expectEqual(s.bitDepth, 10, "bit depth kept")

        // Signalled BT.2020 is honoured at 8 bits, BT.709 at 10 bits.
        let s2020 = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "IEC_sRGB", matrix: "ITU_R_2020", fullRange: true, bitDepth: 8)
        expectEqual(s2020.primaries, .bt2020, "BT.2020 at 8 bits")
        expectEqual(s2020.matrix, .bt2020, "BT.2020 matrix at 8 bits")
        let s709 = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10)
        expectEqual(s709.primaries, .bt709, "BT.709 at 10 bits")
        expect(!s709.primariesAssumed, "signalled primaries not assumed")
        expect(s709.yuvToRGB != s2020.yuvToRGB, "matrix depends on signalled matrix")

        // Mixed signalling: primaries and matrix are independent.
        let mixed = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10)
        expectEqual(mixed.primaries, .bt709, "mixed primaries")
        expectEqual(mixed.matrix, .bt2020, "mixed matrix")

        // Range: absent flag means limited (H.273 default), explicit flags honoured.
        expect(!ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, bitDepth: 8).fullRange, "absent range flag -> limited")
        expect(ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, bitDepth: 8).rangeAssumed, "absent range is assumed")
        expect(ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: true, bitDepth: 8).fullRange, "full range flag")
        expectEqual(ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, bitDepth: nil).bitDepth, 8, "absent bit depth -> 8")

        // Transfers: SDR transfers convert the gamut in linear light (when the output primaries differ); PQ/HLG keep
        // the previous (identity) behaviour.
        expectEqual(ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: nil, fullRange: true, bitDepth: 8).transfer, .sRGB, "sRGB transfer")
        expectEqual(ColourPipeline.select(primaries: nil, transfer: "ITU_R_709_2", matrix: nil, fullRange: true, bitDepth: 8).transfer, .bt709, "709 transfer")
        let pq = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10)
        expectEqual(pq.transfer, .pq, "PQ transfer")
        expect(!pq.convertsGamut, "PQ path does not convert gamut")
        expect(pq.sourceToOutput == matrix_identity_float3x3, "PQ gamut matrix is identity")
        let pqP3 = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10, output: .p3)
        expect(!pqP3.convertsGamut, "PQ path does not convert gamut with P3 output either")
        expectEqual(ColourPipeline.select(primaries: nil, transfer: "ITU_R_2100_HLG", matrix: nil, fullRange: true, bitDepth: 10).transfer, .hlg, "HLG transfer")
        expect(ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: nil, fullRange: true, bitDepth: 8, output: .p3).convertsGamut, "sRGB transfer converts gamut to P3")
        expect(ColourPipeline.select(primaries: "P3_D65", transfer: "IEC_sRGB", matrix: nil, fullRange: true, bitDepth: 8, output: .p3).sourceToOutput == matrix_identity_float3x3, "P3 source -> P3 identity")
    }

    static func testLogLineAndFourCC() {
        let s = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10)
        expectEqual(s.logLine(path: "explicit"), "ALVRCOLOUR primaries=bt709 transfer=sRGB matrix=bt709 range=full bits=10 out=srgb path=explicit")
        let a = ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, bitDepth: 10, output: .p3)
        expectEqual(a.logLine(path: "secret"), "ALVRCOLOUR primaries=bt709(assumed) transfer=unknown matrix=bt709(assumed) range=limited(assumed) bits=10 out=p3 path=secret")
        expectEqual(ColourPipeline.fourCC(0x78343230), "x420")
        expectEqual(ColourPipeline.fourCC(0x26786630), "&xf0")
        expectEqual(ColourPipeline.fourCC(0x00000001), "0x00000001")
    }
}
