import Foundation
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
    }
    private struct Readback {
        let target: Target
        let buffer: MTLBuffer
        let rowBytes: Int
        let imageBytes: Int
        let slices: Int
        let rateTables: [[String: Any]]
    }
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

    static func submit(buffer: MTLCommandBuffer, targets: [Target], directory: URL, metadata: [String: Any], completion: @escaping (Bool) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        let tMs = Diag.monotonicMs()
        let utc = ISO8601DateFormatter().string(from: Date())
        var reads: [Readback] = []
        // Allocate all buffers before encoding any copies. One in-flight capture bounds memory.
        for target in targets {
            let texture = target.texture
            guard texture.pixelFormat == .rgba16Float || texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .bgra8Unorm else {
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
            let tables = (0..<slices).map { rateTables(map: target.rateMap, layer: $0, width: texture.width, height: texture.height) }
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
        buffer.addCompletedHandler { command in
            queue.async {
                guard command.status == .completed else {
                    Diag.log("capture", ["error": command.error?.localizedDescription ?? "command_buffer_failed"])
                    completion(false); return
                }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var slices: [[String: Any]] = []
                    var bytes = 0
                    for read in reads {
                        let target = read.target, texture = target.texture
                        for slice in 0..<read.slices {
                            let pointer = read.buffer.contents().advanced(by: slice * read.imageBytes)
                            var rgba = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
                            for y in 0..<texture.height {
                                let row = pointer.advanced(by: y * read.rowBytes)
                                for x in 0..<texture.width {
                                    for c in 0..<4 {
                                        let value: UInt8
                                        if texture.pixelFormat == .rgba16Float {
                                            let f = Float(Float16(bitPattern: row.assumingMemoryBound(to: UInt16.self)[x * 4 + c]))
                                            value = UInt8((min(1, max(0, f.isNaN ? 0 : f)) * 255).rounded())
                                        } else {
                                            let channel = texture.pixelFormat == .bgra8Unorm && c < 3 ? 2 - c : c
                                            value = row.assumingMemoryBound(to: UInt8.self)[x * 4 + channel]
                                        }
                                        rgba[(y * texture.width + x) * 4 + c] = value
                                    }
                                }
                            }
                            let name = "drawable-\(target.drawableIndex)-texture-\(target.textureIndex)-slice-\(slice).png"
                            let url = directory.appendingPathComponent(name)
                            try writePNG(url: url, width: texture.width, height: texture.height, rgba: rgba)
                            bytes += (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                            let matching = target.views.filter { ($0["slice"] as? Int) == slice }
                            // Preserve every view assignment, including shared slices.
                            for view in matching.isEmpty ? [["slice": slice, "view": -1, "eye": "unknown"]] : matching {
                                var entry = view
                                entry["drawable_index"] = target.drawableIndex
                                entry["texture_index"] = target.textureIndex
                                entry["png"] = name; entry["width"] = texture.width; entry["height"] = texture.height
                                entry["pixel_format"] = texture.pixelFormat == .rgba16Float ? "rgba16Float" : texture.pixelFormat == .rgba8Unorm ? "rgba8Unorm" : "bgra8Unorm"
                                entry["pixel_format_raw"] = texture.pixelFormat.rawValue
                                entry["rate_map"] = read.rateTables[slice]
                                slices.append(entry)
                            }
                        }
                    }
                    var json = metadata
                    json["utc"] = utc; json["t_ms"] = tMs; json["slices"] = slices
                    json["ms_encode_blit"] = encodedMs
                    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
                    bytes += data.count
                    Diag.log("capture", tMs: tMs, [ "dir": directory.lastPathComponent, "slices": slices.count, "bytes": bytes,
                                         "ms_encode_blit": encodedMs, "ms_to_write": (ProcessInfo.processInfo.systemUptime - start) * 1000])
                    completion(true)
                } catch {
                    Diag.log("capture", ["error": error.localizedDescription, "dir": directory.lastPathComponent])
                    completion(false)
                }
            }
        }
    }
}

#if os(visionOS)
import CompositorServices

final class DiagFrameCaptureSession {
    private let lock = NSLock()
    private var busy = false
    init() { DiagCaptureRequests.shared.setAcceptsMarks(true) }
    deinit { DiagCaptureRequests.shared.setAcceptsMarks(false) }

    func encode(buffer: MTLCommandBuffer, drawables: [LayerRenderer.Drawable], idle: Bool, chart: CornerChartRenderer?) {
        DiagCaptureRequests.shared.setAcceptsMarks(idle)
        lock.lock()
        guard !busy, let request = DiagCaptureRequests.shared.take(nowMs: Diag.monotonicMs(), idle: idle) else { lock.unlock(); return }
        busy = true
        lock.unlock()
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
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diag/captures/\(stamp)-\(request.number)")
        let chartState = chart?.captureSnapshot() ?? ["mode": CornerChartMode.off.rawValue, "eye": NSNull(), "spoke": NSNull(),
                                                     "pct": NSNull(), "ring_percents": CornerChart.ringPercents,
                                                     "cut_percents": CornerChart.cutPercents, "marks": [:]]
        let trigger: [String: Any] = ["reason": request.eye == nil ? "start_timer" : "corner_mark",
                                     "eye": request.eye as Any? ?? NSNull(), "pct": request.pct as Any? ?? NSNull(),
                                     "pos_deg": request.positionDegrees as Any? ?? NSNull()]
        DiagFrameCapture.submit(buffer: buffer, targets: targets, directory: directory,
                                metadata: ["corner_chart": chartState, "trigger": trigger]) { [self] _ in
            lock.lock(); busy = false; lock.unlock()
        }
    }
}
#endif
