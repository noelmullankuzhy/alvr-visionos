//
//  GoldenFrame.swift
//
// Golden frame diagnostics (W35b): a server frame pair made on the Mac by tools/golden/golden-frame.py, shown on the
// stream path in place of a decoded frame, so reprojection, foveation and sharpness can be judged against a known truth.
// Documents/diag/golden/<set>/{meta.json, L.server.png, R.server.png}; the 80 px/deg golden PNGs are not displayed.
// Pure parts here (meta, hashes, foveation, overlays, pose, NV12, controls, log fields); GoldenFrameRenderer draws.
//

import CryptoKit
import CoreVideo
import Foundation
import simd

enum GoldenMetaError: Error, Equatable {
    case missingKey(String), unreadable(String), shaMismatch(String), badImage(String)

    // DIAG golden step=error: sha_ok false only when a hash was compared and differed.
    func fields(set: String) -> KeyValuePairs<String, Any> {
        switch self {
        case .missingKey(let key): return ["step": "error", "why": "missing_key", "key": key, "set": set, "sha_ok": "unknown"]
        case .unreadable(let key): return ["step": "error", "why": "unreadable", "key": key, "set": set, "sha_ok": "unknown"]
        case .shaMismatch(let key): return ["step": "error", "why": "sha_mismatch", "key": key, "set": set, "sha_ok": false]
        case .badImage(let key): return ["step": "error", "why": "bad_image", "key": key, "set": set, "sha_ok": true]
        }
    }
}

// The set's foveation as FFR.swift FoveationVars takes it: aligned centre size / shift (c, s), edge ratio r per axis,
// eye size ratio opt / coded, target eye = the render size, optimized eye = the coded size.
struct GoldenFoveation: Equatable {
    var enabled: Bool
    var targetEye, optimizedEye: SIMD2<UInt32>
    var eyeSizeRatio, centerSize, centerShift, edgeRatio: SIMD2<Float>
}

// While golden mode is on its foveation is the one in force; end() leaves the live value untouched.
struct FoveationOverride<V> {
    private(set) var value: V?
    var active: Bool { value != nil }

    mutating func begin(_ v: V) { value = v }
    mutating func end() { value = nil }
    func effective(live: V?) -> V? { value ?? live }
}

struct GoldenMeta {
    struct Overlays {
        let frustumRect: [CornerEye: CornerTangents]
        let eyeAxis: [CornerEye: CornerChart.Point]
        let lens: [CornerEye: [CornerChart.Point]]?   // nil: no lens reference in the set
    }

    let set, contentKind: String
    let pxPerDeg: Double
    let frustum, streamTangents: [CornerEye: CornerTangents]
    let goldenSize: [CornerEye: [Int]]
    let renderSize, serverSize: [Int]
    let serverPNG: [CornerEye: String]
    let foveation: GoldenFoveation
    let overlays: Overlays
    let files: [String: String]   // name -> sha256

