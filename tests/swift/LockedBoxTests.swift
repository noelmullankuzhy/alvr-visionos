// SOURCES: ALVRClient/LockedBox.swift ALVRClient/Settings.swift ALVRClient/Extensions/Codable.swift ALVRClient/FFR.swift
// FLAGS: -sanitize=thread
// The production lock types the render, event and decode threads share (22 Oct crashes), driven concurrently under
// ThreadSanitizer. Settings runs for real (Settings.getAlvrSettings()/clearSettingsCache() over SettingsCodables.Settings,
// with the ALVR call stubbed below); the decoder slot holds real CMFormatDescription values.
// Generic where the real payload needs the ALVR bridge: QueuedFrame carries AlvrViewParams and viewFovs is [AlvrFov],
// so the frame slot holds a CVPixelBuffer-backed frame and the viewFovs box a [simd_float4].
import CoreMedia
import CoreVideo
import Foundation
import simd

// ALVR bridge stubs for Settings.swift (alvr_get_settings_json) and FFR.swift (StreamingStarted_Body and the
// ShaderTypes.h function constants it names).
struct StreamingStarted_Body {
    var view_width: UInt32 = 0
    var view_height: UInt32 = 0
}

enum ALVRFunctionConstant: Int {
    case ffrEnabled = 100
    case ffrCommonShaderEyeSizeRatio = 103
    case ffrCommonShaderCenterSize = 104
    case ffrCommonShaderCenterShift = 105
    case ffrCommonShaderEdgeRatio = 106
}

private let server = NSLock()
private var serverWhite = 100.0
private var serverCopies = 0
private var duringNextCopy: (() -> Void)? = nil

private func setServerWhite(_ white: Double) {
    server.lock(); serverWhite = white; server.unlock()
}

private func serverCopyCount() -> Int {
    server.lock(); defer { server.unlock() }
    return serverCopies
}

func alvr_get_settings_json(_ out: UnsafeMutablePointer<CChar>?) -> UInt64 {
    server.lock()
    // Fixed-width values (100.0, 200.0) so the length call and the copy call agree.
    let json = "{\"video\":{\"encoder_config\":{\"hdr\":{\"reference_white_nits\":\(serverWhite)}}},\"headset\":{}}"
    var hook: (() -> Void)? = nil
    if out != nil {
        serverCopies += 1
        hook = duringNextCopy
        duringNextCopy = nil
    }
    server.unlock()
    let bytes = Array(json.utf8CString)
    if let out {
        bytes.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: bytes.count) }
    }
    hook?() // the event thread acting while this (render-thread) parse is in flight
    return UInt64(bytes.count)
}

private func referenceWhite() -> Double? {
    Settings.getAlvrSettings()?.video.encoder_config?.hdr?.reference_white_nits
}

// Shaped like QueuedFrame: a pixel buffer finalised when the last copy goes.
private struct Frame {
    let imageBuffer: CVPixelBuffer
    let timestamp: UInt64
}

private func makeFrame(_ timestamp: UInt64) -> Frame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
    return Frame(imageBuffer: buffer!, timestamp: timestamp)
}

// Stands in for VTDecompressionSession: VTDecompressionSessionCreate returns nil in the worker sandbox (no decode
// service), and the slot only stores and hands back the reference.
private final class DecoderSession {}

// Decoder k: a session and a real format 16 + k wide, so a snapshot can be checked against its codec.
private func makeDecoder(_ k: Int) -> (session: DecoderSession, format: CMFormatDescription) {
    var format: CMFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_HEVC, width: Int32(16 + k), height: 16,
                                   extensions: nil, formatDescriptionOut: &format)
    return (DecoderSession(), format!)
}

// A few operations on two GCD threads first, staggered by a sleep (not a synchronisation) and joined before the
// storm: ThreadSanitizer reports the unordered pair without a real collision, before the 16-thread storm can corrupt
// a refcount and kill the process mid-report.
private func hammer(_ body: @escaping (_ worker: Int, _ i: Int) -> Void) {
    let warmUp = DispatchGroup()
    for worker in 0..<2 {
        warmUp.enter()
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.05 * Double(worker))
            for i in 0..<4 { body(worker, i) }
            warmUp.leave()
        }
    }
    warmUp.wait()
    DispatchQueue.concurrentPerform(iterations: 16) { worker in
        for i in 0..<3_000 { body(worker, i) }
    }
}

private func testSettingsParseSpanningClearIsNotStored() {
    Settings.clearSettingsCache()
    setServerWhite(100)
    // A DecoderConfig (clear) and new server settings land while the render thread parses the old ones.
    server.lock(); duringNextCopy = { Settings.clearSettingsCache(); setServerWhite(200) }; server.unlock()
    expectEqual(referenceWhite(), 100, "the caller still gets its own parse")
    expectEqual(referenceWhite(), 200, "a parse that spanned a clear is not published")
    let copies = serverCopyCount()
    expectEqual(referenceWhite(), 200, "a parse inside one generation is cached")
    expectEqual(serverCopyCount(), copies, "a cached value is returned without asking ALVR")
    Settings.clearSettingsCache()
    _ = referenceWhite()
    expectEqual(serverCopyCount(), copies + 1, "clear drops the cached value")
}

