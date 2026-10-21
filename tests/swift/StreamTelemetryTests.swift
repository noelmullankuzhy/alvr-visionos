// SOURCES: ALVRClient/StreamTelemetry.swift ALVRClient/FramePacing.swift
// Window counters, pacing counters, percentiles, per-window reset, JSON shape and the jsonl file sink of StreamTelemetry.
import Foundation

private final class CaptureSink: StreamTelemetrySink {
    var sessions: [Date] = []
    var lines: [(prefix: String, json: String)] = []
    func beginSession(utcStart: Date) { sessions.append(utcStart) }
    let encoder = StreamTelemetryRecord.makeEncoder()
    func write(_ record: StreamTelemetryRecord) { lines.append((record.prefix, record.json(using: encoder) ?? "")) }
    func objects(_ prefix: String) -> [[String: Any]] {
        lines.filter { $0.prefix == prefix }.map {
            (try? JSONSerialization.jsonObject(with: Data($0.json.utf8))) as? [String: Any] ?? [:]
        }
    }
}

private final class FakeClock {
    var ns: UInt64 = 5_000_000_000
    func advance(ms: Double) { ns += UInt64(ms * 1_000_000) }
}

private func makeTelemetry() -> (StreamTelemetry, CaptureSink, FakeClock) {
    let sink = CaptureSink()
    let clock = FakeClock()
    let telemetry = StreamTelemetry(sink: sink, clock: { clock.ns }, wallClock: { 1_800_000_000.25 })
    return (telemetry, sink, clock)
}

private func startStream(_ telemetry: StreamTelemetry) {
    telemetry.streamingStarted(viewWidth: 2816, viewHeight: 2240, refreshRateHint: 90, encodingGamma: 1.5,
                               enableFoveatedEncoding: true, enableHdr: false, forceFastSecretTextureFormats: false)
}