    // Tangents in the order the stream's vertex shader reads them: left, right, top, bottom.
    func sentTangents(_ eye: CornerEye) -> SIMD4<Float> {
        let t = streamTangents[eye]!
        return SIMD4<Float>(Float(t.left), Float(t.right), Float(t.top), Float(t.bottom))
    }

    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // A key path into the parsed JSON; a missing, null or mistyped value is missing_key with the dotted path of the
    // first key absent on the way (or of the value itself).
    private struct Node {
        let value: Any?, path: [String]
        var absent: [String]? = nil
        subscript(_ key: String) -> Node {
            let child = (value as? [String: Any])?[key]
            return Node(value: child, path: path + [key], absent: absent ?? (child == nil ? path + [key] : nil))
        }
        var isNull: Bool { value == nil || value is NSNull }
        func fail() -> GoldenMetaError { .missingKey((absent ?? path).joined(separator: ".")) }
        func string() throws -> String { guard let v = value as? String else { throw fail() }; return v }
        func bool() throws -> Bool { guard let v = value as? Bool else { throw fail() }; return v }
        func double() throws -> Double { guard let v = value as? NSNumber, !(value is Bool) else { throw fail() }; return v.doubleValue }
        func doubles(_ count: Int) throws -> [Double] {
            guard let v = value as? [NSNumber], v.count == count else { throw fail() }
            return v.map(\.doubleValue)
        }
        func ints(_ count: Int) throws -> [Int] { try doubles(count).map { Int($0) } }
        func dict() throws -> [String: Any] { guard let v = value as? [String: Any] else { throw fail() }; return v }
        func tangents() throws -> CornerTangents {
            let t = try doubles(4)
            return CornerTangents(left: t[0], right: t[1], bottom: t[2], top: t[3])
        }
        func point() throws -> CornerChart.Point { let t = try doubles(2); return CornerChart.Point(x: t[0], y: t[1]) }
        func eyes<T>(_ read: (Node) throws -> T) throws -> [CornerEye: T] {
            [.left: try read(self["L"]), .right: try read(self["R"])]
        }
    }

    static func parse(_ data: Data) throws -> GoldenMeta {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GoldenMetaError.unreadable("meta.json") }
        let root = Node(value: object, path: [])
        let aligned = root["foveation"]["aligned"], x = aligned["x"], y = aligned["y"]
        let render = try root["render"]["size"].ints(2), server = try root["server"]["size"].ints(2)
        for axis in [x, y] where axis.isNull { throw axis.fail() }
        let ratio = try aligned["eye_size_ratio"].doubles(2)
        let foveation = GoldenFoveation(
            enabled: try root["foveation"]["enabled"].bool(),
            targetEye: SIMD2(UInt32(render[0]), UInt32(render[1])),
            optimizedEye: SIMD2(UInt32(try x["coded"].double()), UInt32(try y["coded"].double())),
            eyeSizeRatio: SIMD2(Float(ratio[0]), Float(ratio[1])),
            centerSize: SIMD2(Float(try x["c"].double()), Float(try y["c"].double())),
            centerShift: SIMD2(Float(try x["s"].double()), Float(try y["s"].double())),
            edgeRatio: SIMD2(Float(try x["r"].double()), Float(try y["r"].double())))
        let overlays = root["overlays"], lensNode = overlays["lens_outline"]
        let lens: [CornerEye: [CornerChart.Point]]? = lensNode.isNull ? nil : try lensNode.eyes { eye in
            guard let polygon = eye["polygon"].value as? [Any] else { throw eye["polygon"].fail() }
            return try polygon.indices.map { try Node(value: polygon[$0], path: eye.path + ["polygon", String($0)])["tan"].point() }
        }
        let filesNode = root["files"]
        var files: [String: String] = [:]
        for (name, _) in try filesNode.dict() { files[name] = try filesNode[name]["sha256"].string() }
        let golden = root["golden"]
        return GoldenMeta(
            set: try root["set"].string(), contentKind: try root["content"]["kind"].string(),
            pxPerDeg: try root["density"]["px_per_deg_axis"].double(),
            frustum: try root["frustum"]["tangents_LRBT"].eyes { try $0.tangents() },
            streamTangents: try root["server"]["stream_tangents_LRBT"].eyes { try $0.tangents() },
            goldenSize: golden.isNull ? [:] : try golden.eyes { try $0["size"].ints(2) },
            renderSize: render, serverSize: server,
            serverPNG: try root["server"]["png"].eyes { try $0.string() },
            foveation: foveation,
            overlays: Overlays(frustumRect: try overlays["frustum_rect"].eyes { try $0["tangents_LRBT"].tangents() },
                               eyeAxis: try overlays["eye_axis"].eyes { try $0["tan"].point() }, lens: lens),
            files: files)
    }

    // meta.json parsed and every listed file present hashed. The server PNGs must be present and listed; the golden
    // PNGs (not displayed) may be left on the Mac.
    static func load(directory: URL) throws -> GoldenMeta {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")) else { throw GoldenMetaError.unreadable("meta.json") }
        let meta = try parse(data)
        let server = [meta.serverPNG[.left]!, meta.serverPNG[.right]!]
        for name in server + meta.files.keys.sorted().filter({ !server.contains($0) }) {
            let url = directory.appendingPathComponent(name)
            guard let expected = meta.files[name] else { throw GoldenMetaError.missingKey("files.\(name)") }
            guard let bytes = try? Data(contentsOf: url) else {
                if server.contains(name) { throw GoldenMetaError.unreadable(name) }
                continue
            }
            if sha256Hex(bytes) != expected { throw GoldenMetaError.shaMismatch(name) }
        }
        return meta
    }
}

