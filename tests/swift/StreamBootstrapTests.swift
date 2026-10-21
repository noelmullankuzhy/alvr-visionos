// SOURCES: ALVRClient/StreamBootstrap.swift
// StreamBootstrap: fake tracking and IDR requests from StreamingStarted until the first frame is queued, then hand over.
@main
enum StreamBootstrapTests {
    static func main() {
        // Idle: nothing to do before a stream starts.
        var b = StreamBootstrap()
        expectEqual(b.phase, .idle, "starts idle")
        expect(!b.shouldSendFakeTracking(now: 1.0), "idle: no fake tracking")
        expect(!b.shouldRequestIdr(now: 1.0, rendering: true), "idle: no IDR request")
        expect(b.frameQueued(now: 1.0) == nil, "idle: no ALVRBOOT line")

        // Stream starts: fake tracking at most every fakeTrackingInterval.
        b.streamStarted(now: 10.0)
        expectEqual(b.phase, .awaitingFirstFrame, "awaiting after StreamingStarted")
        expect(b.shouldSendFakeTracking(now: 10.0), "first fake tracking immediately")
        expect(!b.shouldSendFakeTracking(now: 10.05), "rate-limited within the interval")
        expect(b.shouldSendFakeTracking(now: 10.1), "again after the interval")
        expect(!b.shouldSendFakeTracking(now: 10.15), "rate-limited again")

        // IDR requests only once rendering, at most once per idrRequestInterval.
        expect(!b.shouldRequestIdr(now: 10.2, rendering: false), "no IDR before rendering")
        expectEqual(b.idrRequests, 0, "no IDR counted before rendering")
        expect(b.shouldRequestIdr(now: 10.3, rendering: true), "first IDR as soon as rendering")
        expect(!b.shouldRequestIdr(now: 10.8, rendering: true), "IDR rate-limited")
        expect(b.shouldRequestIdr(now: 11.3, rendering: true), "IDR again after the interval")
        expectEqual(b.idrRequests, 2, "two IDR requests counted")

        // Fake tracking keeps going after rendering starts, until the first frame.
        expect(b.shouldSendFakeTracking(now: 11.4), "fake tracking continues while rendering")

        // First frame queued: one ALVRBOOT line, hand over to real tracking.
        expectEqual(b.frameQueued(now: 11.5), "ALVRBOOT first_frame_queued_ms=1500 idr_requests=2", "ALVRBOOT line")
        expectEqual(b.phase, .streaming, "streaming after the first frame")
        expect(!b.shouldSendFakeTracking(now: 12.0), "no fake tracking once streaming")
        expect(!b.shouldRequestIdr(now: 12.0, rendering: true), "no IDR requests once streaming")
        expect(b.frameQueued(now: 12.0) == nil, "later frames log nothing")

        // Re-entry (headset removed/put back, same stream): bootstrap again, but log only once per stream.
        b.reentered()
        expectEqual(b.phase, .awaitingFirstFrame, "re-entry awaits a frame again")
        expect(b.shouldSendFakeTracking(now: 20.0), "fake tracking resumes on re-entry")
        expect(b.shouldRequestIdr(now: 20.0, rendering: true), "IDR resumes on re-entry")
        expect(b.frameQueued(now: 20.5) == nil, "ALVRBOOT logged once per stream")
        expectEqual(b.phase, .streaming, "streaming after re-entry frame")

        // Stream stops: idle; re-entry while idle stays idle.
        b.streamStopped()
        expectEqual(b.phase, .idle, "idle after stop")
        b.reentered()
        expectEqual(b.phase, .idle, "re-entry without a stream stays idle")
        expect(!b.shouldSendFakeTracking(now: 30.0), "stopped: no fake tracking")

        // Next stream: counters and the log reset.
        b.streamStarted(now: 40.0)
        expectEqual(b.idrRequests, 0, "IDR count resets per stream")
        expect(b.shouldSendFakeTracking(now: 40.0), "new stream: fake tracking immediately")
        expect(b.shouldRequestIdr(now: 40.25, rendering: true), "new stream: IDR immediately")
        expectEqual(b.frameQueued(now: 40.25), "ALVRBOOT first_frame_queued_ms=250 idr_requests=1", "second stream logs again")

        finishTests("StreamBootstrapTests")
    }
}
