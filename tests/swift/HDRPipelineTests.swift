// SOURCES: ALVRClient/ColourPipeline.swift ALVRClient/HDRPipeline.swift
// HDRPipeline (GM decision 63, h2): SMPTE ST 2084 PQ EOTF against reference values, BT.2020 <-> Display P3 matrices,
// the EDR soft roll-off, the Swift mirror of the shader's per-pixel path (PQ and unchanged SDR), the decision-63
// probe levels decoded from 10-bit limited-range BT.2020 codes, and the HDRPROBE log line and 250 ms cadence.
// Decision 63c: PQ output in Display P3, headroom 2.0, the per-stream colour state (HDR off and refused streams keep
// the previous path) and the pipeline slot that publishes pipelines with the state they were built for.
import Foundation
import simd

func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
func nearRel(_ a: Double, _ b: Double, _ rel: Double) -> Bool { abs(a - b) <= abs(b) * rel }

// Independent reference: SMPTE ST 2084 constants written out from the standard.
func referencePQEncode(_ nits: Double) -> Double {
    let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128, c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
    let y = pow(nits / 10000, m1)
    return pow((c1 + c2 * y) / (1 + c3 * y), m2)
}

// Independent reference: BT.2020 NCL limited-range 10-bit codes (unrounded) for non-linear R'G'B'.
func referenceCodes2020(_ rgb: simd_double3) -> simd_double3 {
    let kr = 0.2627, kb = 0.0593, kg = 1 - kr - kb
    let y = kr * rgb.x + kg * rgb.y + kb * rgb.z
    let pb = (rgb.z - y) / (2 * (1 - kb))
    let pr = (rgb.x - y) / (2 * (1 - kr))
    return simd_double3(4 * (219 * y + 16), 4 * (224 * pb + 128), 4 * (224 * pr + 128))
}

@main
enum HDRPipelineTests {
    static func main() {
        testPQEOTFReferenceValues()
        testPQRoundTrip()
        testBT2020ToP3()
        testRollOff()
        testSelection()
        testHeadroomDefault()
        testStreamColourState()
        testPipelineSlot()
        testSDRShadeUnchanged()
        testPQShade()
        testProbeLevelsDecode()
        testProbeLineAndCadence()
        finishTests("HDRPipelineTests")
    }

    static func testPQEOTFReferenceValues() {
        let cases: [(Double, Double)] = [(0.5081, 100), (0.5807, 203), (0.7518, 1000), (1.0, 10000)]
        for (code, nits) in cases {
            let got = HDRPipeline.pqEOTF(code)
            expect(nearRel(got, nits, 0.005), "PQ EOTF(\(code)) = \(got), expected \(nits) +-0.5%")
        }
        expectEqual(HDRPipeline.pqEOTF(0), 0, "PQ EOTF(0) = 0")
        expect(HDRPipeline.pqEOTF(-0.1) == 0, "PQ EOTF clamps negative codes to 0")
        expect(HDRPipeline.pqEOTF(1.2) == 10000, "PQ EOTF clamps codes above 1 to 10000 nits")
        expectEqual(HDRPipeline.referenceWhiteNits, 203, "reference white default (decision 63, BT.2408)")
    }

    static func testPQRoundTrip() {
        for nits in [0.0, 0.1, 1, 10, 50, 100, 203, 406, 812, 1000, 4000, 10000] {
            let e = HDRPipeline.pqInverseEOTF(nits)
            expect(near(e, referencePQEncode(nits), 1e-9), "inverse EOTF(\(nits)) matches reference")
            expect(near(HDRPipeline.pqEOTF(e), nits, max(1e-6, nits * 1e-9)), "EOTF(inverse(\(nits))) round trip")
        }
    }

