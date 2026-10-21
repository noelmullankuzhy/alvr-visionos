// SOURCES: ALVRClient/StreamBootstrap.swift
// Stream start whatever the immersive space does: event-thread pose keepalive, the streaming space's open sequence
// (dismiss and retry, full -> mixed fallback, never a silent wait) and the DIAG stream_start timing lines.
@main
enum StreamStartTests {
    static func keepalive() {
        // Before any render loop runs (space requested, not open yet): send at once, then every interval.
        var k = PoseKeepalive()
        expectEqual(k.shouldSend(now: 10.0), PoseKeepalive.Send(startsEpisode: true), "no render poses yet: send now")
        expect(k.shouldSend(now: 10.05) == nil, "rate-limited within the interval")
        expectEqual(k.shouldSend(now: 10.1), PoseKeepalive.Send(startsEpisode: false), "again after the interval")

        // The space opens and its render loop sends: the keepalive stands down and reports its episode.
        expectEqual(k.renderSent(now: 10.15), 2, "render takeover ends the episode of 2 sends")
        expect(k.renderSent(now: 10.16) == nil, "later render sends end nothing")
        expect(k.shouldSend(now: 10.2) == nil, "render loop fresh: no keepalive")
        expect(k.shouldSend(now: 10.35) == nil, "still fresh just under staleAfter")

        // Render loop at 90 Hz never lets the keepalive in.
        var t = 10.16
        for _ in 0..<200 {
            t += 1.0 / 90.0
            expect(k.renderSent(now: t) == nil, "healthy render loop: no episode")
            expect(k.shouldSend(now: t + 0.005) == nil, "healthy render loop: no keepalive")
        }

        // The layer pauses (space switching): stale after staleAfter, then keepalive at its interval.
        let stall = t
        expect(k.shouldSend(now: stall + 0.15) == nil, "not stale yet")
        expectEqual(k.shouldSend(now: stall + PoseKeepalive.staleAfter), PoseKeepalive.Send(startsEpisode: true), "stale: new episode")
        expect(k.shouldSend(now: stall + PoseKeepalive.staleAfter + 0.05) == nil, "episode rate-limited")
        var sends = 1
        var now = stall + PoseKeepalive.staleAfter
        for _ in 0..<50 {
            now += PoseKeepalive.interval
            if k.shouldSend(now: now) != nil { sends += 1 }
        }
        expectEqual(sends, 51, "keepalive keeps sending for the whole stall (90 s silences never happen)")
        expectEqual(k.renderSent(now: now + 0.01), 51, "resumed render loop ends the episode")
        expect(k.shouldSend(now: now + 0.02) == nil, "render fresh again")

        // Bootstrap fake tracking from a running render loop (10 Hz) also counts as fresh.
        var b = PoseKeepalive()
        _ = b.renderSent(now: 1.0)
        for i in 1...20 {
            let at = 1.0 + Double(i) * StreamBootstrap.fakeTrackingInterval
            expect(b.shouldSend(now: at - 0.001) == nil, "render bootstrap at 10 Hz: no double fake poses")
            _ = b.renderSent(now: at)
        }
    }

