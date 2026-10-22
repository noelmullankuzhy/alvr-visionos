//
//  GoldenFrameRenderer.swift
//
// Device side of the golden frame (GoldenFrame.swift, docs/lumen/golden-frame.md): Diagnostics on, a Golden frame set
// picked and both charts off; the immersive Metal path, with or without a stream. The set's server pair is decoded once
// (ImageIO, PNG code values) into one NV12 '420f' buffer, L | R side by side as a decoded stream frame, and drawn by the
// stream's own entry point (Renderer.beginRenderStreamingFrame with `golden`): the stream vertex shader and reprojection,
// the stream fragment shader with the set's foveation (its own pipelines; the live slot is never written, so exit restores
// the live foveation as it was) and BT.709 full-range SDR constants. The live stream's colour cache, telemetry and taps are
// not touched. Frame pose: the head pose when the set was first shown (world-locked), or the current head (head-locked).
// Then a pass with the overlays (frustum rectangle, eye-axis cross, lens outline from meta.json) and the control status.
// Input: pinch right / left: next / previous control; hold (>= 0.5 s) right: apply; hold left: back.
//        d-pad right or up / left or down: next / previous; A: apply; B: back.
// Controls: lock (world / head; back re-pins), quality 0.5 / 0.75 / 1.0 (W33 settle rule, DIAG golden step=settled),
// overlays, capture (W33 Auto capture of the golden display: head-locked, overlays off, per quality, to
// Documents/diag/captures/golden-<set>-<stamp>-rq<q>), exit (back to the live stream or the no-stream pass).
//

import Foundation
import Metal
import CompositorServices
import CoreVideo
import ImageIO
import GameController
import SwiftUI

// The static pair's colour state and pipelines for Renderer.beginRenderStreamingFrame.
struct GoldenStreamSource {
    let colour: StreamColourState
    let pipelines: (biplanar: MTLRenderPipelineState, secret: MTLRenderPipelineState)
}

extension FoveationVars {
    init(golden f: GoldenFoveation) {
        self.init(enabled: f.enabled, targetEyeWidth: f.targetEye.x, targetEyeHeight: f.targetEye.y,
                  optimizedEyeWidth: f.optimizedEye.x, optimizedEyeHeight: f.optimizedEye.y,
                  eyeWidthRatio: f.eyeSizeRatio.x, eyeHeightRatio: f.eyeSizeRatio.y,
                  centerSizeX: f.centerSize.x, centerSizeY: f.centerSize.y, centerShiftX: f.centerShift.x, centerShiftY: f.centerShift.y,
                  edgeRatioX: f.edgeRatio.x, edgeRatioY: f.edgeRatio.y)
    }
}

extension Renderer {
    // BT.709 full range, sRGB transfer, encoding gamma 1 (golden-frame.py writes sRGB code values), 8-bit planes; the
    // set's foveation. Both stream variants, as rebuildRenderPipelines builds them; chroma key off (default settings).
    func goldenStreamSource(foveation: GoldenFoveation) throws -> GoldenStreamSource {
        let output = VideoHandler.colourOutput
        let selection = ColourPipeline.select(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2", fullRange: true,
                                              bitDepth: 8, planeBitDepth: 8, output: output)
        let colour = StreamColourState(selection: selection, planeBitDepth: 8,
                                       stream: StreamContext(generation: 0, hdrEnabled: false, output: output, encodingGamma: 1.0),
                                       displayHeadroom: displayHeadroom, realityKit: isRealityKit)
        let vars = FoveationVars(golden: foveation)
        func build(_ variant: String) throws -> MTLRenderPipelineState {
            try buildRenderPipelineForVideoFrameWithDevice(device: device, mtlVertexDescriptor: mtlVertexDescriptor,
                                                           colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                           viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                           foveationVars: vars, colour: colour,
                                                           chromaKey: ChromaKeySnapshot(settings: GlobalSettings()), variantName: variant)
        }
        return GoldenStreamSource(colour: colour, pipelines: (try build("YpCbCrBiPlanar"), try build("SecretYpCbCrFormats")))
    }
}

final class GoldenFrameRenderer {
    private static let holdSeconds = 0.5, strokePx = 4.0, statusPx = 40.0
    private static let slotName = "chartcap"

    private enum State { case loading, shown, failed, exited }

