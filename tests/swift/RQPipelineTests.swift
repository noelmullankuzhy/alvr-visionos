// SOURCES: ALVRClient/Diagnostics/RQPipeline.swift
// METAL: ALVRClient/Shaders.metal
import Foundation
import Metal

@main enum RQPipelineTests {
    static func main() throws {
        let descriptor = RQPipeline.descriptor()
        expectEqual(descriptor.inputPrimitiveTopology, .triangle, "RQ pipeline topology")

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP RQPipeline GPU (Metal device unavailable)")
            finishTests("RQPipeline")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        do {
            _ = try device.makeRenderPipelineState(descriptor: RQPipeline.descriptor(library: library))
            expect(true, "RQ render pipeline creates on Metal device")
        } catch {
            expect(false, "RQ render pipeline creation failed: \(error)")
        }
        finishTests("RQPipeline")
    }
}
