import Foundation
import Metal
import CompositorServices
import QuartzCore

// One accumulator per point: completion handlers retain their own point, so late GPU
// callbacks cannot contaminate the next step. Report only after all submissions finish.
private final class RQSamples {
    private let lock = NSLock()
    private var gpu: [Double] = []
    private var frames = 0, pending = 0, missed = 0
    private var report: (([Double], Int, Int) -> Void)?
    init() { gpu.reserveCapacity(4096) }
    func submit() { lock.lock(); frames += 1; pending += 1; lock.unlock() }
    func complete(ms: Double, missedDeadline: Bool) {
        lock.lock()
        if ms > 0 && gpu.count < 4096 { gpu.append(ms) }
        if missedDeadline { missed += 1 }
        pending -= 1
        drain()
        lock.unlock()
    }
    func finish(_ report: @escaping ([Double], Int, Int) -> Void) {
        lock.lock(); self.report = report; drain(); lock.unlock()
    }
    private func drain() {
        if pending == 0, let report { self.report = nil; report(gpu, missed, frames) }
    }
}

final class RQRenderer {
    private static let configurationLock = NSLock()
    private static var configuredDefault: Float = .nan
    static func configure(defaultQuality: Float) {
        configurationLock.lock(); configuredDefault = defaultQuality; configurationLock.unlock()
    }
    private static func defaultQuality() -> Float {
        configurationLock.lock(); defer { configurationLock.unlock() }
        return configuredDefault
    }
    private var schedule = RQSchedule.make(diagnostics: true, enabled: true)!
    private let pipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private var samples = RQSamples()
    private var views: [View] = []
    private struct View {
        let drawable, view, width, height: Int
        let actual: Float
        let screen, physical: String
    }
    var active: Bool { schedule.active }
    init(device: MTLDevice, library: MTLLibrary) throws {
        let descriptor = RQPipeline.descriptor(library: library)
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .always; d.isDepthWriteEnabled = true
        depth = device.makeDepthStencilState(descriptor: d)!
    }
    // Called before queryNextFrame, using the stream state itself (including when
    // streaming has no decoded frames), never the renderer's idle-frame fallback.
    func update(layer: LayerRenderer, enabled: Bool, streaming: Bool) {
        var supported = false
        var previous: Float = 0, maximum: Float = 0, defaultQuality: Float = 0
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            supported = true
            previous = layer.renderQuality.rawValue
            maximum = layer.configuration.maxRenderQuality.rawValue
            defaultQuality = Self.defaultQuality()
        }
#endif
        let action = schedule.tick(now: Diag.monotonicMs(), enabled: enabled, streaming: streaming,
                                   supported: supported, previous: previous, maximum: maximum)
        var next: Float?
        switch action {
        case .none: break
        case .unsupported: Diag.log("rq", ["unsupported": 1])
        case .set(let value):
            Diag.log("rq", RQReport.start(defaultQuality: defaultQuality, maximum: maximum)); next = value
        case .finish(let step, let value):
            let snapshots = views
            samples.finish { gpu, missed, frames in
                Diag.background {
                    let footprint = DiagProbes.physFootprint().map { Double($0) / 1048576 }
                    for v in snapshots {
                        Diag.log("rq", RQReport.step(step: step, actual: v.actual, drawable: v.drawable, view: v.view,
                            width: v.width, height: v.height, screen: v.screen, physical: v.physical,
                            gpu: gpu, missed: missed, frames: frames, footprint: footprint))
                    }
                }
            }
            samples = RQSamples(); views = []; next = value
        case .restore(let value):
            Diag.log("rq", ["cancelled": 1, "streaming": streaming]); next = value
        }
#if XCODE_BETA_26
        if #available(visionOS 26.0, *), let next { layer.renderQuality = .init(next) }
#endif
    }
    func encode(layer: LayerRenderer, drawables: [LayerRenderer.Drawable], buffer: MTLCommandBuffer) {
        guard active else { return }
        let measuring = schedule.measuring(now: Diag.monotonicMs())
        var snapshots: [View] = []
        for (d, drawable) in drawables.enumerated() {
            for (v, view) in drawable.views.enumerated() {
                let map = view.textureMap
                let colour = drawable.colorTextures[map.textureIndex]
                let rateMap = drawable.rasterizationRateMaps.count == 1 ? drawable.rasterizationRateMaps.first :
                    drawable.rasterizationRateMaps.dropFirst(map.textureIndex).first
                var actual: Float = 0
#if XCODE_BETA_26
                if #available(visionOS 26.0, *) { actual = layer.renderQuality.rawValue }
#endif
                func size(_ s: MTLSize) -> String { "\(s.width)x\(s.height)" }
                snapshots.append(View(drawable: d, view: v, width: colour.width, height: colour.height, actual: actual,
                    screen: rateMap.map { size($0.screenSize) } ?? "none",
                    physical: rateMap.map { size($0.physicalSize(layer: min(map.sliceIndex, $0.layerCount - 1))) } ?? "none"))
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = colour
                pass.renderTargetArrayLength = colour.arrayLength
                pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
                pass.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
                pass.depthAttachment.loadAction = .load; pass.depthAttachment.storeAction = .store
                pass.rasterizationRateMap = rateMap
                guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
                let clip = drawable.computeProjection(viewIndex: v) * SIMD4<Float>(0, 0, -2, 1)
                var z = clip.z / clip.w
                let vp = map.viewport
                var centre = SIMD2<Float>(Float(vp.originX + vp.width / 2), Float(vp.originY + vp.height / 2))
                encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
                encoder.setViewport(vp)
                var slice = UInt32(map.sliceIndex)
                encoder.setVertexBytes(&slice, length: MemoryLayout<UInt32>.size, index: 1)
                encoder.setVertexBytes(&z, length: MemoryLayout<Float>.size, index: 0)
                encoder.setFragmentBytes(&centre, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
        }
        guard measuring, let main = drawables.first else { return }
        views = snapshots
        let samples = samples
        samples.submit()
        let deadline = main.frameTiming.renderingDeadline
        let remaining = LayerRenderer.Clock().now.duration(to: deadline).timeInterval
        let hostDeadline = CACurrentMediaTime() + remaining
        buffer.addCompletedHandler { cb in
            samples.complete(ms: (cb.gpuEndTime - cb.gpuStartTime) * 1000,
                             missedDeadline: cb.status == .error || cb.gpuEndTime > hostDeadline)
        }
    }
}
