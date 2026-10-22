// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagFrameCapture.swift ALVRClient/Diagnostics/DiagCapturePose.swift ALVRClient/Diagnostics/CornerChart.swift
// METAL: ALVRClient/Shaders.metal
import Foundation
import Metal

@main enum DiagCaptureGPUTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            expect(false, "Metal device unavailable; GM must run DiagCaptureGPU outside sandbox")
            finishTests("DiagCaptureGPU")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let layer = MTLRasterizationRateLayerDescriptor(sampleCount: MTLSize(width: 3, height: 3, depth: 1))
        for i in 0..<3 {
            layer.horizontal[i] = i == 1 ? 1 : 0.55
            layer.vertical[i] = i == 1 ? 1 : 0.65
        }
        let screen = MTLSize(width: 1600, height: 1400, depth: 1)
        let descriptor = MTLRasterizationRateMapDescriptor(screenSize: screen, layers: [layer, layer])
        guard let map = device.makeRasterizationRateMap(descriptor: descriptor) else {
            expect(false, "real two-layer rate map required")
            finishTests("DiagCaptureGPU")
        }
        let size = map.physicalSize(layer: 0)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false)
        td.textureType = .type2DArray; td.arrayLength = 2; td.storageMode = .private; td.usage = .renderTarget
        let texture = device.makeTexture(descriptor: td)!
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "cornerChartVertexShader")
        pd.fragmentFunction = library.makeFunction(name: "cornerChartFragmentShader")
        pd.colorAttachments[0].pixelFormat = .rgba16Float
        pd.maxVertexAmplificationCount = 2
        let pipeline = try device.makeRenderPipelineState(descriptor: pd)
        let tangents = CornerTangents(left: 1.1, right: 0.9, bottom: 0.85, top: 1.15)
        var vertices: [SIMD4<Float>] = []
        var views: [[String: Any]] = []
        for (slice, eye) in [CornerEye.left, .right].enumerated() {
            let scale: CornerChart.LocalScale = { x, y in
                let sx = Float((x + 1) * Double(screen.width) / 2), sy = Float((1 - y) * Double(screen.height) / 2)
                let x0 = max(0, sx - 1), x1 = min(Float(screen.width), sx + 1)
                let y0 = max(0, sy - 1), y1 = min(Float(screen.height), sy + 1)
                let a = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: x0, y: sy), layer: slice)
                let b = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: x1, y: sy), layer: slice)
                let c = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: sx, y: y0), layer: slice)
                let d = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: sx, y: y1), layer: slice)
                return (Double((b.x - a.x) / (x1 - x0)), Double((d.y - c.y) / (y1 - y0)))
            }
            for quad in CornerChart.geometry(tangents, eye: eye, widthPx: Double(screen.width), heightPx: Double(screen.height), selected: nil, status: "", localScale: scale) {
                let points = quad.vertices
                for i in [0, 1, 2, 1, 3, 2] {
                    vertices += [SIMD4(Float(points[i].x), Float(points[i].y), Float(slice), 0), quad.color]
                }
            }
            views.append(["eye": eye.rawValue, "slice": slice, "view": slice, "viewport": [0, 0, screen.width, screen.height], "tangents": [1.1, 0.9, 0.85, 1.15]])
        }
        let vb = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride)!
        let command = device.makeCommandQueue()!.makeCommandBuffer()!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.renderTargetArrayLength = 2; pass.rasterizationRateMap = map
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        let vp = MTLViewport(originX: 0, originY: 0, width: Double(screen.width), height: Double(screen.height), znear: 0, zfar: 1)
        encoder.setViewports([vp, vp])
        var mappings = [MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0), MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: 1)]
        encoder.setVertexAmplificationCount(2, viewMappings: &mappings)
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 2)
        encoder.endEncoding()
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("gpu-capture")
        try? FileManager.default.removeItem(at: output)
        let done = DispatchSemaphore(value: 0)
        DiagFrameCapture.submit(buffer: command, targets: [.init(texture: texture, views: views, rateMap: map, drawableIndex: 0)], directory: output,
                                metadata: ["corner_chart": ["mode": "Both eyes", "ring_percents": CornerChart.ringPercents, "cut_percents": CornerChart.cutPercents, "ring_stroke_alignment": "center"]]) { success in
            expect(success, "capture writer completed")
            done.signal()
        }
        command.commit()
        expect(done.wait(timeout: .now() + 60) == .success, "capture completes asynchronously")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["tools/diag/verify-capture.py", output.path]
        try process.run(); process.waitUntilExit()
        expectEqual(process.terminationStatus, 0, "real chart through real nonlinear rate map verifies")
        finishTests("DiagCaptureGPU")
    }
}