enum GoldenFrameSetting {
    static let off = "Off"

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag/golden")
    }

    // The picker's values: Off, then every subdirectory holding a meta.json, sorted.
    static func choices(root: URL = root) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return [off] + names.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/meta.json").path) }.sorted()
    }
}

// Overlays in eye NDC (CornerTangents.ndc, as meta.json records them). The eye axis and lens outline are fixed to the
// eye; the frustum rectangle is the frame's edge, so it moves with the frame (frame-to-view rotation of the stream).
enum GoldenOverlay {
    typealias Point = CornerChart.Point
    typealias Segment = (a: Point, b: Point)
    static let crossHalfTan = 0.05   // ~2.9 deg each way

    static func ndc(_ t: CornerTangents, _ p: Point) -> Point { let n = t.ndc(x: p.x, y: p.y); return Point(x: n.x, y: n.y) }

    // Frame-tangent rectangle corners (BL, BR, TR, TL) seen through the view; nil when any is not in front of the eye.
    static func frustumCorners(_ t: CornerTangents, rect r: CornerTangents, frameToView: simd_float3x3) -> [Point]? {
        var out: [Point] = []
        for (x, y) in [(-r.left, -r.bottom), (r.right, -r.bottom), (r.right, r.top), (-r.left, r.top)] {
            let v = frameToView * SIMD3<Float>(Float(x), Float(y), -1)
            guard v.z < -1e-4 else { return nil }
            out.append(ndc(t, Point(x: Double(v.x / -v.z), y: Double(v.y / -v.z))))
        }
        return out
    }

    static func axisCross(_ t: CornerTangents, _ axis: Point) -> [Segment] {
        let k = crossHalfTan
        return [(ndc(t, Point(x: axis.x - k, y: axis.y)), ndc(t, Point(x: axis.x + k, y: axis.y))),
                (ndc(t, Point(x: axis.x, y: axis.y - k)), ndc(t, Point(x: axis.x, y: axis.y + k)))]
    }

    static func closed(_ points: [Point]) -> [Segment] {
        points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
    }

    // Each segment as a quad strokePx thick on a widthPx x heightPx view (corner order x0y0, x1y0, x0y1, x1y1).
    static func quads(_ segments: [Segment], widthPx w: Double, heightPx h: Double, strokePx: Double, color: SIMD4<Float>) -> [CornerChart.Quad] {
        segments.compactMap { s in
            let dx = (s.b.x - s.a.x) * w / 2, dy = (s.b.y - s.a.y) * h / 2, len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { return nil }
            let nx = -dy / len * strokePx / 2 * 2 / w, ny = dx / len * strokePx / 2 * 2 / h
            let c = [Point(x: s.a.x - nx, y: s.a.y - ny), Point(x: s.b.x - nx, y: s.b.y - ny),
                     Point(x: s.a.x + nx, y: s.a.y + ny), Point(x: s.b.x + nx, y: s.b.y + ny)]
            let rect = CornerChart.Rect(x0: c.map(\.x).min()!, y0: c.map(\.y).min()!, x1: c.map(\.x).max()!, y1: c.map(\.y).max()!)
            return CornerChart.Quad(rect: rect, color: color, corners: c)
        }
    }
}

