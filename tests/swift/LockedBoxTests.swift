// SOURCES: ALVRClient/LockedBox.swift
// FLAGS: -sanitize=thread
// The accessors the render, event and decode threads share (22 Oct crashes): Settings' cache (SettingsCache, cleared on
// every DecoderConfig while sendTracking reads it), lastQueuedFrame/pose (LastQueuedFrameSlot, cleared by stop() while
// the render thread assigns it), the decoder session/format (DecoderSlot, torn down by stop() while handleNals copies
// it) and viewFovs (LockedBox). Every value is freshly allocated, so replaced values are released while others read.
import CoreVideo
import Foundation
import simd

// Shaped like QueuedFrame: a pixel buffer finalised when the last copy goes.
private struct Frame {
    let imageBuffer: CVPixelBuffer
    let timestamp: UInt64
}

private final class Tagged {
    let tag: Int
    init(_ tag: Int) { self.tag = tag }
}

private func makeFrame(_ timestamp: UInt64) -> Frame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
    return Frame(imageBuffer: buffer!, timestamp: timestamp)
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

private func testSettingsCacheFillSpanningClearIsNotStored() {
    let cache = SettingsCache<Tagged>()
    // The event thread clears (DecoderConfig) while the render thread is parsing the old settings.
    let stale = cache.get { cache.clear(); return Tagged(1) }
    expectEqual(stale?.tag, 1, "the caller still gets its own parse")
    expectEqual(cache.get { Tagged(2) }?.tag, 2, "a parse that spanned a clear is not published")
    expectEqual(cache.get { Tagged(3) }?.tag, 2, "a parse inside one generation is cached")
    cache.clear()
    expectEqual(cache.get { Tagged(4) }?.tag, 4, "clear drops the cached value")
    expect(cache.get { nil } != nil, "a cached value is returned without parsing")
}

private func testSettingsCacheConcurrentClearAndRead() {
    let cache = SettingsCache<Tagged>()
    hammer { worker, i in
        if worker % 4 == 0 {
            cache.clear()
        } else if let value = cache.get(fill: { Tagged(i) }) {
            _ = value.tag
        }
    }
    expect(cache.get { Tagged(-1) } != nil, "cache still fills after the storm")
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

private func testDecoderSlotSnapshotMatchesPair() {
    let slot = DecoderSlot<Tagged, Tagged>()
    expect(slot.snapshot() == nil, "empty slot has no decoder")
    var mismatched = 0
    let lock = NSLock()
    hammer { worker, i in
        switch worker % 4 {
        case 0: // DecoderConfig / AV1 re-create
            _ = slot.replace(session: Tagged(i), format: Tagged(i))
        case 1: // stop() teardown; the old session is finished outside the lock
            _ = slot.replace(session: nil, format: nil)?.tag
        default: // handleNals
            if let current = slot.snapshot(), current.session.tag != current.format.tag {
                lock.lock(); mismatched += 1; lock.unlock()
            }
            _ = slot.format
        }
    }
    expectEqual(mismatched, 0, "a snapshot never pairs a session with another decoder's format")
    let old = slot.replace(session: Tagged(7), format: Tagged(7))
    expect(slot.replace(session: nil, format: nil)?.tag == 7, "teardown hands back the installed session")
    _ = old
    expect(slot.snapshot() == nil && slot.session == nil, "teardown clears both")
}

private func testViewFovsBox() {
    // EventHandler.viewFovs: Renderer/RealityKit replace it, the decode callback and keepalive read it.
    let box = LockedBox<[simd_float4]>([simd_float4(1, 1, 1, 1), simd_float4(1, 1, 1, 1)])
    hammer { worker, i in
        if worker % 2 == 0 {
            box.set([simd_float4(repeating: Float(i)), simd_float4(repeating: Float(i))])
        } else {
            let fovs = box.get()
            if fovs.count != 2 { box.set([]) }
        }
    }
    expectEqual(box.get().count, 2, "every read sees a whole two-view array")
    expectEqual(box.update { (v: inout [simd_float4]) -> Int in v.append(simd_float4()); return v.count }, 3, "update mutates in place")
}

@main
enum LockedBoxTests {
    static func main() {
        testSettingsCacheFillSpanningClearIsNotStored()
        testSettingsCacheConcurrentClearAndRead()
        testLastQueuedFrameSlot()
        testDecoderSlotSnapshotMatchesPair()
        testViewFovsBox()
        finishTests("LockedBox")
    }
}
