//
//  HDRPipeline.swift
//
//  HDR10 (PQ, BT.2020) display maths, GM decision 63 h2 (pure Foundation/simd, tests/swift/HDRPipelineTests.swift).
//
//  PQ shader path (Shaders.metal videoFrameFragmentShader_YpCbCrBiPlanar with HDR_PQ, maths in VideoColour.h):
//  explicit 10-bit planes -> yuvToRGB (BT.2020 NCL, limited) -> R'G'B' -> ST 2084 EOTF -> absolute nits -> / reference
//  white (SDR white = 1.0, linear BT.2020) -> sourceToOutput (BT.2020 -> Display P3) -> rollOff above the EDR headroom
//  -> rgba16Float drawable as extended-range linear Display P3 (decision 63c (2), Apple's EDR path, WWDC23 10089).
//  CompositorServices exposes no drawable colour space setting, so the P3 interpretation is unproven until the headset
//  run. RealityKit path (renderColorFormatHDR texture): UNPROVEN, its interpretation of the texture is not documented.
//
//  EDR headroom: visionOS has no public query. UIScreen.currentEDRHeadroom is API_UNAVAILABLE(visionos), and
//  CompositorServices (LayerRenderer) and RealityKit expose no headroom (checked against the visionOS 27 SDK). The
//  renderer therefore uses assumedHeadroom 2.0, overridable with UserDefaults ALVRHDRHeadroom, until the headset run
//  measures it.
//
//  Decision 63e: PQ content is never drawn through the SDR/sRGB path. Any non-packed biplanar Y'CbCr buffer (8- or
//  10-bit) is bound as raw normalised planes and runs the PQ conversion; other formats are dropped. The HDR setting,
//  headroom, output policy and encoding gamma are captured once per stream (StreamContext, VideoStreamGate), and
//  pipeline builds snapshot one generation's inputs; stale-generation builds are discarded (VideoPipelineSlot).
//

import CoreVideo
import Foundation
import simd

enum HDRPipeline {
    // hdr.reference_white_nits default shared with the server (decision 63; ITU-R BT.2408): PQ 203 nits = EDR 1.0.
    static let referenceWhiteNits: Double = 203

    // Assumed display headroom (peak / SDR white) until the device measures it; ALVRHDRHeadroom overrides it.
    static let assumedHeadroom: Float = 2
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

    // PQ needs the explicit plane path whatever the HDR setting (the private *_sRGB YCbCr samplers apply the sRGB EOTF
    // themselves), so the decoder is asked for 10-bit biplanar planes. transfer is the CMFormatDescription
    // TransferFunction extension value.
    static func requiresExplicitPlanes(transfer: String?) -> Bool {
        transfer == "SMPTE_ST_2084_PQ"
    }

