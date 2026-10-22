// SOURCES: ALVRClient/LockedBox.swift
// FLAGS: -sanitize=thread
// The lock shared by the render and event threads for lastQueuedFrame/lastQueuedFramePose and the ALVR settings cache:
// concurrent set, clear and read from many threads (the 22 Oct crashes were an unlocked assign racing stop()'s clear,
// and the render thread copying cached settings while the event thread cleared them).
import CoreVideo
import Foundation
import simd

// Shaped like QueuedFrame: a pixel buffer released when the last copy goes.
private struct Frame {
    let imageBuffer: CVPixelBuffer
    let timestamp: UInt64
}

private final class Payload {
    let id: Int
    init(_ id: Int) { self.id = id }
}

private func makeFrame(_ timestamp: UInt64) -> Frame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
    return Frame(imageBuffer: buffer!, timestamp: timestamp)
}

private func testGetSetUpdate() {
    let box = LockedBox<Int>(1)
    expectEqual(box.get(), 1, "initial value")
    box.set(2)
    expectEqual(box.get(), 2, "set replaces the value")
    expectEqual(box.update { (v: inout Int) -> Int in v += 3; return v * 10 }, 50, "update returns the body's result")
    expectEqual(box.get(), 5, "update mutates in place")
}

private func testFramePairSetClearRead() {
    let box = LockedBox<(frame: Frame?, pose: simd_float4x4?)>((nil, nil))
    let frames = (0..<8).map { makeFrame(UInt64($0)) }
    var torn = 0
    let tornLock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 16) { worker in
        for i in 0..<5_000 {
            switch (worker + i) % 4 {
            case 0:
                // Renderer/RealityKit submit: the frame and its pose together.
                let f = frames[(worker + i) % frames.count]
                box.set((f, simd_float4x4(diagonal: simd_float4(repeating: Float(f.timestamp)))))
            case 1:
                box.set((nil, nil)) // EventHandler.stop()
            case 2:
                box.update { $0.frame = frames[i % frames.count] } // drawable-less early return keeps the frame only
            default:
                let last = box.get()
                if last.frame == nil, last.pose != nil {
                    tornLock.lock(); torn += 1; tornLock.unlock()
                }
            }
        }
    }
    expectEqual(torn, 0, "a cleared pair is never read half-cleared")
    box.set((nil, nil))
    expect(box.get().frame == nil && box.get().pose == nil, "cleared at the end")
}

private func testCacheClearWhileReading() {
    // Settings.getAlvrSettings(): fill on miss, the event thread clears on each DecoderConfig/StreamingStarted.
    let cache = LockedBox<Payload?>(nil)
    var reads = 0
    let readsLock = NSLock()
    DispatchQueue.concurrentPerform(iterations: 16) { worker in
        var local = 0
        for i in 0..<5_000 {
            if worker % 4 == 0 {
                cache.set(nil)
            } else if let p = cache.get() {
                local += p.id >= 0 ? 1 : 0
            } else {
                cache.set(Payload(i))
            }
        }
        readsLock.lock(); reads += local; readsLock.unlock()
    }
    expect(reads > 0, "readers saw cached values")
}

@main
enum LockedBoxTests {
    static func main() {
        testGetSetUpdate()
        testFramePairSetClearRead()
        testCacheClearWhileReading()
        finishTests("LockedBox")
    }
}
