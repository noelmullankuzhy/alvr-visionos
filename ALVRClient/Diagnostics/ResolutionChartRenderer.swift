//
//  ResolutionChartRenderer.swift
//
// Device side of the resolution measurement (ResolutionChart.swift): Diagnostics on + the Resolution chart setting, the
// immersive Metal path with no stream (the corner chart takes precedence when both are set). Head-locked, black
// background, drawn in each lit view's NDC with the corner chart's pipeline.
//   0-20 s: fixation dot (centre, 20° left, 20° right, 15° up, 15° down); DIAG rrm per view once per second.
//   then: grating walk at render quality 0.5, 0.75, 1.0 (restored when done). DIAG rrm again whenever the map's size
//   changes; DIAG grating per judgment.
// Input: pinch right / left: next / previous patch; hold (>= 0.5 s) right: seen; hold left: not seen.
//        d-pad right or up / left or down: next / previous; A: seen; B: not seen.
// Auto capture (setting): after the sweep, no input: per render quality the chart (no frame) is drawn, read back from
// each eye's drawable with its patch rects (ChartCapture) to Documents/diag/captures/chart-*, DIAG chartcap per eye.
//

import Foundation
import Metal
import CompositorServices
import GameController
import SwiftUI

final class ResolutionChartRenderer {
    private static let holdSeconds = 0.5

    private let lock = NSLock()
    private let session: GratingSession
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let foveation: Bool
    private var startMs: Int?
    private var sweepTaken = -1
    private var gratingStarted = false
    private var restoreQuality: Float?
    private var pendingQuality: Float?
    private var mapSizeKey = ""
    private var parameterBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0
    private var geometryKey = ""
    private var pinches: [AnyHashable: (start: Double, right: Bool)] = [:]
    private var padHeld: [GratingSession.Action: Bool] = [:]
    private let autoMode: Bool
    private var auto: AutoCaptureSession?   // from the end of the sweep, holding the quality to restore

