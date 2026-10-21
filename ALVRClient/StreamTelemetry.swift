//
//  StreamTelemetry.swift
//
// Machine-readable stream telemetry, so quality/performance changes can be measured:
// - one `ALVRSTATS {json}` console line per 1 s window while streaming
// - one `ALVRFORMAT {json}` line whenever the video format or stream config changes
// - the same records appended to Documents/telemetry/<session-start-utc>.jsonl
//
// Foundation-only so it is unit tested on macOS (tests/swift/StreamTelemetryTests.swift).
// Hot path: counters and preallocated sample slots under one lock; JSON is encoded once per window.
//

import Foundation

protocol StreamTelemetrySink: AnyObject {
    func beginSession(utcStart: Date)
    func write(prefix: String, json: String)
}

// Latency samples for one window, stored in preallocated slots. The mean covers every sample;
// percentiles cover the first `capacity` samples of the window.
struct LatencySamples {
    private var values: [Double]
    private(set) var count = 0
    private var sum = 0.0

    init(capacity: Int) {
        values = [Double](repeating: 0, count: capacity)
    }

    mutating func add(_ value: Double) {
        if count < values.count {
            values[count] = value
        }
        sum += value
        count += 1
    }

    mutating func reset() {
        count = 0
        sum = 0
    }

    var mean: Double? {
        count > 0 ? sum / Double(count) : nil
    }

    func percentile(_ p: Double) -> Double? {
        StreamTelemetry.percentile(Array(values[0..<min(count, values.count)]), p)
    }
}

struct StreamStatsRecord: Encodable, Equatable {
    var type = "stats"
    var t: Double
    var windowS: Double
    var framesReceived: Int
    var framesDecoded: Int
    var decodeErrors: Int
    var framesPresented: Int
    var framesRepeated: Int
    var framesBlank: Int
    var framesDropped: Int
    var droppedBeforeDecode: Int
    var droppedDecodeOverrun: Int
    var droppedQueueOverflow: Int
    var presentedFps: Double
    var renderLoops: Int
    var renderLoopHz: Double
    var decodeMsMean: Double?
    var decodeMsP95: Double?
    var receiveToPresentMsMean: Double?
    var receiveToPresentMsP95: Double?
}

struct StreamFormatRecord: Encodable, Equatable {
    var type = "format"
    var t: Double?
    var renderer: String?
    // From the CMFormatDescription the decoder was created with
    var codec: String?
    var codedWidth: Int?
    var codedHeight: Int?
    var bitDepth: Int?
    var chromaSubsampling: String?
    var fullRange: Bool?
    var colorPrimaries: String?
    var transferFunction: String?
    var ycbcrMatrix: String?
    // From decoded frames and the render path
    var decoderPixelFormat: String?
    var decoderPixelFormatName: String?
    var lumaTextureFormat: UInt?
    var chromaTextureFormat: UInt?
    var drawablePixelFormat: UInt?
    var drawableViewSizes: [[Int]]?
    var displayRefreshRateHz: Double?
    // From StreamingStarted
    var viewWidth: Int?
    var viewHeight: Int?
    var refreshRateHint: Double?
    var encodingGamma: Double?
    var enableFoveatedEncoding: Bool?
    var enableHdr: Bool?
    var forceFastSecretTextureFormats: Bool?

    mutating func clearDecoderFields() {
        codec = nil
        codedWidth = nil
        codedHeight = nil
        bitDepth = nil
        chromaSubsampling = nil
        fullRange = nil
        colorPrimaries = nil
        transferFunction = nil
        ycbcrMatrix = nil
        decoderPixelFormat = nil
        decoderPixelFormatName = nil
        lumaTextureFormat = nil
        chromaTextureFormat = nil
    }
}

final class StreamTelemetry {
    static let shared = StreamTelemetry(sink: StreamTelemetryFileSink.documents())

    static let windowNs: UInt64 = 1_000_000_000
    static let sampleCapacity = 1024

