// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/EDRDiagnostic.swift ALVRClient/Diagnostics/EDRRenderer.swift
// METAL: ALVRClient/Shaders.metal
// Exercise the app's encoder, shaders, attachment setup and depth state with independent pixel goldens.
import Foundation
import Metal
import simd

@main enum EDRGPUTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            expect(false, "Metal device unavailable in this sandbox; GM must run the GPU tests")
            finishTests("EDRGPU")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let drawing = try EDRDrawing(device: device, library: library)
        let queue = device.makeCommandQueue()!
        let width = 224, height = 192
        func texture(_ format: MTLPixelFormat) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = 2
            descriptor.usage = .renderTarget
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)!
        }
        let colour = texture(.rgba16Float), depth = texture(.depth32Float)
        let viewport = MTLViewport(originX: 8, originY: 12, width: 200, height: 160, znear: 0, zfar: 1)
        // Right-up-back reverse-Z projection: near=0.1, far=100 metres.
        let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                               SIMD4(0, 0, 0.1 / 99.9, -1), SIMD4(0, 0, 10 / 99.9, 0)))
        let expectedDepth: Float = 0.1 * (100 - 2) / (2 * (100 - 0.1)) // two-metre plane
        func render(_ layout: EDRLayout, _ value: Float, slice: Int, projection: simd_float4x4) {
            let buffer = queue.makeCommandBuffer()!
            drawing.encode(buffer: buffer, colour: colour, depth: depth, slice: slice, viewport: viewport,
                           patches: layout.patches(value: value), projection: projection)
            buffer.commit(); buffer.waitUntilCompleted()
            expect(buffer.error == nil, "GPU completed: \(String(describing: buffer.error))")
        }
        // Other array slice must survive every pass; offset viewport catches viewport-origin mistakes.
        render(.full, 0.25, slice: 0, projection: projection)
        for layout in EDRLayout.allCases {
            render(layout, 4, slice: 1, projection: projection)
            var pixels = [UInt16](repeating: 0, count: width * height * 4)
            var depths = [Float](repeating: -1, count: width * height)
            pixels.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: width * 8, bytesPerImage: width * height * 8,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: 1)
            }
            depths.withUnsafeMutableBytes {
                depth.getBytes($0.baseAddress!, bytesPerRow: width * 4, bytesPerImage: width * height * 4,
                               from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, slice: 1)
            }
            var bright = 0
            for y in 0..<height {
                for x in 0..<width {
                    let u = (Double(x) + 0.5 - 8) / 200, v = (Double(y) + 0.5 - 12) / 160
                    let inside = u >= 0 && u < 1 && v >= 0 && v < 1
                    var expected: Float = 0
                    if inside {
                        switch layout {
                        case .onePercent: expected = abs(u - 0.5) < 0.05 && abs(v - 0.5) < 0.05 ? 4 : 0
                        case .tenPercent: expected = abs(u - 0.5) < sqrt(0.1) / 2 && abs(v - 0.5) < sqrt(0.1) / 2 ? 4 : 0
                        case .full: expected = 4
                        case .split: expected = u < 0.5 ? 1 : 4
                        case .checkerboard: expected = (Int(u * 8) + Int(v * 8)) % 2 == 0 ? 0 : 4
                        }
                    }
                    if expected == 4 { bright += 1 }
                    let pixel = y * width + x
                    for channel in 0..<4 {
                        let golden: Float = channel == 3 ? (inside ? 1 : 0) : expected
                        expectEqual(Float(Float16(bitPattern: pixels[pixel * 4 + channel])), golden, "\(layout) pixel \(x),\(y) channel \(channel)")
                    }
                    expect(abs(depths[pixel] - (inside ? expectedDepth : 0)) < 1e-6,
                           "\(layout) finite reverse-Z at \(x),\(y), including black surround: \(depths[pixel])")
                }
            }
            if layout == .onePercent { expectEqual(bright, 320, "1% of the 200×160 viewport") }
            var otherColour = [UInt16](repeating: 0, count: 4)
            var otherDepth: Float = 0
            otherColour.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: 8, bytesPerImage: 8, from: MTLRegionMake2D(100, 80, 1, 1), mipmapLevel: 0, slice: 0)
            }
            depth.getBytes(&otherDepth, bytesPerRow: 4, bytesPerImage: 4, from: MTLRegionMake2D(100, 80, 1, 1), mipmapLevel: 0, slice: 0)
            expectEqual(Float(Float16(bitPattern: otherColour[0])), 0.25, "other eye colour survives")
            expect(abs(otherDepth - expectedDepth) < 1e-6, "other eye depth survives")
        }
        // The shader must receive each current projection, rather than a fixed raw depth.
        let infiniteProjection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                                       SIMD4(0, 0, 0, -1), SIMD4(0, 0, 0.05, 0)))
        for level: Float in [0, 0.25, 0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 4] {
            render(.full, level, slice: 1, projection: infiniteProjection)
            var pixel = [UInt16](repeating: 0, count: 4)
            var z: Float = 0
            pixel.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: 8, bytesPerImage: 8, from: MTLRegionMake2D(100, 80, 1, 1), mipmapLevel: 0, slice: 1)
            }
            depth.getBytes(&z, bytesPerRow: 4, bytesPerImage: 4, from: MTLRegionMake2D(100, 80, 1, 1), mipmapLevel: 0, slice: 1)
            for channel in 0..<4 { expectEqual(Float(Float16(bitPattern: pixel[channel])), channel == 3 ? 1 : level, "raw ramp \(level)") }
            expect(abs(z - 0.025) < 1e-6, "updated projection, near/distance = 0.05/2")
        }
        finishTests("EDRGPU")
    }
}
