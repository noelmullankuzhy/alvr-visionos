// SOURCES: ALVRClient/StreamBootstrap.swift
// StreamBootstrap: fake tracking from StreamingStarted until the first frame is queued, then hand over.
@main
enum StreamBootstrapTests {
    static func main() {
        // Idle: nothing to do before a stream starts.
        var b = StreamBootstrap()
        expectEqual(b.phase, .idle, "starts idle")
        expect(!b.shouldSendFakeTracking(now: 1.0), "idle: no fake tracking")
        expect(b.frameQueued(now: 1.0) == nil, "idle: no ALVRBOOT line")

        // Stream starts: fake tracking at most every fakeTrackingInterval.
        b.streamStarted(now: 10.0)
        expectEqual(b.phase, .awaitingFirstFrame, "awaiting after StreamingStarted")
        expect(b.shouldSendFakeTracking(now: 10.0), "first fake tracking immediately")
        expect(!b.shouldSendFakeTracking(now: 10.05), "rate-limited within the interval")
        expect(b.shouldSendFakeTracking(now: 10.1), "again after the interval")
        expect(!b.shouldSendFakeTracking(now: 10.15), "rate-limited again")

        // Fake tracking keeps going (rendering or not) until the first frame.
        expect(b.shouldSendFakeTracking(now: 11.4), "fake tracking continues until the first frame")

        // First frame queued: one ALVRBOOT line, hand over to real tracking.
        expectEqual(b.frameQueued(now: 11.5), "ALVRBOOT first_frame_queued_ms=1500", "ALVRBOOT line")
        expectEqual(b.phase, .streaming, "streaming after the first frame")
        expect(!b.shouldSendFakeTracking(now: 12.0), "no fake tracking once streaming")
        expect(b.frameQueued(now: 12.0) == nil, "later frames log nothing")

        // Re-entry (headset removed/put back, same stream): bootstrap again, but log only once per stream.
        b.reentered()
        expectEqual(b.phase, .awaitingFirstFrame, "re-entry awaits a frame again")
        expect(b.shouldSendFakeTracking(now: 20.0), "fake tracking resumes on re-entry")
        expect(b.frameQueued(now: 20.5) == nil, "ALVRBOOT logged once per stream")
        expectEqual(b.phase, .streaming, "streaming after re-entry frame")

        // Stream stops: idle; re-entry while idle stays idle.
        b.streamStopped()
        expectEqual(b.phase, .idle, "idle after stop")
        b.reentered()
        expectEqual(b.phase, .idle, "re-entry without a stream stays idle")
        expect(!b.shouldSendFakeTracking(now: 30.0), "stopped: no fake tracking")

        // Next stream: the rate limit and the log reset.
        b.streamStarted(now: 40.0)
        expect(b.shouldSendFakeTracking(now: 40.0), "new stream: fake tracking immediately")
        expectEqual(b.frameQueued(now: 40.25), "ALVRBOOT first_frame_queued_ms=250", "second stream logs again")

        finishTests("StreamBootstrapTests")
    }
}
