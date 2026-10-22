import Foundation
import simd
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Buffers are copied in the presenting command buffer. Conversion and I/O run
// on a utility queue after GPU completion. No waitUntilCompleted or texture.getBytes on render.
enum DiagFrameCapture {
    struct Target {
        let texture: MTLTexture
        let views: [[String: Any]]
        let rateMap: MTLRasterizationRateMap?
        let drawableIndex: Int
        var textureIndex: Int = 0
        // Sharpness-chain stage (DiagStreamStages.record): written as stage-<stage>-<eye>.png into capture.json "stages",
        // never "slices" (the drawable tools take the first slice of an eye). nil for drawables.
        var stage: [String: Any]? = nil
    }
    private struct Readback {
        let target: Target
        let buffer: MTLBuffer
        let rowBytes: Int
        let imageBytes: Int
        let slices: Int
        let rateTables: [[String: Any]]
    }
    typealias PoseRecord = (render: simd_float4x4, display: simd_float4x4, renderT: Double, displayT: Double, simYawDitherRad: Double?)
    // binary16 bit pattern -> sRGB-encoded byte (a linear drawable is encoded through this table).
    private static let srgbByteForHalf: [UInt8] = (0...UInt16.max).map { DiagCaptureEncoding.srgbByte(Float(Float16(bitPattern: $0))) }
    private static let queue = DispatchQueue(label: "uk.lumenio.alvr.capture", qos: .utility)

