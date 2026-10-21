//
//  EyeDecodeWindows.swift
//
// "Per-eye decode windows (debug)": two windows, one per eye, showing the RAW decoded half of the side-by-side
// frame (still foveation-warped, before the renderer samples it), so what is shown is the decoder's output and nothing
// the renderer did. Each has counters: decoded frames, fps, gaps, repeats, max nits.
//
// Cost control: counters are fed one timestamp per decoded frame (no pixels). Pixels are read at most once per
// 66 ms, on a utility queue, with one copy in flight and nothing queued behind it; the decoded buffer is retained only
// for that read. The render thread does a gate check and a dispatch.
//
import SwiftUI
import CoreVideo
import simd

final class EyeDecodeWindows: ObservableObject {
    static let shared = EyeDecodeWindows()
    static let windowIDs = ["EyeWindowLeft", "EyeWindowRight"]
    static let titles = ["Left eye (decoded)", "Right eye (decoded)"]
    private static let maxEyeWidth = 360

    // Streaming with the setting on; the windows close when this goes false. Main thread.
    @Published private(set) var active = false
    let models = [EyeWindowModel(), EyeWindowModel()]

    private let lock = NSLock()
    private var running = false
    private var counters = [EyeDecodeCounters(frameIntervalNs: 11_111_111), EyeDecodeCounters(frameIntervalNs: 11_111_111)]
    private var gate = EyeCopyGate(minIntervalNs: 66_000_000)
    private var shown = [0, 0]
    private let copyAvailable = DispatchSemaphore(value: 1)
    private let copyQueue = DispatchQueue(label: "ALVR.EyeWindows", qos: .utility)

    private static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // Stream start (and window open): idempotent, so counters are not reset by the second call.
    func start(refreshRate: Double = 0) {
        guard ALVRClientApp.gStore.settings.eyeDecodeWindows else { return }
        lock.lock()
        if !running {
            running = true
            let interval = UInt64(1e9 / (refreshRate >= 1 ? refreshRate : 90))
            counters = [EyeDecodeCounters(frameIntervalNs: interval), EyeDecodeCounters(frameIntervalNs: interval)]
            gate = EyeCopyGate(minIntervalNs: 66_000_000)
            shown = [0, 0]
        }
        lock.unlock()
        DispatchQueue.main.async { self.active = true }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        DispatchQueue.main.async {
            self.active = false
            self.models.forEach { $0.reset() }
        }
    }

