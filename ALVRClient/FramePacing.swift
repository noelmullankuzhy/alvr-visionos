//
//  FramePacing.swift
//
// Pure frame-pacing logic for the Metal render loop:
// - wrap-safe timing arithmetic for alvr_report_submit and lateness telemetry
// - the deadline-budgeted wait that replaces the fixed 5 ms poll when `ALVRDeadlineSelect` is on
// - the frame selection rule (newest decoded frame not newer than the render target)
//
// Foundation-only so it is unit tested on macOS (tests/swift/FramePacingTests.swift).
//

import Foundation

enum FramePacing {
    // Opt-in switch for deadline-budgeted selection; off keeps the legacy poll.
    static let defaultsKey = "ALVRDeadlineSelect"
    // The legacy loop polled for up to 5 ms after optimalInputTime; the budgeted wait never exceeds it.
    static let legacyPollNs: UInt64 = 5_000_000
    // Reserved between the end of the wait and the GPU p95 for encoding and commit on the CPU.
    static let marginNs: UInt64 = 1_000_000

    // a - b without wrapping, saturated to Int64.
    static func signedDifferenceNs(_ a: UInt64, _ b: UInt64) -> Int64 {
        if a >= b {
            let d = a - b
            return d > UInt64(Int64.max) ? Int64.max : Int64(d)
        }
        let d = b - a
        return d > UInt64(Int64.max) ? Int64.min : -Int64(d)
    }

    // Upper bound for the submit duration: the core adds it to an Instant, so a bogus vsync must not overflow it.
    static let submitHorizonNs: UInt64 = 1_000_000_000

    // Time from GPU completion until predicted vsync, the duration alvr_report_submit expects; 0 when late,
    // at most submitHorizonNs.
    static func submitQueueNs(vsyncNs: UInt64, completionNs: UInt64) -> UInt64 {
        vsyncNs > completionNs ? min(vsyncNs - completionNs, submitHorizonNs) : 0
    }

    // Signed lateness of GPU completion against predicted vsync (positive = late).
    static func latenessNs(vsyncNs: UInt64, completionNs: UInt64) -> Int64 {
        signedDifferenceNs(completionNs, vsyncNs)
    }

    static func isLate(vsyncNs: UInt64, completionNs: UInt64) -> Bool {
        completionNs > vsyncNs
    }

    // Latest time the render loop may keep waiting for a decoded frame:
    // min(start + legacy 5 ms, renderingDeadline - GPU p95 - margin), never before `startNs`.
    static func waitDeadlineNs(startNs: UInt64, renderingDeadlineNs: UInt64, gpuP95Ns: UInt64?, marginNs: UInt64) -> UInt64 {
        let reserve = (gpuP95Ns ?? 0).addingReportingOverflow(marginNs)
        let budgetEnd: UInt64
        if reserve.overflow || reserve.partialValue >= renderingDeadlineNs {
            budgetEnd = 0
        } else {
            budgetEnd = renderingDeadlineNs - reserve.partialValue
        }
        let legacyEnd = startNs.addingReportingOverflow(legacyPollNs)
        let cap = legacyEnd.overflow ? UInt64.max : legacyEnd.partialValue
        return max(startNs, min(cap, budgetEnd))
    }

    static func budgetRemains(nowNs: UInt64, waitDeadlineNs: UInt64) -> Bool {
        nowNs < waitDeadlineNs
    }

    // Index of the newest frame (by timestamp) whose timestamp is not after `targetNs`.
    // Frame timestamps are the predicted vsync the tracking was sent for, on the same clock as the target.
    static func newestIndex(_ timestamps: [UInt64], notNewerThan targetNs: UInt64) -> Int? {
        var best: Int? = nil
        for (i, ts) in timestamps.enumerated() where ts <= targetNs {
            if best == nil || ts > timestamps[best!] {
                best = i
            }
        }
        return best
    }

    enum Choice: Equatable {
        case queued(Int)  // present this queue entry (older entries are skipped)
        case retry        // re-present the previous frame, which visionOS never submitted
        case wait         // nothing yet and budget remains: yield and decide again
        case reuse        // reproject the previous frame
        case none         // nothing to show
    }

    // One selection decision, evaluated under the frame queue lock.
    static func choose(queue: [UInt64], targetNs: UInt64, lastTimestamp: UInt64?, lastSubmitted: Bool, canWait: Bool) -> Choice {
        if let i = newestIndex(queue, notNewerThan: targetNs) {
            return .queued(i)
        }
        if lastTimestamp != nil && !lastSubmitted {
            return .retry
        }
        // Queued frames that are all newer than the target will not become older by waiting.
        if canWait && queue.isEmpty {
            return .wait
        }
        // Nothing shown yet and only future frames queued: draw nothing now; they stay queued for their vsync.
        return lastTimestamp != nil ? .reuse : .none
    }
}

// Recent GPU frame durations; written from command buffer completion, read by the render loop.
final class GpuTimeEstimator {
    private let lock = NSLock()
    private var samples: [UInt64]
    private var count = 0
    private var next = 0

    init(capacity: Int = 90) {
        samples = [UInt64](repeating: 0, count: max(capacity, 1))
    }

    func add(ns: UInt64) {
        guard ns > 0 else { return }
        lock.lock()
        samples[next] = ns
        next = (next + 1) % samples.count
        count = min(count + 1, samples.count)
        lock.unlock()
    }

    // Nearest-rank p95 over the stored samples; nil until the first sample.
    func p95Ns() -> UInt64? {
        lock.lock()
        let values = Array(samples[0..<count])
        lock.unlock()
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
