//
//  CornerChartRenderer.swift
//
// Device side of the corner chart (CornerChart.swift, GM decision 65): Diagnostics on + the Corner chart setting, the
// immersive Metal path with no stream. Draws each lit view's chart in its own NDC and colour (left cyan, right magenta,
// with an L / R at the centre; head-locked, other eye black in the monocular modes) and takes marks from pinches or a
// gamepad:
//   pinch right / left: ring out / in; hold (>= 0.5 s) right: record and next; hold left: back.
//   d-pad up or right / down or left: ring out / in; A: record; B: back.
// Logs once: per view eye, tangents, drawable size (corner), the visible-area API result (corner api=unavailable);
// per record: corner eye pos_deg ring_pct tan_x tan_y; per eye completed: corner_summary with the visible tangent
// polygon and the boundary shape (CornerShape) with its raw numbers.
//

import Foundation
import Metal
import CompositorServices
import GameController
import SwiftUI

final class CornerChartRenderer {
    private static let holdSeconds = 0.5

    private let lock = NSLock()
    private let session: CornerChartSession
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var tangents: [CornerEye: CornerTangents] = [:]
    private var loggedViews = false
    private var vertexBuffer: MTLBuffer?
    private var vertexCount = 0
    private var geometryKey = ""
    private var pinches: [AnyHashable: (start: Double, right: Bool)] = [:]
    private var padHeld: [CornerChartSession.Action: Bool] = [:]

    // nil unless Diagnostics is on and the setting picks a mode.
    static func make(device: MTLDevice, layerRenderer: LayerRenderer) -> CornerChartRenderer? {
        let mode = CornerChartMode(setting: ALVRClientApp.gStore.settings.cornerChart)
        guard Diag.isOn, mode != .off, let library = device.makeDefaultLibrary() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "CornerChart"
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
            Diag.log("corner", ["chart": "pipeline_failed"])
            return nil
        }
        Diag.log("corner", ["chart": "on", "mode": mode.rawValue])
        return CornerChartRenderer(session: CornerChartSession(mode: mode), pipeline: pipeline, depthState: depthState)
    }

    private init(session: CornerChartSession, pipeline: MTLRenderPipelineState, depthState: MTLDepthStencilState) {
        self.session = session
        self.pipeline = pipeline
        self.depthState = depthState
    }

    func apply(_ action: CornerChartSession.Action) {
        lock.lock()
        defer { lock.unlock() }
        for event in session.apply(action) {
            switch event {
            case let .mark(eye, spoke, pct):
                guard let t = tangents[eye] else { continue }
                Diag.log("corner", CornerChart.markFields(eye, spoke, pct, t))
            case let .summary(eye):
                guard let t = tangents[eye] else { continue }
                Diag.log("corner_summary", CornerChart.summaryFields(eye, t, marks: session.marks[eye] ?? [:]))
            case .done:
                Diag.log("corner", ["chart": "done"])
            }
        }
    }

    // Layer spatial events (any thread): a short pinch steps the ring, a held one records (right) or goes back (left).
    func spatialEvent(_ event: SpatialEventCollection.Event) {
        guard event.kind == .indirectPinch else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var action: CornerChartSession.Action?
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
                action = held ? (pinch.right ? .record : .back) : (pinch.right ? .outward : .inward)
            }
        default:
            pinches.removeValue(forKey: event.id)
        }
        lock.unlock()
        if let action { apply(action) }
    }

    private func pollGamepad() {
        guard let pad = GCController.current?.extendedGamepad else { return }
        let state: [CornerChartSession.Action: Bool] = [.outward: pad.dpad.up.isPressed || pad.dpad.right.isPressed,
                                                        .inward: pad.dpad.down.isPressed || pad.dpad.left.isPressed,
                                                        .record: pad.buttonA.isPressed, .back: pad.buttonB.isPressed]
        for (action, pressed) in state where pressed && !(padHeld[action] ?? false) {
            apply(action)
        }
        padHeld = state
    }

    // Render thread, in place of the no-stream pass: clears to black, draws the lit views' charts.
    func encode(commandBuffer: MTLCommandBuffer, drawable: LayerRenderer.Drawable, viewports: [MTLViewport], rasterizationRateMap: MTLRasterizationRateMap?) {
        pollGamepad()
        lock.lock()
        var views: [(eye: CornerEye, view: Int, t: CornerTangents, vp: MTLViewport)] = []
        for (v, view) in drawable.views.enumerated() {
            let eye = CornerEye(viewOffsetX: Double(view.transform.columns.3.x))
            views.append((eye, v, CornerTangents(simd: drawable.gimmeTangents(viewIndex: v)), view.textureMap.viewport))
            tangents[eye] = views[v].t
        }
        if !loggedViews {
            loggedViews = true
            for (eye, v, t, vp) in views {
                let index = Int(drawable.views[v].textureMap.textureIndex)
                let texture = index < drawable.colorTextures.count ? drawable.colorTextures[index] : nil
                Diag.log("corner", CornerChart.viewFields(eye, view: v, t, drawableW: texture?.width ?? 0, drawableH: texture?.height ?? 0,
                                                          viewport: String(format: "%.0f,%.0f,%.0f,%.0f", vp.originX, vp.originY, vp.width, vp.height)))
            }
            Diag.log("corner", CornerChart.apiFields)
        }
        let key = "\(session.statusText)|\(views.map { "\($0.t)\($0.vp.width)x\($0.vp.height)" })"
        if key != geometryKey {
            geometryKey = key
            var vertices: [SIMD4<Float>] = []
            for (eye, v, t, vp) in views where session.lit(eye) {
                let selected = session.eye == eye ? (session.spoke, session.pct) : nil
                for q in CornerChart.geometry(t, eye: eye, widthPx: vp.width, heightPx: vp.height, selected: selected, status: session.statusText) {
                    let r = q.rect
                    for (x, y) in [(r.x0, r.y0), (r.x1, r.y0), (r.x0, r.y1), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)] {
                        vertices += [SIMD4<Float>(Float(x), Float(y), Float(v), 0), q.color]
                    }
                }
            }
            vertexCount = vertices.count / 2
            vertexBuffer = vertices.isEmpty ? nil : drawable.colorTextures[0].device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride)
        }
        let buffer = vertexBuffer, count = vertexCount
        lock.unlock()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.colorTextures[0]
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = drawable.depthTextures[0]
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0.0
        pass.rasterizationRateMap = rasterizationRateMap
        pass.renderTargetArrayLength = viewports.count
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Corner Chart"
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
    }
}