    static func nowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private let sink: StreamTelemetrySink
    private let clock: () -> UInt64
    private let wallClock: () -> Double
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private var active = false
    private var windowStartNs: UInt64 = 0
    private var framesReceived = 0
    private var framesDecoded = 0
    private var decodeErrors = 0
    private var framesPresented = 0
    private var framesRepeated = 0
    private var framesBlank = 0
    private var droppedBeforeDecode = 0
    private var droppedDecodeOverrun = 0
    private var droppedQueueOverflow = 0
    private var decodeMs = LatencySamples(capacity: StreamTelemetry.sampleCapacity)
    private var receiveToPresentMs = LatencySamples(capacity: StreamTelemetry.sampleCapacity)
    private var lastPresentedTimestampNs: UInt64? = nil

    // Receive time per frame timestamp, a small ring so presentation can find it without allocating.
    private static let receiveRingSize = 32
    private var receiveRingTimestamps = [UInt64](repeating: 0, count: StreamTelemetry.receiveRingSize)
    private var receiveRingNs = [UInt64](repeating: 0, count: StreamTelemetry.receiveRingSize)
    private var receiveRingIndex = 0

    private var format = StreamFormatRecord()
    private var lastEmittedFormat: StreamFormatRecord? = nil
    private var lastDecoderOutputKey: (UInt32, UInt, UInt)? = nil
    private var lastDrawableKey: (UInt, Int, Int, Int, Int)? = nil

    init(sink: StreamTelemetrySink, clock: @escaping () -> UInt64 = StreamTelemetry.nowNs, wallClock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.sink = sink
        self.clock = clock
        self.wallClock = wallClock
    }

    // MARK: - Stream lifecycle

    func streamingStarted(viewWidth: Int, viewHeight: Int, refreshRateHint: Double, encodingGamma: Double, enableFoveatedEncoding: Bool, enableHdr: Bool, forceFastSecretTextureFormats: Bool) {
        lock.lock()
        let newSession = !active
        if newSession {
            active = true
            resetWindow(clock())
            lastPresentedTimestampNs = nil
        }
        format.viewWidth = viewWidth
        format.viewHeight = viewHeight
        format.refreshRateHint = StreamTelemetry.round(refreshRateHint, 4)
        format.encodingGamma = StreamTelemetry.round(encodingGamma, 4)
        format.enableFoveatedEncoding = enableFoveatedEncoding
        format.enableHdr = enableHdr
        format.forceFastSecretTextureFormats = forceFastSecretTextureFormats
        let record = takeFormatIfChanged(force: newSession)
        lock.unlock()
        if newSession {
            sink.beginSession(utcStart: Date(timeIntervalSince1970: wallClock()))
        }
        emit(record)
    }

    func streamingStopped() {
        lock.lock()
        let record = active ? takeWindow(clock()) : nil
        active = false
        format.clearDecoderFields()
        lastDecoderOutputKey = nil
        lock.unlock()
        emit(record)
    }

    // MARK: - Hot path counters

    func recordReceived(timestampNs: UInt64) {
        let now = clock()
        lock.lock()
        framesReceived += 1
        receiveRingTimestamps[receiveRingIndex] = timestampNs
        receiveRingNs[receiveRingIndex] = now
        receiveRingIndex = (receiveRingIndex + 1) % StreamTelemetry.receiveRingSize
        let record = takeWindowIfDue(now)
        lock.unlock()
        emit(record)
    }

    func recordDroppedBeforeDecode() {
        lock.lock()
        droppedBeforeDecode += 1
        lock.unlock()
    }

    func recordDecodeSubmitFailed() {
        lock.lock()
        decodeErrors += 1
        lock.unlock()
    }

    // Called from the decoder output handler; `ok` is false for an error status or no image.
    func recordDecodeOutput(submitNs: UInt64, ok: Bool) {
        let now = clock()
        lock.lock()
        if ok {
            framesDecoded += 1
            if now >= submitNs {
                decodeMs.add(Double(now - submitNs) / 1_000_000.0)
            }
        } else {
            decodeErrors += 1
        }
        lock.unlock()
    }