    static func rateTables(map: MTLRasterizationRateMap?, layer: Int, width: Int, height: Int) -> [String: Any] {
        let w = map?.screenSize.width ?? width, h = map?.screenSize.height ?? height
        let xs = (0...w).map { x -> Double in
            guard let map else { return Double(x) }
            return Double(map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: Float(x), y: 0), layer: layer).x)
        }
        let ys = (0...h).map { y -> Double in
            guard let map else { return Double(y) }
            return Double(map.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: 0, y: Float(y)), layer: layer).y)
        }
        return ["screen_w": w, "screen_h": h, "physical_x": xs, "physical_y": ys, "layer": layer]
    }

    static func writePNG(url: URL, width: Int, height: Int, rgba: [UInt8]) throws {
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "DiagCapturePNG", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "DiagCapturePNG", code: 2) }
    }

    // Readback bytes -> RGBA8 for the PNG (pure; unit tested without a GPU: tests/swift/DiagCaptureConvertTests.swift).
    static func rgbaBytes(from pointer: UnsafeRawPointer, rowBytes: Int, width w: Int, height: Int, format: MTLPixelFormat) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: w * height * 4)
        let half = format == .rgba16Float
        let bgra = format == .bgra8Unorm || format == .bgra8Unorm_srgb
        rgba.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = pointer.advanced(by: y * rowBytes)
                let base = y * w * 4
                if half {
                    let src = row.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<(w * 4) {
                        if i % 4 == 3 {
                            let f = Float(Float16(bitPattern: src[i]))
                            out[base + i] = UInt8((min(1, max(0, f.isNaN ? 0 : f)) * 255).rounded())
                        } else {
                            out[base + i] = srgbByteForHalf[Int(src[i])]
                        }
                    }
                } else {
                    let src = row.assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w {
                        let i = x * 4
                        out[base + i] = src[i + (bgra ? 2 : 0)]; out[base + i + 1] = src[i + 1]
                        out[base + i + 2] = src[i + (bgra ? 0 : 2)]; out[base + i + 3] = src[i + 3]
                    }
                }
            }
        }
        return rgba
    }

    static func formatName(_ format: MTLPixelFormat) -> String {
        switch format {
        case .rgba16Float: return "rgba16Float"
        case .rgba8Unorm: return "rgba8Unorm"
        case .bgra8Unorm: return "bgra8Unorm"
        case .rgba8Unorm_srgb: return "rgba8Unorm_srgb"
        case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
        default: return "format_\(format.rawValue)"
        }
    }

    // PNG values are sRGB-encoded: rgba16Float is linear extended-range (HDRPipeline), so RGB gets the sRGB transfer function
    // (alpha stays linear); the *_srgb formats already store encoded bytes (the GPU encodes on write) and are copied as is.
    // Plain rgba8Unorm/bgra8Unorm carry whatever the shader wrote and are copied as is. Other formats are refused.
    // `pose`: render/display head pose of the stream frame this capture presents (nil on idle captures: no render pose).
    static func submit(buffer: MTLCommandBuffer, targets: [Target], directory: URL, metadata: [String: Any], pose: PoseRecord? = nil,
                       completion: @escaping (Bool) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        let tMs = Diag.monotonicMs()
        let utc = ISO8601DateFormatter().string(from: Date())
        var reads: [Readback] = []
        // Allocate all buffers before encoding any copies. One in-flight capture bounds memory.
        for target in targets {
            let texture = target.texture
            guard [.rgba16Float, .rgba8Unorm, .bgra8Unorm, .rgba8Unorm_srgb, .bgra8Unorm_srgb].contains(texture.pixelFormat) else {
                Diag.log("capture", ["error": "unsupported_pixel_format", "format": texture.pixelFormat.rawValue])
                completion(false); return
            }
            let bpp = texture.pixelFormat == .rgba16Float ? 8 : 4
            let row = (texture.width * bpp + 255) & ~255
            let image = row * texture.height
            let slices = texture.textureType == .type2DArray ? texture.arrayLength : 1
            guard let shared = texture.device.makeBuffer(length: image * slices, options: .storageModeShared) else {
                Diag.log("capture", ["error": "buffer_allocation_failed"])
                completion(false); return
            }
            // Sample while this drawable owns its frame map. Retaining the map until the
            // asynchronous writer runs would risk observing compositor-recycled parameters.
            let tables = target.stage != nil ? [] : (0..<slices).map { rateTables(map: target.rateMap, layer: $0, width: texture.width, height: texture.height) }
            reads.append(Readback(target: target, buffer: shared, rowBytes: row, imageBytes: image, slices: slices, rateTables: tables))
        }
        guard let blit = buffer.makeBlitCommandEncoder() else { completion(false); return }
        blit.label = "Diagnostic frame readback"
        for read in reads {
            let texture = read.target.texture
            for slice in 0..<read.slices {
                blit.copy(from: texture, sourceSlice: slice, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: read.buffer,
                          destinationOffset: slice * read.imageBytes, destinationBytesPerRow: read.rowBytes, destinationBytesPerImage: read.imageBytes)
            }
        }
        blit.endEncoding()
        let encodedMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let reason = (metadata["trigger"] as? [String: Any])?["reason"] as? String ?? "unknown"
        buffer.addCompletedHandler { command in
            let gpuDoneMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
            queue.async {
                guard command.status == .completed else {
                    Diag.log("capture", ["error": command.error?.localizedDescription ?? "command_buffer_failed"])
                    completion(false); return
                }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var slices: [[String: Any]] = []
                    var stages: [[String: Any]] = []
                    var bytes = 0
                    for read in reads {
                        let target = read.target, texture = target.texture
                        for slice in 0..<read.slices {
                            let pointer = read.buffer.contents().advanced(by: slice * read.imageBytes)
                            let rgba = rgbaBytes(from: pointer, rowBytes: read.rowBytes, width: texture.width, height: texture.height, format: texture.pixelFormat)
                            let name = target.stage.map { DiagStreamStages.pngName(stage: $0["stage"] as? String ?? "stage", eye: $0["eye"] as? String ?? "unknown") }
                                ?? "drawable-\(target.drawableIndex)-texture-\(target.textureIndex)-slice-\(slice).png"
                            let url = directory.appendingPathComponent(name)
                            try writePNG(url: url, width: texture.width, height: texture.height, rgba: rgba)
                            bytes += (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                            if var entry = target.stage {
                                entry["png"] = name; entry["width"] = texture.width; entry["height"] = texture.height
                                entry["pixel_format"] = formatName(texture.pixelFormat)
                                entry["pixel_format_raw"] = texture.pixelFormat.rawValue
                                stages.append(entry)
                                continue
                            }
                            let matching = target.views.filter { ($0["slice"] as? Int) == slice }
                            // Preserve every view assignment, including shared slices.
                            for view in matching.isEmpty ? [["slice": slice, "view": -1, "eye": "unknown"]] : matching {
                                var entry = view
                                entry["drawable_index"] = target.drawableIndex
                                entry["texture_index"] = target.textureIndex
                                entry["png"] = name; entry["width"] = texture.width; entry["height"] = texture.height
                                entry["pixel_format"] = formatName(texture.pixelFormat)
                                entry["pixel_format_raw"] = texture.pixelFormat.rawValue
                                entry["rate_map"] = read.rateTables[slice]
                                slices.append(entry)
                            }
                        }
                    }
                    var json = metadata
                    json["utc"] = utc; json["t_ms"] = tMs; json["slices"] = slices
                    json["ms_encode_blit"] = encodedMs
                    if !stages.isEmpty {
                        json["stages"] = stages
                        json["resample_chain"] = DiagStreamStages.resampleChain
                    }
                    let sourceFormat = formatName(reads[0].target.texture.pixelFormat)
                    if let pose {
                        DiagCapturePose.annotate(&json, sourcePixelFormat: sourceFormat, render: pose.render, display: pose.display, renderT: pose.renderT, displayT: pose.displayT, simYawDitherRad: pose.simYawDitherRad)
                    } else {
                        DiagCapturePose.annotateEncoding(&json, sourcePixelFormat: sourceFormat)
                    }
                    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
                    bytes += data.count
                    Diag.log("capture", tMs: tMs, [ "dir": directory.lastPathComponent, "reason": reason, "slices": slices.count, "stages": stages.count, "bytes": bytes,
                                         "ms_encode_blit": encodedMs, "ms_gpu_done": gpuDoneMs, "ms_to_write": (ProcessInfo.processInfo.systemUptime - start) * 1000])
                    Diag.log("capture_trigger", ["step": "written", "reason": reason, "dir": directory.lastPathComponent])
                    completion(true)
                } catch {
                    Diag.log("capture", ["error": error.localizedDescription, "dir": directory.lastPathComponent])
                    completion(false)
                }
            }
        }
    }
}

