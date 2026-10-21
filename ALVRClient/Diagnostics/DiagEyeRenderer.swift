import Metal
import simd

// One opaque pass per eye, loading the existing image. Array index also selects the matching foveation-map layer.
final class DiagEyeDrawing {
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    static func pipelineDescriptor(colourFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.inputPrimitiveTopology = .triangle // required by diagEyeVertex's render_target_array_index
        descriptor.colorAttachments[0].pixelFormat = colourFormat
        descriptor.depthAttachmentPixelFormat = depthFormat
        return descriptor
    }
    init(device: MTLDevice, library: MTLLibrary, colourFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) throws {
        let descriptor = Self.pipelineDescriptor(colourFormat: colourFormat, depthFormat: depthFormat)
        descriptor.vertexFunction = library.makeFunction(name: "diagEyeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "diagEyeFragment")
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .always; depth.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depth)!
    }
    func encode(buffer: MTLCommandBuffer, colour: MTLTexture, depth: MTLTexture, slice: Int, viewport: MTLViewport,
                placement: DiagEye.Placement, eye: DiagEye, projection: simd_float4x4, rateMap: MTLRasterizationRateMap? = nil) {
        let clip = projection * SIMD4<Float>(0, 0, -2, 1)
        var z = clip.z / clip.w, layer = UInt32(slice), colourValue = eye.colour, glyph = eye.glyphBits
        guard z.isFinite, z > 0, z < 1 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .load; pass.depthAttachment.storeAction = .store
        pass.renderTargetArrayLength = colour.textureType == .type2DArray ? colour.arrayLength : 1
        pass.rasterizationRateMap = rateMap
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depthState)
        let r = placement.rect
        encoder.setViewport(MTLViewport(originX: viewport.originX + r.x * viewport.width, originY: viewport.originY + r.y * viewport.height,
                                        width: r.z * viewport.width, height: r.w * viewport.height, znear: 0, zfar: 1))
        encoder.setVertexBytes(&z, length: MemoryLayout<Float>.size, index: 0)
        encoder.setVertexBytes(&layer, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setFragmentBytes(&colourValue, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&glyph, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}

#if os(visionOS)
import CompositorServices

// Created only by a Metal renderer with Diagnostics on; never instantiated by the off or RealityKit paths.
final class DiagEyeRenderer {
    private let drawing: DiagEyeDrawing
    private var logs = DiagEye.LogState()
    init(_ layer: LayerRenderer) {
        drawing = try! DiagEyeDrawing(device: layer.device, library: layer.device.makeDefaultLibrary()!,
                                     colourFormat: layer.configuration.colorFormat, depthFormat: layer.configuration.depthFormat)
    }
    func encode(buffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable, mode: String, generation: UInt64?) {
        for (index, view) in drawable.views.enumerated() {
            let assignment = DiagEye.assign(view: index, x: view.transform.columns.3.x)
            let placement = DiagEye.placement(tangents: drawable.gimmeTangents(viewIndex: index))
            if assignment.mismatch { Diag.log("eye_badge", ["mismatch": 1, "view": index, "x": view.transform.columns.3.x]) }
            if logs.shouldLog(eye: assignment.eye, mode: mode, generation: generation) {
                Diag.log("eye_badge", placement.fields(eye: assignment.eye, view: index, mode: mode))
            }
            let map = view.textureMap
            let rateMaps = drawable.rasterizationRateMaps
            let rateMap = rateMaps.indices.contains(map.textureIndex) ? rateMaps[map.textureIndex] : rateMaps.first
            drawing.encode(buffer: buffer, colour: drawable.colorTextures[map.textureIndex], depth: drawable.depthTextures[map.textureIndex],
                           slice: map.sliceIndex, viewport: map.viewport, placement: placement, eye: assignment.eye,
                           projection: drawable.computeProjection(viewIndex: index), rateMap: rateMap)
        }
    }
}
#endif
