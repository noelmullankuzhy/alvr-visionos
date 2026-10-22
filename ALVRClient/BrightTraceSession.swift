//
//  BrightTraceSession.swift
//
// Brightness trace sampling and sinks (BrightTrace.swift has the maths and record). Render thread, per drawn frame with
// the trace on: copies references and scalars, encodes one blit per output grid row into a pooled shared buffer in the
// presenting command buffer and adds a completion handler. Everything else runs on one utility serial queue: the Y-plane
// grid of the retained decoded buffer (read-only lock), the CVPixelBuffer attachments, the readback decode after GPU
// completion, the jsonl line (DiagSink, Documents/diag/brighttrace-<UTC>.jsonl, 50 MB rotation), the jump detector and
// the 1 Hz BRIGHTTRACE line through alvr_log at Info (forwarded to the streamer log like HDRPROBE). Off: the caller's
// one flag check. No waitUntilCompleted or getBytes on the render thread.
//
// visionOS exposes no per-frame EDR headroom or display brightness (UIScreen is unavailable, LayerRenderer, its drawable
// and RealityKit have none, checked against the visionOS 27 SDK), and no drawable colour space: drawable_colorspace is
// recorded as not_exposed.
//

import Foundation
import CoreVideo
import Metal
import CompositorServices

final class BrightTraceSession {
    // One eye's colour texture, slice, viewport and the rate map (and layer) mapping it (BrightTrace.targets).
    typealias View = (eye: String, texture: MTLTexture, slice: Int, viewport: MTLViewport, rateMap: MTLRasterizationRateMap?, layer: Int)

    private static let lock = NSLock()
    private static var on = LaunchFlags.bool(BrightTrace.defaultsKey, setting: ALVRClientApp.gStore.settings.brightnessTrace)
    static var enabled: Bool { lock.lock(); defer { lock.unlock() }; return on }
    static func updateEnabled(_ value: Bool) { lock.lock(); on = value; lock.unlock() }

    static let shared = BrightTraceSession()
    private let queue = DispatchQueue(label: "uk.lumenio.alvr.brighttrace", qos: .utility)
    private let poolLock = NSLock()
    private var pool: [MTLBuffer] = []
    private var buffersMade = 0
    private static let maxBuffers = 4
    private var seq = 0   // render thread only

    // Trace queue only.
    private lazy var sink = DiagSink(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag"),
                                     maxBytes: BrightTrace.maxFileBytes, now: { Date() }, console: nil, name: "brighttrace", fileExtension: "jsonl")
    private var state = BrightTraceState()
    private var detector = BrightTraceJumpDetector()
    private var summary = BrightTraceSummary()
    private var pending: [Int: BrightTraceRecord] = [:]
    private var pendingInput: [Int: [[Double]?]] = [:]
    private var lastInput: (timestampNs: UInt64, eyes: [[Double]?])?

    // Render thread, after the video pass into `texture`.
    func frame(commandBuffer: MTLCommandBuffer, views: [View], queuedFrame: QueuedFrame,
               colour: StreamColourState, secret: Bool, realityKit: Bool, asyncDecode: Bool, renderStartS: Double, presentS: Double,
               layerFormat: MTLPixelFormat?, overlayAlpha: Float) {
        seq += 1
        // Scalars and the decoded buffer only: the drawable textures are not retained past this frame.
        let id = seq, tMs = Int(Date().timeIntervalSince1970 * 1000), pixelBuffer = queuedFrame.imageBuffer, ts = queuedFrame.timestamp
        let drawableFormat = views.first?.texture.pixelFormat ?? .invalid, eyes = views.map(\.eye)
        queue.async { [self] in
            var fields = Self.fields(colour: colour, secret: secret, realityKit: realityKit, asyncDecode: asyncDecode)
            fields["drawable_format"] = DiagFrameCapture.formatName(drawableFormat)
            fields["drawable_colorspace"] = "not_exposed"
            fields["layer_format"] = layerFormat.map(DiagFrameCapture.formatName) ?? "none"
            fields.merge(Self.attachments(pixelBuffer)) { $1 }
            if lastInput?.timestampNs != ts { lastInput = (ts, Self.inputGrids(pixelBuffer, colour: colour)) }
            pendingInput[id] = lastInput?.eyes
            pending[id] = BrightTraceRecord(seq: id, tMs: tMs, renderStartS: renderStartS, presentS: presentS, timestampNs: ts,
                                            fields: fields, overlayAlpha: Double(overlayAlpha), eyes: [])
        }
        let readback = encodeReadback(commandBuffer: commandBuffer, views: views)
        commandBuffer.addCompletedHandler { [self] done in
            let ok = done.status == .completed
            queue.async { [self] in
                defer { if let buffer = readback?.buffer { poolLock.lock(); pool.append(buffer); poolLock.unlock() } }
                let outputs = eyes.indices.map { i -> [Double]? in
                    guard ok, let readback, let format = readback.formats[i] else { return nil }
                    return readback.rows[i].luma(readback.buffer.contents().advanced(by: readback.offsets[i]), rowBytes: readback.rowBytes[i], format: format)
                }
                finish(id, eyes: eyes, outputs: outputs)
            }
        }
    }