    static func openSequence() {
        typealias S = StreamSpaceOpen
        expectEqual(S.spaceID(fullImmersion: false), "MetalClient", "mixed space id")
        expectEqual(S.spaceID(fullImmersion: true), "MetalClientFull", "full space id")

        // Opened: done, for either space and any attempt.
        expectEqual(S.next(after: "MetalClient", opened: true, attempt: 1), .done, "mixed opened")
        expectEqual(S.next(after: "MetalClientFull", opened: true, attempt: 1), .done, "full opened")
        expectEqual(S.next(after: "MetalClient", opened: true, attempt: 3), .done, "fallback opened")

        // Mixed failure: unchanged behaviour (no retry), the caller only logs it.
        expectEqual(S.next(after: "MetalClient", opened: false, attempt: 1), .giveUp, "mixed failure gives up as before")

        // Full failure: another immersive space may hold the single slot, so dismiss first and retry,
        // then fall back to the mixed space, then give up. Always terminates.
        expectEqual(S.next(after: "MetalClientFull", opened: false, attempt: 1), .dismissThenOpen("MetalClientFull"), "full fails: dismiss, retry")
        expectEqual(S.next(after: "MetalClientFull", opened: false, attempt: 2), .open("MetalClient"), "full fails twice: mixed fallback")
        expectEqual(S.next(after: "MetalClient", opened: false, attempt: 3), .giveUp, "fallback fails: give up")

        var id = S.spaceID(fullImmersion: true)
        var attempt = 1
        var trace: [String] = []
        loop: while attempt < 10 {
            trace.append(id)
            switch S.next(after: id, opened: false, attempt: attempt) {
            case .done, .giveUp: break loop
            case .dismissThenOpen(let next): trace.append("dismiss"); id = next
            case .open(let next): id = next
            }
            attempt += 1
        }
        expectEqual(trace, ["MetalClientFull", "dismiss", "MetalClientFull", "MetalClient"], "full sequence when nothing opens")

        // A pending open is logged, never a silent wait.
        expect(S.pendingLogInterval > 0 && S.pendingLogInterval <= 5, "pending open logged at least every 5 s")
    }

    static func timing() {
        var t = StreamStartTiming()
        expectEqual(t.line(.spaceRequested, now: 1.0, fields: [("id", "MetalClientFull")]),
                    "DIAG stream_start event=space_requested since_connect_ms=na id=MetalClientFull", "before connect: na")
        expectEqual(t.line(.connect, now: 100.0), "DIAG stream_start event=connect since_connect_ms=0", "connect is t0")
        expectEqual(t.line(.spaceRequested, now: 100.25, fields: [("id", "MetalClientFull"), ("attempt", "1")]),
                    "DIAG stream_start event=space_requested since_connect_ms=250 id=MetalClientFull attempt=1", "space requested")
        expectEqual(t.line(.spaceOpenResult, now: 148.5, fields: [("result", "opened")]),
                    "DIAG stream_start event=space_open_result since_connect_ms=48500 result=opened", "open result")

        // once: at most one line per connection per event and fields.
        expectEqual(t.line(.firstPoseSent, now: 100.001, fields: [("kind", "fake")], once: true),
                    "DIAG stream_start event=first_pose_sent since_connect_ms=1 kind=fake", "first fake pose")
        expect(t.line(.firstPoseSent, now: 100.2, fields: [("kind", "fake")], once: true) == nil, "fake pose logged once")
        expectEqual(t.line(.firstPoseSent, now: 149.0, fields: [("kind", "real")], once: true),
                    "DIAG stream_start event=first_pose_sent since_connect_ms=49000 kind=real", "first real pose")
        expectEqual(t.line(.firstDecodedFrame, now: 148.9, once: true),
                    "DIAG stream_start event=first_decoded_frame since_connect_ms=48900", "first decoded frame")
        expect(t.line(.firstDecodedFrame, now: 149.9, once: true) == nil, "decoded frame logged once")
        expect(t.line(.layerPaused, now: 150.0) != nil, "space events log every time")
        expect(t.line(.layerPaused, now: 151.0) != nil, "space events log every time (again)")

        // Disconnect: no stale t0. Next connect: new t0, once-lines again.
        t.disconnected()
        expectEqual(t.line(.spaceRequested, now: 200.0),
                    "DIAG stream_start event=space_requested since_connect_ms=na", "after disconnect: na")
        _ = t.line(.connect, now: 300.0)
        expectEqual(t.line(.firstPoseSent, now: 300.1, fields: [("kind", "fake")], once: true),
                    "DIAG stream_start event=first_pose_sent since_connect_ms=100 kind=fake", "new connection logs again")
    }

    static func main() {
        keepalive()
        openSequence()
        timing()
        finishTests("StreamStartTests")
    }
}