// Sharpness chain (docs/lumen/sharpness-chain.md): the client's resample stages before the drawable, drawn on a capture
// frame by the stream's own fragment shader (same planes, sampler and colour constants) into one texture per eye and stage:
// decoded = FFR off, the eye's half of the decoded frame at 1:1 (texel centres, so only the chroma upsample resamples);
// expanded = the stream's FFR decompress at the stream view size, no warp. The drawable is the warp's output.
// Pure Foundation/simd (unit tested: tests/swift/DiagStreamStagesTests.swift); Renderer draws the plans.
enum DiagStreamStages {
    // Shaders.metal videoFrameFragmentShader_* colorSampler: mip_filter::none, mag/min linear; address and coord are
    // Metal's defaults (clamp_to_edge, normalized).
    static let sampler: [String: Any] = ["min_filter": "linear", "mag_filter": "linear", "mip_filter": "none",
                                         "address": "clamp_to_edge", "coord": "normalized"]

    struct Plan: Equatable {
        let stage: String           // "decoded" | "expanded"
        let eye: String             // "L" | "R"
        let width: Int
        let height: Int
        let uvRect: SIMD4<Float>    // x, y, w, h of the eye in the decoded frame's normalised coordinates
        let ffr: Bool
    }

    // decodedWidth/Height: the decoded frame (both eyes side by side); viewWidth/Height: the stream view (FFR target).
    static func plans(decodedWidth: Int, decodedHeight: Int, viewWidth: Int, viewHeight: Int, ffr: Bool) -> [Plan] {
        ["L", "R"].enumerated().flatMap { index, eye -> [Plan] in
            let rect = SIMD4<Float>(Float(index) * 0.5, 0, 0.5, 1)
            return [Plan(stage: "decoded", eye: eye, width: decodedWidth / 2, height: decodedHeight, uvRect: rect, ffr: false),
                    Plan(stage: "expanded", eye: eye, width: ffr ? viewWidth : decodedWidth / 2, height: ffr ? viewHeight : decodedHeight,
                         uvRect: rect, ffr: ffr)]
        }
    }