private func testSettingsConcurrentClearAndRead() {
    setServerWhite(100)
    Settings.clearSettingsCache()
    var wrong = 0
    let lock = NSLock()
    hammer { worker, _ in
        if worker % 4 == 0 {
            Settings.clearSettingsCache() // event thread, every DecoderConfig
        } else if let white = referenceWhite(), white != 100 { // render thread, sendTracking
            lock.lock(); wrong += 1; lock.unlock()
        }
    }
    expectEqual(wrong, 0, "every read decodes the server's settings")
    expectEqual(referenceWhite(), 100, "settings still fill after the storm")
}

private func testLastQueuedFrameSlot() {
    let slot = LastQueuedFrameSlot<Frame>()
    var torn = 0
    let tornLock = NSLock()
    hammer { worker, i in
        switch (worker + i) % 4 {
        case 0: // Renderer/RealityKit submit: the frame and its pose together.
            slot.set(makeFrame(UInt64(i)), pose: simd_float4x4(diagonal: simd_float4(repeating: Float(i))))
        case 1: // EventHandler.stop()
            slot.clear()
        case 2: // drawable-less early return keeps the frame only
            slot.frame = makeFrame(UInt64(i))
        default:
            let last = slot.get()
            _ = slot.frame?.timestamp
            if last.frame == nil, last.pose != nil {
                tornLock.lock(); torn += 1; tornLock.unlock()
            }
        }
    }
    expectEqual(torn, 0, "a cleared pair is never read half-cleared")
    slot.clear()
    expect(slot.get().frame == nil && slot.get().pose == nil, "cleared at the end")
}

private func testDecoderSlotCodecTravelsWithSession() {
    let decoders = (0..<4).map(makeDecoder)
    let slot = DecoderSlot<DecoderSession, CMFormatDescription>()
    expect(slot.snapshot() == nil && slot.codec == -1, "empty slot: no decoder, no codec")
    var mismatched = 0
    let lock = NSLock()
    hammer { worker, i in
        switch worker % 4 {
        case 0: // DecoderConfig / AV1 re-create: a new session with its own format and codec
            let k = i % decoders.count
            slot.replace(session: decoders[k].session, format: decoders[k].format, codec: k)
        case 1: // stop() teardown; the old session is finished outside the lock
            slot.replace(session: nil, format: nil, codec: -1)
        default: // handleNals
            if let current = slot.snapshot() {
                let k = decoders.firstIndex { $0.session === current.session }
                let width = Int(CMVideoFormatDescriptionGetDimensions(current.format).width) - 16
                if k != current.codec || width != current.codec {
                    lock.lock(); mismatched += 1; lock.unlock()
                }
            }
            _ = slot.format
        }
    }
    expectEqual(mismatched, 0, "a snapshot never pairs a session with another decoder's format or codec")
    slot.replace(session: decoders[2].session, format: decoders[2].format, codec: 2)
    expect(slot.replace(session: decoders[3].session, format: decoders[3].format, codec: 3) === decoders[2].session,
           "replace hands back the old session to finish")
    slot.setCodec(-1)
    expect(slot.snapshot()?.session === decoders[3].session && slot.codec == -1, "setCodec keeps the session")
    expect(slot.replace(session: nil, format: nil, codec: -1) === decoders[3].session, "teardown hands back the session")
    expect(slot.snapshot() == nil && slot.session == nil && slot.format == nil, "teardown clears the decoder")
}

private func testViewFovsBox() {
    // EventHandler.viewFovsBox: Renderer/RealityKit replace it, the decode callback and keepalive read it.
    let box = LockedBox<[simd_float4]>([simd_float4(1, 1, 1, 1), simd_float4(1, 1, 1, 1)])
    var torn = 0
    let lock = NSLock()
    hammer { worker, i in
        if worker % 2 == 0 {
            box.set([simd_float4(repeating: Float(i)), simd_float4(repeating: Float(i))])
        } else if box.get().count != 2 {
            lock.lock(); torn += 1; lock.unlock()
        }
    }
    expectEqual(torn, 0, "every read sees a whole two-view array")
    expectEqual(box.update { (v: inout [simd_float4]) -> Int in v.append(simd_float4()); return v.count }, 3, "update mutates in place")
}

@main
enum LockedBoxTests {
    static func main() {
        testSettingsParseSpanningClearIsNotStored()
        testSettingsConcurrentClearAndRead()
        testLastQueuedFrameSlot()
        testDecoderSlotCodecTravelsWithSession()
        testViewFovsBox()
        finishTests("LockedBox")
    }
}
