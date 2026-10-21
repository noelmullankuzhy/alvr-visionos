// SOURCES: ALVRClient/FramePacing.swift
// Wrap-safe timing arithmetic, the deadline-budgeted wait and the frame selection rule of FramePacing.
import Foundation

private let ms: UInt64 = 1_000_000

private func testSignedDifference() {
    expectEqual(FramePacing.signedDifferenceNs(10 * ms, 4 * ms), Int64(6 * ms), "positive difference")
    expectEqual(FramePacing.signedDifferenceNs(4 * ms, 10 * ms), -Int64(6 * ms), "negative difference instead of a wrap")
    expectEqual(FramePacing.signedDifferenceNs(7, 7), 0, "equal")
    expectEqual(FramePacing.signedDifferenceNs(UInt64.max, 0), Int64.max, "saturates high")
    expectEqual(FramePacing.signedDifferenceNs(0, UInt64.max), Int64.min, "saturates low")
}

private func testSubmitQueueDuration() {
    // The old argument `vsync &- completion` wrapped to ~1.8e19 ns when the GPU finished after vsync.
    expectEqual(FramePacing.submitQueueNs(vsyncNs: 100 * ms, completionNs: 97 * ms), 3 * ms, "time left until vsync")
    expectEqual(FramePacing.submitQueueNs(vsyncNs: 100 * ms, completionNs: 102 * ms), 0, "late completion saturates at 0")
    expectEqual(FramePacing.submitQueueNs(vsyncNs: 0, completionNs: 1), 0, "no wrap at the bottom")
    // The core adds this to an Instant; anything beyond the horizon is clamped so it cannot overflow there.
    expectEqual(FramePacing.submitQueueNs(vsyncNs: UInt64.max, completionNs: 0), FramePacing.submitHorizonNs, "clamped high")
    expectEqual(FramePacing.submitQueueNs(vsyncNs: UInt64.max, completionNs: UInt64.max), 0, "equal extremes")
    expectEqual(FramePacing.submitQueueNs(vsyncNs: 0, completionNs: UInt64.max), 0, "late extreme")
    expectEqual(FramePacing.submitQueueNs(vsyncNs: 2_000 * ms, completionNs: 1_000 * ms), 1_000 * ms, "exactly the horizon")
    expectEqual(FramePacing.submitHorizonNs, 1_000 * ms, "1 s horizon")
}

private func testLateness() {
    expectEqual(FramePacing.latenessNs(vsyncNs: 100 * ms, completionNs: 102 * ms), Int64(2 * ms), "late by 2 ms")
    expectEqual(FramePacing.latenessNs(vsyncNs: 100 * ms, completionNs: 97 * ms), -Int64(3 * ms), "3 ms early is negative")
    expect(FramePacing.isLate(vsyncNs: 100 * ms, completionNs: 100 * ms + 1), "1 ns after vsync is late")
    expect(!FramePacing.isLate(vsyncNs: 100 * ms, completionNs: 100 * ms), "on vsync is not late")
}

private func testWaitDeadline() {
    let start = 1_000 * ms
    // Plenty of budget: capped at the old 5 ms poll.
    expectEqual(FramePacing.waitDeadlineNs(startNs: start, renderingDeadlineNs: start + 20 * ms, gpuP95Ns: 3 * ms, marginNs: 1 * ms),
                start + 5 * ms, "never more than the legacy 5 ms")
    // Deadline 8 ms away, GPU p95 4 ms, margin 1 ms: 3 ms of waiting left.
    expectEqual(FramePacing.waitDeadlineNs(startNs: start, renderingDeadlineNs: start + 8 * ms, gpuP95Ns: 4 * ms, marginNs: 1 * ms),
                start + 3 * ms, "deadline minus GPU p95 minus margin")
    // No budget left: no waiting at all.
    expectEqual(FramePacing.waitDeadlineNs(startNs: start, renderingDeadlineNs: start + 4 * ms, gpuP95Ns: 4 * ms, marginNs: 1 * ms),
                start, "negative budget waits zero")
    expectEqual(FramePacing.waitDeadlineNs(startNs: start, renderingDeadlineNs: start - 2 * ms, gpuP95Ns: nil, marginNs: 1 * ms),
                start, "deadline already passed")
    expectEqual(FramePacing.waitDeadlineNs(startNs: start, renderingDeadlineNs: 0, gpuP95Ns: UInt64.max, marginNs: UInt64.max),
                start, "huge inputs do not wrap")
    // No GPU samples yet: only the margin is reserved.
    expectEqual(FramePacing.waitDeadlineNs(startNs: start, renderingDeadlineNs: start + 3 * ms, gpuP95Ns: nil, marginNs: 1 * ms),
                start + 2 * ms, "unknown GPU time reserves the margin only")
    expect(FramePacing.budgetRemains(nowNs: start + 1 * ms, waitDeadlineNs: start + 3 * ms), "inside the budget")
    expect(!FramePacing.budgetRemains(nowNs: start + 3 * ms, waitDeadlineNs: start + 3 * ms), "budget exhausted at the deadline")
}

