import Foundation
import AVFoundation
import VideoToolbox

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw Failure("\(operation): OSStatus \(status)") }
}
func pqCode(_ nits: Double) -> UInt16 {
    let p = pow(nits / 10000, 2610.0 / 16384)
    let pq = pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)
    return UInt16((64 + 876 * pq).rounded())
}
let levels = [0.05, 0.25, 0.5, 1, 2, 4, 4.926].map { $0 * 203 }

final class Sink {
    let input: AVAssetWriterInput
    let lock = NSLock()
    var error: String?
    var frames = 0
    var bytes = 0
    var format: [String: Any] = [:]
    init(_ input: AVAssetWriterInput) { self.input = input }
    func receive(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        guard status == noErr, let sample = sample else { error = "callback status \(status)"; return }
        if let desc = CMSampleBufferGetFormatDescription(sample) {
            let ext = (CMFormatDescriptionGetExtensions(desc) as NSDictionary?) ?? [:]
            if let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary,
               let config = atoms["hvcC"] as? Data, config.count >= 19 {
                format = ["profileIDC": Int(config[1] & 31), "tier": Int(config[1] >> 5 & 1),
                          "levelIDC": Int(config[12]), "chromaFormatIDC": Int(config[16] & 3),
                          "lumaBitDepth": Int(config[17] & 7) + 8, "chromaBitDepth": Int(config[18] & 7) + 8]
            }
        }
        let timeout = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData && Date() < timeout { Thread.sleep(forTimeInterval: 0.001) }
        if !input.isReadyForMoreMediaData || !input.append(sample) { error = "writer append failed"; return }
        frames += 1
        bytes += CMSampleBufferGetTotalSampleSize(sample)
    }
}

func encode(out: URL, width: Int, height: Int, fps: Int, seconds: Double, bitrate: Int, kind: String) throws -> [String: Any] {
    let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw Failure("writer refuses video") }
    writer.add(input)
    defer { if writer.status == .writing { writer.cancelWriting() } }
    let sink = Sink(input)
    var session: VTCompressionSession?
    let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                   kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                   kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    try check(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
        outputCallback: { ref, _, status, _, sample in
            guard let ref = ref else { return }
            Unmanaged<Sink>.fromOpaque(ref).takeUnretainedValue().receive(status, sample)
        }, refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &session), "create encoder")
    guard let session = session else { throw Failure("no encoder") }
    defer { VTCompressionSessionInvalidate(session) }
    let isPQ = kind != "stress"
    let properties: [CFString: Any] = [
        kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel,
        kVTCompressionPropertyKey_RealTime: true,
        kVTCompressionPropertyKey_AllowFrameReordering: false,
        kVTCompressionPropertyKey_ExpectedFrameRate: fps,
        kVTCompressionPropertyKey_MaxKeyFrameInterval: fps,
        kVTCompressionPropertyKey_AverageBitRate: bitrate,
        kVTCompressionPropertyKey_ColorPrimaries: isPQ ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
        kVTCompressionPropertyKey_TransferFunction: isPQ ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,
        kVTCompressionPropertyKey_YCbCrMatrix: isPQ ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ]
    for (key, value) in properties { try check(VTSessionSetProperty(session, key: key, value: value as CFTypeRef), "set \(key)") }
    try check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare")
    guard writer.startWriting() else { throw Failure("start writer: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    let count = max(1, Int((seconds * Double(fps)).rounded()))
    guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { throw Failure("no pixel pool") }
    for frame in 0..<count {
        try autoreleasepool {
            var pixel: CVPixelBuffer?
            try check(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel), "allocate P010")
            guard let pixel = pixel else { throw Failure("no pixel") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) / 2
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) / 2
            let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt16.self)
            let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt16.self)
            // P010 stores each limited-range 10-bit code in the high bits of a 16-bit word.
            var row = [UInt16](repeating: 0, count: width)
            for x in 0..<width {
                if kind == "steps" { row[x] = pqCode(levels[min(levels.count - 1, frame / (2 * fps))]) << 6 }
                else if kind == "gradient" { row[x] = pqCode(Double(x) / Double(width - 1) * 10000) << 6 }
                else { row[x] = UInt16(64 + ((x + frame * 37) % 877)) << 6 }
            }
            for line in 0..<height {
                row.withUnsafeBufferPointer { src in
                    y.advanced(by: line * yStride).update(from: src.baseAddress!, count: width)
                }
                // Moving horizontal structure as well as the moving vertical ramp.
                if kind == "stress" && (line + frame * 13) % 128 < 16 {
                    y.advanced(by: line * yStride).update(repeating: UInt16(64 + (frame * 17) % 877) << 6, count: width)
                }
            }
            for line in 0..<(height / 2) { uv.advanced(by: line * uvStride).update(repeating: 512 << 6, count: width) }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            for (key, value) in [(kCVImageBufferColorPrimariesKey, properties[kVTCompressionPropertyKey_ColorPrimaries]!),
                                 (kCVImageBufferTransferFunctionKey, properties[kVTCompressionPropertyKey_TransferFunction]!),
                                 (kCVImageBufferYCbCrMatrixKey, properties[kVTCompressionPropertyKey_YCbCrMatrix]!)] {
                CVBufferSetAttachment(pixel, key, value as CFTypeRef, .shouldPropagate)
            }
            try check(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel,
                presentationTimeStamp: CMTime(value: Int64(frame), timescale: Int32(fps)),
                duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), "encode frame \(frame)")
        }
    }
    try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "complete")
    if let error = sink.error { throw Failure(error) }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw Failure("finish writer: \(String(describing: writer.error))") }
    guard sink.frames == count, sink.format["lumaBitDepth"] as? Int == 10,
          sink.format["chromaFormatIDC"] as? Int == 1, sink.format["profileIDC"] as? Int == 2 else {
        throw Failure("output is not Main10 4:2:0 or frames missing: \(sink.format)")
    }
    var result: [String: Any] = ["file": out.lastPathComponent, "kind": kind, "width": width, "height": height,
        "fps": fps, "frames": sink.frames, "seconds": Double(count) / Double(fps),
        "requestedBitrate": bitrate, "bitrate": Double(sink.bytes * 8 * fps) / Double(count),
        "format": sink.format, "profile": "HEVC Main10", "realTime": true, "allowFrameReordering": false, "range": "limited",
        "primaries": isPQ ? "BT.2020" : "BT.709", "transfer": isPQ ? "SMPTE ST 2084" : "BT.709",
        "matrix": isPQ ? "BT.2020 NCL" : "BT.709"]
    if kind == "steps" {
        let duration = Double(count) / Double(fps)
        result["schedule"] = levels.enumerated().filter { Double($0.offset * 2) < duration }.map {
            ["startSeconds": Double($0.offset * 2), "durationSeconds": $0.offset == levels.count - 1 ? duration - Double($0.offset * 2) : min(2, duration - Double($0.offset * 2)),
             "nits": $0.element, "lumaCode": Double(pqCode($0.element))]
        }
    }
    if kind == "gradient" { result["gradientNits"] = [0, 10000] }
    return result
}