    func recordDecodeOverrun() {
        lock.lock()
        droppedDecodeOverrun += 1
        lock.unlock()
    }

    func recordQueueOverflow() {
        lock.lock()
        droppedQueueOverflow += 1
        lock.unlock()
    }

    // Called once per render loop. `displayed` means a video frame was drawn; a frame whose timestamp
    // was already presented counts as a repeat (reprojected/reused), otherwise as newly presented.
    // `presentNs` is the predicted presentation time on the same clock as `nowNs()`.
    func recordRender(frameTimestampNs: UInt64?, displayed: Bool, presentNs: UInt64) {
        let now = clock()
        lock.lock()
        if displayed, let ts = frameTimestampNs {
            if ts == lastPresentedTimestampNs {
                framesRepeated += 1
            } else {
                framesPresented += 1
                lastPresentedTimestampNs = ts
                for i in 0..<StreamTelemetry.receiveRingSize where receiveRingTimestamps[i] == ts {
                    if presentNs >= receiveRingNs[i] {
                        receiveToPresentMs.add(Double(presentNs - receiveRingNs[i]) / 1_000_000.0)
                    }
                    break
                }
            }
        } else {
            framesBlank += 1
        }
        let record = takeWindowIfDue(now)
        lock.unlock()
        emit(record)
    }

    // MARK: - Format/config

    // Applies a change and emits ALVRFORMAT if anything differs from the last record. Not for per-frame use.
    func updateFormat(_ mutate: (inout StreamFormatRecord) -> Void) {
        lock.lock()
        mutate(&format)
        let record = takeFormatIfChanged(force: false)
        lock.unlock()
        emit(record)
    }

    // Per-frame safe: compares integers and only builds strings when the decoder output changes.
    func noteDecoderOutput(pixelFormat: UInt32, lumaTextureFormat: UInt, chromaTextureFormat: UInt, name: @autoclosure () -> String?) {
        lock.lock()
        if let key = lastDecoderOutputKey, key == (pixelFormat, lumaTextureFormat, chromaTextureFormat) {
            lock.unlock()
            return
        }
        lastDecoderOutputKey = (pixelFormat, lumaTextureFormat, chromaTextureFormat)
        format.decoderPixelFormat = StreamTelemetry.fourCCString(pixelFormat)
        format.decoderPixelFormatName = name()
        format.lumaTextureFormat = lumaTextureFormat != 0 ? lumaTextureFormat : nil
        format.chromaTextureFormat = chromaTextureFormat != 0 ? chromaTextureFormat : nil
        let record = takeFormatIfChanged(force: false)
        lock.unlock()
        emit(record)
    }

    // Per-frame safe. A view size of 0 means that view does not exist.
    func noteDrawable(pixelFormat: UInt, view0Width: Int, view0Height: Int, view1Width: Int, view1Height: Int) {
        lock.lock()
        if let key = lastDrawableKey, key == (pixelFormat, view0Width, view0Height, view1Width, view1Height) {
            lock.unlock()
            return
        }
        lastDrawableKey = (pixelFormat, view0Width, view0Height, view1Width, view1Height)
        format.drawablePixelFormat = pixelFormat
        var sizes = [[view0Width, view0Height]]
        if view1Width > 0 && view1Height > 0 {
            sizes.append([view1Width, view1Height])
        }
        format.drawableViewSizes = sizes
        let record = takeFormatIfChanged(force: false)
        lock.unlock()
        emit(record)
    }

    // MARK: - Windowing (call with the lock held)

    private func resetWindow(_ now: UInt64) {
        windowStartNs = now
        framesReceived = 0
        framesDecoded = 0
        decodeErrors = 0
        framesPresented = 0
        framesRepeated = 0
        framesBlank = 0
        droppedBeforeDecode = 0
        droppedDecodeOverrun = 0
        droppedQueueOverflow = 0
        decodeMs.reset()
        receiveToPresentMs.reset()
    }

