// SOURCES: ALVRClient/ColourPipeline.swift ALVRClient/HDRPipeline.swift
// METAL: tests/swift/HDRGPUKernel.metal
// GPU goldens (GM decision 63c (5)): the shader's video colour conversion (ALVRClient/VideoColour.h, shared with
// Shaders.metal) runs on the Mac GPU with the constants the app derives (ColourPipeline.select -> StreamColourState),
// reading 10-bit codes from r16Unorm/rg16Unorm planes (codes in the MSBs, as kCVPixelFormatType_420YpCbCr10BiPlanar*)
// and 8-bit codes from r8Unorm/rg8Unorm. Goldens are independent of the app's maths: EDR values computed separately
// in double precision from SMPTE ST 2084 and BT.2020 NCL for the rounded codes below, the published BT.2020 ->
// Display P3 matrix, and the sRGB EOTF for SDR grey codes.
// run-tests.sh compiles the METAL file to a metallib and passes its path as the first argument.
import Foundation
import Metal
import simd

// Layout matches VideoColourTestParams in HDRGPUKernel.metal.
struct KernelParams {
    var yuvTransform: simd_float4x4
    var gamutToOutput: simd_float3x3
    var pqScale: Float
    var encodingGamma: Float
    var headroom: Float
    var hdrPQ: UInt32
    var applyGamut: UInt32
}

struct GPU {
    let device: MTLDevice
    let pipeline: MTLComputePipelineState
    let queue: MTLCommandQueue

    // codes: (Y, Cb, Cr) at bits 10 (r16Unorm planes, code << 6) or 8 (r8Unorm planes).
    func run(codes: [simd_int3], bits: Int, params: KernelParams) -> [simd_float3] {
        let n = codes.count
        func plane(_ format: MTLPixelFormat, _ values: [Int32]) -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: values.count / (format == .r16Unorm || format == .r8Unorm ? 1 : 2), height: 1, mipmapped: false)
            desc.usage = .shaderRead
            let texture = device.makeTexture(descriptor: desc)!
            let width = desc.width
            if bits == 10 {
                let words = values.map { UInt16($0 << 6) }
                words.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: $0.count) }
            } else {
                let bytes = values.map { UInt8($0) }
                bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: $0.count) }
            }
            return texture
        }
        let luma = plane(bits == 10 ? .r16Unorm : .r8Unorm, codes.map { $0.x })
        let chroma = plane(bits == 10 ? .rg16Unorm : .rg8Unorm, codes.flatMap { [$0.y, $0.z] })
        let out = device.makeBuffer(length: n * MemoryLayout<simd_float4>.stride, options: .storageModeShared)!
        var p = params
        let commands = queue.makeCommandBuffer()!
        let encoder = commands.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setBuffer(out, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<KernelParams>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let values = out.contents().bindMemory(to: simd_float4.self, capacity: n)
        return (0..<n).map { simd_float3(values[$0].x, values[$0].y, values[$0].z) }
    }
}

// The constants Renderer.buildRenderPipelineForVideoFrameWithDevice sets for this stream state; applyGamut mirrors
// Shaders.metal videoFrameFragmentShader_output (!REALITYKIT_ENABLED || HDR_PQ).
func params(_ s: StreamColourState, realityKit: Bool, encodingGamma: Float, headroom: Float) -> KernelParams {
    KernelParams(yuvTransform: s.yuvToRGB, gamutToOutput: s.gamutToOutput, pqScale: Float(10000 / HDRPipeline.referenceWhiteNits),
                 encodingGamma: encodingGamma, headroom: headroom, hdrPQ: s.hdrPQ ? 1 : 0, applyGamut: (!realityKit || s.hdrPQ) ? 1 : 0)
}

func close(_ got: simd_float3, _ expected: simd_float3, abs absTol: Float, rel: Float) -> Bool {
    let d = simd_abs(got - expected)
    let tol = simd_float3(repeating: absTol) + rel * simd_abs(expected)
    return d.x <= tol.x && d.y <= tol.y && d.z <= tol.z
}