    // Code depth a PQ frame's planes bind at as raw normalised codes (decision 63e (1)): 8 for 8-bit biplanar
    // (r8Unorm/rg8Unorm), 10 for the CV 10-bit biplanar formats (r16Unorm/rg16Unorm, codes in the MSBs). nil for packed,
    // private or unknown formats, which have no raw plane binding: those frames are dropped.
    static func pqPlaneBitDepth(pixelFormat: OSType) -> Int? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange:
            return 8
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return 10
        default:
            return nil
        }
    }

    // Swift mirror of the video fragment shader for a stream colour state, with the constants Renderer builds from it
    // (gamut applied on Metal, and on RealityKit for PQ; the RealityKit SDR state carries an identity gamut).
    static func shade(sample: simd_float4, colour: StreamColourState) -> simd_float3 {
        let rgb = colour.yuvToRGB * sample
        if colour.hdrPQ {
            let scale = Float(10000 / referenceWhiteNits)
            func edr(_ e: Float) -> Float { Float(pqEOTF(Double(e)) / 10000) * scale }
            return rollOff(colour.gamutToOutput * simd_float3(edr(rgb.x), edr(rgb.y), edr(rgb.z)), headroom: colour.headroom)
        }
        let lin = simd_float3(ColourPipeline.srgbEOTF(rgb.x), ColourPipeline.srgbEOTF(rgb.y), ColourPipeline.srgbEOTF(rgb.z))
        let gamma = colour.encodingGamma
        return colour.gamutToOutput * simd_float3(ColourPipeline.encodingGammaToLinear(lin.x, gamma: gamma),
                                                  ColourPipeline.encodingGammaToLinear(lin.y, gamma: gamma),
                                                  ColourPipeline.encodingGammaToLinear(lin.z, gamma: gamma))
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

// Immutable inputs of one stream (decision 63e (2)), captured once at STREAMING_STARTED by VideoStreamGate: the HDR
// setting, the display headroom, the SDR output policy and the server's encoding gamma. Decode and render threads read
// only this, never the UI settings. generation increases with every stream start.
struct StreamContext: Equatable {
    let generation: UInt64
    let hdrEnabled: Bool
    let headroom: Float
    let output: ColourOutput
    let encodingGamma: Float
}

// How a frame's buffer is bound for the video shader.
enum VideoFrameBinding: Equatable {
    // PQ in a format with no raw plane binding (packed, private or unknown): never drawn.
    case drop
    // Raw normalised Y and CbCr planes: r8Unorm/rg8Unorm (8) or r16Unorm/rg16Unorm (10, codes in the MSBs).
    case explicitPlanes(bitDepth: Int)
    // SDR: the decoder's buffer bound as before (private *_sRGB formats on device).
    case decoderDefault
}

// Colour state of one stream's frames: a pure function of the frame's format description (selection), the plane depth
// its decoded pixel format binds at (HDRPipeline.pqPlaneBitDepth for PQ), the stream's captured context and the
// renderer. Never mutated; Renderer publishes it together with the pipelines built from it (VideoPipelineSlot).
struct StreamColourState: Equatable {
    let stream: StreamContext
    let selection: ColourSelection
    let binding: VideoFrameBinding
    // HDR_PQ shader path: PQ on raw planes of any depth (decision 63e (1)), with the HDR setting on or off.
    let hdrPQ: Bool
    // PQ frames with no raw plane binding: dropped, never drawn through another path.
    let dropFrames: Bool
    // 8-bit PQ planes: drawn on the PQ path, with one precision warning per stream.
    let lowPrecisionPQ: Bool
    // EDR roll-off limit: the stream's headroom with the HDR setting on, SDR range (1.0) with it off.
    let headroom: Float
    // GAMUT_TO_OUTPUT constants.
    let gamutToOutput: simd_float3x3

    var yuvToRGB: simd_float4x4 { selection.yuvToRGB }
    var encodingGamma: Float { stream.encodingGamma }

    init(selection: ColourSelection, planeBitDepth: Int?, stream: StreamContext, realityKit: Bool) {
        self.stream = stream
        self.selection = selection
        if selection.isPQ {
            if let bits = planeBitDepth {
                binding = .explicitPlanes(bitDepth: bits)
            } else {
                binding = .drop
            }
            hdrPQ = planeBitDepth != nil
            dropFrames = planeBitDepth == nil
            lowPrecisionPQ = planeBitDepth == 8
            // BT.2020 -> Display P3 on both renderers.
            gamutToOutput = selection.sourceToOutput
        } else {
            binding = .decoderDefault
            hdrPQ = false
            dropFrames = false
            lowPrecisionPQ = false
            // SDR: the previous constants exactly (RealityKit never set a gamut).
            gamutToOutput = realityKit ? matrix_identity_float3x3 : selection.sourceToOutput
        }
        headroom = stream.hdrEnabled ? stream.headroom : 1
    }
}

// The current stream and its generation (decision 63e (2), (3); the decision-61 ControllerInputGate pattern): one lock,
// a generation bumped at every stream start, and the stream's immutable context with its payload (the Renderer's
// foveation). VideoPipelineSlot runs every operation under the same lock, so a pipeline build's inputs come from one
// generation and a build whose generation is stale is discarded. beforeLock/inLock are test seams called with the
// entry name just before and just after the lock is taken.
final class VideoStreamGate<Payload> {
    private let lock = NSLock()
    private let beforeLock: ((String) -> Void)?
    private let inLock: ((String) -> Void)?
    private var generation: UInt64 = 0
    private var stream: (context: StreamContext, payload: Payload)?

    init(beforeLock: ((String) -> Void)? = nil, inLock: ((String) -> Void)? = nil) {
        self.beforeLock = beforeLock
        self.inLock = inLock
    }

    func locked<T>(_ entry: String, _ body: () -> T) -> T {
        beforeLock?(entry)
        lock.lock()
        defer { lock.unlock() }
        inLock?(entry)
        return body()
    }

    // STREAMING_STARTED: captures the stream's inputs once.
    @discardableResult
    func streamStarted(hdrEnabled: Bool, headroom: Float, output: ColourOutput, encodingGamma: Float, payload: Payload) -> StreamContext {
        locked("streamStarted") {
            generation += 1
            let context = StreamContext(generation: generation, hdrEnabled: hdrEnabled, headroom: headroom, output: output, encodingGamma: encodingGamma)
            stream = (context, payload)
            return context
        }
    }

    func streamStopped() {
        locked("streamStopped") { stream = nil }
    }

    var currentStream: StreamContext? {
        locked("currentStream") { stream?.context }
    }

    // Only inside locked(_:_:).
    var currentLocked: (context: StreamContext, payload: Payload)? { stream }
}

// Video pipelines published with the colour state, and so the stream generation, they were built for (decisions 63c
// (4), 63e (3)). A frame draws only with pipelines built for its own state on the current generation; a build for a
// state no longer requested, or for a stream that has since stopped or restarted, is discarded, never published.
final class VideoPipelineSlot<Payload, Pipelines> {
    private let gate: VideoStreamGate<Payload>
    private var requested: StreamColourState?
    private var published: (colour: StreamColourState, pipelines: Pipelines)?

    init(gate: VideoStreamGate<Payload>) {
        self.gate = gate
    }

    private func isCurrent(_ colour: StreamColourState) -> Bool {
        gate.currentLocked?.context.generation == colour.stream.generation
    }

    // Records the state the next build uses; true when it changed (the caller rebuilds). A stale-generation frame
    // never requests a build.
    func request(_ colour: StreamColourState) -> Bool {
        gate.locked("request") {
            guard isCurrent(colour), requested != colour else { return false }
            requested = colour
            return true
        }
    }

    // Everything a build needs, from one generation: the requested colour state (with its stream's gamma and
    // headroom) and that stream's payload. nil when nothing is requested for the current stream.
    func buildInputs() -> (colour: StreamColourState, payload: Payload)? {
        gate.locked("buildInputs") {
            guard let requested, isCurrent(requested), let current = gate.currentLocked else { return nil }
            return (requested, current.payload)
        }
    }

    func publish(_ pipelines: Pipelines, builtFor colour: StreamColourState) -> Bool {
        gate.locked("publish") {
            guard isCurrent(colour), requested == colour else { return false }
            published = (colour, pipelines)
            return true
        }
    }

    func pipelines(for colour: StreamColourState) -> Pipelines? {
        gate.locked("pipelines") {
            guard isCurrent(colour), let published, published.colour == colour else { return nil }
            return published.pipelines
        }
    }
}

// Probe cadence: at most one sample per 250 ms, measured from the last sample taken, on a monotonic clock
// (monotonicMs); a clock that steps back restarts the cadence instead of stalling it.
struct HDRProbeClock {
    static let intervalMs = 250
    private var lastMs: Int?

    static func monotonicMs(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        Int(uptime * 1000)
    }

    mutating func shouldSample(nowMs: Int) -> Bool {
        if let last = lastMs, nowMs >= last, nowMs - last < HDRProbeClock.intervalMs { return false }
        lastMs = nowMs
        return true
    }
}