private func double(_ object: [String: Any], _ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
private func int(_ object: [String: Any], _ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }

private func testPercentile() {
    expectEqual(StreamTelemetry.percentile([], 0.95), nil, "empty has no p95")
    expectEqual(StreamTelemetry.percentile([7], 0.95), 7, "single sample")
    expectEqual(StreamTelemetry.percentile((1...100).map(Double.init).shuffled(), 0.95), 95, "nearest rank p95 of 1..100")
    expectEqual(StreamTelemetry.percentile((1...20).map(Double.init), 0.95), 19, "nearest rank p95 of 1..20")
    expectEqual(StreamTelemetry.percentile([3, 1, 2], 0.5), 2, "median of 3")
}

private func testLatencySamples() {
    var samples = LatencySamples(capacity: 4)
    expectEqual(samples.mean, nil, "no mean when empty")
    for v in [1.0, 2, 3, 4, 100, 200] { samples.add(v) }
    expectEqual(samples.count, 6, "count includes samples beyond capacity")
    expectEqual(samples.mean, 310.0 / 6.0, "mean uses every sample")
    expectEqual(samples.percentile(0.95), 4, "percentile over the stored samples only")
    samples.reset()
    expectEqual(samples.count, 0, "reset clears count")
    expectEqual(samples.mean, nil, "reset clears mean")
    samples.add(9)
    expectEqual(samples.percentile(0.95), 9, "stale stored values are not reused after reset")
}

private func testWindowingAndCounters() {
    let (telemetry, sink, clock) = makeTelemetry()
    telemetry.recordReceived(timestampNs: 1)
    clock.advance(ms: 2000)
    telemetry.recordRender(frameTimestampNs: 1, displayed: true, presentNs: clock.ns)
    expectEqual(sink.objects("ALVRSTATS").count, 0, "no stats before streaming starts")

    startStream(telemetry)
    expectEqual(sink.sessions.count, 1, "streaming start begins a session")
    // 1 s window: 3 frames received, 1 dropped before decode, 2 decoded (5 ms, 7 ms), 1 decode error, 1 overflow.
    for ts: UInt64 in [100, 200, 300] {
        telemetry.recordReceived(timestampNs: ts)
    }
    telemetry.recordDroppedBeforeDecode()
    let submit = clock.ns
    clock.advance(ms: 5)
    telemetry.recordDecodeOutput(submitNs: submit, ok: true)
    let submit2 = clock.ns
    clock.advance(ms: 7)
    telemetry.recordDecodeOutput(submitNs: submit2, ok: true)
    telemetry.recordDecodeOutput(submitNs: clock.ns, ok: false)
    telemetry.recordDecodeSubmitFailed()
    telemetry.recordDecodeOverrun()
    telemetry.recordQueueOverflow()
    // Frame 100 received at t0+0; presented 20 ms later. Frame 200 presented twice (second is a repeat).
    clock.advance(ms: 8)
    telemetry.recordRender(frameTimestampNs: 100, displayed: true, presentNs: clock.ns)
    telemetry.recordRender(frameTimestampNs: 200, displayed: true, presentNs: clock.ns + 10_000_000)
    telemetry.recordRender(frameTimestampNs: 200, displayed: true, presentNs: clock.ns + 20_000_000)
    telemetry.recordRender(frameTimestampNs: nil, displayed: false, presentNs: clock.ns)
    expectEqual(sink.objects("ALVRSTATS").count, 0, "nothing emitted inside the window")

    clock.advance(ms: 980)  // 1000 ms since start
    telemetry.recordRender(frameTimestampNs: 200, displayed: true, presentNs: clock.ns)
    let stats = sink.objects("ALVRSTATS")
    expectEqual(stats.count, 1, "one record once the window closes")
    guard let s = stats.first else { return }
    expectEqual(s["type"] as? String, "stats", "type")
    expectEqual(double(s, "window_s"), 1.0, "window length")
    expectEqual(double(s, "t"), 1_800_000_000.25, "wall clock time")
    expectEqual(int(s, "frames_received"), 3, "received")
    expectEqual(int(s, "frames_decoded"), 2, "decoded")
    expectEqual(int(s, "decode_errors"), 2, "decode errors (output error + submit failure)")
    expectEqual(int(s, "dropped_before_decode"), 1, "dropped before decode")
    expectEqual(int(s, "dropped_decode_overrun"), 1, "decode overrun")
    expectEqual(int(s, "dropped_queue_overflow"), 1, "queue overflow")
    expectEqual(int(s, "frames_dropped"), 3, "drops total")
    expectEqual(int(s, "frames_presented"), 2, "new frames presented")
    expectEqual(int(s, "frames_repeated"), 2, "repeats (same timestamp again, incl. the window-closing render)")
    expectEqual(int(s, "frames_blank"), 1, "render loops without video")
    expectEqual(int(s, "render_loops"), 5, "every render call counts as a loop")
    expectEqual(double(s, "render_loop_hz"), 5.0, "loops per second")
    expectEqual(double(s, "presented_fps"), 2.0, "presented per second")
    expectEqual(double(s, "decode_ms_mean"), 6.0, "decode mean")
    expectEqual(double(s, "decode_ms_p95"), 7.0, "decode p95")
    expectEqual(double(s, "receive_to_present_ms_mean"), 25.0, "receive->present mean of 20 and 30 ms")
    expectEqual(double(s, "receive_to_present_ms_p95"), 30.0, "receive->present p95")

    // Next window is reset: only one repeat render, no decode samples -> latency keys omitted.
    clock.advance(ms: 1000)
    telemetry.recordRender(frameTimestampNs: 200, displayed: true, presentNs: clock.ns)
    let second = sink.objects("ALVRSTATS")
    expectEqual(second.count, 2, "second window emitted")
    guard second.count == 2 else { return }
    let r = second[1]
    expectEqual(int(r, "frames_received"), 0, "counters reset per window")
    expectEqual(int(r, "frames_repeated"), 1, "only this window's repeat")
    expectEqual(int(r, "frames_presented"), 0, "nothing new")
    expect(r["decode_ms_mean"] == nil, "decode mean omitted when no samples")
    expect(r["decode_ms_p95"] == nil, "decode p95 omitted when no samples")
    expect(r["receive_to_present_ms_mean"] == nil, "latency omitted when no samples")

    // Stopping flushes a partial window, then nothing more is emitted.
    clock.advance(ms: 500)
    telemetry.recordReceived(timestampNs: 900)
    telemetry.streamingStopped()
    let afterStop = sink.objects("ALVRSTATS")
    expectEqual(afterStop.count, 3, "partial window flushed on stop")
    if afterStop.count == 3 {
        expectEqual(double(afterStop[2], "window_s"), 0.5, "partial window length")
        expectEqual(int(afterStop[2], "frames_received"), 1, "partial window counter")
    }
    clock.advance(ms: 3000)
    telemetry.recordRender(frameTimestampNs: 900, displayed: true, presentNs: clock.ns)
    expectEqual(sink.objects("ALVRSTATS").count, 3, "no stats after stop")
}

private func testStatsJsonShape() {
    let (telemetry, sink, clock) = makeTelemetry()
    startStream(telemetry)
    clock.advance(ms: 1000)
    telemetry.recordRender(frameTimestampNs: nil, displayed: false, presentNs: clock.ns)
    guard let line = sink.lines.last(where: { $0.prefix == "ALVRSTATS" }) else {
        expect(false, "stats line emitted")
        return
    }
    expect(!line.json.contains("\n"), "one line")
    let keys = ["decode_errors", "dropped_before_decode", "dropped_decode_overrun", "dropped_queue_overflow",
                "dropped_selection_skip", "frames_blank", "frames_decoded", "frames_dropped", "frames_presented",
                "frames_received", "frames_repeated", "late_frames", "presented_fps", "render_loop_hz", "render_loops",
                "repeats_no_new_frame", "repeats_retry", "t", "type", "unique_presented_fps", "window_s"]
    let object = sink.objects("ALVRSTATS").last ?? [:]
    expectEqual(object.keys.sorted(), keys, "stable stats keys (no optional latency keys without samples)")
    let positions = keys.compactMap { line.json.range(of: "\"\($0)\"")?.lowerBound }
    expectEqual(positions.count, keys.count, "all keys present in text")
    expectEqual(positions, positions.sorted(), "keys are sorted in the JSON text")
    expect(!line.json.contains("\"frames_received\":\""), "numbers are not strings")
}

private func testPacingCounters() {
    let (telemetry, sink, clock) = makeTelemetry()
    telemetry.recordFrameQueued(timestampNs: 100)
    telemetry.recordSelection(timestampNs: 100, source: .new, pollWaitNs: 1_000_000)
    telemetry.recordSubmitTiming(vsyncNs: 100_000_000, completionNs: 105_000_000)
    startStream(telemetry)
    // Frame 100 decoded at t0 and selected 3 ms later; frame 200 decoded, selected 5 ms later, one older frame skipped.
    telemetry.recordFrameQueued(timestampNs: 100)
    clock.advance(ms: 3)
    telemetry.recordSelection(timestampNs: 100, source: .new, pollWaitNs: 1_000_000)
    telemetry.recordFrameQueued(timestampNs: 200)
    clock.advance(ms: 5)
    telemetry.recordSelection(timestampNs: 200, source: .new, pollWaitNs: 2_000_000, skipped: 1)
    telemetry.recordSelection(timestampNs: 200, source: .retry, pollWaitNs: 0)
    telemetry.recordSelection(timestampNs: 200, source: .reuse, pollWaitNs: 5_000_000)
    telemetry.recordSelection(timestampNs: nil, source: .none, pollWaitNs: 5_000_000)
    // GPU finished 2 ms early, then 3 ms late.
    telemetry.recordSubmitTiming(vsyncNs: 100_000_000, completionNs: 98_000_000)
    telemetry.recordSubmitTiming(vsyncNs: 200_000_000, completionNs: 203_000_000)
    // Presented 100, 200, 200 (repeat), 100 again (a change but not a new timestamp), 300.
    for ts: UInt64 in [100, 200, 200, 100] {
        telemetry.recordRender(frameTimestampNs: ts, displayed: true, presentNs: clock.ns)
    }
    clock.advance(ms: 992)
    telemetry.recordRender(frameTimestampNs: 300, displayed: true, presentNs: clock.ns)
    guard let s = sink.objects("ALVRSTATS").first else {
        expect(false, "stats emitted")
        return
    }
    expectEqual(double(s, "queue_age_ms_mean"), 4.0, "decode->selected mean of 3 and 5 ms")
    expectEqual(double(s, "queue_age_ms_p95"), 5.0, "decode->selected p95")
    expectEqual(double(s, "poll_wait_ms_mean"), 2.6, "poll wait mean over every selection")
    expectEqual(double(s, "poll_wait_ms_p95"), 5.0, "poll wait p95")
    expectEqual(int(s, "repeats_retry"), 1, "retry repeats")
    expectEqual(int(s, "repeats_no_new_frame"), 1, "no-new-frame repeats")
    expectEqual(int(s, "dropped_selection_skip"), 1, "older frames skipped by selection")
    expectEqual(int(s, "frames_dropped"), 1, "skips count as drops")
    expectEqual(int(s, "late_frames"), 1, "one completion after vsync")
    expectEqual(double(s, "late_ms_mean"), 0.5, "signed lateness mean of -2 and +3 ms")
    expectEqual(double(s, "late_ms_p95"), 3.0, "lateness p95")
    expectEqual(int(s, "frames_presented"), 4, "presented counts timestamp changes")
    expectEqual(double(s, "unique_presented_fps"), 3.0, "distinct new timestamps per second")

    // Next window: nothing selected or submitted -> pacing latency keys omitted, counters reset.
    clock.advance(ms: 1000)
    telemetry.recordRender(frameTimestampNs: 300, displayed: true, presentNs: clock.ns)
    let stats = sink.objects("ALVRSTATS")
    expectEqual(stats.count, 2, "second window")
    guard stats.count == 2 else { return }
    let r = stats[1]
    expect(r["queue_age_ms_mean"] == nil && r["poll_wait_ms_mean"] == nil && r["late_ms_mean"] == nil, "pacing latencies omitted without samples")
    expectEqual(int(r, "late_frames"), 0, "late frames reset")
    expectEqual(int(r, "repeats_retry"), 0, "retry reset")
    expectEqual(double(r, "unique_presented_fps"), 0, "no new timestamp")

    // A new session forgets the presented timestamps of the last one.
    telemetry.streamingStopped()
    startStream(telemetry)
    telemetry.recordRender(frameTimestampNs: 50, displayed: true, presentNs: clock.ns)
    clock.advance(ms: 1000)
    telemetry.recordRender(frameTimestampNs: 50, displayed: true, presentNs: clock.ns)
    expectEqual(double(sink.objects("ALVRSTATS").last ?? [:], "unique_presented_fps"), 1.0, "unique count restarts per session")
}

// Out-of-order presentation: every timestamp not presented before counts once.
private func testUniquePresentedOutOfOrder() {
    let (telemetry, sink, clock) = makeTelemetry()
    startStream(telemetry)
    for ts: UInt64 in [200, 100, 200, 100, 150] {
        telemetry.recordRender(frameTimestampNs: ts, displayed: true, presentNs: clock.ns)
    }
    clock.advance(ms: 1000)
    telemetry.recordRender(frameTimestampNs: 150, displayed: true, presentNs: clock.ns)
    let s = sink.objects("ALVRSTATS").last ?? [:]
    expectEqual(double(s, "unique_presented_fps"), 3.0, "200, 100 and 150 are distinct even though 100 and 150 are below the max")
    expectEqual(int(s, "frames_presented"), 5, "timestamp changes")
}

// The same timestamp queued twice: queue age is measured from the latest enqueue.
private func testQueueAgeUsesLatestEnqueue() {
    let (telemetry, sink, clock) = makeTelemetry()
    startStream(telemetry)
    telemetry.recordFrameQueued(timestampNs: 100)
    clock.advance(ms: 10)
    telemetry.recordFrameQueued(timestampNs: 100)
    clock.advance(ms: 2)
    telemetry.recordSelection(timestampNs: 100, source: .new, pollWaitNs: 0)
    clock.advance(ms: 988)
    telemetry.recordRender(frameTimestampNs: nil, displayed: false, presentNs: clock.ns)
    let s = sink.objects("ALVRSTATS").last ?? [:]
    expectEqual(double(s, "queue_age_ms_mean"), 2.0, "age from the latest enqueue, not the first")
}

private func testFormatRecords() {
    let (telemetry, sink, _) = makeTelemetry()
    telemetry.updateFormat { $0.renderer = "metal" }
    expectEqual(sink.lines.count, 0, "format changes before a session are buffered, not written")
    expectEqual(sink.sessions.count, 0, "no session before the stream starts")
    startStream(telemetry)
    var formats = sink.objects("ALVRFORMAT")
    expectEqual(formats.count, 1, "stream start emits the current format as the session's first record")
    expectEqual(sink.lines.first?.prefix, "ALVRFORMAT", "format is the first record of the session")
    guard let started = formats.last else { return }
    expectEqual(started["type"] as? String, "format", "type")
    expectEqual(started["renderer"] as? String, "metal", "renderer kept")
    expectEqual(int(started, "view_width"), 2816, "view width")
    expectEqual(int(started, "view_height"), 2240, "view height")
    expectEqual(double(started, "refresh_rate_hint"), 90, "refresh hint")
    expectEqual(double(started, "encoding_gamma"), 1.5, "gamma")
    expectEqual(started["enable_foveated_encoding"] as? Bool, true, "ffe")
    expectEqual(started["enable_hdr"] as? Bool, false, "hdr")
    expectEqual(started["force_fast_secret_texture_formats"] as? Bool, false, "secret formats flag")
    expect(started["codec"] == nil, "codec omitted until known")

    telemetry.updateFormat { $0.codec = "hevc"; $0.codedWidth = 5664; $0.codedHeight = 2240; $0.bitDepth = 10 }
    telemetry.updateFormat { $0.codec = "hevc" }  // unchanged -> no record
    formats = sink.objects("ALVRFORMAT")
    expectEqual(formats.count, 2, "only real changes emit")

    telemetry.noteDecoderOutput(pixelFormat: 0x2678_6630, lumaTextureFormat: 508, chromaTextureFormat: 0, name: "Lossless")
    telemetry.noteDecoderOutput(pixelFormat: 0x2678_6630, lumaTextureFormat: 508, chromaTextureFormat: 0, name: "Lossless")
    telemetry.noteDrawable(pixelFormat: 81, view0Width: 1888, view0Height: 1824, view1Width: 1888, view1Height: 1824)
    telemetry.noteDrawable(pixelFormat: 81, view0Width: 1888, view0Height: 1824, view1Width: 1888, view1Height: 1824)
    formats = sink.objects("ALVRFORMAT")
    expectEqual(formats.count, 4, "decoder output and drawable each emit once")
    guard let last = formats.last else { return }
    expectEqual(last["decoder_pixel_format"] as? String, "&xf0", "FourCC string")
    expectEqual(last["decoder_pixel_format_name"] as? String, "Lossless", "pixel format name")
    expectEqual(int(last, "luma_texture_format"), 508, "luma texture format")
    expect(last["chroma_texture_format"] == nil, "invalid chroma texture format omitted")
    expectEqual(int(last, "drawable_pixel_format"), 81, "drawable format")
    expectEqual((last["drawable_view_sizes"] as? [[Int]]) ?? [], [[1888, 1824], [1888, 1824]], "per-view sizes")
    expectEqual(int(last, "coded_width"), 5664, "coded width persists")

    // Stop clears decoder-derived fields so the next session reports its own decoder.
    telemetry.streamingStopped()
    let linesAtStop = sink.lines.count
    telemetry.updateFormat { $0.displayRefreshRateHz = 90 }
    expectEqual(sink.lines.count, linesAtStop, "no records between sessions")
    startStream(telemetry)
    guard let restarted = sink.objects("ALVRFORMAT").last else { return }
    expectEqual(double(restarted, "display_refresh_rate_hz"), 90, "change made between sessions is in the next session's first record")
    expect(restarted["codec"] == nil, "codec cleared by stop")
    expect(restarted["decoder_pixel_format"] == nil, "pixel format cleared by stop")
    expectEqual(restarted["renderer"] as? String, "metal", "renderer survives stop")
    expectEqual(sink.sessions.count, 2, "new session per stream")
    telemetry.noteDecoderOutput(pixelFormat: 0x2678_6630, lumaTextureFormat: 508, chromaTextureFormat: 0, name: "Lossless")
    expectEqual(sink.objects("ALVRFORMAT").last?["decoder_pixel_format"] as? String, "&xf0", "decoder re-noted after restart")

    // Repeated StreamingStarted while active does not open another session.
    startStream(telemetry)
    expectEqual(sink.sessions.count, 2, "no new session while active")
}

private func testCodecHelpers() {
    expectEqual(StreamTelemetry.fourCCString(0x6876_6331), "hvc1", "fourcc hvc1")
    expectEqual(StreamTelemetry.fourCCString(0x2D78_6630), "-xf0", "fourcc with punctuation")
    expectEqual(StreamTelemetry.fourCCString(0x0000_0028), "40", "non-printable fourcc falls back to decimal")
    expectEqual(StreamTelemetry.codecName(fourCC: "hvc1"), "hevc", "hvc1")
    expectEqual(StreamTelemetry.codecName(fourCC: "hev1"), "hevc", "hev1")
    expectEqual(StreamTelemetry.codecName(fourCC: "avc1"), "h264", "avc1")
    expectEqual(StreamTelemetry.codecName(fourCC: "av01"), "av1", "av01")
    expectEqual(StreamTelemetry.codecName(fourCC: "jpeg"), nil, "unknown")

    // hvcC header from the client's fallback blob: chromaFormat 0xfd -> 4:2:0, bitDepthLumaMinus8 0xfa -> 10-bit.
    let hvcC: [UInt8] = [0x01, 0x22, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0xb4, 0xf0, 0x00, 0xfc,
                         0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x04]
    let hevc = StreamTelemetry.parseCodecConfig(fourCC: "hvc1", bytes: hvcC)
    expectEqual(hevc?.bitDepth, 10, "hvcC bit depth")
    expectEqual(hevc?.chromaSubsampling, "4:2:0", "hvcC chroma")
    var hvcC444 = hvcC
    hvcC444[16] = 0xfc | 3
    hvcC444[17] = 0xf8
    expectEqual(StreamTelemetry.parseCodecConfig(fourCC: "hvc1", bytes: hvcC444)?.chromaSubsampling, "4:4:4", "hvcC 4:4:4")
    expectEqual(StreamTelemetry.parseCodecConfig(fourCC: "hvc1", bytes: hvcC444)?.bitDepth, 8, "hvcC 8-bit")
    expect(StreamTelemetry.parseCodecConfig(fourCC: "hvc1", bytes: Array(hvcC[0..<10])) == nil, "short hvcC")

    // av1C from the client's fake AV1 config: byte2 0x0c -> 8-bit, subsampling x=1 y=1 -> 4:2:0.
    let av1C: [UInt8] = [0x81, 0x05, 0x0c, 0x00]
    let av1 = StreamTelemetry.parseCodecConfig(fourCC: "av01", bytes: av1C)
    expectEqual(av1?.bitDepth, 8, "av1C 8-bit")
    expectEqual(av1?.chromaSubsampling, "4:2:0", "av1C 4:2:0")
    expectEqual(StreamTelemetry.parseCodecConfig(fourCC: "av01", bytes: [0x81, 0x05, 0x40, 0x00])?.bitDepth, 10, "av1C 10-bit high_bitdepth")
    expectEqual(StreamTelemetry.parseCodecConfig(fourCC: "av01", bytes: [0x81, 0x05, 0x40, 0x00])?.chromaSubsampling, "4:4:4", "av1C 4:4:4")
    expectEqual(StreamTelemetry.parseCodecConfig(fourCC: "av01", bytes: [0x81, 0x05, 0x50, 0x00])?.chromaSubsampling, "4:0:0", "av1C monochrome")

    // avcC, High profile (100) with one tiny SPS/PPS and the chroma/bit-depth trailer: 4:2:0, 8-bit.
    let avcC: [UInt8] = [0x01, 100, 0x00, 0x33, 0xff, 0xe1, 0x00, 0x02, 0x67, 0x64, 0x01, 0x00, 0x01, 0x68,
                         0xfd, 0xf8, 0xf8, 0x00]
    expectEqual(StreamTelemetry.parseCodecConfig(fourCC: "avc1", bytes: avcC)?.chromaSubsampling, "4:2:0", "avcC chroma")
    expectEqual(StreamTelemetry.parseCodecConfig(fourCC: "avc1", bytes: avcC)?.bitDepth, 8, "avcC bit depth")
    expect(StreamTelemetry.parseCodecConfig(fourCC: "avc1", bytes: Array(avcC[0..<14])) == nil, "avcC without trailer")
}

private func testFileSink() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("local-scratch/stream-telemetry-test/telemetry")
    try? FileManager.default.removeItem(at: dir)
    expectEqual(StreamTelemetryFileSink.fileName(for: Date(timeIntervalSince1970: 1_792_546_200)), "20261021T013000Z.jsonl", "UTC file name")

    let sink = StreamTelemetryFileSink(directory: dir, echo: false)
    var format = StreamFormatRecord()
    format.renderer = "metal"
    sink.beginSession(utcStart: Date(timeIntervalSince1970: 1_792_546_200))
    sink.write(.format(StreamFormatRecord()))
    sink.write(.format(format))
    sink.flush()
    let file = dir.appendingPathComponent("20261021T013000Z.jsonl")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    expectEqual(text, "{\"type\":\"format\"}\n{\"renderer\":\"metal\",\"type\":\"format\"}\n", "records encoded and appended as jsonl")

    sink.beginSession(utcStart: Date(timeIntervalSince1970: 1_792_546_201))
    sink.write(.format(StreamFormatRecord()))
    sink.flush()
    let second = dir.appendingPathComponent("20261021T013001Z.jsonl")
    expectEqual((try? String(contentsOf: second, encoding: .utf8)) ?? "", "{\"type\":\"format\"}\n", "new session, new file")

    // Writing before any session starts one lazily.
    let lazyDir = dir.appendingPathComponent("lazy")
    let lazy = StreamTelemetryFileSink(directory: lazyDir, echo: false)
    lazy.write(.format(StreamFormatRecord()))
    lazy.flush()
    let made = (try? FileManager.default.contentsOfDirectory(atPath: lazyDir.path)) ?? []
    expectEqual(made.count, 1, "lazy session file created")
    expect(made.first?.hasSuffix("Z.jsonl") ?? false, "lazy file named by UTC start")
}

