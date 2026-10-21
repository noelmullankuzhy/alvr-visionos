// SOURCES: ALVRClient/ColourPipeline.swift
// ColourPipeline: YCbCr->RGB matrices (H.273 / BT.601, BT.709, BT.2020, full and limited range, 8- and 10-bit code
// ranges), source primaries -> Display P3 matrices derived from chromaticities, and the colour selection parsed from
// the format description (never inferring BT.2020 from bit depth).
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
    let bits = selection.bitDepth
    let sample = simd_float4(ColourPipeline.sampleValue(code: codes.x, bitDepth: bits),
                             ColourPipeline.sampleValue(code: codes.y, bitDepth: bits),
                             ColourPipeline.sampleValue(code: codes.z, bitDepth: bits), 1)
    let out = selection.yuvToRGB * sample
    return simd_float3(out.x, out.y, out.z)
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
        testSelection()
        testLogLineAndFourCC()
        finishTests("ColourPipelineTests")
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

        // The float matrix the shader gets transforms BT.709 white to P3 white and red to the published P3 red.
        let sel = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10)
        expectNear3(sel.sourceToDisplayP3 * simd_float3(1, 1, 1), simd_float3(1, 1, 1), 1e-6, "709 white -> P3 white")
        expectNear3(sel.sourceToDisplayP3 * simd_float3(1, 0, 0), simd_float3(0.822462, 0.033194, 0.017083), 1e-4, "709 red -> P3")
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

        // Transfers: SDR transfers convert the gamut in linear light; PQ/HLG keep the previous (identity) behaviour.
        expectEqual(ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: nil, fullRange: true, bitDepth: 8).transfer, .sRGB, "sRGB transfer")
        expectEqual(ColourPipeline.select(primaries: nil, transfer: "ITU_R_709_2", matrix: nil, fullRange: true, bitDepth: 8).transfer, .bt709, "709 transfer")
        let pq = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10)
        expectEqual(pq.transfer, .pq, "PQ transfer")
        expect(!pq.convertsGamut, "PQ path does not convert gamut")
        expect(pq.sourceToDisplayP3 == matrix_identity_float3x3, "PQ gamut matrix is identity")
        expectEqual(ColourPipeline.select(primaries: nil, transfer: "ITU_R_2100_HLG", matrix: nil, fullRange: true, bitDepth: 10).transfer, .hlg, "HLG transfer")
        expect(ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: nil, fullRange: true, bitDepth: 8).convertsGamut, "sRGB converts gamut")
        expect(ColourPipeline.select(primaries: "P3_D65", transfer: "IEC_sRGB", matrix: nil, fullRange: true, bitDepth: 8).sourceToDisplayP3 == matrix_identity_float3x3, "P3 source -> identity")
    }

    static func testLogLineAndFourCC() {
        let s = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10)
        expectEqual(s.logLine(path: "explicit"), "ALVRCOLOUR primaries=bt709 transfer=sRGB matrix=bt709 range=full bits=10 path=explicit")
        let a = ColourPipeline.select(primaries: nil, transfer: nil, matrix: nil, fullRange: nil, bitDepth: 10)
        expectEqual(a.logLine(path: "secret"), "ALVRCOLOUR primaries=bt709(assumed) transfer=unknown matrix=bt709(assumed) range=limited(assumed) bits=10 path=secret")
        expectEqual(ColourPipeline.fourCC(0x78343230), "x420")
        expectEqual(ColourPipeline.fourCC(0x26786630), "&xf0")
        expectEqual(ColourPipeline.fourCC(0x00000001), "0x00000001")
    }
}