// The frame's pose: world-locked at the head pose P it was pinned at, or head-locked (follows the head, Q).
struct GoldenPose {
    private(set) var pinned: simd_float4x4
    private(set) var worldLocked = true

    init(shownAt p: simd_float4x4) { pinned = p }

    func framePose(current q: simd_float4x4) -> simd_float4x4 { worldLocked ? pinned : q }
    mutating func repin(current q: simd_float4x4) { pinned = q }
    // Back to world-locked pins at the current pose, so the frame does not jump.
    mutating func setWorldLocked(_ on: Bool, current q: simd_float4x4) {
        if on && !worldLocked { pinned = q }
        worldLocked = on
    }
}

// The server PNGs as one NV12 frame, L | R side by side as the stream decodes them: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
// BT.709 full range from the PNG code values (no colour management), 4:2:0 CbCr the box average of each 2x2 block.
enum GoldenNV12 {
    struct Image {
        let width, height, channels, bytesPerRow: Int   // channels 1 (grey), 3 (RGB) or 4 (RGBA, alpha ignored)
        let pixels: [UInt8]
    }

    struct Frame {
        let width, height: Int
        let luma: [UInt8]     // width x height
        let chroma: [UInt8]   // CbCr pairs, width / 2 x height / 2
    }

    static let kr = 0.2126, kb = 0.0722

    private static func ycc(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let y = kr * r + (1 - kr - kb) * g + kb * b
        return (y, (b - y) / (2 * (1 - kb)) + 128, (r - y) / (2 * (1 - kr)) + 128)
    }

    private static func clamp(_ v: Double) -> Int { min(255, max(0, Int(v.rounded()))) }

    static func code(r: UInt8, g: UInt8, b: UInt8) -> (Int, Int, Int) {
        let c = ycc(Double(r), Double(g), Double(b))
        return (clamp(c.0), clamp(c.1), clamp(c.2))
    }

    // nil: eyes of different sizes or an odd size.
    static func frame(left: Image, right: Image) -> Frame? {
        guard left.width == right.width, left.height == right.height, left.width % 2 == 0, left.height % 2 == 0,
              [1, 3, 4].contains(left.channels), [1, 3, 4].contains(right.channels) else { return nil }
        let ew = left.width, h = left.height, w = 2 * ew
        var luma = [UInt8](repeating: 0, count: w * h)
        var chroma = [UInt8](repeating: 128, count: w * h / 2)
        for (index, eye) in [left, right].enumerated() {
            let x0 = index * ew, grey = eye.channels == 1
            eye.pixels.withUnsafeBufferPointer { p in
                for by in 0..<(h / 2) {
                    for bx in 0..<(ew / 2) {
                        var cb = 0.0, cr = 0.0
                        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                            let x = 2 * bx + dx, y = 2 * by + dy, o = y * eye.bytesPerRow + x * eye.channels
                            let r = Double(p[o]), g = grey ? r : Double(p[o + 1]), b = grey ? r : Double(p[o + 2])
                            let c = grey ? (r, 128, 128) : ycc(r, g, b)
                            luma[y * w + x0 + x] = UInt8(clamp(c.0))
                            cb += c.1; cr += c.2
                        }
                        let o = by * w + x0 + 2 * bx
                        chroma[o] = UInt8(clamp(cb / 4)); chroma[o + 1] = UInt8(clamp(cr / 4))
                    }
                }
            }
        }
        return Frame(width: w, height: h, luma: luma, chroma: chroma)
    }

    // The live decoder output's colour tags (VideoHandler.swift:383-385), so the YCbCr sampler, which reads matrix and range
    // from the buffer, converts the golden pair as it converts the stream.
    static let colourTags: [(key: CFString, value: CFString)] = [
        (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
        (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB),
    ]

    // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, IOSurface-backed and Metal-compatible (CVMetalTextureCache binds it).
    static func pixelBuffer(_ f: Frame) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, f.width, f.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes as CFDictionary, &out) == kCVReturnSuccess, let buffer = out else { return nil }
        for tag in colourTags { CVBufferSetAttachment(buffer, tag.key, tag.value, .shouldPropagate) }
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
}

