// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagFrameCapture.swift ALVRClient/Diagnostics/DiagCapturePose.swift
// METAL: ALVRClient/Shaders.metal
// Sharpness-chain stages on the Mac GPU: diagStageVertexShader with one eye's uvRect at 1:1 reproduces that half of the
// source exactly (pixel centres on texel centres: the decoded stage adds no resample), and DiagFrameCapture.submit writes
// stage targets into capture.json "stages" (stage-<stage>-<eye>.png) with "resample_chain", never into "slices".
import Foundation
import Metal

@main enum DiagStreamStagesGPUTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            expect(false, "Metal device unavailable; GM must run DiagStreamStagesGPU outside sandbox")
            finishTests("DiagStreamStagesGPU")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let (w, h) = (16, 6)                                    // two 8x6 eyes side by side
        var src = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            src[i] = UInt8((x * 37 + y * 11) % 256); src[i + 1] = UInt8((x * 13 + y * 71) % 256); src[i + 2] = UInt8((x ^ y) * 9 % 256); src[i + 3] = 255
        } }
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        sd.usage = .shaderRead
        let source = device.makeTexture(descriptor: sd)!
        source.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: src, bytesPerRow: w * 4)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "diagStageVertexShader")
        pd.fragmentFunction = library.makeFunction(name: "hudFragmentShader")   // bilinear sample of texture 0, like the stream shaders
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pd)
        let plans = DiagStreamStages.plans(decodedWidth: w, decodedHeight: h, viewWidth: 12, viewHeight: 9, ffr: true).filter { $0.stage == "decoded" }
        let command = device.makeCommandQueue()!.makeCommandBuffer()!
        var targets: [DiagFrameCapture.Target] = []
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        dd.usage = [.shaderRead]
        let drawable = device.makeTexture(descriptor: dd)!
        drawable.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: src, bytesPerRow: w * 4)
        targets.append(.init(texture: drawable, views: [["eye": "L", "slice": 0, "view": 0, "viewport": [0, 0, w, h], "tangents": [1, 1, 1, 1]]],
                             rateMap: nil, drawableIndex: 0))
        var outputs: [MTLTexture] = []
        for plan in plans {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: plan.width, height: plan.height, mipmapped: false)
            td.usage = .renderTarget; td.storageMode = .shared
            let texture = device.makeTexture(descriptor: td)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            var rect = plan.uvRect
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            outputs.append(texture)
            targets.append(.init(texture: texture, views: [], rateMap: nil, drawableIndex: -1,
                                 stage: DiagStreamStages.record(plan, planes: [("rgba8Unorm", w, h)], shader: "hudFragmentShader", decoderPixelFormat: "test")))
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("gpu-stages")
        try? FileManager.default.removeItem(at: output)
        let done = DispatchSemaphore(value: 0)
        DiagFrameCapture.submit(buffer: command, targets: targets, directory: output, metadata: ["trigger": ["reason": "test"]]) { success in
            expect(success, "capture writer completed")
            done.signal()
        }
        command.commit()
        expect(done.wait(timeout: .now() + 60) == .success, "capture completes asynchronously")
        for (plan, texture) in zip(plans, outputs) {
            var got = [UInt8](repeating: 0, count: plan.width * plan.height * 4)
            texture.getBytes(&got, bytesPerRow: plan.width * 4, from: MTLRegionMake2D(0, 0, plan.width, plan.height), mipmapLevel: 0)
            let x0 = plan.eye == "L" ? 0 : w / 2
            var want: [UInt8] = []
            for y in 0..<h { want += src[((y * w + x0) * 4)..<((y * w + x0 + w / 2) * 4)] }
            expectEqual(got, want, "\(plan.eye): decoded stage reproduces the eye's half exactly (1:1, no resample)")
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("capture.json")))) as? [String: Any] ?? [:]
        let slices = json["slices"] as? [[String: Any]] ?? []
        let stages = json["stages"] as? [[String: Any]] ?? []
        expectEqual(slices.count, 1, "only the drawable is a slice")
        expectEqual(stages.compactMap { $0["png"] as? String }, ["stage-decoded-L.png", "stage-decoded-R.png"], "stage PNG names")
        for stage in stages {
            for key in ["stage", "eye", "png", "width", "height", "pixel_format", "sampler", "source", "encoding"] {
                expect(stage[key] != nil, "stage entry has \(key)")
            }
            expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(stage["png"] as? String ?? "-").path), "stage PNG written")
        }
        expectEqual((json["resample_chain"] as? [[String: Any]])?.count, 3, "resample_chain recorded with stages")
        finishTests("DiagStreamStagesGPU")
    }
}