    // VT callback, every decoded frame. Both eyes come from one side-by-side buffer, so both see this timestamp.
    func decoded(timestampNs: UInt64) {
        let now = Self.nowNs()
        lock.lock()
        guard running else { lock.unlock(); return }
        var lines = [String]()
        for eye in 0..<2 {
            counters[eye].record(timestampNs: timestampNs, nowNs: now)
            if let line = counters[eye].logLine(eye: eye == 0 ? "L" : "R", nowNs: now) { lines.append(line) }
        }
        lock.unlock()
        for line in lines { alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), line) }
    }

    // Render thread, after the frame is bound: admission and dispatch only.
    func tap(pixelBuffer: CVPixelBuffer, colour: StreamColourState, timestampNs: UInt64) {
        lock.lock()
        let due = running && gate.admit(nowNs: Self.nowNs())
        lock.unlock()
        guard due, copyAvailable.wait(timeout: .now()) == .success else { return }
        copyQueue.async { [self] in
            let eyes = Self.sample(pixelBuffer: pixelBuffer, colour: colour)
            let format = ColourPipeline.fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
            let now = Self.nowNs()
            lock.lock()
            if let eyes = eyes {
                for eye in 0..<2 {
                    counters[eye].maxNits = eyes[eye].maxNits
                    counters[eye].recordShown(nowNs: now)
                    shown[eye] += 1
                }
            }
            let snapshot = (0..<2).map { eye in (counters[eye], shown[eye], counters[eye].lastIndex) }
            lock.unlock()
            let mapping = colour.selection.isPQ ? "PQ to SDR: nits/203 clipped, sRGB, no gamut map" : "SDR codes, as decoded"
            DispatchQueue.main.async { [self] in
                defer { copyAvailable.signal() }
                for (eye, (c, shownCount, index)) in snapshot.enumerated() {
                    let image = eyes.flatMap { Self.cgImage($0[eye]) }
                    models[eye].update(image: image, text:
                        "\(eye == 0 ? "L" : "R")  idx \(index)  ts \(timestampNs / 1_000_000) ms  shown \(shownCount) (shown_fps \(String(format: "%.1f", c.shownFps(nowNs: now))))\n"
                        + String(format: "decoded %ld (%.1f/s)  unique %ld (%.1f/s)  repeats %ld\n", c.decoded, c.decodedFps(nowNs: now), c.unique, c.uniqueFps(nowNs: now), c.repeats)
                        + String(format: "gaps %ld (%ld missing)  stalls %ld  max %.0f nits\n", c.gaps, c.missing, c.stalls, c.maxNits)
                        + (eyes == nil ? "unsupported pixel format \(format)" : "raw decoded half, foveation-warped | \(mapping)")
                        + "\n" + EyeDecodeCounters.definitions)
                }
            }
        }
    }

    // MARK: - Pixels

    struct EyeImage {
        let width: Int
        let height: Int
        let rgba: [UInt8]
        let maxNits: Double
    }

    // Left half (x < width/2) and right half, stride-sampled to at most maxEyeWidth wide. Max nits is over those samples.
    static func sample(pixelBuffer: CVPixelBuffer, colour: StreamColourState) -> [EyeImage]? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let bits = HDRPipeline.pqPlaneBitDepth(pixelFormat: format), CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let cw = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), ch = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let bytes = bits > 8 ? 2 : 1
        let half = width / 2
        let step = max(1, half / maxEyeWidth)
        let outW = half / step, outH = height / step
        guard outW > 0, outH > 0 else { return nil }
        let selection = colour.selection
        func code(_ base: UnsafeRawPointer, _ offset: Int) -> Double {
            bytes == 1 ? Double(base.load(fromByteOffset: offset, as: UInt8.self))
                       : Double(base.load(fromByteOffset: offset, as: UInt16.self) >> 6) // 10-bit codes sit in the MSBs
        }
        return (0..<2).map { eye in
            var rgba = [UInt8](repeating: 255, count: outW * outH * 4)
            var maxNits = 0.0
            for oy in 0..<outH {
                let y = oy * step, cy = y * ch / height
                for ox in 0..<outW {
                    let x = eye * half + ox * step, cx = x * cw / width
                    let codes = simd_double3(code(yBase, y * yStride + x * bytes),
                                             code(cBase, cy * cStride + cx * 2 * bytes),
                                             code(cBase, cy * cStride + (cx * 2 + 1) * bytes))
                    let o = (oy * outW + ox) * 4
                    if selection.isPQ {
                        let nits = HDRPipeline.decodeNits(codes: codes, selection: selection)
                        maxNits = max(maxNits, nits.x, nits.y, nits.z)
                        rgba[o] = EyeToneMap.sdrByte(nits: nits.x)
                        rgba[o + 1] = EyeToneMap.sdrByte(nits: nits.y)
                        rgba[o + 2] = EyeToneMap.sdrByte(nits: nits.z)
                    } else {
                        let sample = simd_float4(ColourPipeline.sampleValue(code: codes.x, bitDepth: bits),
                                                 ColourPipeline.sampleValue(code: codes.y, bitDepth: bits),
                                                 ColourPipeline.sampleValue(code: codes.z, bitDepth: bits), 1)
                        let rgb = selection.yuvToRGB * sample
                        rgba[o] = UInt8(min(max(rgb.x, 0), 1) * 255)
                        rgba[o + 1] = UInt8(min(max(rgb.y, 0), 1) * 255)
                        rgba[o + 2] = UInt8(min(max(rgb.z, 0), 1) * 255)
                    }
                }
            }
            return EyeImage(width: outW, height: outH, rgba: rgba, maxNits: maxNits)
        }
    }

    private static func cgImage(_ eye: EyeImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(eye.rgba) as CFData) else { return nil }
        return CGImage(width: eye.width, height: eye.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: eye.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

final class EyeWindowModel: ObservableObject {
    @Published var image: CGImage?
    @Published var text = "waiting for decoded frames"

    func update(image: CGImage?, text: String) {
        if let image = image { self.image = image }
        self.text = text
    }

    func reset() {
        image = nil
        text = "waiting for decoded frames"
    }
}

struct EyeWindowView: View {
    let eye: Int
    @ObservedObject private var hub = EyeDecodeWindows.shared
    @ObservedObject private var model: EyeWindowModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(eye: Int) {
        self.eye = eye
        model = EyeDecodeWindows.shared.models[eye]
    }

    var body: some View {
        VStack(spacing: 8) {
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black.aspectRatio(1, contentMode: .fit)
            }
            Text(model.text)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 560)
        // Restored after a relaunch with no stream, or the stream ended: close.
        .onAppear { if !hub.active { dismissWindow(id: EyeDecodeWindows.windowIDs[eye]) } }
        .onChange(of: hub.active) { _, active in
            if !active { dismissWindow(id: EyeDecodeWindows.windowIDs[eye]) }
        }
    }
}

extension Scene {
    // Both windows fully visible: the Left window opens at the default spot, the Right one on its trailing side.
    // defaultWindowPlacement needs visionOS 2; on 1.x the windows overlap as before.
    @SceneBuilder func eyeWindowPlacement(trailingOf otherID: String?) -> some Scene {
        if #available(visionOS 2.0, *) {
            self.defaultSize(width: 520, height: 640)
                .defaultWindowPlacement { _, context in
                    if let otherID = otherID, let other = context.windows.first(where: { $0.id == otherID }) {
                        return WindowPlacement(.trailing(other))
                    }
                    return WindowPlacement()
                }
        } else {
            self
        }
    }
}