// The Diag controls, one selected at a time: pinch right / left (d-pad) selects, hold right (A) applies, hold left (B)
// steps back. Every applied change is one DIAG golden step=setting line.
final class GoldenFrameSession {
    enum Control: Int, CaseIterable { case lock, quality, overlays, capture, exit }
    enum Action { case next, previous, apply, back }
    enum Event: Equatable { case setting(key: String, value: String), repin, quality(Float), capture, exit }

    struct Overlays: Equatable {
        var frustum = true, axis = true, lens = true
        var code: String { [frustum, axis, lens].map { $0 ? "1" : "0" }.joined() }
    }

    static let qualities: [Float] = [0.5, 0.75, 1.0]
    private static let overlayCycle = [Overlays(), Overlays(frustum: true, axis: false, lens: false), Overlays(frustum: false, axis: true, lens: false),
                                       Overlays(frustum: false, axis: false, lens: true), Overlays(frustum: false, axis: false, lens: false)]

    private(set) var control = Control.lock
    private(set) var worldLocked = true
    private(set) var quality: Float
    private(set) var overlays = Overlays()

    // quality: the layer's read-back at entry, snapped to the nearest step (nil: 1.0).
    init(quality: Float?) {
        let q = quality ?? 1.0
        self.quality = Self.qualities.min { abs($0 - q) < abs($1 - q) }!
    }

    var statusText: String {
        switch control {
        case .lock: return worldLocked ? "UorLd" : "HEAd"
        case .quality: return String(format: "rq %.2f", quality)
        case .overlays: return "OL " + overlays.code
        case .capture: return "CAP"
        case .exit: return "End"
        }
    }

    func apply(_ action: Action) -> [Event] {
        switch action {
        case .next: control = Control(rawValue: min(control.rawValue + 1, Control.allCases.count - 1))!; return []
        case .previous: control = Control(rawValue: max(control.rawValue - 1, 0))!; return []
        case .apply, .back:
            let step = action == .apply ? 1 : -1
            switch control {
            case .lock:
                if action == .back { return [.setting(key: "repin", value: "true"), .repin] }
                worldLocked.toggle()
                return worldLocked ? [.setting(key: "world_locked", value: "true"), .repin] : [.setting(key: "world_locked", value: "false")]
            case .quality:
                let i = Self.qualities.firstIndex(of: quality)!, n = Self.qualities.count
                quality = Self.qualities[(i + step + n) % n]
                return [.setting(key: "rq", value: String(format: "%.3f", quality)), .quality(quality)]
            case .overlays:
                let n = Self.overlayCycle.count, i = Self.overlayCycle.firstIndex(of: overlays) ?? 0
                overlays = Self.overlayCycle[(i + step + n) % n]
                return [.setting(key: "overlays", value: overlays.code)]
            case .capture: return action == .apply ? [.setting(key: "capture", value: "start"), .capture] : []
            case .exit: return action == .apply ? [.setting(key: "exit", value: "live"), .exit] : []
            }
        }
    }
}

// W33 settle rule for a golden quality change: the rate map's screen size within 1 % of the expected size for 30
// consecutive frames (AutoCaptureSession.expectedScreen / matches); without a map the read-back; unconfirmed after 600.
struct GoldenQualitySettle {
    struct Result: Equatable { let quality: Float; let frames: Int; let settle: String; let screen: [Int]? }

    let reference: [Int]?, referenceQuality: Float?
    private var target: Float?
    private var frames = 0, confirmed = 0

    init(reference: [Int]?, referenceQuality: Float?) { (self.reference, self.referenceQuality) = (reference, referenceQuality) }

