// SOURCES: ALVRClient/ColourPipeline.swift ALVRClient/HDRPipeline.swift
// HDRPipeline (GM decision 63, h2): SMPTE ST 2084 PQ EOTF against reference values, BT.2020 <-> Display P3 matrices,
// the EDR soft roll-off, the Swift mirror of the shader's per-pixel path (PQ and unchanged SDR), the decision-63
// probe levels decoded from 10-bit limited-range BT.2020 codes, and the HDRPROBE log line and 250 ms cadence.
// Decision 63c: PQ output in Display P3, headroom 2.0, the per-stream colour state (HDR off and refused streams keep
// the previous path) and the pipeline slot that publishes pipelines with the state they were built for.
// Decision 63e: PQ is never drawn through the SDR/sRGB path (8- and 10-bit biplanar planes run the PQ conversion,
// other formats are dropped); the HDR setting is captured once per stream (StreamContext); pipeline builds snapshot
// one generation's inputs and stale-generation builds are discarded (VideoStreamGate, both lock orders forced).
import CoreVideo
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
        testEightBitPQRendersPQ()
        testSettingCapturedPerStream()
        testPipelineSlot()
        testReconnectPublishInterleaving()
        testSDRShadeUnchanged()
        testPQShade()
        testProbeLevelsDecode()
        testProbeLineAndCadence()
        testLiveProbeFlag()
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
        // Decision 63e (1): PQ always requests explicit 10-bit planes (no sRGB-decoding private sampler), whatever the
        // HDR setting; SDR keeps the decoder's default output.
        expect(HDRPipeline.requiresExplicitPlanes(transfer: "SMPTE_ST_2084_PQ"), "PQ requests explicit 10-bit planes")
        expect(!HDRPipeline.requiresExplicitPlanes(transfer: "IEC_sRGB"), "sRGB keeps today's decoder output")
        expect(!HDRPipeline.requiresExplicitPlanes(transfer: nil), "unsignalled keeps today's decoder output")
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

    static func context(generation: UInt64 = 1, hdr: Bool = true, headroom: Float = 2, output: ColourOutput = .srgb, gamma: Float = 1) -> StreamContext {
        StreamContext(generation: generation, hdrEnabled: hdr, headroom: headroom, output: output, encodingGamma: gamma)
    }

    static func pqState(_ pixelFormat: OSType, stream: StreamContext = context(), realityKit: Bool = false) -> StreamColourState {
        let bits = HDRPipeline.pqPlaneBitDepth(pixelFormat: pixelFormat)
        return StreamColourState(selection: pqSelection(planeBitDepth: bits), planeBitDepth: bits, stream: stream, realityKit: realityKit)
    }

    // Decision 63e (1): the stream colour state as the renderer binds it. PQ never takes the SDR/sRGB path: every
    // non-packed biplanar format is bound as raw normalised planes (8 or 10 bit) and runs the PQ conversion; packed
    // and unknown formats are dropped.
    static func testStreamColourState() {
        let toP3 = simd_float3x3(columns: (simd_float3(ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3).columns.0),
                                           simd_float3(ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3).columns.1),
                                           simd_float3(ColourPipeline.primariesConversion(from: .bt2020, to: .displayP3).columns.2)))
        let tenBit: [OSType] = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange]
        let eightBit: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                                  kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange]
        let dropped: [OSType] = [0x70343230 /* p420 */, 0x2D786630 /* -xf0 */, kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
                                 kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8Planar, 0x3F3F3F3F]
        for realityKit in [false, true] {
            for hdr in [true, false] {
                let stream = context(hdr: hdr, headroom: 3)
                for (formats, bits) in [(tenBit, 10), (eightBit, 8)] {
                    for f in formats {
                        let s = pqState(f, stream: stream, realityKit: realityKit)
                        expectEqual(s.binding, .explicitPlanes(bitDepth: bits), "PQ \(ColourPipeline.fourCC(f)) bound as raw \(bits)-bit planes (hdr \(hdr))")
                        expect(s.hdrPQ && !s.dropFrames, "PQ \(ColourPipeline.fourCC(f)) runs the PQ conversion (hdr \(hdr), realityKit \(realityKit))")
                        expectEqual(s.selection.planeBitDepth, bits, "yuvToRGB quantised for \(bits)-bit planes")
                        expectEqual(s.gamutToOutput, toP3, "PQ gamut BT.2020 -> P3")
                        expectEqual(s.lowPrecisionPQ, bits == 8, "8-bit PQ precision warning flag")
                        // HDR setting off: still PQ, rolled off into SDR range (headroom 1) instead of the EDR headroom.
                        expectEqual(s.headroom, hdr ? 3 : 1, "headroom from the stream's captured setting")
                    }
                }
                for f in dropped {
                    let s = pqState(f, stream: stream, realityKit: realityKit)
                    expectEqual(s.binding, .drop, "PQ on \(ColourPipeline.fourCC(f)): frames dropped, never drawn through another path")
                    expect(s.dropFrames && !s.hdrPQ, "dropped state flags")
                }
            }
        }
        // SDR: the previous binding and constants exactly, whatever the HDR setting: Metal keeps the ColourOutput gamut,
        // RealityKit identity; decoder-default planes (private formats on device).
        for output in [ColourOutput.srgb, .p3] {
            let sdr = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false, bitDepth: 8, planeBitDepth: 8, output: output)
            for hdr in [false, true] {
                let metal = StreamColourState(selection: sdr, planeBitDepth: 8, stream: context(hdr: hdr, output: output), realityKit: false)
                let rk = StreamColourState(selection: sdr, planeBitDepth: 8, stream: context(hdr: hdr, output: output), realityKit: true)
                expectEqual(metal.binding, .decoderDefault, "SDR keeps the decoder-default binding")
                expectEqual(metal.gamutToOutput, sdr.sourceToOutput, "SDR Metal gamut = ColourOutput conversion")
                expectEqual(rk.gamutToOutput, matrix_identity_float3x3, "SDR RealityKit gamut identity, as before")
                expect(!metal.hdrPQ && !metal.dropFrames && !metal.lowPrecisionPQ, "SDR never PQ or dropped")
                expectEqual(metal.yuvToRGB, sdr.yuvToRGB, "yuvToRGB from the selection")
                expectEqual(metal.encodingGamma, 1, "encoding gamma from the stream context")
            }
        }
    }

    // Render level (decision 63e tests): an 8-bit PQ frame takes the PQ path. The shader mirror on the r8Unorm sample
    // of 8-bit limited codes gives the PQ EDR goldens (independent: double-precision ST 2084 for the rounded codes), far
    // from what the SDR/sRGB path would show.
    static func testEightBitPQRendersPQ() {
        let s = pqState(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, stream: context(hdr: true, headroom: 100))
        expectEqual(s.binding, .explicitPlanes(bitDepth: 8), "8-bit PQ binds raw planes")
        for (code, edr, sdrPath) in [(127, 0.486612, 0.220436), (143, 0.992562, 0.295598), (181, 4.998830, 0.527872)] as [(Int, Double, Double)] {
            let sample = simd_float4(Float(code) / 255, 128.0 / 255, 128.0 / 255, 1)
            let out = HDRPipeline.shade(sample: sample, colour: s)
            for c in 0..<3 {
                expect(nearRel(Double(out[c]), edr, 0.003), "8-bit PQ code \(code) -> EDR \(edr), got \(out)")
                expect(abs(Double(out[c]) - sdrPath) > 0.1, "8-bit PQ code \(code) is not the SDR-path value \(sdrPath)")
            }
        }
    }

    // Decision 63e (2): the HDR setting is captured once at STREAMING_STARTED; toggling it mid-stream does not change
    // the running stream's state, the next stream picks it up.
    static func testSettingCapturedPerStream() {
        let gate = VideoStreamGate<String>()
        var uiSetting = true
        let first = gate.streamStarted(hdrEnabled: uiSetting, headroom: 2, output: .srgb, encodingGamma: 1, payload: "fov1")
        let frameA = pqState(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, stream: gate.currentStream!)
        uiSetting = false
        let frameB = pqState(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, stream: gate.currentStream!)
        expect(gate.currentStream == first && first.hdrEnabled, "the running stream keeps HDR on after the toggle")
        expect(frameA == frameB && frameB.headroom == 2, "frames after the toggle keep the stream's state and pipelines key")
        let second = gate.streamStarted(hdrEnabled: uiSetting, headroom: 2, output: .srgb, encodingGamma: 1, payload: "fov2")
        expect(second.generation == first.generation + 1 && !second.hdrEnabled, "the next stream captures the new setting")
        expectEqual(pqState(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, stream: second).headroom, 1, "HDR off: SDR-range roll-off")
        gate.streamStopped()
        expect(gate.currentStream == nil, "stopped: no stream")
    }

    static func sdrState(_ stream: StreamContext, output: ColourOutput = .srgb) -> StreamColourState {
        StreamColourState(selection: ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false, bitDepth: 8, planeBitDepth: 8, output: output),
                          planeBitDepth: 8, stream: stream, realityKit: false)
    }

    // Decision 63c (4) / 63e (3): pipelines are published with the colour state and generation they were built for,
    // and used only for exactly that state on the current generation.
    static func testPipelineSlot() {
        let gate = VideoStreamGate<String>()
        let slot = VideoPipelineSlot<String, String>(gate: gate)
        let stream = gate.streamStarted(hdrEnabled: false, headroom: 2, output: .srgb, encodingGamma: 1, payload: "fov1")
        let srgb = sdrState(stream)
        let p3 = sdrState(stream, output: .p3)
        expect(srgb != p3 && srgb.yuvToRGB == p3.yuvToRGB && srgb.hdrPQ == p3.hdrPQ, "states differ only in gamut")
        expect(slot.buildInputs() == nil && slot.pipelines(for: srgb) == nil, "nothing requested or published at start")
        expect(slot.request(srgb), "first request rebuilds")
        expect(!slot.request(srgb), "same state: no rebuild")
        expect(slot.pipelines(for: srgb) == nil, "not drawn before its pipelines are published")
        let inputs = slot.buildInputs()
        expect(inputs?.colour == srgb && inputs?.payload == "fov1", "build inputs: requested state with its own stream's foveation")
        expect(slot.publish("A", builtFor: srgb), "build for the requested state published")
        expectEqual(slot.pipelines(for: srgb), "A", "published pipelines for their own state")
        expect(slot.request(p3), "gamut-only change rebuilds")
        expect(slot.pipelines(for: p3) == nil, "the P3 frame never draws with the sRGB pipelines")
        expect(!slot.publish("stale", builtFor: srgb), "a build for a state no longer requested is dropped")
        expect(slot.publish("B", builtFor: p3), "P3 build published")
        expectEqual(slot.pipelines(for: p3), "B", "P3 pipelines")
        expect(slot.pipelines(for: srgb) == nil, "an old-state frame never draws with the new pipelines")
        // A build that snapshotted generation 1 and finishes after a reconnect is discarded, and its inputs are never
        // mixed with generation 2's (foveation, gamma, colour come from one snapshot).
        let old = slot.buildInputs()!
        let next = gate.streamStarted(hdrEnabled: true, headroom: 2, output: .srgb, encodingGamma: 2.2, payload: "fov2")
        expect(!slot.publish("old", builtFor: old.colour), "stale-generation build discarded")
        expect(slot.pipelines(for: p3) == nil, "generation-1 frames are not drawn after the reconnect")
        expect(slot.buildInputs() == nil, "no build inputs until the new stream requests its state")
        expect(!slot.request(p3), "a stale-generation frame cannot request a build")
        let fresh = sdrState(next)
        expect(slot.request(fresh), "new stream requests its own state")
        let newInputs = slot.buildInputs()
        expect(newInputs?.colour == fresh && newInputs?.payload == "fov2" && newInputs?.colour.encodingGamma == 2.2, "generation-2 inputs only")
        expect(slot.publish("C", builtFor: fresh), "generation-2 build published")
        gate.streamStopped()
        expect(slot.pipelines(for: fresh) == nil && !slot.publish("C", builtFor: fresh), "stopped: nothing drawn or published")
    }

    // Decision 63e tests: reconnect vs build publish, both lock orders forced with the gate's seams (no sleeps).
    static func testReconnectPublishInterleaving() {
        for publishFirst in [true, false] {
            let order = LockOrder()
            let gate = VideoStreamGate<String>(beforeLock: { order.beforeLock($0) }, inLock: { order.inLock($0) })
            let slot = VideoPipelineSlot<String, String>(gate: gate)
            let first = gate.streamStarted(hdrEnabled: true, headroom: 2, output: .srgb, encodingGamma: 1, payload: "fov1")
            let colour = pqState(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, stream: first)
            _ = slot.request(colour)
            let inputs = slot.buildInputs()!
            var published: Bool?
            var second: StreamContext?
            let publish = { published = slot.publish("P", builtFor: inputs.colour) }
            let reconnect = { second = gate.streamStarted(hdrEnabled: true, headroom: 2, output: .srgb, encodingGamma: 1, payload: "fov2") }
            let forced = publishFirst
                ? order.run(holderEntry: "publish", publish, waiterEntry: "streamStarted", reconnect)
                : order.run(holderEntry: "streamStarted", reconnect, waiterEntry: "publish", publish)
            expect(forced, "lock order forced (publishFirst \(publishFirst))")
            expectEqual(published, publishFirst, "publish succeeds only before the reconnect (publishFirst \(publishFirst))")
            expect(slot.pipelines(for: colour) == nil, "after the reconnect generation-1 pipelines are never used (publishFirst \(publishFirst))")
            if let second {
                let next = pqState(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, stream: second)
                expect(slot.request(next) && slot.pipelines(for: next) == nil, "the new stream builds its own pipelines (publishFirst \(publishFirst))")
                expectEqual(slot.buildInputs()?.payload, "fov2", "new build snapshots the new stream's foveation")
            } else {
                expect(false, "reconnect ran")
            }
        }
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

    static func testLiveProbeFlag() {
        let flag = HDRProbeFlag(environment: [:], defaultsValue: nil)
        expect(!flag.enabled, "cached probe defaults off")
        flag.update(defaultsValue: true)
        expect(flag.enabled, "toggle enables the existing cache without relaunch")
        flag.update(defaultsValue: false)
        expect(!flag.enabled, "toggle disables the existing cache without relaunch")
        for (value, expected) in [("1", true), ("0", false), ("", false)] {
            let overridden = HDRProbeFlag(environment: [HDRPipeline.probeKey: value], defaultsValue: !expected)
            expectEqual(overridden.enabled, expected, "environment overrides initial defaults")
            overridden.update(defaultsValue: true)
            expectEqual(overridden.enabled, expected, "environment overrides toggle on")
            overridden.update(defaultsValue: false)
            expectEqual(overridden.enabled, expected, "environment overrides toggle off")
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