// Records in sink call order, with session starts inline; safe to call from several threads.
private final class OrderedSink: StreamTelemetrySink {
    private let lock = NSLock()
    private let encoder = StreamTelemetryRecord.makeEncoder()
    private(set) var entries: [[String: Any]] = []
    func beginSession(utcStart: Date) {
        lock.lock()
        entries.append(["session": true])
        lock.unlock()
    }
    func write(_ record: StreamTelemetryRecord) {
        guard case .format = record, let json = record.json(using: encoder),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        lock.lock()
        entries.append(object)
        lock.unlock()
    }
}

// The session's initial format must be enqueued before any format update that follows the session
// start, so the first record of a session is never older than a later one.
private func testSessionStartFormatOrdering() {
    var violations = 0
    var sessionsChecked = 0
    for _ in 0..<300 {
        let sink = OrderedSink()
        let telemetry = StreamTelemetry(sink: sink)
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            if worker == 0 {
                startStream(telemetry)
            } else {
                for value in 1...200 {
                    telemetry.updateFormat { $0.displayRefreshRateHz = Double(value) }
                }
            }
        }
        let entries = sink.entries
        guard let sessionIndex = entries.firstIndex(where: { $0["session"] != nil }) else {
            violations += 1
            continue
        }
        let formats = entries[(sessionIndex + 1)...]
        guard let first = formats.first else {
            violations += 1
            continue
        }
        sessionsChecked += 1
        let firstValue = double(first, "display_refresh_rate_hz") ?? 0
        if first["view_width"] == nil || formats.dropFirst().contains(where: { (double($0, "display_refresh_rate_hz") ?? 0) < firstValue }) {
            violations += 1
        }
        if entries[..<sessionIndex].count != 0 {
            violations += 1
        }
    }
    expectEqual(sessionsChecked, 300, "every run starts one session with an initial format")
    expectEqual(violations, 0, "initial format first and never older than later updates")
}