    var expected: [Int]? {
        guard let reference, let referenceQuality, let target else { return nil }
        return AutoCaptureSession.expectedScreen(quality: target, reference: reference, referenceQuality: referenceQuality)
    }

    mutating func set(_ q: Float) { target = q; frames = 0; confirmed = 0 }

    // One frame; the result once, when the change settles or times out.
    mutating func frame(screen: [Int]?, actual: Float?) -> Result? {
        guard let target else { return nil }
        frames += 1
        let byMap = expected != nil
        if let expected {
            confirmed = screen.map { AutoCaptureSession.matches($0, expected) } == true ? confirmed + 1 : 0
        } else if let actual, abs(actual - target) < 0.005 {
            confirmed += 1
        }
        let done = confirmed >= AutoCaptureSession.settleFrames ? (byMap ? "rate_map" : "render_quality")
            : frames >= AutoCaptureSession.timeoutFrames ? "timeout" : nil
        guard let done else { return nil }
        self.target = nil
        return Result(quality: target, frames: frames, settle: done, screen: screen)
    }
}

enum GoldenFrame {
    static let colour = "nv12 420f bt709 full range, sRGB transfer, encoding gamma 1"

    static func size(_ s: [Int]) -> String { s.map(String.init).joined(separator: "x") }

    // DIAG golden step=show|hide: the settings in force.
    static func fields(step: String, set: String, eyePx: [Int], density: Double, rq: Float?, worldLocked: Bool,
                       overlays: GoldenFrameSession.Overlays, shaOK: Bool) -> KeyValuePairs<String, Any> {
        ["step": step, "set": set, "eye_px": size(eyePx), "density": String(format: "%g", density), "rq": ChartCapture.quality(rq),
         "world_locked": worldLocked, "overlays": overlays.code, "sha_ok": shaOK]
    }

    static func settingFields(set: String, key: String, value: String) -> KeyValuePairs<String, Any> {
        ["step": "setting", "set": set, "key": key, "value": value]
    }

    static func settledFields(set: String, _ r: GoldenQualitySettle.Result, actual: Float?) -> KeyValuePairs<String, Any> {
        ["step": "settled", "set": set, "rq_set": ChartCapture.quality(r.quality), "rq": ChartCapture.quality(actual), "frames": r.frames,
         "settle": r.settle, "screen": r.screen.map(size) ?? "none"]
    }

    static func directoryName(set: String, stamp: String, quality: Float) -> String {
        String(format: "golden-%@-%@-rq%.2f", set, stamp, quality)
    }

    // capture.json "golden": the settings in force for the capture.
    static func settings(meta: GoldenMeta, requested: Float, actual: Float?, worldLocked: Bool, overlays: GoldenFrameSession.Overlays) -> [String: Any] {
        let f = meta.foveation
        return ["set": meta.set, "eye_px": meta.serverSize, "density_px_per_deg": meta.pxPerDeg, "render_size": meta.renderSize,
                "rq_set": ChartCapture.quality(requested), "rq": ChartCapture.quality(actual), "world_locked": worldLocked,
                "overlays": overlays.code, "content": meta.contentKind, "colour": colour,
                "foveation": ["enabled": f.enabled, "center_size": [f.centerSize.x, f.centerSize.y].map(Double.init),
                              "center_shift": [f.centerShift.x, f.centerShift.y].map(Double.init),
                              "edge_ratio": [f.edgeRatio.x, f.edgeRatio.y].map(Double.init),
                              "eye_size_ratio": [f.eyeSizeRatio.x, f.eyeSizeRatio.y].map(Double.init)]]
    }

    // golden_set is what tools/golden/golden-frame.py measure keys its rows on.
    static func captureMetadata(chart: [String: Any], meta: GoldenMeta, settings: [String: Any]) -> [String: Any] {
        ["chart_capture": ChartCapture.goldenMetadata(chart, set: meta.set), "trigger": ["reason": "chartcap"], "golden_set": meta.set,
         "golden": settings]
    }
}