    static func pngName(stage: String, eye: String) -> String { "stage-\(stage)-\(eye).png" }

    // capture.json "stages" entry (DiagFrameCapture.submit adds png, width, height and pixel_format).
    static func record(_ plan: Plan, planes: [(format: String, width: Int, height: Int)], shader: String, decoderPixelFormat: String) -> [String: Any] {
        let chroma: String
        if planes.count < 2 {
            chroma = "in driver sampler (private YCbCr format)"
        } else {
            let (luma, cbcr) = (planes[0], planes[1])
            chroma = cbcr.width * 2 == luma.width && cbcr.height * 2 == luma.height ? "4:2:0"
                : cbcr.width * 2 == luma.width && cbcr.height == luma.height ? "4:2:2" : "\(cbcr.width)x\(cbcr.height) of \(luma.width)x\(luma.height)"
        }
        return ["stage": plan.stage, "eye": plan.eye, "encoding": "srgb", "sampler": sampler,
                "source": ["ffr": plan.ffr, "uv_rect": [plan.uvRect.x, plan.uvRect.y, plan.uvRect.z, plan.uvRect.w].map(Double.init),
                           "planes": planes.map { ["format": $0.format, "width": $0.width, "height": $0.height] as [String: Any] },
                           "chroma_subsampling": chroma, "shader": shader, "vertex": "diagStageVertexShader",
                           "decoder_pixel_format": decoderPixelFormat] as [String: Any]]
    }

    // Every resample between the decoder and the display, in order (capture.json "resample_chain").
    static let resampleChain: [[String: Any]] = [
        ["step": "decode_chroma", "sampler": sampler,
         "what": "chroma plane (4:2:0: half size both ways) bilinearly upsampled at the luma coordinate in the stream fragment shader; private YCbCr formats do it in the driver's sampler"],
        ["step": "ffr_expand_and_warp", "sampler": sampler,
         "what": "one bilinear sample per drawable pixel: decompressAxisAlignedCoord (FFR) then the view projection, no mipmaps (minification aliases)"],
        ["step": "compositor", "sampler": NSNull(),
         "what": "visionOS compositor: rate-mapped drawable to the display panel; not readable from the app"]]
}

#if os(visionOS)
import CompositorServices

