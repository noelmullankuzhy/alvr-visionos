//
//  BrightTraceSession.swift
//
// Brightness trace sampling and sinks (BrightTrace.swift has the maths and record). Render thread, per drawn frame with
// the trace on: copies references and scalars, encodes one blit per output grid row into a pooled shared buffer in the
// presenting command buffer and adds a completion handler; on the Metal path, again (the post grid) after the last pass
// just before present, into a second pooled buffer through the frame's Post. Everything else runs on one utility serial queue: the Y-plane
// grid of the retained decoded buffer (read-only lock), the CVPixelBuffer attachments, the readback decode after GPU
// completion, the jsonl line (DiagSink, Documents/diag/brighttrace-<UTC>.jsonl, 50 MB rotation, 200 MB in total), the
// jump detector and the 1 Hz BRIGHTTRACE line through alvr_log at Info (forwarded to the streamer log like HDRPROBE).
// Off: the caller's one atomic load. No waitUntilCompleted, getBytes or buffer allocation on the render thread: readback
// buffers are allocated on a utility queue, the render thread only takes the bookkeeping lock. Bounded: at most
// maxFramesInFlight frames admitted and maxQueuedLines lines queued on the sink; drops are counted in the 1 Hz line.
//
// visionOS exposes no per-frame EDR headroom or display brightness (UIScreen is unavailable, LayerRenderer, its drawable
// and RealityKit have none, checked against the visionOS 27 SDK), and no drawable colour space: drawable_colorspace is
// recorded as not_exposed.
//

import Foundation
import CoreVideo
import Metal
import CompositorServices
import Synchronization

final class BrightTraceSession {
    // One eye's colour texture, slice, viewport and the rate map (and layer) mapping it (BrightTrace.targets).
    typealias View = (eye: String, texture: MTLTexture, slice: Int, viewport: MTLViewport, rateMap: MTLRasterizationRateMap?, layer: Int)

    private static let on = Atomic<Bool>(LaunchFlags.bool(BrightTrace.defaultsKey, setting: ALVRClientApp.gStore.settings.brightnessTrace))
    static var enabled: Bool { on.load(ordering: .relaxed) }
    static func updateEnabled(_ value: Bool) { on.store(value, ordering: .relaxed) }

    static let shared = BrightTraceSession()
    private let queue = DispatchQueue(label: "uk.lumenio.alvr.brighttrace", qos: .utility)
    private let allocationQueue = DispatchQueue(label: "uk.lumenio.alvr.brighttrace.alloc", qos: .utility)
    // Bookkeeping only (admission, line cap, pool); never held across an allocation, encode or I/O.
    private let lock = NSLock()
    private var frames = BrightTraceGate(capacity: BrightTrace.maxFramesInFlight)
    private var lines = BrightTraceGate(capacity: BrightTrace.maxQueuedLines)
    private var pool = BrightTracePool<MTLBuffer>(capacity: BrightTrace.maxReadbackBuffers)
    private var seq = 0   // render thread only

    // Trace queue only.
    private lazy var sink = DiagSink(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag"),
                                     maxBytes: BrightTrace.maxFileBytes, now: { Date() }, console: nil, name: "brighttrace", fileExtension: "jsonl",
                                     maxTotalBytes: BrightTrace.maxTotalBytes)
    private var state = BrightTraceState()
    private var detector = BrightTraceJumpDetector()
    private var summary = BrightTraceSummary()
    private var pending: [Int: BrightTraceRecord] = [:]
    private var pendingInput: [Int: [[Double]?]] = [:]
    private var lastInput: (timestampNs: UInt64, eyes: [[Double]?])?

    // An admitted frame's second readback, encoded by post(_:) before present; read under `lock` at completion.
    final class Post {
        fileprivate var readback: Readback?
        fileprivate var encoded = false
    }