    // Per view: a nil format when its texture format or slice cannot be read.
    private struct Readback { let buffer: MTLBuffer; let rows: [BrightTraceRows]; let offsets: [Int]; let rowBytes: [Int]; let formats: [BrightTraceRows.Format?] }

    private static func format(_ texture: MTLTexture, slice: Int) -> BrightTraceRows.Format? {
        guard slice < (texture.textureType == .type2DArray ? texture.arrayLength : 1) else { return nil }
        switch texture.pixelFormat {
        case .rgba16Float: return .half
        case .rgba8Unorm: return .rgba8
        case .bgra8Unorm: return .bgra8
        case .rgba8Unorm_srgb: return .rgba8srgb
        case .bgra8Unorm_srgb: return .bgra8srgb
        default: return nil
        }
    }

    private func encodeReadback(commandBuffer: MTLCommandBuffer, views: [View]) -> Readback? {
        let formats = views.map { Self.format($0.texture, slice: $0.slice) }
        guard let device = views.first?.texture.device, formats.contains(where: { $0 != nil }) else { return nil }
        let rows = views.map { v in
            BrightTraceRows(x: v.viewport.originX, y: v.viewport.originY, width: v.viewport.width, height: v.viewport.height,
                            textureWidth: v.texture.width, textureHeight: v.texture.height) { x, y in
                guard let rateMap = v.rateMap else { return (x, y) }
                let layer = min(v.layer, rateMap.layerCount - 1)
                let p = rateMap.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: Float(x), y: Float(y)), layer: layer)
                return (Double(p.x), Double(p.y))
            }
        }
        let rowBytes = rows.indices.map { (rows[$0].span * (formats[$0] == .half ? 8 : 4) + 255) & ~255 }
        let offsets = rows.indices.map { i in rows.indices.prefix(i).reduce(0) { $0 + rowBytes[$1] * rows[$1].rows.count } }
        let length = rows.indices.reduce(0) { $0 + rowBytes[$1] * rows[$1].rows.count }
        poolLock.lock()
        var buffer = pool.firstIndex { $0.length >= length }.map { pool.remove(at: $0) }
        if buffer == nil, buffersMade < Self.maxBuffers { buffersMade += 1; buffer = device.makeBuffer(length: length, options: .storageModeShared) }
        poolLock.unlock()
        guard let buffer else { return nil }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { poolLock.lock(); pool.append(buffer); poolLock.unlock(); return nil }
        blit.label = "Brightness trace readback"
        for (i, view) in views.enumerated() where formats[i] != nil {
            for (r, y) in rows[i].rows.enumerated() {
                blit.copy(from: view.texture, sourceSlice: view.slice, sourceLevel: 0, sourceOrigin: MTLOrigin(x: rows[i].xMin, y: y, z: 0),
                          sourceSize: MTLSize(width: rows[i].span, height: 1, depth: 1), to: buffer,
                          destinationOffset: offsets[i] + r * rowBytes[i], destinationBytesPerRow: rowBytes[i], destinationBytesPerImage: rowBytes[i])
            }
        }
        blit.endEncoding()
        return Readback(buffer: buffer, rows: rows, offsets: offsets, rowBytes: rowBytes, formats: formats)
    }

    // Trace queue.
    // Inputs are indexed by eye (left and right halves of the plane), outputs by view.
    private func finish(_ id: Int, eyes: [String], outputs: [[Double]?]) {
        guard var record = pending.removeValue(forKey: id) else { return }
        let inputs = pendingInput.removeValue(forKey: id) ?? []
        record.eyes = zip(eyes, outputs).map { eye, out in
            let i = ["L", "R"].firstIndex(of: eye) ?? -1
            return BrightTraceEye(eye: eye, input: inputs.indices.contains(i) ? inputs[i] : nil, output: out)
        }
        state.annotate(&record)
        summary.add(record)
        sink.write(record.line())
        let nowMs = HDRProbeClock.monotonicMs()
        if let jump = detector.check(record, nowMs: nowMs) {
            summary.addJump()
            emit(jump.line(tMs: record.tMs))
        }
        if let line = summary.take(nowMs: nowMs, tMs: record.tMs) { emit(line) }
    }

    private static func fields(colour: StreamColourState, secret: Bool, realityKit: Bool, asyncDecode: Bool) -> [String: String] {
        let binding: String
        switch colour.binding {
        case .drop: binding = "drop"
        case .explicitPlanes(let bits): binding = "explicit\(bits)"
        case .decoderDefault: binding = "decoderDefault"
        }
        let g = colour.gamutToOutput
        let gamut = [g.columns.0, g.columns.1, g.columns.2].flatMap { [$0.x, $0.y, $0.z] }
            .reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1.bitPattern)) &* 0x100000001b3 }   // FNV-1a over the bit patterns
        return ["path": realityKit ? "realitykit" : "metal", "pipeline": secret ? "secret" : "biplanar", "binding": binding,
                "hdr_pq": String(colour.hdrPQ), "headroom": BrightTrace.format(Double(colour.headroom)),
                "transfer": colour.selection.transfer.rawValue, "matrix": colour.selection.matrix.rawValue,
                "range": colour.selection.fullRange ? "full" : "limited", "encoding_gamma": BrightTrace.format(Double(colour.encodingGamma)),
                "gamut_hash": String(gamut, radix: 16), "decode": asyncDecode ? "async" : "sync", "stream": String(colour.stream.generation)]
    }

    private static func attachments(_ buffer: CVPixelBuffer) -> [String: String] {
        let all = (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any]) ?? [:]
        func text(_ key: CFString) -> String {
            switch all[key as String] {
            case let s as String: return s
            case let d as Data: return d.map { String(format: "%02x", $0) }.joined()
            case nil: return "none"
            case let other?: return String(describing: other)
            }
        }
        return ["cv_fourcc": ColourPipeline.fourCC(CVPixelBufferGetPixelFormatType(buffer)),
                "cv_transfer": text(kCVImageBufferTransferFunctionKey), "cv_matrix": text(kCVImageBufferYCbCrMatrixKey),
                "cv_primaries": text(kCVImageBufferColorPrimariesKey), "cv_mastering": text(kCVImageBufferMasteringDisplayColorVolumeKey),
                "cv_cll": text(kCVImageBufferContentLightLevelInfoKey)]
    }

    // Y-plane grids of both eyes (side by side), relative linear; nil without a CPU-readable biplanar plane.
    private static func inputGrids(_ buffer: CVPixelBuffer, colour: StreamColourState) -> [[Double]?] {
        guard let bits = HDRPipeline.pqPlaneBitDepth(pixelFormat: CVPixelBufferGetPixelFormatType(buffer)), CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [nil, nil] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [nil, nil] }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        return (0..<2).map { eye in
            BrightTrace.planePoints(width: width, height: height, eye: eye, eyes: 2).map { p in
                // 10-bit codes sit in the MSBs of 16.
                let code = bits == 8 ? Double(base.load(fromByteOffset: p.y * stride + p.x, as: UInt8.self))
                    : Double(base.load(fromByteOffset: p.y * stride + p.x * 2, as: UInt16.self) >> 6)
                return BrightTrace.inputLinear(signal: BrightTrace.codeSignal(code, bits: bits, fullRange: colour.selection.fullRange),
                                               pq: colour.selection.isPQ, referenceWhiteNits: colour.stream.referenceWhiteNits)
            }
        }
    }

    private func emit(_ line: String) {
        alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), line)
    }
}

