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
            descriptor.storageMode = format == .depth32Float ? .private : .shared
            return device.makeTexture(descriptor: descriptor)!
        }
        let colour = texture(.rgba16Float), depth = texture(.depth32Float)
        let viewport = MTLViewport(originX: 8, originY: 12, width: 200, height: 160, znear: 0, zfar: 1)
        // Right-up-back reverse-Z projection: near=0.1, far=100 metres.
        let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                               SIMD4(0.12, 0.04, 0.1 / 99.9, -1), SIMD4(0, 0, 10 / 99.9, 0)))
        let expectedDepth: Float = 0.1 * (100 - 2) / (2 * (100 - 0.1)) // two-metre plane
        func render(_ layout: EDRLayout, _ value: Float, slice: Int, projection: simd_float4x4,
                    grid: EDRGrid = EDRGrid()) {
            let buffer = queue.makeCommandBuffer()!
            drawing.encode(buffer: buffer, colour: colour, depth: depth, slice: slice, viewport: viewport,
                           patches: layout.patches(value: value,
                                                   centre: EDRView.centre(projectionX: Double(projection.columns.2.x),
                                                                          projectionY: Double(projection.columns.2.y)),
                                                   aspect: viewport.width / viewport.height, grid: grid,
                                                   pixelHeight: viewport.height), projection: projection)
            buffer.commit(); buffer.waitUntilCompleted()
            expect(buffer.error == nil, "GPU completed: \(String(describing: buffer.error))")
        }
        // Depth textures stay private; blit into a shared buffer with aligned rows for CPU inspection.
        func readDepth(slice: Int) -> [Float] {
            let rowBytes = 1024
            let readback = device.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
            let buffer = queue.makeCommandBuffer()!
            let blit = buffer.makeBlitCommandEncoder()!
            blit.copy(from: depth, sourceSlice: slice, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                      destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
            blit.endEncoding(); buffer.commit(); buffer.waitUntilCompleted()
            expect(buffer.error == nil, "depth readback completed")
            let values = readback.contents().assumingMemoryBound(to: Float.self)
            return (0..<height).flatMap { row in Array(UnsafeBufferPointer(start: values + row * rowBytes / 4, count: width)) }
        }
        // Other array slice must survive every pass; offset viewport catches viewport-origin mistakes.
        render(.full, 0.25, slice: 0, projection: projection)
        // Independent straight-ahead golden: projection offsets (0.12, 0.04) give viewport (0.44, 0.52).
        // Explicit row-major indices along the snake, independent of EDRGrid.entries.
        let snake = [[0, 1, 2, 3, 4], [9, 8, 7, 6, 5], [10, 11, 12, 13, 14],
                     [19, 18, 17, 16, 15], [20, 21, 22, 23, 24]]
        // Every layout, plus both ranges and mirror directions for every grid area.
        var cases = EDRLayout.allCases.map { ($0, EDRGrid()) }
        for layout in [EDRLayout.gridOne, .gridTen, .gridFifty] {
            for range in EDRGridRange.allCases {
                for mirror in [false, true] where range != .fine || mirror {
                    cases.append((layout, EDRGrid(range: range, mirror: mirror)))
                }
            }
        }
        for (layout, grid) in cases {
            let context = "\(layout.rawValue) \(grid.range.rawValue) mirror=\(grid.mirror)"
            render(layout, 4, slice: 1, projection: projection, grid: grid)
            var pixels = [UInt16](repeating: 0, count: width * height * 4)
            let depths = readDepth(slice: 1)
            pixels.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: width * 8, bytesPerImage: width * height * 8,
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
                        case .pairOne, .pairFive, .pairTwenty:
                            // Independent total-area goldens, pixel-square geometry in a 200x160 viewport.
                            let area = layout == .pairOne ? 0.01 : layout == .pairFive ? 0.05 : 0.20
                            let side = sqrt(area * 200 * 160 / 2)
                            let dx = (u - 0.44) * 200, dy = (v - 0.52) * 160
                            if abs(dy) < side / 2 {
                                if dx >= -1.5 * side && dx < -0.5 * side { expected = 1 }
                                if dx >= 0.5 * side && dx < 1.5 * side { expected = 4 }
                            }
                        case .gridOne, .gridTen, .gridFifty:
                            let area = layout == .gridOne ? 0.01 : layout == .gridTen ? 0.10 : 0.50
                            let side = sqrt(area * 200 * 160 / 25)
                            let pitch = side + 2 // exactly two physical pixels of black between cells
                            let dx = (u - 0.44) * 200, dy = (v - 0.52) * 160
                            for row in 0..<5 {
                                for column in 0..<5 {
                                    let cellX = Double(column - 2) * pitch, cellY = Double(row - 2) * pitch
                                    if abs(dx - cellX) < side / 2 && abs(dy - cellY) < side / 2 {
                                        let index = grid.mirror ? 24 - snake[row][column] : snake[row][column]
                                        expected = Float(grid.range == .fine ? 1 + Double(index) / 24 : 0.5 + Double(index) / 10)
                                    }
                                }
                            }
                        }
                    }
                    if expected == 4 { bright += 1 }
                    let pixel = y * width + x
                    for channel in 0..<4 {
                        // rgba16Float stores the submitted Float rounded to binary16, including 1/24 grid levels.
                        let golden: Float = channel == 3 ? (inside ? 1 : 0) : Float(Float16(expected))
                        expectEqual(Float(Float16(bitPattern: pixels[pixel * 4 + channel])), golden, "\(context) pixel \(x),\(y) channel \(channel)")
                    }
                    expect(abs(depths[pixel] - (inside ? expectedDepth : 0)) < 1e-6,
                           "\(context) finite reverse-Z at \(x),\(y), including black surround: \(depths[pixel])")
                }
            }
            if layout == .onePercent { expectEqual(bright, 320, "1% of the 200×160 viewport") }
            var otherColour = [UInt16](repeating: 0, count: 4)
            let otherDepth = readDepth(slice: 0)[80 * width + 100]
            otherColour.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: 8, bytesPerImage: 8, from: MTLRegionMake2D(100, 80, 1, 1), mipmapLevel: 0, slice: 0)
            }
            expectEqual(Float(Float16(bitPattern: otherColour[0])), 0.25, "other eye colour survives")
            expect(abs(otherDepth - expectedDepth) < 1e-6, "other eye depth survives")
        }
        // The shader must receive each current projection, rather than a fixed raw depth.
        let infiniteProjection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                                       SIMD4(0, 0, 0, -1), SIMD4(0, 0, 0.05, 0)))
        let levels = Set(EDRStep.values + EDRStep.fineValues + EDRGrid().entries.map(\.value)
                         + EDRGrid(range: .coarse).entries.map(\.value)).sorted()
        for level in levels {
            render(.full, level, slice: 1, projection: infiniteProjection)
            var pixel = [UInt16](repeating: 0, count: 4)
            let z = readDepth(slice: 1)[80 * width + 100]
            pixel.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: 8, bytesPerImage: 8, from: MTLRegionMake2D(100, 80, 1, 1), mipmapLevel: 0, slice: 1)
            }
            for channel in 0..<4 { expectEqual(Float(Float16(bitPattern: pixel[channel])), channel == 3 ? 1 : Float(Float16(level)), "raw ramp \(level)") }
            expect(abs(z - 0.025) < 1e-6, "updated projection, near/distance = 0.05/2")
        }
        finishTests("EDRGPU")
    }
}
