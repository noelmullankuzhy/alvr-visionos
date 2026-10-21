/*
Abstract:
Gets a stream to its first video frame, however early the immersive space opens.
*/

import Foundation

/// From StreamingStarted until the first decoded frame is queued, the server needs a head pose and view params
/// to encode anything, and the renderer only sends real ones once it has a frame.
/// Decides when to send fake tracking; hands over to real tracking at the first frame.
/// Foundation only, so it is unit-tested on macOS.
struct StreamBootstrap {
    enum Phase: Equatable {
        case idle
        case awaitingFirstFrame
        case streaming
    }

    static let fakeTrackingInterval = 0.1
    // Loop timing jitter allowance for the rate limit.
    private static let slack = 0.001

    private(set) var phase = Phase.idle
    private var streamStartTime = 0.0
    private var lastFakeTrackingTime: Double? = nil
    private var loggedFirstFrame = false

    mutating func streamStarted(now: Double) {
        phase = .awaitingFirstFrame
        streamStartTime = now
        lastFakeTrackingTime = nil
        loggedFirstFrame = false
    }

    mutating func streamStopped() {
        phase = .idle
    }

    /// The immersive space (re)opened on a running stream: frames must flow again before real tracking takes over.
    mutating func reentered() {
        guard phase != .idle else { return }
        phase = .awaitingFirstFrame
        lastFakeTrackingTime = nil
    }

    /// True when fake view params and head pose should be sent now.
    mutating func shouldSendFakeTracking(now: Double) -> Bool {
        guard phase == .awaitingFirstFrame else { return false }
        if let last = lastFakeTrackingTime, now - last < StreamBootstrap.fakeTrackingInterval - StreamBootstrap.slack {
            return false
        }
        lastFakeTrackingTime = now
        return true
    }

    /// A decoded frame was queued for display. Returns the ALVRBOOT log line for the stream's first frame, else nil.
    mutating func frameQueued(now: Double) -> String? {
        guard phase == .awaitingFirstFrame else { return nil }
        phase = .streaming
        if loggedFirstFrame {
            return nil
        }
        loggedFirstFrame = true
        let ms = Int(((now - streamStartTime) * 1000).rounded())
        return "ALVRBOOT first_frame_queued_ms=\(ms)"
    }
}