    // Render thread, after the video pass into `texture`. nil: not admitted (no post readback either).
    @discardableResult
    func frame(commandBuffer: MTLCommandBuffer, views: [View], queuedFrame: QueuedFrame,
               colour: StreamColourState, secret: Bool, realityKit: Bool, asyncDecode: Bool, renderStartS: Double, presentS: Double,
               layerFormat: MTLPixelFormat?, overlayAlpha: Float) -> Post? {
        seq += 1
        lock.lock()
        let admitted = frames.admit()
        lock.unlock()
        guard admitted else { return nil }
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
        let post = Post()
        commandBuffer.addCompletedHandler { [self] done in
            let ok = done.status == .completed
            lock.lock()
            let postReadback = post.readback
            lock.unlock()
            queue.async { [self] in
                defer {
                    lock.lock()
                    for buffer in [readback?.buffer, postReadback?.buffer].compactMap({ $0 }) { pool.put(buffer, length: buffer.length) }
                    frames.release()
                    lock.unlock()
                }
                func grids(_ readback: Readback?) -> [[Double]?] {
                    eyes.indices.map { i -> [Double]? in
                        guard ok, let readback, i < readback.formats.count, let format = readback.formats[i] else { return nil }
                        return readback.rows[i].luma(readback.buffer.contents().advanced(by: readback.offsets[i]), rowBytes: readback.rowBytes[i], format: format)
                    }
                }
                finish(id, eyes: eyes, outputs: grids(readback), posts: grids(postReadback))
            }
        }
        return post
    }

    // Render thread, after the last pass of the frame `post` came from, just before present: the same views read again
    // (the post grid). Once per Post; no buffer free in the pool: that frame's post grid is null.
    func post(_ post: Post, commandBuffer: MTLCommandBuffer, views: [View]) {
        guard !post.encoded else { return }
        post.encoded = true
        let readback = encodeReadback(commandBuffer: commandBuffer, views: views, label: "Brightness trace post readback")
        lock.lock()
        post.readback = readback
        lock.unlock()
    }

    // Per view: a nil format when its texture format or slice cannot be read.
    fileprivate struct Readback { let buffer: MTLBuffer; let rows: [BrightTraceRows]; let offsets: [Int]; let rowBytes: [Int]; let formats: [BrightTraceRows.Format?] }

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

    private func encodeReadback(commandBuffer: MTLCommandBuffer, views: [View], label: String = "Brightness trace readback") -> Readback? {
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
        lock.lock()
        let taken = pool.take(length: length)
        lock.unlock()
        if let allocate = taken.allocate {
            // No buffer fits: this frame has no output samples; a buffer for the next is made (and any evicted one
            // released) off the render thread.
            let evicted = taken.evicted
            allocationQueue.async { [self] in
                let made = device.makeBuffer(length: allocate, options: .storageModeShared)
                withExtendedLifetime(evicted) {}
                lock.lock(); pool.allocated(made, length: allocate); lock.unlock()
            }
        }
        guard let buffer = taken.buffer else { return nil }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { lock.lock(); pool.put(buffer, length: buffer.length); lock.unlock(); return nil }
        blit.label = label
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
    private func finish(_ id: Int, eyes: [String], outputs: [[Double]?], posts: [[Double]?]) {
        guard var record = pending.removeValue(forKey: id) else { return }
        let inputs = pendingInput.removeValue(forKey: id) ?? []
        record.eyes = eyes.indices.map { v in
            let i = ["L", "R"].firstIndex(of: eyes[v]) ?? -1
            return BrightTraceEye(eye: eyes[v], input: inputs.indices.contains(i) ? inputs[i] : nil, output: outputs[v], post: posts[v])
        }
        state.annotate(&record)
        summary.add(record)
        lock.lock()
        let queued = lines.admit()
        summary.addDropped(frames: frames.takeDropped(), lines: lines.takeDropped())
        lock.unlock()
        if queued {
            sink.write(record.line())
            sink.async { [self] in lock.lock(); lines.release(); lock.unlock() }
        }
        let nowMs = HDRProbeClock.monotonicMs()
        if let jump = detector.check(record, nowMs: nowMs) {
            summary.addJump(eyes: jump.eyes)
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
    // views: every eye, each from its own mapped texture and slice (layered, dedicated or shared layout). The Metal path
    // passes the returned Post to BrightTraceSession.post just before present.
    @discardableResult
    func brightTrace(commandBuffer: MTLCommandBuffer, views: [BrightTraceSession.View], queuedFrame: QueuedFrame, renderStartS: Double, presentS: Double) -> BrightTraceSession.Post? {
        guard let colour = VideoHandler.streamColourState(for: queuedFrame, realityKit: isRealityKit, displayHeadroom: displayHeadroom) else { return nil }
        return BrightTraceSession.shared.frame(commandBuffer: commandBuffer, views: views, queuedFrame: queuedFrame, colour: colour,
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
