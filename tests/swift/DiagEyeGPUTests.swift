// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagEye.swift ALVRClient/Diagnostics/DiagEyeRenderer.swift ALVRClient/Diagnostics/EDRDiagnostic.swift ALVRClient/Diagnostics/EDRRenderer.swift
// METAL: ALVRClient/Shaders.metal
import Foundation
import Metal
import simd

@main enum DiagEyeGPUTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            expect(false, "Metal device unavailable in this sandbox; GM must run DiagEyeGPU")
            finishTests("DiagEyeGPU")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let badge = try DiagEyeDrawing(device: device, library: library, colourFormat: .rgba16Float, depthFormat: .depth32Float)
        let ramp = try EDRDrawing(device: device, library: library)
        let queue = device.makeCommandQueue()!
        let size = 512
        func texture(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
            d.textureType = .type2DArray; d.arrayLength = 2; d.usage = .renderTarget
            d.storageMode = format == .depth32Float ? .private : .shared
            return device.makeTexture(descriptor: d)!
        }
        let colour = texture(.rgba16Float), depth = texture(.depth32Float)
        let viewport = MTLViewport(originX: 32, originY: 48, width: 448, height: 400, znear: 0, zfar: 1)
        let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0.1 / 99.9, -1), SIMD4(0, 0, 10 / 99.9, 0)))
        let placement = DiagEye.placement(tangents: SIMD4(1, 1, 1, 1))
        for layout in EDRLayout.allCases {
            let buffer = queue.makeCommandBuffer()!
            for (slice, eye) in [DiagEye.left, .right].enumerated() {
                ramp.encode(buffer: buffer, colour: colour, depth: depth, slice: slice, viewport: viewport, patches: layout.patches(value: 4), projection: projection)
                badge.encode(buffer: buffer, colour: colour, depth: depth, slice: slice, viewport: viewport, placement: placement, eye: eye, projection: projection)
            }
            buffer.commit(); buffer.waitUntilCompleted()
            expect(buffer.error == nil, "both eyes complete")
            for (slice, eye) in [DiagEye.left, .right].enumerated() {
                var pixels = [UInt16](repeating: 0, count: size * size * 4)
                pixels.withUnsafeMutableBytes {
                    colour.getBytes($0.baseAddress!, bytesPerRow: size * 8, bytesPerImage: size * size * 8, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: slice)
                }
                var cyanOrMagenta = 0, black = 0
                for y in 0..<size {
                    for x in 0..<size {
                        let u = (Double(x) + 0.5 - viewport.originX) / viewport.width
                        let v = (Double(y) + 0.5 - viewport.originY) / viewport.height
                        let r = placement.rect
                        let inside = u >= r.x && u < r.x + r.z && v >= r.y && v < r.y + r.w
                        let base = (y * size + x) * 4
                        let rgb = SIMD3(Float(Float16(bitPattern: pixels[base])), Float(Float16(bitPattern: pixels[base + 1])), Float(Float16(bitPattern: pixels[base + 2])))
                        if inside {
                            expect(rgb == SIMD3(eye.colour.x, eye.colour.y, eye.colour.z) || rgb == .zero, "solid SDR badge or black glyph, never EDR")
                            if rgb == .zero { black += 1 } else { cyanOrMagenta += 1 }
                        } else if u >= 0 && u < 1 && v >= 0 && v < 1 {
                            let patch = layout.patches(value: 4).last { u >= $0.x && u < $0.x + $0.width && v >= $0.y && v < $0.y + $0.height }
                            expectEqual(rgb, SIMD3(repeating: patch?.value ?? 0), "all pixels outside badge preserved, including 1% patch")
                        }
                    }
                }
                expect(cyanOrMagenta > 10 && black > 3, "visible solid colour and glyph in each eye")
            }
        }
        finishTests("DiagEyeGPU")
    }
}
