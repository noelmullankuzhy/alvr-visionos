// SOURCES: ALVRClient/Diagnostics/Diag.swift
// Streaming capture triggers: the request file (Documents/diag/capture.request, polled at most once per second, deleted
// when taken), ALVR_DIAG_CAPTURE_AFTER_MS (one capture N ms after the first presented stream frame), diagnostics off =
// never, and the reason strings written to capture.json. Idle captures are covered by DiagCaptureTests.
import Foundation

private final class FakeFS {
    var present = false
    var existsCalls = 0
    var removed = 0
    func exists(_ url: URL) -> Bool { existsCalls += 1; return present }
    func remove(_ url: URL) { removed += 1; present = false }
}

@main enum DiagStreamCaptureTests {
    static func main() throws {
        let dir = URL(fileURLWithPath: "/nonexistent/diag")

        // Request file: absent, present, deleted once taken, once-per-second poll.
        let fs = FakeFS()
        let file = DiagCaptureRequestFile(enabled: true, directory: dir, exists: fs.exists, remove: fs.remove)
        expectEqual(file.url.lastPathComponent, "capture.request", "request file name")
        expect(!file.poll(nowMs: 5000), "absent file: no request")
        expectEqual(fs.existsCalls, 1, "first poll checks the file")
        fs.present = true
        expect(!file.poll(nowMs: 5999), "polled less than a second ago: file not even looked at")
        expectEqual(fs.existsCalls, 1, "no filesystem access inside the one second window")
        expect(file.poll(nowMs: 6000), "present after a second: request taken")
        expectEqual(fs.removed, 1, "file deleted when taken")
        expect(!file.poll(nowMs: 7000), "deleted file does not repeat")
        fs.present = true
        expect(!file.poll(nowMs: 7500), "second request waits for the next poll slot")
        expect(file.poll(nowMs: 8000), "next request taken a second later")
        expectEqual(fs.removed, 2, "second request deleted too")

        // Diagnostics off: never looks, never deletes, never requests.
        let off = FakeFS(); off.present = true
        let disabled = DiagCaptureRequestFile(enabled: false, directory: dir, exists: off.exists, remove: off.remove)
        for ms in stride(from: 0, to: 10_000, by: 1000) { expect(!disabled.poll(nowMs: ms), "diag off: no request at \(ms)") }
        expectEqual(off.existsCalls, 0, "diag off: no filesystem access")
        expectEqual(off.removed, 0, "diag off: nothing deleted")

        // Environment parsing.
        expectEqual(DiagCaptureRequestFile.afterMs(environment: [:]), nil, "unset: no automatic capture")
        expectEqual(DiagCaptureRequestFile.afterMs(environment: ["ALVR_DIAG_CAPTURE_AFTER_MS": "2500"]), 2500, "N ms parsed")
        expectEqual(DiagCaptureRequestFile.afterMs(environment: ["ALVR_DIAG_CAPTURE_AFTER_MS": "0"]), 0, "zero is allowed")
        expectEqual(DiagCaptureRequestFile.afterMs(environment: ["ALVR_DIAG_CAPTURE_AFTER_MS": "soon"]), nil, "junk ignored")
        expectEqual(DiagCaptureRequestFile.afterMs(environment: ["ALVR_DIAG_CAPTURE_AFTER_MS": "-5"]), nil, "negative ignored")

        // Request file reaches the render thread as one streaming capture on a presented stream frame.
        let requests = DiagCaptureRequests()
        expect(requests.take(nowMs: 100, idle: false, streamFrame: true) == nil, "nothing requested: no streaming capture")
        requests.requestStreaming()
        requests.requestStreaming()
        expect(requests.take(nowMs: 200, idle: false, streamFrame: false) == nil, "no stream frame composited: request stays pending")
        let fileCapture = requests.take(nowMs: 300, idle: false, streamFrame: true)
        expectEqual(fileCapture?.reason, "request_file", "reason request_file")
        expect(requests.take(nowMs: 400, idle: false, streamFrame: true) == nil, "duplicate requests collapse to one capture")

        // After N ms: once, counted from the first stream frame.
        let after = DiagCaptureRequests()
        after.configureAfterMs(1500)
        expect(after.take(nowMs: 9000, idle: false, streamFrame: false) == nil, "waiting frames do not start the clock")
        expect(after.take(nowMs: 10_000, idle: false, streamFrame: true) == nil, "first stream frame starts the clock")
        expect(after.take(nowMs: 11_499, idle: false, streamFrame: true) == nil, "not before N ms")
        expectEqual(after.take(nowMs: 11_500, idle: false, streamFrame: true)?.reason, "after_ms", "reason after_ms at N ms")
        expect(after.take(nowMs: 20_000, idle: false, streamFrame: true) == nil, "after_ms is one-shot")
        let zero = DiagCaptureRequests()
        zero.configureAfterMs(0)
        expectEqual(zero.take(nowMs: 1, idle: false, streamFrame: true)?.reason, "after_ms", "N = 0 captures on the first frame")

        // Streaming and idle paths stay separate; idle reasons are explicit.
        let mixed = DiagCaptureRequests()
        mixed.requestStreaming()
        expect(mixed.take(nowMs: 0, idle: true) == nil, "idle frame never takes the streaming request")
        expectEqual(mixed.take(nowMs: 1, idle: false, streamFrame: true)?.reason, "request_file", "streaming request still pending")
        let timer = DiagCaptureRequests()
        _ = timer.take(nowMs: 0, idle: true)
        expectEqual(timer.take(nowMs: 3000, idle: true)?.reason, "start_timer", "idle timer reason")
        timer.mark(eye: "L", spoke: 0, pct: 90)
        expectEqual(timer.take(nowMs: 3001, idle: true)?.reason, "corner_mark", "idle mark reason")

        // Session cap applies to streaming captures too.
        let cap = DiagCaptureRequests()
        var taken = 0
        for i in 0..<40 { cap.requestStreaming(); if cap.take(nowMs: i, idle: false, streamFrame: true) != nil { taken += 1 } }
        expectEqual(taken, 24, "session cap covers streaming captures")

        // Diag off: DiagCaptureRequests is never configured or fed, so streaming frames never capture.
        let untouched = DiagCaptureRequests(acceptsMarks: false)
        for i in 0..<5 { expect(untouched.take(nowMs: i * 1000, idle: false, streamFrame: true) == nil, "unconfigured: never captures") }
        finishTests("DiagStreamCapture")
    }
}