private func testNewestIndex() {
    expectEqual(FramePacing.newestIndex([10, 20, 30], notNewerThan: 25), 1, "newest at or before the target")
    expectEqual(FramePacing.newestIndex([10, 20, 30], notNewerThan: 30), 2, "equal to the target qualifies")
    expectEqual(FramePacing.newestIndex([10, 20, 30], notNewerThan: 100), 2, "all qualify: newest")
    expectEqual(FramePacing.newestIndex([40, 50], notNewerThan: 30), nil, "all from the future")
    expectEqual(FramePacing.newestIndex([], notNewerThan: 30), nil, "empty queue")
    expectEqual(FramePacing.newestIndex([30, 10, 20], notNewerThan: 25), 2, "newest by timestamp, not by position")
}

private func testChoose() {
    typealias C = FramePacing.Choice
    // A qualifying queued frame always wins, even over a retry.
    expectEqual(FramePacing.choose(queue: [10, 20], targetNs: 50, lastTimestamp: 5, lastSubmitted: false, canWait: true), C.queued(1), "newest queued")
    // Nothing queued: retry the previous frame if visionOS never submitted it.
    expectEqual(FramePacing.choose(queue: [], targetNs: 50, lastTimestamp: 5, lastSubmitted: false, canWait: true), C.retry, "retry unsubmitted")
    // Nothing queued, previous submitted: wait while budget remains, then reproject.
    expectEqual(FramePacing.choose(queue: [], targetNs: 50, lastTimestamp: 5, lastSubmitted: true, canWait: true), C.wait, "wait for a decode")
    expectEqual(FramePacing.choose(queue: [], targetNs: 50, lastTimestamp: 5, lastSubmitted: true, canWait: false), C.reuse, "budget gone: reproject")
    // Only future frames queued: waiting cannot help this vsync, reproject now and keep them.
    expectEqual(FramePacing.choose(queue: [60], targetNs: 50, lastTimestamp: 5, lastSubmitted: true, canWait: true), C.reuse, "future frame kept for later")
    // Nothing shown yet and only future frames: show nothing now, keep them queued for their vsync.
    expectEqual(FramePacing.choose(queue: [60, 70], targetNs: 50, lastTimestamp: nil, lastSubmitted: true, canWait: false), C.none, "future frame never shown early")
    expectEqual(FramePacing.choose(queue: [60, 70], targetNs: 50, lastTimestamp: nil, lastSubmitted: true, canWait: true), C.none, "waiting cannot make a future frame qualify")
    expectEqual(FramePacing.choose(queue: [], targetNs: 50, lastTimestamp: nil, lastSubmitted: true, canWait: true), C.wait, "first frame: wait")
    expectEqual(FramePacing.choose(queue: [], targetNs: 50, lastTimestamp: nil, lastSubmitted: true, canWait: false), C.none, "nothing at all")
}

private func testGpuTimeEstimator() {
    let gpu = GpuTimeEstimator(capacity: 20)
    expectEqual(gpu.p95Ns(), nil, "no samples")
    for i in 1...20 { gpu.add(ns: UInt64(i) * ms) }
    expectEqual(gpu.p95Ns(), 19 * ms, "nearest-rank p95 of 1..20 ms")
    // The ring keeps the newest `capacity` samples.
    for _ in 1...20 { gpu.add(ns: 2 * ms) }
    expectEqual(gpu.p95Ns(), 2 * ms, "old samples rotated out")
    gpu.add(ns: 0)
    expectEqual(gpu.p95Ns(), 2 * ms, "zero-length samples ignored")
}

@main
enum FramePacingTests {
    static func main() {
        testSignedDifference()
        testSubmitQueueDuration()
        testLateness()
        testWaitDeadline()
        testNewestIndex()
        testChoose()
        testGpuTimeEstimator()
        finishTests("FramePacingTests")
    }
}