func main() throws {
    var options: [String: String] = [:]
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") {
        print("--out DIR [--sizes 3840x2160,5120x2880,7680x4320,3648x2912] [--fps 90,120] [--seconds 5] [--bitrate 40000000]; PQ defaults: 1920x1080, 30fps, 14s steps + 5s gradient. --seconds overrides each clip.")
        return
    }
    let known = ["--out", "--sizes", "--fps", "--seconds", "--bitrate", "--kind"]
    guard args.count % 2 == 0 else { throw Failure("expected --option value; use --help") }
    for i in stride(from: 0, to: args.count, by: 2) {
        guard known.contains(args[i]) else { throw Failure("unknown option \(args[i])") }
        options[args[i]] = args[i + 1]
    }
    guard let directory = options["--out"] else { throw Failure("--out required") }
    let isPQ = options["--kind"] == "pq"
    let sizes = (options["--sizes"] ?? (isPQ ? "1920x1080" : "3840x2160,5120x2880,7680x4320,3648x2912")).split(separator: ",")
    let rates = (options["--fps"] ?? (isPQ ? "30" : "90,120")).split(separator: ",")
    guard let bitrate = Int(options["--bitrate"] ?? "40000000"), bitrate > 0,
          let seconds = Double(options["--seconds"] ?? "5"), seconds.isFinite, seconds > 0, seconds <= 3600 else { throw Failure("invalid bitrate/duration") }
    let out = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let manifestURL = out.appendingPathComponent(isPQ ? "pq-manifest.json" : "hevc-manifest.json")
    guard !FileManager.default.fileExists(atPath: manifestURL.path) else { throw Failure("manifest already exists; choose a fresh output directory") }
    var clips: [[String: Any]] = []
    var refused: [[String: Any]] = []
    for size in sizes {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 >= 2 && $0 <= 16384 && $0 % 2 == 0 }) else { throw Failure("invalid even dimensions: \(size)") }
        for rate in rates {
            guard let fps = Int(rate), fps > 0, fps <= 240 else { throw Failure("invalid fps") }
            for kind in (isPQ ? ["steps", "gradient"] : ["stress"]) {
                let url = out.appendingPathComponent("\(kind)-\(size)-\(fps).mov")
                guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure("file exists: \(url.path)") }
                do {
                    let duration = options["--seconds"] == nil && kind == "steps" ? 14 : seconds
                    let clip = try encode(out: url, width: parts[0], height: parts[1], fps: fps, seconds: duration, bitrate: bitrate, kind: kind)
                    clips.append(clip)
                    print("Wrote \(url.lastPathComponent)")
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    refused.append(["size": String(size), "fps": fps, "kind": kind, "error": String(describing: error)])
                    fputs("Skipped \(size) @ \(fps): \(error)\n", stderr)
                }
            }
        }
    }
    let manifest: [String: Any] = ["schemaVersion": 1, "clips": clips, "refused": refused,
        "host": ProcessInfo.processInfo.operatingSystemVersionString, "createdUTC": ISO8601DateFormatter().string(from: Date())]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: manifestURL, options: .atomic)
    if clips.isEmpty { throw Failure("no clips encoded; see manifest") }
}
do { try main() } catch { fputs("Error: \(error)\n", stderr); exit(1) }