final class DiagFrameCaptureSession {
    private let gate = DiagCaptureGate(requests: DiagCaptureRequests.shared)
    private var lastWait: String?   // render thread only: log each wait reason once, not per frame
    // Request-file poll: a utility timer, never the render thread. The session exists only with diagnostics on.
    private let requestFile: DiagCaptureRequestFile
    private let pollQueue = DispatchQueue(label: "uk.lumenio.alvr.capture.request", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    init() {
        DiagCaptureRequests.shared.setAcceptsMarks(true)
        DiagCaptureRequests.shared.configureAfterMs(DiagCaptureRequestFile.afterMs(environment: ProcessInfo.processInfo.environment))
        requestFile = DiagCaptureRequestFile(enabled: Diag.isOn, directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diag"))
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler { [requestFile] in
            if requestFile.poll(nowMs: Diag.monotonicMs()) {
                DiagCaptureRequests.shared.requestStreaming()
                Diag.log("capture_trigger", ["step": "request_seen", "source": "request_file", "file": DiagCaptureRequestFile.name])
            }
        }
        timer.resume()
        pollTimer = timer
        Diag.log("capture_trigger", ["step": "session_started", "dir": requestFile.url.deletingLastPathComponent().path,
                                     "after_ms": DiagCaptureRequestFile.afterMs(environment: ProcessInfo.processInfo.environment).map(String.init) ?? "off"])
    }
    deinit {
        pollTimer?.cancel()
        DiagCaptureRequests.shared.setAcceptsMarks(false)
        DiagCaptureRequests.shared.configureAfterMs(nil)
    }

    // `streamFrame`: stream content was composited into these drawables this frame (captures them as presented).
    // `pose`: render/display head pose of the stream frame being presented (DiagCapturePose); nil when idle.
    // `stages`: draws the sharpness-chain stage textures into `buffer` (DiagStreamStages); called only when a request is
    // taken on a stream frame.
    func encode(buffer: MTLCommandBuffer, drawables: [LayerRenderer.Drawable], idle: Bool, streamFrame: Bool = false,
                pose: DiagFrameCapture.PoseRecord? = nil, chart: CornerChartRenderer?, stages: (() -> [DiagFrameCapture.Target])? = nil) {
        DiagCaptureRequests.shared.setAcceptsMarks(idle)
        let request: DiagCaptureRequests.Request
        switch gate.next(nowMs: Diag.monotonicMs(), idle: idle, streamFrame: streamFrame) {
        case .none:
            lastWait = nil; return
        case .busy(let pending):
            if pending, lastWait != "busy" { lastWait = "busy"; Diag.log("capture_trigger", ["step": "waiting", "why": "previous_capture_in_flight"]) }
            return
        case .waiting(let why):
            if lastWait != why { lastWait = why; Diag.log("capture_trigger", ["step": "waiting", "why": why]) }
            return
        case .request(let taken):
            lastWait = nil; request = taken
        }
        Diag.log("capture_trigger", ["step": "request_taken", "reason": request.reason, "number": request.number, "idle": idle, "stream_frame": streamFrame])
        let targets = drawables.enumerated().flatMap { index, drawable in
            drawable.colorTextures.enumerated().map { textureIndex, texture in
                let views: [[String: Any]] = drawable.views.enumerated().compactMap { viewIndex, view in
                    guard view.textureMap.textureIndex == textureIndex else { return nil }
                    let vp = view.textureMap.viewport, t = drawable.gimmeTangents(viewIndex: viewIndex)
                    return ["eye": view.transform.columns.3.x <= 0 ? "L" : "R", "view": viewIndex, "slice": view.textureMap.sliceIndex,
                            "viewport": [vp.originX, vp.originY, vp.width, vp.height], "tangents": [t.x, t.y, t.z, t.w], "texture_index": textureIndex]
                }
                let maps = drawable.rasterizationRateMaps
                return DiagFrameCapture.Target(texture: texture, views: views, rateMap: maps.indices.contains(textureIndex) ? maps[textureIndex] : maps.first, drawableIndex: index, textureIndex: textureIndex)
            }
        }
        let stageTargets = streamFrame ? stages?() ?? [] : []   // after the drawables: submit takes its encoding from the first target
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diag/captures/\(stamp)-\(request.number)")
        let chartState = chart?.captureSnapshot() ?? ["mode": CornerChartMode.off.rawValue, "eye": NSNull(), "spoke": NSNull(),
                                                     "pct": NSNull(), "ring_percents": CornerChart.ringPercents,
                                                     "cut_percents": CornerChart.cutPercents, "marks": [:]]
        let trigger: [String: Any] = ["reason": request.reason,
                                     "eye": request.eye as Any? ?? NSNull(), "pct": request.pct as Any? ?? NSNull(),
                                     "pos_deg": request.positionDegrees as Any? ?? NSNull()]
        var metadata: [String: Any] = ["corner_chart": chartState, "trigger": trigger]
        if let debugEyes = EventHandler.shared.debugEyeTangentsRecord {
            metadata["debug_eye_tangents"] = debugEyes   // the per-eye FOV the server got; slices keep the drawable's own
        }
        DiagFrameCapture.submit(buffer: buffer, targets: targets + stageTargets, directory: directory,
                                metadata: metadata,
                                pose: streamFrame ? pose : nil) { [gate] ok in
            if !ok { Diag.log("capture_trigger", ["step": "skipped", "reason": request.reason, "why": "capture_failed_see_capture_error"]) }
            gate.finished()
        }
        Diag.log("capture_trigger", ["step": "submitted", "reason": request.reason, "dir": directory.lastPathComponent, "targets": targets.count,
                                     "stages": stageTargets.count])
    }
}
#endif