    private func takeWindowIfDue(_ now: UInt64) -> StreamStatsRecord? {
        guard active, now >= windowStartNs, now - windowStartNs >= StreamTelemetry.windowNs else {
            return nil
        }
        return takeWindow(now)
    }

    private func takeWindow(_ now: UInt64) -> StreamStatsRecord {
        let windowS = Double(now >= windowStartNs ? now - windowStartNs : 0) / 1_000_000_000.0
        let loops = framesPresented + framesRepeated + framesBlank
        let perSecond = { (count: Int) -> Double in windowS > 0 ? StreamTelemetry.round(Double(count) / windowS, 3) : 0 }
        let record = StreamStatsRecord(
            t: StreamTelemetry.round(wallClock(), 3),
            windowS: StreamTelemetry.round(windowS, 3),
            framesReceived: framesReceived,
            framesDecoded: framesDecoded,
            decodeErrors: decodeErrors,
            framesPresented: framesPresented,
            framesRepeated: framesRepeated,
            framesBlank: framesBlank,
            framesDropped: droppedBeforeDecode + droppedDecodeOverrun + droppedQueueOverflow,
            droppedBeforeDecode: droppedBeforeDecode,
            droppedDecodeOverrun: droppedDecodeOverrun,
            droppedQueueOverflow: droppedQueueOverflow,
            presentedFps: perSecond(framesPresented),
            renderLoops: loops,
            renderLoopHz: perSecond(loops),
            decodeMsMean: decodeMs.mean.map { StreamTelemetry.round($0, 3) },
            decodeMsP95: decodeMs.percentile(0.95).map { StreamTelemetry.round($0, 3) },
            receiveToPresentMsMean: receiveToPresentMs.mean.map { StreamTelemetry.round($0, 3) },
            receiveToPresentMsP95: receiveToPresentMs.percentile(0.95).map { StreamTelemetry.round($0, 3) }
        )
        resetWindow(now)
        return record
    }

    private func takeFormatIfChanged(force: Bool) -> StreamFormatRecord? {
        if !force && format == lastEmittedFormat {
            return nil
        }
        lastEmittedFormat = format
        var record = format
        record.t = StreamTelemetry.round(wallClock(), 3)
        return record
    }

    // MARK: - Output (call without the lock)

    private func emit(_ record: StreamStatsRecord?) {
        guard let record, let data = try? encoder.encode(record) else { return }
        sink.write(prefix: "ALVRSTATS", json: String(decoding: data, as: UTF8.self))
    }