    private let lock = NSLock()
    private let setName: String
    private let overlayPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let foveation: Bool
    private let session: GoldenFrameSession
    private var state = State.loading
    private var meta: GoldenMeta?
    private var source: GoldenStreamSource?
    private var frame: QueuedFrame?
    private var override = FoveationOverride<GoldenFoveation>()
    private var pose: GoldenPose?
    private var entryQuality: Float?
    private var settle: GoldenQualitySettle?
    private var auto: AutoCaptureSession?
    private var pendingQuality: Float?
    private var lockChanged = false, repinRequested = false, captureRequested = false, exitRequested = false
    private var pinches: [AnyHashable: (start: Double, right: Bool)] = [:]
    private var padHeld: [GoldenFrameSession.Action: Bool] = [:]
    private var loggedNoEncoder = false

    var active: Bool { lock.lock(); defer { lock.unlock() }; return state == .shown }

    // nil unless Diagnostics is on, a set is picked and both charts are off (they take precedence).
    static func make(renderer: Renderer, layerRenderer: LayerRenderer) -> GoldenFrameRenderer? {
        let settings = ALVRClientApp.gStore.settings
        guard Diag.isOn, settings.goldenFrameSet != GoldenFrameSetting.off,
              CornerChartMode(setting: settings.cornerChart) == .off, ResolutionChartSetting.mode(settings.resolutionChart) == .off,
              let library = layerRenderer.device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GoldenFrameOverlay"
        descriptor.vertexFunction = library.makeFunction(name: "cornerChartVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "cornerChartFragmentShader")
        descriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        descriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .always
        depth.isDepthWriteEnabled = false
        guard let pipeline = try? layerRenderer.device.makeRenderPipelineState(descriptor: descriptor),
              let depthState = layerRenderer.device.makeDepthStencilState(descriptor: depth) else {
            Diag.log("golden", ["step": "error", "why": "pipeline_failed", "set": settings.goldenFrameSet, "sha_ok": "unknown"])
            return nil
        }
        let golden = GoldenFrameRenderer(setName: settings.goldenFrameSet, pipeline: pipeline, depthState: depthState,
                                         foveation: layerRenderer.configuration.isFoveationEnabled, quality: quality(layerRenderer))
        let directory = GoldenFrameSetting.root.appendingPathComponent(settings.goldenFrameSet)
        DispatchQueue.global(qos: .userInitiated).async { [weak golden, weak renderer] in
            guard let golden, let renderer else { return }
            golden.load(directory: directory, renderer: renderer)
        }
        return golden
    }

    private init(setName: String, pipeline: MTLRenderPipelineState, depthState: MTLDepthStencilState, foveation: Bool, quality: Float?) {
        self.setName = setName
        self.overlayPipeline = pipeline
        self.depthState = depthState
        self.foveation = foveation
        self.session = GoldenFrameSession(quality: quality)
    }

    // Background: meta.json and hashes, both PNGs to one NV12 buffer, the set's pipelines. Any failure: DIAG golden
    // step=error and the mode stays off (the live path draws).
    private func load(directory: URL, renderer: Renderer) {
        do {
            let meta = try GoldenMeta.load(directory: directory)
            let left = try Self.image(directory.appendingPathComponent(meta.serverPNG[.left]!), name: meta.serverPNG[.left]!)
            let right = try Self.image(directory.appendingPathComponent(meta.serverPNG[.right]!), name: meta.serverPNG[.right]!)
            guard let nv12 = GoldenNV12.frame(left: left, right: right) else { throw GoldenMetaError.badImage("server.png sizes") }
            guard [nv12.width / 2, nv12.height] == meta.serverSize else { throw GoldenMetaError.badImage("server.size") }
            guard let buffer = Self.pixelBuffer(nv12) else { throw GoldenMetaError.badImage("pixel_buffer") }
            var override = FoveationOverride<GoldenFoveation>()
            override.begin(meta.foveation)
            let source = try renderer.goldenStreamSource(foveation: override.effective(live: nil)!)
            lock.lock()
            self.meta = meta
            self.source = source
            self.override = override
            self.frame = QueuedFrame(imageBuffer: buffer, timestamp: 0, viewParamsValid: true, viewParams: [], videoFormat: nil, stream: nil)
            if state == .loading { state = .shown }
            lock.unlock()
        } catch let error as GoldenMetaError {
            lock.lock(); state = .failed; lock.unlock()
            Diag.log("golden", error.fields(set: setName))
        } catch {
            lock.lock(); state = .failed; lock.unlock()
            Diag.log("golden", ["step": "error", "why": "pipeline_failed", "key": "\(error)", "set": setName, "sha_ok": true])
        }
    }

    // PNG code values as stored (no colour management) when the decoded layout is plain 8-bit grey / RGB / RGBA;
    // anything else is drawn into 8-bit RGBX in its own RGB space (sRGB for others).
    private static func image(_ url: URL, name: String) throws -> GoldenNV12.Image {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw GoldenMetaError.badImage(name)
        }
        let channels = cg.bitsPerPixel / 8
        let alphaOK = channels == 4 ? [.last, .premultipliedLast, .noneSkipLast].contains(cg.alphaInfo) : cg.alphaInfo == .none
        if cg.bitsPerComponent == 8, [1, 3, 4].contains(channels), alphaOK, cg.byteOrderInfo == .orderDefault,
           let data = cg.dataProvider?.data {
            return GoldenNV12.Image(width: cg.width, height: cg.height, channels: channels, bytesPerRow: cg.bytesPerRow, pixels: [UInt8](data as Data))
        }
        let space = cg.colorSpace?.model == .rgb ? cg.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw GoldenMetaError.badImage(name) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let base = context.data else { throw GoldenMetaError.badImage(name) }
        let bytes = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: cg.width * 4 * cg.height))
        return GoldenNV12.Image(width: cg.width, height: cg.height, channels: 4, bytesPerRow: cg.width * 4, pixels: bytes)
    }

    // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, IOSurface-backed and Metal-compatible (CVMetalTextureCache binds it).
    private static func pixelBuffer(_ f: GoldenNV12.Frame) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, f.width, f.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes as CFDictionary, &out) == kCVReturnSuccess, let buffer = out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, bytes) in [f.luma, f.chroma].enumerated() {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            bytes.withUnsafeBytes { src in
                for row in 0..<rows { memcpy(base + row * stride, src.baseAddress! + row * f.width, f.width) }
            }
        }
        return buffer
    }

    // Input thread: one control action; changes needing the head pose or the layer wait for the next frame.
    func apply(_ action: GoldenFrameSession.Action) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .shown, auto == nil else { return }
        for event in session.apply(action) {
            switch event {
            case let .setting(key, value):
                if key == "world_locked" { lockChanged = true }
                Diag.log("golden", GoldenFrame.settingFields(set: setName, key: key, value: value))
            case .repin: repinRequested = true
            case let .quality(q): pendingQuality = q
            case .capture: captureRequested = true
            case .exit: exitRequested = true
            }
        }
    }

    func spatialEvent(_ event: SpatialEventCollection.Event) {
        guard event.kind == .indirectPinch else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var action: GoldenFrameSession.Action?
        lock.lock()
        switch event.phase {
        case .active:
            if pinches[event.id] == nil {
                var right = true
                if #available(visionOS 2.0, *) { right = event.chirality != .left }
                pinches[event.id] = (now, right)
            }
        case .ended:
            if let pinch = pinches.removeValue(forKey: event.id) {
                let held = now - pinch.start >= Self.holdSeconds
                action = held ? (pinch.right ? .apply : .back) : (pinch.right ? .next : .previous)
            }
        default:
            pinches.removeValue(forKey: event.id)
        }
        lock.unlock()
        if let action { apply(action) }
    }

    private func pollGamepad() {
        guard let pad = GCController.current?.extendedGamepad else { return }
        let state: [GoldenFrameSession.Action: Bool] = [.next: pad.dpad.right.isPressed || pad.dpad.up.isPressed,
                                                        .previous: pad.dpad.left.isPressed || pad.dpad.down.isPressed,
                                                        .apply: pad.buttonA.isPressed, .back: pad.buttonB.isPressed]
        for (action, pressed) in state where pressed && !(padHeld[action] ?? false) {
            apply(action)
        }
        padHeld = state
    }

    private static func quality(_ layer: LayerRenderer) -> Float? {
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) { return layer.renderQuality.rawValue }
#endif
        return nil
    }

    private static func maxQuality(_ layer: LayerRenderer) -> Float? {
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) { return layer.configuration.maxRenderQuality.rawValue }
#endif
        return nil
    }

    private static func setQuality(_ layer: LayerRenderer, _ value: Float) {
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            layer.renderQuality = .init(min(value, layer.configuration.maxRenderQuality.rawValue))
        }