@main
enum HDRGPUTests {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            expect(false, "metallib path argument (run through tests/swift/run-tests.sh)")
            finishTests("HDRGPUTests")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            expect(false, "a Metal device")
            finishTests("HDRGPUTests")
        }
        let library = try! device.makeLibrary(URL: URL(fileURLWithPath: args[1]))
        let pipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "videoColourTestKernel")!)
        let gpu = GPU(device: device, pipeline: pipeline, queue: device.makeCommandQueue()!)
        print("HDRGPUTests on \(device.name)")
        testPQNeutral(gpu)
        testBT2020Primaries(gpu)
        testSDRPassthrough(gpu)
        finishTests("HDRGPUTests")
    }

    static func pqState(realityKit: Bool) -> StreamColourState {
        let s = ColourPipeline.select(primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020", fullRange: false, bitDepth: 10, planeBitDepth: 10, output: .srgb)
        return StreamColourState(selection: s, planeBitDepth: 10, hdrEnabled: true, realityKit: realityKit)
    }

    // PQ neutral greys, BT.2020 NCL limited 10-bit codes 509/573/723 (100/203/1000 nits nominal). Golden EDR values of
    // the rounded codes: 99.913/203.703/1004.192 nits over 203.
    static func testPQNeutral(_ gpu: GPU) {
        let codes = [simd_int3(509, 512, 512), simd_int3(573, 512, 512), simd_int3(723, 512, 512)]
        let golden: [Float] = [0.492181, 1.003463, 4.946758]
        for realityKit in [false, true] {
            let out = gpu.run(codes: codes, bits: 10, params: params(pqState(realityKit: realityKit), realityKit: realityKit, encodingGamma: 2.2, headroom: 100))
            for (i, g) in golden.enumerated() {
                expect(close(out[i], simd_float3(repeating: g), abs: 1e-4, rel: 2e-3), "PQ neutral code \(codes[i].x) -> EDR \(g) (realityKit \(realityKit)), got \(out[i])")
            }
            // Within 1% of the nominal 100/203/1000 nits.
            for (i, nits) in [100.0, 203.0, 1000.0].enumerated() {
                expect(abs(Double(out[i].x) * 203 / nits - 1) < 0.01, "code \(codes[i].x) ~ \(nits) nits, got \(Double(out[i].x) * 203)")
            }
            // At the assumed 2.0 headroom 1000 nits rolls off to 2 - 0.5 exp(-(4.946758 - 1.5) / 0.5) = 1.999491.
            let rolled = gpu.run(codes: [codes[2], codes[1]], bits: 10, params: params(pqState(realityKit: realityKit), realityKit: realityKit, encodingGamma: 2.2, headroom: HDRPipeline.assumedHeadroom))
            expect(close(rolled[0], simd_float3(repeating: 1.999491), abs: 2e-4, rel: 0), "1000 nits at headroom 2 -> 1.999491, got \(rolled[0])")
            expect(close(rolled[1], simd_float3(repeating: 1.003463), abs: 1e-4, rel: 2e-3), "203 nits below the knee unchanged at headroom 2, got \(rolled[1])")
        }
    }

    // Pure BT.2020 primaries at 203 nits (R'/G'/B' = PQ(203)), rounded codes; golden EDR of the decoded primary
    // channel times the published BT.2020 -> Display P3 column.
    static func testBT2020Primaries(_ gpu: GPU) {
        let cases: [(String, simd_int3, Float, simd_float3)] = [
            ("red", simd_int3(198, 439, 772), 1.001690, simd_float3(1.3435, -0.0653, 0.0028)),
            ("green", simd_int3(409, 325, 273), 0.998979, simd_float3(-0.2822, 1.0758, -0.0196)),
            ("blue", simd_int3(94, 772, 491), 0.995224, simd_float3(-0.0613, -0.0105, 1.0168)),
        ]
        for realityKit in [false, true] {
            let out = gpu.run(codes: cases.map { $0.1 }, bits: 10, params: params(pqState(realityKit: realityKit), realityKit: realityKit, encodingGamma: 2.2, headroom: 100))
            for (i, c) in cases.enumerated() {
                let expected = c.3 * c.2
                expect(close(out[i], expected, abs: 2e-3, rel: 2e-3), "BT.2020 \(c.0) -> linear P3 \(expected) (realityKit \(realityKit)), got \(out[i])")
            }
        }
    }

    // SDR (BT.709 limited 8-bit, HDR setting on or off): the explicit-plane path is unchanged. Grey codes decode to
    // the sRGB EOTF of (code - 16) / 219; a colour sample matches the pre-HDR formula (sRGB EOTF -> encoding gamma ->
    // ColourOutput matrix on Metal, no matrix on RealityKit).
    static func testSDRPassthrough(_ gpu: GPU) {
        let greys = [simd_int3(16, 128, 128), simd_int3(126, 128, 128), simd_int3(180, 128, 128), simd_int3(235, 128, 128)]
        let golden: [Float] = [0, 0.216160, 0.520745, 1]
        for hdr in [false, true] {
            for output in [ColourOutput.srgb, .p3] {
                let s = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2", fullRange: false, bitDepth: 8, planeBitDepth: 8, output: output)
                for realityKit in [false, true] {
                    let state = StreamColourState(selection: s, planeBitDepth: 8, hdrEnabled: hdr, realityKit: realityKit)
                    let out = gpu.run(codes: greys, bits: 8, params: params(state, realityKit: realityKit, encodingGamma: 1, headroom: 2))
                    for (i, g) in golden.enumerated() {
                        expect(close(out[i], simd_float3(repeating: g), abs: 2e-3, rel: 2e-3), "SDR grey \(greys[i].x) -> \(g) (\(output), realityKit \(realityKit), hdr \(hdr)), got \(out[i])")
                    }
                    let colour = simd_int3(150, 90, 200)
                    let gamma: Float = 1.5
                    let got = gpu.run(codes: [colour], bits: 8, params: params(state, realityKit: realityKit, encodingGamma: gamma, headroom: 2))[0]
                    let rgb = s.yuvToRGB * simd_float4(Float(colour.x) / 255, Float(colour.y) / 255, Float(colour.z) / 255, 1)
                    let lin = simd_float3(ColourPipeline.srgbEOTF(rgb.x), ColourPipeline.srgbEOTF(rgb.y), ColourPipeline.srgbEOTF(rgb.z))
                    let src = simd_float3(ColourPipeline.encodingGammaToLinear(lin.x, gamma: gamma), ColourPipeline.encodingGammaToLinear(lin.y, gamma: gamma), ColourPipeline.encodingGammaToLinear(lin.z, gamma: gamma))
                    let expected = realityKit ? src : s.sourceToOutput * src
                    expect(close(got, expected, abs: 1e-4, rel: 1e-3), "SDR colour (\(output), realityKit \(realityKit), hdr \(hdr)) \(expected), got \(got)")
                }
            }
        }
    }
}
