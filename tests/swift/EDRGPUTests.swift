// SOURCES:
// METAL: ALVRClient/Shaders.metal
// Execute the production ramp fragment into rgba16Float, including levels beyond stream headroom.
import Foundation
import Metal

@main enum EDRGPUTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            expect(false, "Metal device unavailable in this sandbox; GM must run the GPU tests")
            finishTests("EDRGPU")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "diagEDRVertex")
        desc.fragmentFunction = library.makeFunction(name: "diagEDRFragment")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false)
        textureDesc.usage = .renderTarget
        textureDesc.storageMode = .shared
        let texture = device.makeTexture(descriptor: textureDesc)!
        let queue = device.makeCommandQueue()!
        for level: Float in [0, 0.25, 0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 4] {
            let buffer = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            var value = level
            encoder.setFragmentBytes(&value, length: 4, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            buffer.commit(); buffer.waitUntilCompleted()
            expect(buffer.error == nil, "GPU completed: \(String(describing: buffer.error))")
            var pixels = [UInt16](repeating: 0, count: 16)
            pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0) }
            for pixel in 0..<4 {
                for channel in 0..<4 {
                    expectEqual(Float(Float16(bitPattern: pixels[pixel * 4 + channel])), channel == 3 ? 1 : level, "raw ramp \(level), alpha=1")
                }
            }
        }
        finishTests("EDRGPU")
    }
}
