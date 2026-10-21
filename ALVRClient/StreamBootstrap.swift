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

/// The render loops send head poses only while their layer runs: from the moment a renderer exists
/// (EventHandler.renderStarted, never cleared) until a space's layer runs, while it is paused, and while a
/// space opens or switches, nothing else did, so the server (and the game) starved. The event thread asks this
/// whether to send a keepalive pose: only when no render loop has sent one for staleAfter, then every interval.
struct PoseKeepalive {
    static let staleAfter = 0.2
    static let interval = StreamBootstrap.fakeTrackingInterval
    private static let slack = 0.001

    struct Send: Equatable {
        let startsEpisode: Bool
    }

    private var lastRenderSent: Double? = nil
    private var lastKeepaliveSent: Double? = nil
    private var episodeSends = 0

    /// Event thread: non-nil when a keepalive pose should be sent now.
    mutating func shouldSend(now: Double) -> Send? {
        if let last = lastRenderSent, now - last < PoseKeepalive.staleAfter - PoseKeepalive.slack {
            return nil
        }
        if let last = lastKeepaliveSent, now - last < PoseKeepalive.interval - PoseKeepalive.slack {
            return nil
        }
        lastKeepaliveSent = now
        episodeSends += 1
        return Send(startsEpisode: episodeSends == 1)
    }

    /// A render loop sent a pose (real, or bootstrap fake). Returns the keepalive sends of the episode it ends.
    mutating func renderSent(now: Double) -> Int? {
        lastRenderSent = now
        guard episodeSends > 0 else { return nil }
        defer {
            episodeSends = 0
            lastKeepaliveSent = nil
        }
        return episodeSends
    }

    /// Stream stop or disconnect: the next stream starts a new episode (and logs it).
    mutating func reset() { self = PoseKeepalive() }
}

/// What a keepalive sends: the stream's last real head pose, at a timestamp never older than that pose's, so the
/// server holds the head where it was (as before any keepalive existed). The fake pose only before the stream has
/// sent a real one.
struct KeepalivePose<Motion> {
    enum Choice {
        case fake
        case real(Motion, timestamp: Double)
    }

    private var last: (motion: Motion, timestamp: Double)? = nil

    mutating func realSent(_ motion: Motion, timestamp: Double) { last = (motion, timestamp) }
    mutating func reset() { last = nil }

    func choose(target: Double) -> Choice {
        guard let last else { return .fake }
        return .real(last.motion, timestamp: max(target, last.timestamp))
    }
}

extension KeepalivePose.Choice: Equatable where Motion: Equatable {}

/// Opens the streaming space without a silent failure. visionOS has one immersive space slot, so a full open that
/// fails is retried once after dismissing whatever holds it, then falls back to the mixed space. A mixed open is
/// unchanged (one try); the caller logs every result and, while an open is pending, every pendingLogInterval.
enum StreamSpaceOpen {
    static let mixedID = "MetalClient"
    static let fullID = "MetalClientFull"
    static let pendingLogInterval = 5.0

    enum Step: Equatable {
        case done
        case giveUp
        case dismissThenOpen(String)
        case open(String)
    }

    static func spaceID(fullImmersion: Bool) -> String {
        fullImmersion ? fullID : mixedID
    }

    enum Result {
        case opened
        case userCancelled
        case failed
    }

    /// The next step after attempt `attempt` (1 = first) to open `id`. A cancelled full open is not retried
    /// (that would prompt again): the mixed space opens once instead.
    static func next(after id: String, result: Result, attempt: Int) -> Step {
        if result == .opened { return .done }
        guard id == fullID else { return .giveUp }
        return attempt == 1 && result == .failed ? .dismissThenOpen(fullID) : .open(mixedID)
    }
}

/// DIAG stream_start lines: ms since the stream's connect (STREAMING_STARTED) for the space request, its open
/// result, the layer running or pausing, the first decoded frame and the first poses, so a device run shows where
/// the start time goes. `once` lines log at most once per connection (keyed by event and fields).
struct StreamStartTiming {
    enum Event: String {
        case connect
        case spaceRequested = "space_requested"
        case spaceOpenPending = "space_open_pending"
        case spaceOpenResult = "space_open_result"
        case layerRunning = "layer_running"
        case layerPaused = "layer_paused"
        case firstDecodedFrame = "first_decoded_frame"
        case firstPoseSent = "first_pose_sent"
        case poseKeepalive = "pose_keepalive"
    }

    private var connectTime: Double? = nil
    private var logged = Set<String>()

    mutating func disconnected() {
        connectTime = nil
    }

    mutating func line(_ event: Event, now: Double, fields: [(String, String)] = [], once: Bool = false) -> String? {
        if event == .connect {
            connectTime = now
            logged.removeAll()
        }
        let pairs = fields.map { "\($0.0)=\($0.1)" }
        if once && !logged.insert(([event.rawValue] + pairs).joined(separator: " ")).inserted {
            return nil
        }
        let since = connectTime.map { String(Int(((now - $0) * 1000).rounded())) } ?? "na"
        return (["DIAG stream_start event=\(event.rawValue) since_connect_ms=\(since)"] + pairs).joined(separator: " ")
    }
}