#endif
    }

    private func rateMap(_ drawable: LayerRenderer.Drawable, view: LayerRenderer.Drawable.View) -> MTLRasterizationRateMap? {
        let maps = drawable.rasterizationRateMaps
        return maps.count == 1 ? maps.first : maps.dropFirst(view.textureMap.textureIndex).first
    }

    private func logState(_ step: String, meta: GoldenMeta, actual: Float?) {
        let worldLocked = session.worldLocked && auto == nil
        Diag.log("golden", GoldenFrame.fields(step: step, set: setName, eyePx: meta.serverSize, density: meta.pxPerDeg, rq: actual,
                                              worldLocked: worldLocked, overlays: session.overlays, shaOK: true))
    }

    // Render thread, in place of the stream or the no-stream pass while active.
    func encode(renderer: Renderer, commandBuffer: MTLCommandBuffer, layer: LayerRenderer, drawable: LayerRenderer.Drawable,
                viewports: [MTLViewport], viewTransforms: [simd_float4x4], nearZ: Double, farZ: Double,
                rasterizationRateMap: MTLRasterizationRateMap?, simdDeviceAnchor: simd_float4x4) {
        pollGamepad()
        let actual = Self.quality(layer)
        let screen = rasterizationRateMap.map { [$0.screenSize.width, $0.screenSize.height] }
        lock.lock()
        guard state == .shown, let meta, let source, let frame else { lock.unlock(); return }
        if pose == nil {
            pose = GoldenPose(shownAt: simdDeviceAnchor)
            entryQuality = actual
            settle = GoldenQualitySettle(reference: screen, referenceQuality: actual)
            logState("show", meta: meta, actual: actual)
        }
        if lockChanged { pose!.setWorldLocked(session.worldLocked, current: simdDeviceAnchor); lockChanged = false }
        if repinRequested { pose!.repin(current: simdDeviceAnchor); repinRequested = false }
        var setQuality = pendingQuality
        pendingQuality = nil
        if let q = setQuality { settle?.set(min(q, Self.maxQuality(layer) ?? q)) }
        if let result = settle?.frame(screen: screen, actual: actual) {
            Diag.log("golden", GoldenFrame.settledFields(set: setName, result, actual: actual))
        }
        if captureRequested {
            captureRequested = false
            auto = AutoCaptureSession(restore: actual, reference: screen)
        }
        var captureStep: (quality: Float, confirmed: Bool, frames: Int, settle: String, expected: [Int]?)?
        if let auto {
            switch auto.frame(actual: actual, max: Self.maxQuality(layer), screen: screen) {
            case let .setQuality(q)?:
                setQuality = q
                Diag.log("chartcap", ["step": "quality", "source": "golden", "set": setName, "rq_set": ChartCapture.quality(q),
                                      "rq": ChartCapture.quality(actual),
                                      "expected_screen": auto.expectedScreen.map(GoldenFrame.size) ?? "none"])
            case let .capture(q, confirmed, frames)?:
                captureStep = (q, confirmed, frames, auto.settle, auto.expectedScreen)
            case let .done(restore)?:
                setQuality = restore
                Diag.log("chartcap", ["step": "done", "source": "golden", "set": setName, "captures": auto.captures, "failed": auto.failures,
                                      "fov": foveation ? "on" : "off", "restore": ChartCapture.quality(restore)])
                self.auto = nil
            case nil:
                break
            }
        }
        if exitRequested {
            exitRequested = false
            state = .exited
            override.end()
            setQuality = entryQuality
            logState("hide", meta: meta, actual: actual)
        }
        // During a capture: head-locked, overlays off (the chart patches at the drawable's tangents, as W33).
        let capturing = auto != nil
        let framePose = capturing ? simdDeviceAnchor : pose!.framePose(current: simdDeviceAnchor)
        let overlays = capturing ? GoldenFrameSession.Overlays(frustum: false, axis: false, lens: false) : session.overlays
        let status = auto?.statusText ?? session.statusText
        let exited = state == .exited
        lock.unlock()
        if let setQuality { Self.setQuality(layer, setQuality) }
        if exited { return }

        // The stream path: the pair as a decoded frame, its tangents (L, R, T, B) per view by eye.
        let eyes = drawable.views.map { CornerEye(viewOffsetX: Double($0.transform.columns.3.x)) }
        let tangents = drawable.views.indices.map { CornerTangents(simd: drawable.gimmeTangents(viewIndex: $0)) }
        let sent = eyes.map { meta.sentTangents($0) }
        let real = tangents.map { SIMD4<Float>(Float($0.left), Float($0.right), Float($0.top), Float($0.bottom)) }
        if let encoder = renderer.beginRenderStreamingFrame(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0],
                                                            renderTargetDepth: drawable.depthTextures[0], viewports: viewports,
                                                            viewTransforms: viewTransforms, sentViewTangents: sent, realViewTangents: real,
                                                            nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap,
                                                            queuedFrame: frame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor,
                                                            drawable: drawable, golden: source) {
            renderer.renderStreamingFrame(0, commandBuffer: commandBuffer, renderEncoder: encoder, renderTargetColor: drawable.colorTextures[0],
                                          renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms,
                                          sentViewTangents: sent, realViewTangents: real, nearZ: nearZ, farZ: farZ,
                                          rasterizationRateMap: rasterizationRateMap, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
            renderer.endRenderStreamingFrame(renderEncoder: encoder)
        } else if !loggedNoEncoder {
            loggedNoEncoder = true
            Diag.log("golden", ["step": "error", "why": "stream_pass_skipped", "set": setName, "sha_ok": true])
        }

        // Overlays and status in each view's NDC; the depth cleared non-zero so the compositor keeps the frame (as the charts).
        var vertices: [SIMD4<Float>] = []
        for (v, view) in drawable.views.enumerated() {
            let eye = eyes[v], t = tangents[v], vp = view.textureMap.viewport
            var quads: [CornerChart.Quad] = []
            func stroke(_ segments: [GoldenOverlay.Segment], _ color: SIMD4<Float>) {
                quads += GoldenOverlay.quads(segments, widthPx: vp.width, heightPx: vp.height, strokePx: Self.strokePx, color: color)
            }
            if overlays.frustum, let rect = meta.overlays.frustumRect[eye] {
                let m = StreamReprojection.viewMatrixFrame(framePose: framePose, deviceAnchor: simdDeviceAnchor, viewTransform: viewTransforms[v])
                let rotation = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                             SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                if let corners = GoldenOverlay.frustumCorners(t, rect: rect, frameToView: rotation) { stroke(GoldenOverlay.closed(corners), eye.color) }
            }
            let axis = meta.overlays.eyeAxis[eye] ?? CornerChart.Point(x: 0, y: 0)
            if overlays.axis { stroke(GoldenOverlay.axisCross(t, axis), [1, 1, 0, 1]) }
            if overlays.lens, let lens = meta.overlays.lens?[eye] { stroke(GoldenOverlay.closed(lens.map { GoldenOverlay.ndc(t, $0) }), [0, 1, 0, 1]) }
            let size = CornerChart.textSize(status, h: Self.statusPx, vertical: false)
            let centre = GoldenOverlay.ndc(t, CornerChart.Point(x: axis.x, y: axis.y - 0.45))
            let hw = size.w / vp.width, hh = size.h / vp.height
            quads += CornerChart.text(status, in: CornerChart.Rect(x0: centre.x - hw, y0: centre.y - hh, x1: centre.x + hw, y1: centre.y + hh),
                                      vertical: false, color: [1, 1, 1, 1])
            for q in quads {
                let points = q.vertices
                for i in [0, 1, 2, 1, 3, 2] { vertices += [SIMD4<Float>(Float(points[i].x), Float(points[i].y), Float(v), 0), q.color] }
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.colorTextures[0]
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = drawable.depthTextures[0]
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0.000000001
        pass.rasterizationRateMap = rasterizationRateMap
        pass.renderTargetArrayLength = viewports.count
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            if let captureStep {
                Diag.log("chartcap", ["error": "encoder_nil", "source": "golden", "rq_set": ChartCapture.quality(captureStep.quality)])
                lock.lock(); auto?.captured(ok: false); lock.unlock()
            }
            return
        }
        encoder.label = "Golden Frame Overlays"
        encoder.setViewports(viewports)
        if viewports.count > 1 {
            var mappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0), renderTargetArrayIndexOffset: UInt32($0))
            }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &mappings)
        }
        if !vertices.isEmpty, let buffer = drawable.colorTextures[0].device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride) {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(buffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 2)
        }
        encoder.endEncoding()
        if let captureStep {
            capture(commandBuffer, drawable: drawable, meta: meta, quality: captureStep.quality, actual: actual, confirmed: captureStep.confirmed,
                    frames: captureStep.frames, settle: captureStep.settle, expectedScreen: captureStep.expected)
        }
    }

    // W33 Auto capture of the golden display (ResolutionChartRenderer.capture): every colour texture of this drawable read
    // back with the chart's patch rects through this frame's map; capture.json adds golden_set and the settings in force.
    private func capture(_ commandBuffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable, meta: GoldenMeta, quality q: Float, actual: Float?,
                         confirmed: Bool, frames: Int, settle: String, expectedScreen: [Int]?) {
        guard DiagReadbackSlot.shared.acquire(Self.slotName) else {
            lock.lock(); auto?.deferCapture(); lock.unlock()
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = GoldenFrame.directoryName(set: setName, stamp: stamp, quality: q)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diag/captures/\(name)")
        func size(_ s: MTLSize) -> [Int] { [s.width, s.height] }
        var views: [ChartCapture.View] = []
        var targetViews: [Int: [[String: Any]]] = [:]
        for (v, view) in drawable.views.enumerated() {
            let eye = CornerEye(viewOffsetX: Double(view.transform.columns.3.x))
            let t = drawable.gimmeTangents(viewIndex: v)
            let vp = view.textureMap.viewport
            let index = Int(view.textureMap.textureIndex)
            let texture = index < drawable.colorTextures.count ? drawable.colorTextures[index] : nil
            let map = rateMap(drawable, view: view)
            let layer = map.map { min(view.textureMap.sliceIndex, $0.layerCount - 1) } ?? view.textureMap.sliceIndex
            let mapping: RateMapSampling.Mapping? = map.map { map in
                { x, y in
                    let p = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: Float(vp.originX + x), y: Float(vp.originY + y)), layer: layer)
                    return (Double(p.x), Double(p.y))
                }
            }
            let textureSize = texture.map { [$0.width, $0.height] } ?? []
            views.append(ChartCapture.View(eye: eye, view: v, slice: view.textureMap.sliceIndex, textureIndex: index,
                                           tangents: CornerTangents(simd: t), viewport: [vp.originX, vp.originY, vp.width, vp.height],
                                           screen: map.map { size($0.screenSize) } ?? textureSize,
                                           physical: map.map { size($0.physicalSize(layer: layer)) } ?? textureSize, map: mapping))
            targetViews[index, default: []].append(["eye": eye.rawValue, "view": v, "slice": view.textureMap.sliceIndex,
                                                     "viewport": [vp.originX, vp.originY, vp.width, vp.height],
                                                     "tangents": [t.x, t.y, t.z, t.w], "texture_index": index])
        }
        let chart = ChartCapture.metadata(views: views, requested: q, actual: actual, confirmed: confirmed, foveation: foveation, frames: frames,
                                          settle: settle, expectedScreen: expectedScreen)
        let settings = GoldenFrame.settings(meta: meta, requested: q, actual: actual, worldLocked: false,
                                            overlays: GoldenFrameSession.Overlays(frustum: false, axis: false, lens: false))
        let maps = drawable.rasterizationRateMaps
        let targets = drawable.colorTextures.enumerated().map { index, texture in
            DiagFrameCapture.Target(texture: texture, views: targetViews[index] ?? [],
                                    rateMap: maps.indices.contains(index) ? maps[index] : maps.first, drawableIndex: 0, textureIndex: index)
        }
        for v in views {
            Diag.log("chartcap", ChartCapture.goldenFields(eye: v.eye, requested: q, actual: actual, confirmed: confirmed, foveation: foveation,
                                                           dir: name, slice: v.slice, physical: v.physical, screen: v.screen,
                                                           expectedScreen: expectedScreen, settle: settle, set: setName))
        }
        DiagFrameCapture.submit(buffer: commandBuffer, targets: targets, directory: directory,
                                metadata: GoldenFrame.captureMetadata(chart: chart, meta: meta, settings: settings)) { [weak self] ok in
            DiagReadbackSlot.shared.release(Self.slotName)
            if !ok { Diag.log("chartcap", ["error": "capture_failed", "source": "golden", "dir": name]) }
            guard let self else { return }
            self.lock.lock()
            self.auto?.captured(ok: ok)
            self.lock.unlock()
        }
    }
}