extension Renderer {
    // Both render paths, right after the video pass (Metal: first drawable only). Caller checks BrightTraceSession.enabled.
    // views: every eye, each from its own mapped texture and slice (layered, dedicated or shared layout).
    func brightTrace(commandBuffer: MTLCommandBuffer, views: [BrightTraceSession.View], queuedFrame: QueuedFrame, renderStartS: Double, presentS: Double) {
        guard let colour = VideoHandler.streamColourState(for: queuedFrame, realityKit: isRealityKit, displayHeadroom: displayHeadroom) else { return }
        BrightTraceSession.shared.frame(commandBuffer: commandBuffer, views: views, queuedFrame: queuedFrame, colour: colour,
                                        secret: VideoHandler.usesSecretPipeline(colour, format: CVPixelBufferGetPixelFormatType(queuedFrame.imageBuffer)),
                                        realityKit: isRealityKit, asyncDecode: EventHandler.shared.asyncDecode != nil, renderStartS: renderStartS,
                                        presentS: presentS, layerFormat: layerRenderer?.configuration.colorFormat, overlayAlpha: fadeInOverlayAlpha)
    }

    // Metal path: the drawable's views mapped to their colour textures, slices and rate maps.
    static func brightTraceViews(_ drawable: LayerRenderer.Drawable) -> [BrightTraceSession.View] {
        let maps = drawable.rasterizationRateMaps, textures = drawable.colorTextures
        let targets = BrightTrace.targets(views: drawable.views.map { ($0.textureMap.textureIndex, $0.textureMap.sliceIndex) }, rateMaps: maps.count)
        return zip(targets, drawable.views).compactMap { t, v in
            guard t.texture < textures.count else { return nil }
            return (t.eye, textures[t.texture], t.slice, v.textureMap.viewport, t.rateMap.map { maps[$0] }, t.layer)
        }
    }

    // RealityKit path: one texture, a slice and rate map layer per eye.
    static func brightTraceViews(texture: MTLTexture, viewports: [MTLViewport], rateMap: MTLRasterizationRateMap?) -> [BrightTraceSession.View] {
        let targets = BrightTrace.targets(views: viewports.indices.map { (0, $0) }, rateMaps: rateMap == nil ? 0 : 1)
        return zip(targets, viewports).map { t, v in (t.eye, texture, t.slice, v, rateMap, t.layer) }
    }
}