    // nil unless Diagnostics is on, the setting picks a mode and the corner chart is off.
    static func make(device: MTLDevice, layerRenderer: LayerRenderer) -> ResolutionChartRenderer? {
        let settings = ALVRClientApp.gStore.settings
        let mode = ResolutionChartSetting.mode(settings.resolutionChart)
        guard Diag.isOn, mode != .off, CornerChartMode(setting: settings.cornerChart) == .off,
              let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "ResolutionChart"
        descriptor.vertexFunction = library.makeFunction(name: "cornerChartVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "cornerChartFragmentShader")
        descriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        descriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        descriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .always
        depth.isDepthWriteEnabled = false
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let depthState = device.makeDepthStencilState(descriptor: depth) else {
            Diag.log("grating", ["chart": "pipeline_failed"])
            return nil
        }
        let foveation = layerRenderer.configuration.isFoveationEnabled
        let auto = ResolutionChartSetting.isAuto(settings.resolutionChart)
        Diag.log("grating", ["chart": "on", "mode": auto ? "auto" : mode.rawValue, "foveation": foveation ? "on" : "off",
                             "foveation_setting": settings.resolutionFoveation ? "on" : "off"])
        return ResolutionChartRenderer(session: GratingSession(mode: mode), pipeline: pipeline, depthState: depthState, foveation: foveation,
                                       autoMode: auto)
    }

    private init(session: GratingSession, pipeline: MTLRenderPipelineState, depthState: MTLDepthStencilState, foveation: Bool,
                 autoMode: Bool) {
        self.session = session
        self.pipeline = pipeline
        self.depthState = depthState
        self.foveation = foveation
        self.autoMode = autoMode
    }

    // Judgments are ignored during the 20 s sweep.
    func apply(_ action: GratingSession.Action, actualQuality: Float? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard gratingStarted, !autoMode else { return }
        for event in session.apply(action) {
            switch event {
            case let .judged(index, seen, quality):
                // The latest frame's tangents and logical viewport for the judged eye (both eyes: the left one).
                let patch = GratingChart.patches[index]
                let eye: CornerEye = session.eyeLabel == "R" ? .right : .left
                let nyquist = lastViews.first { $0.eye == eye }.map {
                    GratingChart.nyquistLogical($0.t, width: $0.width, height: $0.height, eye: eye, patch: patch)
                }
                Diag.log("grating", GratingChart.fields(eye: session.eyeLabel, patch: patch, seen: seen, requested: quality,
                                                        actual: lastActual, foveation: foveation, nyquist: nyquist))
            case let .quality(q):
                pendingQuality = q
                Diag.log("grating", ["quality": String(format: "%.3f", q)])
            case .done:
                pendingQuality = restoreQuality
                Diag.log("grating", ["chart": "done", "restore": restoreQuality.map { String(format: "%.3f", $0) } ?? "none"])
            }
        }
    }

    private var lastActual: Float?
    private var lastViews: [(eye: CornerEye, t: CornerTangents, width: Double, height: Double)] = []

    func spatialEvent(_ event: SpatialEventCollection.Event) {
        guard event.kind == .indirectPinch else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var action: GratingSession.Action?
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
                action = held ? (pinch.right ? .seen : .notSeen) : (pinch.right ? .next : .previous)
            }
        default:
            pinches.removeValue(forKey: event.id)
        }
        lock.unlock()
        if let action { apply(action) }
    }

    private func pollGamepad() {
        guard let pad = GCController.current?.extendedGamepad else { return }
        let state: [GratingSession.Action: Bool] = [.next: pad.dpad.right.isPressed || pad.dpad.up.isPressed,
                                                    .previous: pad.dpad.left.isPressed || pad.dpad.down.isPressed,
                                                    .seen: pad.buttonA.isPressed, .notSeen: pad.buttonB.isPressed]
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

    // One DIAG rrm per view: logical -> physical through physicalCoordinates(screenCoordinates:layer:).
    private func sample(_ drawable: LayerRenderer.Drawable, drawableIndex: Int, phase: String, second: Int,
                        fixation: RateMapSampling.Fixation?, quality: Float?) {
        for (v, view) in drawable.views.enumerated() {
            let eye = CornerEye(viewOffsetX: Double(view.transform.columns.3.x))
            let t = CornerTangents(simd: drawable.gimmeTangents(viewIndex: v))
            let vp = view.textureMap.viewport
            let map = rateMap(drawable, view: view)
            let layer = map.map { min(view.textureMap.sliceIndex, $0.layerCount - 1) } ?? view.textureMap.sliceIndex
            var mapping: RateMapSampling.Mapping?
            var hash = "none"
            if let map {
                mapping = { x, y in
                    let p = map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: Float(vp.originX + x), y: Float(vp.originY + y)), layer: layer)
                    return (Double(p.x), Double(p.y))
                }
                let size = map.parameterDataSizeAndAlign.size
                if parameterBuffer == nil || parameterBuffer!.length < size {
                    parameterBuffer = map.device.makeBuffer(length: size, options: .storageModeShared)
                }
                if let buffer = parameterBuffer {
                    map.copyParameterData(buffer: buffer, offset: 0)
                    hash = RateMapSampling.hash(Data(bytes: buffer.contents(), count: size))
                }
            }
            let w = vp.width, h = vp.height
            let index = Int(view.textureMap.textureIndex)
            let texture = index < drawable.colorTextures.count ? drawable.colorTextures[index] : nil
            func size(_ s: MTLSize) -> String { "\(s.width)x\(s.height)" }
            let s = RateMapSampling.ViewSample(
                phase: phase, second: second, fixation: fixation, eye: eye, drawable: drawableIndex, view: v, layer: layer,
                quality: quality, foveation: foveation, mapped: map != nil,
                screen: map.map { size($0.screenSize) } ?? texture.map { "\($0.width)x\($0.height)" } ?? "none",
                physical: map.map { size($0.physicalSize(layer: layer)) } ?? texture.map { "\($0.width)x\($0.height)" } ?? "none",
                viewport: String(format: "%.0f,%.0f,%.0f,%.0f", vp.originX, vp.originY, vp.width, vp.height),
                tangents: t, axis: RateMapSampling.axis(t, width: w, height: h), pxPerTan: RateMapSampling.pxPerTan(t, width: w, height: h),
                h: RateMapSampling.profile(t, width: w, height: h, horizontal: true, map: mapping),
                v: RateMapSampling.profile(t, width: w, height: h, horizontal: false, map: mapping),
                hPeak: RateMapSampling.peak(t, width: w, height: h, horizontal: true, map: mapping),
                vPeak: RateMapSampling.peak(t, width: w, height: h, horizontal: false, map: mapping), hash: hash)
            Diag.log("rrm", RateMapSampling.fields(s))
        }
    }

    // Render thread, in place of the no-stream pass: clears to black, draws the dot or the gratings.
    func encode(commandBuffer: MTLCommandBuffer, layer: LayerRenderer, drawable: LayerRenderer.Drawable, drawableIndex: Int,
                viewports: [MTLViewport], rasterizationRateMap: MTLRasterizationRateMap?) {
        pollGamepad()
        let now = Diag.monotonicMs()
        let actual = Self.quality(layer)
        lock.lock()
        lastActual = actual
        if startMs == nil { startMs = now }
        let elapsed = now - startMs!
        let fixation = RateMapSampling.fixation(elapsedMs: elapsed)
        if let s = RateMapSampling.dueSample(elapsedMs: elapsed, taken: sweepTaken) {
            sweepTaken = s
            sample(drawable, drawableIndex: drawableIndex, phase: "sweep", second: s, fixation: RateMapSampling.fixation(elapsedMs: elapsed), quality: actual)
        }
        if fixation == nil && !gratingStarted {
            gratingStarted = true
            restoreQuality = actual
            if autoMode {
                auto = AutoCaptureSession(restore: actual)
                // The layer's foveation is fixed when the space is configured: a foveation-off pass needs the
                // Resolution chart foveation setting off and a new entry.
                Diag.log("chartcap", ["step": "start", "fov": foveation ? "on" : "off", "fov_off": foveation ? "unavailable" : "this_pass",
                                      "why": foveation ? "layer_foveation_fixed_at_entry" : "layer_without_foveation",
                                      "restore": ChartCapture.quality(actual)])
            } else {
                pendingQuality = session.quality
                Diag.log("grating", ["walk": "start", "quality": String(format: "%.3f", session.quality ?? 0),
                                     "restore": actual.map { String(format: "%.3f", $0) } ?? "none"])
            }
        }
        var captureStep: (quality: Float, confirmed: Bool, frames: Int)?
        if gratingStarted, let auto {
            switch auto.frame(actual: actual, max: Self.maxQuality(layer)) {
            case let .setQuality(q)?:
                pendingQuality = q
                Diag.log("chartcap", ["step": "quality", "rq_set": ChartCapture.quality(q), "rq": ChartCapture.quality(actual)])
            case let .capture(q, confirmed, frames)?:
                captureStep = (q, confirmed, frames)
            case let .done(restore)?:
                pendingQuality = restore
                Diag.log("chartcap", ["step": "done", "captures": auto.captures, "failed": auto.failures, "fov": foveation ? "on" : "off",
                                      "fov_off": foveation ? "unavailable" : "this_pass", "restore": ChartCapture.quality(restore)])
            case nil:
                break
            }
        }
        if gratingStarted {
            // Log every rate-map size the quality steps produce (once per size).
            let key = rasterizationRateMap.map { "\($0.screenSize.width)x\($0.screenSize.height)/\($0.physicalSize(layer: 0).width)x\($0.physicalSize(layer: 0).height)" } ?? "none"
            if key != mapSizeKey {
                mapSizeKey = key
                sample(drawable, drawableIndex: drawableIndex, phase: "quality", second: 0, fixation: nil, quality: actual)
            }
        }
        let setQuality = pendingQuality
        pendingQuality = nil

        var views: [(eye: CornerEye, view: Int, t: CornerTangents)] = []
        for (v, view) in drawable.views.enumerated() {
            views.append((CornerEye(viewOffsetX: Double(view.transform.columns.3.x)), v, CornerTangents(simd: drawable.gimmeTangents(viewIndex: v))))
        }
        lastViews = views.map { ($0.eye, $0.t, drawable.views[$0.view].textureMap.viewport.width,
                                 drawable.views[$0.view].textureMap.viewport.height) }
        let status = auto?.statusText ?? session.statusText
        let key = "\(fixation?.name ?? "grating")|\(status)|\(views.map { "\($0.t)" })"
        if key != geometryKey {
            geometryKey = key
            var vertices: [SIMD4<Float>] = []
            for (eye, v, t) in views {
                for q in GratingChart.geometry(t, eye: eye, session: session, fixation: fixation, highlight: !autoMode, status: status) {
                    let points = q.vertices
                    for i in [0, 1, 2, 1, 3, 2] {
                        vertices += [SIMD4<Float>(Float(points[i].x), Float(points[i].y), Float(v), 0), q.color]
                    }
                }
            }
            vertexCount = vertices.count / 2
            vertexBuffer = vertices.isEmpty ? nil : drawable.colorTextures[0].device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride)
        }
        let buffer = vertexBuffer, count = vertexCount
        lock.unlock()
        if let setQuality { Self.setQuality(layer, setQuality) }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.colorTextures[0]
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = drawable.depthTextures[0]
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        // Non-zero, as the corner chart (a depth-0 chart was not shown on device in mixed immersion, 21 Oct).
        pass.depthAttachment.clearDepth = 0.000000001
        pass.rasterizationRateMap = rasterizationRateMap
        pass.renderTargetArrayLength = viewports.count
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            // Nothing drawn to read back: a failed capture, so the walk moves on and still restores at done.
            if let captureStep {
                Diag.log("chartcap", ["error": "encoder_nil", "rq_set": ChartCapture.quality(captureStep.quality)])
                lock.lock(); auto?.captured(ok: false); lock.unlock()
            }
            return
        }
        encoder.label = "Resolution Chart"
        encoder.setViewports(viewports)
        if viewports.count > 1 {
            var mappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0), renderTargetArrayIndexOffset: UInt32($0))
            }
            encoder.setVertexAmplificationCount(viewports.count, viewMappings: &mappings)
        }
        if let buffer, count > 0 {
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(buffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
        encoder.endEncoding()
        if let captureStep {
            capture(commandBuffer, drawable: drawable, quality: captureStep.quality, actual: actual, confirmed: captureStep.confirmed,
                    frames: captureStep.frames)
        }
    }

    // Auto capture: every colour texture of this drawable (physical, as rendered through the rate map) read back after the
    // chart pass by DiagFrameCapture (PNG per slice + capture.json); the patch rects are mapped now, through this frame's map.
    private func capture(_ commandBuffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable, quality q: Float, actual: Float?,
                         confirmed: Bool, frames: Int) {
        // One full readback per process: while a frame capture holds the slot, retry next frame (nothing counted).
        guard DiagReadbackSlot.shared.acquire(Self.slotName) else {
            lock.lock(); auto?.deferCapture(); lock.unlock()
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = ChartCapture.directoryName(stamp: stamp, quality: q, foveation: foveation)
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
        let metadata = ChartCapture.metadata(views: views, requested: q, actual: actual, confirmed: confirmed, foveation: foveation, frames: frames)
        let maps = drawable.rasterizationRateMaps
        let targets = drawable.colorTextures.enumerated().map { index, texture in
            DiagFrameCapture.Target(texture: texture, views: targetViews[index] ?? [],
                                    rateMap: maps.indices.contains(index) ? maps[index] : maps.first, drawableIndex: 0, textureIndex: index)
        }
        for v in views {
            Diag.log("chartcap", ChartCapture.fields(eye: v.eye, requested: q, actual: actual, confirmed: confirmed, foveation: foveation,
                                                     dir: name, slice: v.slice, physical: v.physical))
        }
        DiagFrameCapture.submit(buffer: commandBuffer, targets: targets, directory: directory,
                                metadata: ["chart_capture": metadata, "trigger": ["reason": "chartcap"]]) { [weak self] ok in
            DiagReadbackSlot.shared.release(Self.slotName)
            if !ok { Diag.log("chartcap", ["error": "capture_failed", "dir": name]) }
            guard let self else { return }
            self.lock.lock()
            self.auto?.captured(ok: ok)
            self.lock.unlock()
        }
    }

    private static let slotName = "chartcap"
}