    static func testBT2020ToP3() {
        let toP3 = ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3)
        let back = ColourPipeline.primariesConversion(from: .displayP3, to: .bt2020)
        let id = back * toP3
        for c in 0..<3 {
            for r in 0..<3 {
                expect(near(id[c][r], c == r ? 1 : 0, 1e-9), "2020 -> P3 -> 2020 is identity [\(c)][\(r)]")
            }
        }
        // Published BT.2020 -> Display P3 (D65) matrix, rows R, G, B.
        let expected: [[Double]] = [[1.3435, -0.2822, -0.0613], [-0.0653, 1.0758, -0.0105], [0.0028, -0.0196, 1.0168]]
        for r in 0..<3 {
            for c in 0..<3 {
                expect(near(toP3[c][r], expected[r][c], 1e-3), "2020 -> P3 [\(r)][\(c)] = \(toP3[c][r]), expected \(expected[r][c])")
            }
        }
        let white = toP3 * simd_double3(1, 1, 1)
        expect(near(white.x, 1, 1e-9) && near(white.y, 1, 1e-9) && near(white.z, 1, 1e-9), "D65 white preserved")
    }

    static func testRollOff() {
        for headroom: Float in [1, 1.5, 2, 4, 4.926, 8, 16] {
            let knee = headroom * 0.75
            var x: Float = 0
            var previous = -Float.infinity
            while x <= headroom * 20 {
                let y = HDRPipeline.rollOff(x, headroom: headroom)
                if x <= knee {
                    expect(y == x, "roll-off identity below 0.75 x headroom (h=\(headroom), x=\(x)) got \(y)")
                }
                expect(y <= headroom, "roll-off never exceeds headroom (h=\(headroom), x=\(x)) got \(y)")
                expect(y >= previous, "roll-off monotonic (h=\(headroom), x=\(x))")
                // Float resolution flattens the last ulps of the shoulder, so strictness is checked below 99.9%.
                expect(y > previous || y >= headroom * 0.999, "roll-off strictly increasing until headroom (h=\(headroom), x=\(x))")
                previous = y
                x += headroom / 64
            }
            expect(HDRPipeline.rollOff(1e6, headroom: headroom) <= headroom, "huge input stays within headroom")
            // Smooth knee: slope 1 just above the knee, so no visible kink.
            let d: Float = 1e-3
            let slope = (HDRPipeline.rollOff(knee + d, headroom: headroom) - HDRPipeline.rollOff(knee, headroom: headroom)) / d
            expect(abs(slope - 1) < 0.01, "slope ~1 at the knee (h=\(headroom)) got \(slope)")
        }
        // Colour roll-off scales by max(R,G,B): hue ratios kept, identity below the knee, max channel <= headroom.
        let h: Float = 4
        let dim = simd_float3(2.5, 1.0, 0.25)
        expect(HDRPipeline.rollOff(dim, headroom: h) == dim, "RGB below knee unchanged")
        let hot = simd_float3(12, 6, 3)
        let out = HDRPipeline.rollOff(hot, headroom: h)
        expect(max(out.x, max(out.y, out.z)) <= h, "RGB max channel <= headroom")
        expect(abs(out.y / out.x - 0.5) < 1e-5 && abs(out.z / out.x - 0.25) < 1e-5, "RGB ratios preserved")
        expect(HDRPipeline.rollOff(simd_float3(0, 0, 0), headroom: h) == simd_float3(0, 0, 0), "black stays black")
        expect(HDRPipeline.rollOff(1.0, headroom: 0.5) <= 1.0, "headroom below 1 is treated as 1 (SDR white never dimmed)")
        expect(HDRPipeline.rollOff(0.75, headroom: 0.5) == 0.75, "headroom below 1 is treated as 1")
    }

    // Decision 63c (2): PQ output is extended linear Display P3 whatever the SDR output policy.
    static func testSelection() {
        let toP3 = ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3)
        for output in [ColourOutput.srgb, .p3] {
            let pq = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10, output: output)
            expect(pq.isPQ, "PQ selection flagged")
            expectEqual(pq.output, .p3, "PQ output primaries are Display P3 (SDR policy \(output))")
            for c in 0..<3 {
                expect(simd_length(pq.sourceToOutput[c] - simd_float3(toP3[c])) < 1e-6, "PQ: linear BT.2020 -> P3 output column \(c) (SDR policy \(output))")
            }
        }
        let sdr = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 10)
        expect(!sdr.isPQ, "sRGB stream is not PQ")
        expectEqual(sdr.output, .srgb, "SDR keeps the ColourOutput policy")
        expect(!ColourPipeline.select(primaries: nil, transfer: "ITU_R_2100_HLG", matrix: nil, fullRange: false, bitDepth: 10).isPQ, "HLG is not PQ")
        expect(HDRPipeline.requiresExplicitPlanes(transfer: "SMPTE_ST_2084_PQ", hdrEnabled: true), "PQ with HDR on needs explicit 10-bit planes (no sRGB-decoding private sampler)")
        expect(!HDRPipeline.requiresExplicitPlanes(transfer: "SMPTE_ST_2084_PQ", hdrEnabled: false), "HDR off keeps today's decoder output, even for a PQ stream")
        expect(!HDRPipeline.requiresExplicitPlanes(transfer: "IEC_sRGB", hdrEnabled: true), "sRGB keeps today's decoder output")
        expect(!HDRPipeline.requiresExplicitPlanes(transfer: nil, hdrEnabled: true), "unsignalled keeps today's decoder output")
    }

    // Decision 63c (2): assumed headroom 2.0 until the headset measures it; ALVRHDRHeadroom >= 1 overrides.
    static func testHeadroomDefault() {
        expectEqual(HDRPipeline.assumedHeadroom, 2, "assumed EDR headroom")
        expectEqual(HDRPipeline.headroom(defaultsValue: 0), 2, "unset ALVRHDRHeadroom -> assumed")
        expectEqual(HDRPipeline.headroom(defaultsValue: 3.5), 3.5, "ALVRHDRHeadroom overrides")
        expectEqual(HDRPipeline.headroom(defaultsValue: 0.5), 2, "ALVRHDRHeadroom below 1 ignored")
    }

    static func pqSelection(planeBitDepth: Int?) -> ColourSelection {
        ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10, planeBitDepth: planeBitDepth, output: .srgb)
    }

    // Decision 63c (1), (3), (4): the per-stream colour state is a pure function of the stream, the decoded format's
    // plane depth, the HDR setting and the renderer.
    static func testStreamColourState() {
        let toP3 = simd_float3x3(columns: (simd_float3(ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3).columns.0),
                                           simd_float3(ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3).columns.1),
                                           simd_float3(ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3).columns.2)))
        for realityKit in [false, true] {
            // PQ, HDR on, explicit 10-bit planes: HDR path, BT.2020 -> P3 on both renderers.
            let pq = StreamColourState(selection: pqSelection(planeBitDepth: 10), planeBitDepth: 10, hdrEnabled: true, realityKit: realityKit)
            expect(pq.hdrPQ && !pq.pqRefused && pq.explicitPlanes, "PQ on explicit 10-bit planes takes the HDR path (realityKit \(realityKit))")
            expectEqual(pq.gamutToOutput, toP3, "PQ gamut BT.2020 -> P3 (realityKit \(realityKit))")
            // The decoder ignored the explicit request (private packed format, or 8-bit planes): HDR refused for the
            // stream, which then takes exactly the HDR-off path.
            for planes in [nil, 8] as [Int?] {
                let refused = StreamColourState(selection: pqSelection(planeBitDepth: planes), planeBitDepth: planes, hdrEnabled: true, realityKit: realityKit)
                let off = StreamColourState(selection: pqSelection(planeBitDepth: planes), planeBitDepth: planes, hdrEnabled: false, realityKit: realityKit)
                expect(refused.pqRefused && !refused.hdrPQ && !refused.explicitPlanes, "PQ on planes \(String(describing: planes)) refused (realityKit \(realityKit))")
                expectEqual(refused.gamutToOutput, off.gamutToOutput, "refused = HDR-off gamut")
                expect(!off.pqRefused && !off.hdrPQ, "HDR off: never refused, never HDR")
            }
            // HDR off on a PQ stream: the previous path, no gamut conversion added.
            let off = StreamColourState(selection: pqSelection(planeBitDepth: 10), planeBitDepth: 10, hdrEnabled: false, realityKit: realityKit)
            expectEqual(off.gamutToOutput, matrix_identity_float3x3, "HDR off, PQ stream: identity gamut as before (realityKit \(realityKit))")
            expect(!off.explicitPlanes, "HDR off: decoder's default planes")
        }
        // SDR: Metal keeps the ColourOutput gamut, RealityKit keeps identity (decision 63c (1): unchanged SDR).
        let sdrP3 = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false, bitDepth: 8, planeBitDepth: 8, output: .p3)
        for hdr in [false, true] {
            let metal = StreamColourState(selection: sdrP3, planeBitDepth: 8, hdrEnabled: hdr, realityKit: false)
            let rk = StreamColourState(selection: sdrP3, planeBitDepth: 8, hdrEnabled: hdr, realityKit: true)
            expectEqual(metal.gamutToOutput, sdrP3.sourceToOutput, "SDR Metal gamut = ColourOutput conversion (HDR setting \(hdr))")
            expectEqual(rk.gamutToOutput, matrix_identity_float3x3, "SDR RealityKit gamut identity, as before (HDR setting \(hdr))")
            expect(!metal.hdrPQ && !metal.pqRefused && !rk.hdrPQ && !rk.pqRefused, "SDR never HDR or refused")
            expectEqual(metal.yuvToRGB, sdrP3.yuvToRGB, "yuvToRGB from the selection")
        }
    }

    // Decision 63c (4): pipelines are published with the colour state they were built for, and used only for it.
    static func testPipelineSlot() {
        let srgb = StreamColourState(selection: ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false, bitDepth: 8, planeBitDepth: 8, output: .srgb), planeBitDepth: 8, hdrEnabled: false, realityKit: false)
        let p3 = StreamColourState(selection: ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false, bitDepth: 8, planeBitDepth: 8, output: .p3), planeBitDepth: 8, hdrEnabled: false, realityKit: false)
        expect(srgb != p3 && srgb.yuvToRGB == p3.yuvToRGB && srgb.hdrPQ == p3.hdrPQ, "states differ only in gamut")
        let slot = VideoPipelineSlot<String>()
        expect(slot.requestedColour == nil && slot.pipelines(for: srgb) == nil, "nothing requested or published at start")
        expect(slot.request(srgb), "first request rebuilds")
        expect(!slot.request(srgb), "same state: no rebuild")
        expect(slot.pipelines(for: srgb) == nil, "not drawn before its pipelines are published")
        expect(slot.publish("A", builtFor: srgb), "build for the requested state published")
        expectEqual(slot.pipelines(for: srgb), "A", "published pipelines for their own state")
        expect(slot.request(p3), "gamut-only change rebuilds")
        expect(slot.pipelines(for: p3) == nil, "the P3 frame never draws with the sRGB pipelines")
        expect(!slot.publish("stale", builtFor: srgb), "a build for a state no longer requested is dropped")
        expect(slot.pipelines(for: p3) == nil, "still nothing for P3")
        expect(slot.publish("B", builtFor: p3), "P3 build published")
        expectEqual(slot.pipelines(for: p3), "B", "P3 pipelines")
        expect(slot.pipelines(for: srgb) == nil, "an old-state frame never draws with the new pipelines")
        expectEqual(slot.requestedColour, p3, "requested state")
    }

    // SDR: shade() is exactly sRGB EOTF -> encoding gamma -> gamut matrix, as before HDR (no roll-off, any headroom).
    static func testSDRShadeUnchanged() {
        for output in [ColourOutput.srgb, .p3] {
            let s = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true, bitDepth: 8, output: output)
            for sample in [simd_float4(0.1, 0.5, 0.5, 1), simd_float4(0.9, 0.3, 0.8, 1), simd_float4(1, 0.5, 0.5, 1), simd_float4(0.6, 0.1, 0.95, 1)] {
                let rgb = (s.yuvToRGB * sample)
                let lin = simd_float3(ColourPipeline.srgbEOTF(rgb.x), ColourPipeline.srgbEOTF(rgb.y), ColourPipeline.srgbEOTF(rgb.z))
                let gamma: Float = 1.5
                let src = simd_float3(ColourPipeline.encodingGammaToLinear(lin.x, gamma: gamma), ColourPipeline.encodingGammaToLinear(lin.y, gamma: gamma), ColourPipeline.encodingGammaToLinear(lin.z, gamma: gamma))
                let expected = s.sourceToOutput * src
                for headroom: Float in [1, 4] {
                    expect(HDRPipeline.shade(sample: sample, selection: s, encodingGamma: gamma, headroom: headroom) == expected, "SDR shade unchanged (\(output), \(sample), h=\(headroom))")
                }
            }
        }
    }

    static func testPQShade() {
        let s = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10, planeBitDepth: 10)
        // 203-nit grey -> EDR 1.0 (SDR white), whatever the encoding gamma; 1000 nits -> 4.926 below an 8x headroom.
        for (nits, edr) in [(203.0, 1.0), (1000.0, 1000.0 / 203), (10.0, 10.0 / 203)] {
            let e = HDRPipeline.pqInverseEOTF(nits)
            let code = referenceCodes2020(simd_double3(e, e, e))
            let sample = simd_float4(Float(code.x * 64 / 65535), Float(code.y * 64 / 65535), Float(code.z * 64 / 65535), 1)
            let out = HDRPipeline.shade(sample: sample, selection: s, encodingGamma: 1.5, headroom: 8)
            for c in 0..<3 {
                expect(nearRel(Double(out[c]), edr, 0.005), "PQ \(nits) nits grey -> EDR \(edr), got \(out)")
            }
        }
        // Above the headroom: soft roll-off, never above it.
        let e = HDRPipeline.pqInverseEOTF(4000)
        let code = referenceCodes2020(simd_double3(e, e, e))
        let sample = simd_float4(Float(code.x * 64 / 65535), Float(code.y * 64 / 65535), Float(code.z * 64 / 65535), 1)
        let out = HDRPipeline.shade(sample: sample, selection: s, encodingGamma: 1.5, headroom: 4)
        expect(out.x <= 4 && out.x > 3, "4000 nits rolls off into (3, 4] at headroom 4, got \(out)")
    }

    // Decision 63 oracle levels: 0.05/0.25/0.5/1/2/4/4.926 x 203 nits decode within 0.5% from rounded 10-bit codes.
    static func testProbeLevelsDecode() {
        let s = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10, planeBitDepth: 10)
        for level in [0.05, 0.25, 0.5, 1, 2, 4, 4.926] {
            let nits = level * 203
            let e = HDRPipeline.pqInverseEOTF(nits)
            let code = referenceCodes2020(simd_double3(e, e, e))
            let rounded = simd_double3(code.x.rounded(), code.y.rounded(), code.z.rounded())
            let decoded = HDRPipeline.decodeNits(codes: rounded, selection: s)
            for c in 0..<3 {
                // One 10-bit PQ code is ~0.9% near 10 nits; the oracle allows 3% or 2 codes.
                expect(nearRel(decoded[c], nits, level < 0.2 ? 0.02 : 0.01), "level \(level): \(nits) nits decoded \(decoded)")
            }
        }
    }

    static func testProbeLineAndCadence() {
        let line = HDRPipeline.probeLine(tMs: 1234, eye: "L", code: simd_double3(509, 512, 512), nits: simd_double3(203.04, 202.96, 203))
        expectEqual(line, "HDRPROBE t_ms=1234 eye=L code=509,512,512 nits=203.0,203.0,203.0")
        expect(HDRPipeline.probeEnabled(environment: ["ALVR_HDR_PROBE": "1"], defaultsValue: nil), "env 1 enables")
        expect(HDRPipeline.probeEnabled(environment: ["ALVR_HDR_PROBE": "true"], defaultsValue: nil), "env true enables")
        expect(!HDRPipeline.probeEnabled(environment: ["ALVR_HDR_PROBE": "0"], defaultsValue: nil), "env 0 disables")
        expect(!HDRPipeline.probeEnabled(environment: [:], defaultsValue: nil), "off by default")
        expect(HDRPipeline.probeEnabled(environment: [:], defaultsValue: true), "UserDefaults ALVR_HDR_PROBE enables")
        var clock = HDRProbeClock()
        expect(clock.shouldSample(nowMs: 1000), "first sample")
        expect(!clock.shouldSample(nowMs: 1100), "not before 250 ms")
        expect(!clock.shouldSample(nowMs: 1249), "not before 250 ms")
        expect(clock.shouldSample(nowMs: 1250), "at 250 ms")
        expect(clock.shouldSample(nowMs: 1600), "late frame samples")
        expect(!clock.shouldSample(nowMs: 1700), "250 ms from the last sample")
        // Monotonic scheduling: HDRProbe feeds the clock monotonic ms, apart from the logged wall-clock t_ms.
        expect(HDRProbeClock.monotonicMs(uptime: 12.3456) == 12345, "monotonic ms from system uptime seconds")
        var stepped = HDRProbeClock()
        expect(stepped.shouldSample(nowMs: 5000), "first sample")
        expect(stepped.shouldSample(nowMs: 1000), "a clock that stepped back never stalls the probe")
        expect(!stepped.shouldSample(nowMs: 1100), "cadence resumes from the new time")
    }
}
