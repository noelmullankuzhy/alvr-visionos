import Metal
import simd

// Shared by the compositor renderer and Mac GPU tests: opaque view plane at two metres.
// WWDC24 10092 requires reverse-Z perspective depth for every nontransparent pixel.
final class EDRDrawing {
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    init(device: MTLDevice, library: MTLLibrary) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "diagEDRVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "diagEDRFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .always // coplanar patches overwrite the surround
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!
    }
    func encode(buffer: MTLCommandBuffer, colour: MTLTexture, depth: MTLTexture, slice: Int,
                viewport: MTLViewport, patches: [EDRLayout.Patch], projection: simd_float4x4) {
        let clip = projection * SIMD4<Float>(0, 0, -2, 1)
        var z = clip.z / clip.w
        guard z.isFinite, z > 0, z < 1 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].slice = slice
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.slice = slice
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBytes(&z, length: MemoryLayout<Float>.size, index: 0)
        // Draw the opaque black surround too: clearing colour alone leaves depth at infinity.
        let surround = EDRLayout.Patch(x: 0, y: 0, width: 1, height: 1, value: 0)
        for patch in [surround] + patches {
            encoder.setViewport(MTLViewport(originX: viewport.originX + patch.x * viewport.width,
                                            originY: viewport.originY + patch.y * viewport.height,
                                            width: patch.width * viewport.width, height: patch.height * viewport.height, znear: 0, zfar: 1))
            var value = patch.value
            encoder.setFragmentBytes(&value, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }
}

#if os(visionOS)
import CompositorServices
import SwiftUI

struct EDRConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .rgba16Float
        configuration.depthFormat = .depth32Float
        configuration.isFoveationEnabled = false // patch areas are measured in unfoveated per-view coordinates
        configuration.layout = capabilities.supportedLayouts(options: []).contains(.dedicated) ? .dedicated : .layered
    }
}

final class EDRRenderer {
    let layer: LayerRenderer
    let queue: MTLCommandQueue
    let drawing: EDRDrawing
    let badge: DiagEyeRenderer?
    let runID = EDRSession.shared.currentRun
    private var anchorMissingLogged = false
    private var shiftedViews = Set<String>()
    let immersion: String
    init(_ layer: LayerRenderer, immersion: String) throws {
        self.layer = layer
        self.immersion = immersion
        badge = Diag.isOn ? DiagEyeRenderer(layer) : nil
        queue = layer.device.makeCommandQueue()!
        drawing = try EDRDrawing(device: layer.device, library: layer.device.makeDefaultLibrary()!)
    }
    func start() {
        guard Diag.isOn else { return }
        layer.onSpatialEvent = { events in
            for event in events where event.phase == .ended { EDRSession.shared.next() }
        }
        Thread.detachNewThread { [self] in
            while layer.state != .invalidated {
                if layer.state == .paused { layer.waitUntilRunning() }
                else { autoreleasepool { render() } }
            }
            Task { @MainActor in
                if EDRSession.shared.currentRun == runID, PQDiagnostic.shared.space == "EDRDiagnostic" { PQDiagnostic.shared.space = nil }
            }
        }
    }
    private func render() {
        guard let frame = layer.queryNextFrame(), let timing = frame.predictTiming() else { return }
        frame.startUpdate(); frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables: [LayerRenderer.Drawable]
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) { drawables = frame.queryDrawables() }
        else { drawables = frame.queryDrawable().map { [$0] } ?? [] }
#else
        drawables = frame.queryDrawable().map { [$0] } ?? []
#endif
        // Stop can invalidate the layer before a drawable is available; do not end an unsubmitted frame.
        guard !drawables.isEmpty, let buffer = queue.makeCommandBuffer() else { return }
        // The compositor needs the device pose each frame was rendered for; without it nothing in this space was
        // shown on device (21 Oct). The patches are drawn in view space, so the current pose keeps them head-locked.
        let presentation = LayerRenderer.Clock.Instant.epoch.duration(to: timing.presentationTime).timeInterval
        let anchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: presentation)
        if anchor == nil, !anchorMissingLogged { anchorMissingLogged = true; Diag.log("edr", ["device_anchor": "missing", "immersion": immersion]) }
        let snapshot = EDRSession.shared.frame()
        for drawable in drawables {
            drawable.deviceAnchor = anchor
            for (index, view) in drawable.views.enumerated() {
                let map = view.textureMap
                let projection = drawable.computeProjection(viewIndex: index)
                let centre = EDRView.centre(projectionX: Double(projection.columns.2.x),
                                            projectionY: Double(projection.columns.2.y))
                let shiftKey = "\(snapshot.layout.rawValue):\(snapshot.grid.borders):\(index)"
                if let fields = snapshot.shiftFields(centre: centre, aspect: map.viewport.width / map.viewport.height,
                                                     pixelHeight: map.viewport.height, view: index, immersion: immersion),
                   shiftedViews.insert(shiftKey).inserted {
                    Diag.log("edr", fields)
                }
                let patches = snapshot.patches(centre: centre, aspect: map.viewport.width / map.viewport.height,
                                               pixelHeight: map.viewport.height)
                drawing.encode(buffer: buffer, colour: drawable.colorTextures[map.textureIndex],
                               depth: drawable.depthTextures[map.textureIndex], slice: map.sliceIndex,
                               viewport: map.viewport, patches: patches, projection: projection)
            }
            badge?.encode(buffer: buffer, drawable: drawable, mode: "edr_ramp", generation: nil)
            drawable.encodePresent(commandBuffer: buffer)
        }
        buffer.commit()
        frame.endSubmission()
    }
}

#endif