    private func emit(_ record: StreamFormatRecord?) {
        guard let record, let data = try? encoder.encode(record) else { return }
        sink.write(prefix: "ALVRFORMAT", json: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Pure helpers

    // Nearest-rank percentile (p in 0...1); nil when there are no values.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }

    // Four printable ASCII characters (e.g. "hvc1", "&xf0"), else the decimal value.
    static func fourCCString(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(code)
    }

    static func codecName(fourCC: String) -> String? {
        switch fourCC {
        case "hvc1", "hev1": return "hevc"
        case "avc1", "avc3": return "h264"
        case "av01": return "av1"
        default: return nil
        }
    }

    // Bit depth and chroma subsampling from an hvcC/avcC/av1C decoder configuration record.
    static func parseCodecConfig(fourCC: String, bytes: [UInt8]) -> (bitDepth: Int, chromaSubsampling: String)? {
        let chromaNames = ["4:0:0", "4:2:0", "4:2:2", "4:4:4"]
        switch codecName(fourCC: fourCC) {
        case "hevc":
            // ISO/IEC 14496-15 8.3.3.1: byte 16 chromaFormat (2 bits), byte 17 bitDepthLumaMinus8 (3 bits)
            guard bytes.count >= 23 else { return nil }
            return (Int(bytes[17] & 0x07) + 8, chromaNames[Int(bytes[16] & 0x03)])
        case "h264":
            // ISO/IEC 14496-15 5.3.3.1: chroma/bit depth trail the SPS/PPS lists for High profiles only
            guard bytes.count >= 6, [100, 110, 122, 144].contains(bytes[1]) else { return nil }
            var offset = 5
            let spsCount = Int(bytes[offset] & 0x1F)
            offset += 1
            for _ in 0..<spsCount {
                guard offset + 2 <= bytes.count else { return nil }
                offset += 2 + (Int(bytes[offset]) << 8 | Int(bytes[offset + 1]))
            }
            guard offset < bytes.count else { return nil }
            let ppsCount = Int(bytes[offset])
            offset += 1
            for _ in 0..<ppsCount {
                guard offset + 2 <= bytes.count else { return nil }
                offset += 2 + (Int(bytes[offset]) << 8 | Int(bytes[offset + 1]))
            }
            guard offset + 2 <= bytes.count else { return nil }
            return (Int(bytes[offset + 1] & 0x07) + 8, chromaNames[Int(bytes[offset] & 0x03)])
        case "av1":
            // AV1 ISOBMFF 2.3.3: byte 2 = tier(1) high_bitdepth(1) twelve_bit(1) monochrome(1) ss_x(1) ss_y(1) pos(2)
            guard bytes.count >= 3 else { return nil }
            let b = bytes[2]
            let highBitdepth = b & 0x40 != 0
            let twelveBit = b & 0x20 != 0
            let bitDepth = highBitdepth ? (twelveBit ? 12 : 10) : 8
            if b & 0x10 != 0 {
                return (bitDepth, "4:0:0")
            }
            let subsamplingX = b & 0x08 != 0
            let subsamplingY = b & 0x04 != 0
            return (bitDepth, subsamplingX ? (subsamplingY ? "4:2:0" : "4:2:2") : "4:4:4")
        default:
            return nil
        }
    }
}

// Prints each record to the console and appends it to <directory>/<session-start-utc>.jsonl.
// Both happen on a private serial queue, off the render and decode threads.
final class StreamTelemetryFileSink: StreamTelemetrySink {
    private let directory: URL?
    private let echo: Bool
    private let queue = DispatchQueue(label: "StreamTelemetry.Sink", qos: .utility)
    private var handle: FileHandle? = nil
    private var reportedError = false

    // Documents/telemetry in the app data container (simulator and device).
    static func documents() -> StreamTelemetryFileSink {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return StreamTelemetryFileSink(directory: docs?.appendingPathComponent("telemetry", isDirectory: true), echo: true)
    }

    static func fileName(for start: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: start) + ".jsonl"
    }

    init(directory: URL?, echo: Bool) {
        self.directory = directory
        self.echo = echo
    }

    func beginSession(utcStart: Date) {
        queue.async {
            self.openFile(utcStart)
        }
    }

    func write(prefix: String, json: String) {
        queue.async {
            if self.echo {
                print(prefix + " " + json)
            }
            if self.handle == nil {
                self.openFile(Date())
            }
            self.handle?.write(Data((json + "\n").utf8))
        }
    }

    // Waits until queued writes are on disk (tests and shutdown).
    func flush() {
        queue.sync {
            try? self.handle?.synchronize()
        }
    }

    private func openFile(_ start: Date) {
        try? handle?.close()
        handle = nil
        guard let directory else { return }
        let url = directory.appendingPathComponent(StreamTelemetryFileSink.fileName(for: start))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
            let fileHandle = try FileHandle(forWritingTo: url)
            fileHandle.seekToEndOfFile()
            handle = fileHandle
            print("StreamTelemetry: writing", url.path)
        } catch {
            if !reportedError {
                reportedError = true
                print("StreamTelemetry: cannot open \(url.path): \(error)")
            }
        }
    }
}