private func testPrunePolicy() {
    let names = (1...23).map { String(format: "202610%02dT120000Z.jsonl", $0) }.shuffled() + ["notes.txt", ".DS_Store", "x.jsonl"]
    let pruned = StreamTelemetryFileSink.filesToPrune(names, keep: 20)
    expectEqual(pruned.sorted(), ["20261001T120000Z.jsonl", "20261002T120000Z.jsonl", "20261003T120000Z.jsonl"], "oldest telemetry files beyond the newest 20")
    expectEqual(StreamTelemetryFileSink.filesToPrune(Array(names.prefix(5)), keep: 20), [], "nothing pruned under the limit")
    expectEqual(StreamTelemetryFileSink.filesToPrune(["notes.txt", "x.jsonl"], keep: 0), [], "foreign files never pruned")
}

private func testFileSinkPrunesOnSessionStart() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("local-scratch/stream-telemetry-test/prune")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for day in 1...25 {
        try? Data().write(to: dir.appendingPathComponent(String(format: "202609%02dT000000Z.jsonl", day)))
    }
    try? Data().write(to: dir.appendingPathComponent("keep.txt"))
    // A directory with a telemetry-style name, older than everything: never deleted, never counted.
    let namedDir = dir.appendingPathComponent("20250101T000000Z.jsonl")
    try? FileManager.default.createDirectory(at: namedDir, withIntermediateDirectories: true)
    try? Data().write(to: namedDir.appendingPathComponent("inner.txt"))
    let sink = StreamTelemetryFileSink(directory: dir, echo: false)
    sink.beginSession(utcStart: Date(timeIntervalSince1970: 1_792_546_200))
    sink.flush()
    let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    expectEqual(left.count, 22, "newest 20 telemetry files plus the foreign file and directory")
    expect(left.contains("20250101T000000Z.jsonl"), "timestamp-named directory not pruned")
    expect(FileManager.default.fileExists(atPath: namedDir.appendingPathComponent("inner.txt").path), "directory contents untouched")
    expect(left.contains("20261021T013000Z.jsonl"), "new session file kept")
    expect(!left.contains("20260906T000000Z.jsonl"), "older files pruned")
    expect(left.contains("20260907T000000Z.jsonl"), "19 newest older files kept")
    expect(left.contains("keep.txt"), "foreign file kept")
}

@main
enum StreamTelemetryTests {
    static func main() {
        testPercentile()
        testLatencySamples()
        testWindowingAndCounters()
        testStatsJsonShape()
        testPacingCounters()
        testUniquePresentedOutOfOrder()
        testQueueAgeUsesLatestEnqueue()
        testFormatRecords()
        testCodecHelpers()
        testFileSink()
        testSessionStartFormatOrdering()
        testPrunePolicy()
        testFileSinkPrunesOnSessionStart()
        finishTests("StreamTelemetryTests")
    }
}
