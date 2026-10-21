import CompositorServices
import Metal
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
    let pipeline: MTLRenderPipelineState
    let runID = EDRSession.shared.currentRun
    init(_ layer: LayerRenderer) throws {
        self.layer = layer
        queue = layer.device.makeCommandQueue()!
        let library = layer.device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "diagEDRVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "diagEDRFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try layer.device.makeRenderPipelineState(descriptor: descriptor)
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
        defer { frame.endSubmission() }
        let drawables: [LayerRenderer.Drawable]
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) { drawables = frame.queryDrawables() }
        else { drawables = frame.queryDrawable().map { [$0] } ?? [] }
#else
        drawables = frame.queryDrawable().map { [$0] } ?? []
#endif
        guard !drawables.isEmpty, let buffer = queue.makeCommandBuffer() else { return }
        let patches = EDRSession.shared.frame()
        for drawable in drawables {
            for view in drawable.views {
                let map = view.textureMap
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.colorTextures[map.textureIndex]
                pass.colorAttachments[0].slice = map.sliceIndex
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                pass.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
                pass.depthAttachment.slice = map.sliceIndex
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.storeAction = .store
                pass.depthAttachment.clearDepth = 0
                guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
                encoder.setRenderPipelineState(pipeline)
                for patch in patches {
                    let v = map.viewport
                    encoder.setViewport(MTLViewport(originX: v.originX + patch.x * v.width, originY: v.originY + patch.y * v.height,
                                                    width: patch.width * v.width, height: patch.height * v.height, znear: 0, zfar: 1))
                    var value = patch.value
                    encoder.setFragmentBytes(&value, length: MemoryLayout<Float>.size, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                encoder.endEncoding()
            }
            drawable.encodePresent(commandBuffer: buffer)
        }
        buffer.commit()
    }
}
