// SOURCES: ALVRClient/Diagnostics/Diag.swift
// Diagnostics core (GM decision 65): the DIAG line format and key/value escaping, the file sink's rotation at its size
// limit, off = no file and no work, the per-second cadence and GPU aggregation (nearest-rank p50/p95) and the thermal
// state names.
import Foundation

private func tempDir(_ name: String) -> URL {
    // $TMPDIR first: a sandboxed run may only write there, not to the per-user temporary directory.
    let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let url = base.appendingPathComponent("diag-tests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func logFiles(_ dir: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("diag-") && $0.pathExtension == "log" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func testLineFormat() {
    expectEqual(Diag.line(topic: "m6", tMs: 1234, fields: ["frames": 90, "ok": true, "p50_ms": 11.1111, "os": "26.1"]),
                "DIAG m6 t_ms=1234 frames=90 ok=true p50_ms=11.111 os=26.1", "fields in call order, doubles at 3 decimals")
    expectEqual(Diag.line(topic: "m1", tMs: 0, fields: [:]), "DIAG m1 t_ms=0", "no fields")
    expectEqual(Diag.line(topic: "bad topic", tMs: 5, fields: ["a b=c": 1, "": 2, "x.y_z9": 3]),
                "DIAG bad_topic t_ms=5 a_b_c=1 _=2 x.y_z9=3", "keys and topic keep [A-Za-z0-9_.], everything else becomes _")
    expectEqual(Diag.line(topic: "m1", tMs: 1, fields: ["os": "Version 26.1 (Build 23N5)", "q": "say \"hi\"\\", "nl": "a\nb", "eq": "a=b", "empty": ""]),
                #"DIAG m1 t_ms=1 os="Version 26.1 (Build 23N5)" q="say \"hi\"\\" nl="a\nb" eq="a=b" empty="""#,
                "values with spaces, quotes, backslashes, newlines, = or empty are quoted and escaped")
    expectEqual(Diag.line(topic: "m9", tMs: 2, fields: ["nan": Double.nan, "list": "rgba16Float,bgra8Unorm_srgb"]),
                "DIAG m9 t_ms=2 nan=nan list=rgba16Float,bgra8Unorm_srgb", "nan and comma lists stay bare")
}

private func testEnabled() {
    expect(!Diag.enabled(environment: [:], setting: false), "default off")
    expect(Diag.enabled(environment: [:], setting: true), "setting Diagnostics on")
    for value in ["1", "true", "YES", "on"] {
        expect(Diag.enabled(environment: ["ALVR_DIAG": value], setting: false), "ALVR_DIAG=\(value) on")
    }
    expect(!Diag.enabled(environment: ["ALVR_DIAG": "0"], setting: false), "ALVR_DIAG=0 off")
    expect(Diag.enabled(environment: ["ALVR_DIAG": "0"], setting: true), "setting or env: the setting still turns it on")
}

private func testRotation() {
    let dir = tempDir("rotate")
    var tick = 0.0
    let sink = DiagSink(directory: dir, maxBytes: 100, now: { tick += 1; return Date(timeIntervalSince1970: 1_792_500_000 + tick) }, console: nil)
    let line = String(repeating: "x", count: 39)  // 40 bytes with the newline
    for _ in 0..<5 { sink.write(line) }
    sink.flush()
    let files = logFiles(dir)
    expectEqual(files.count, 3, "40-byte lines in 100-byte files: 2 + 2 + 1")
    let sizes = files.map { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? Int) ?? -1 }
    expectEqual(sizes, [80, 80, 40], "no file passes the limit, no line is split or lost")
    expect(files.allSatisfy { $0.lastPathComponent.range(of: #"^diag-\d{8}T\d{6}Z(-\d+)?\.log$"#, options: .regularExpression) != nil },
           "names are diag-<UTC stamp>.log: \(files.map { $0.lastPathComponent })")

    // Same second for every file: names stay unique.
    let dir2 = tempDir("collide")
    let fixed = DiagSink(directory: dir2, maxBytes: 50, now: { Date(timeIntervalSince1970: 1_792_500_000) }, console: nil)
    for _ in 0..<3 { fixed.write(line) }
    fixed.flush()
    expectEqual(logFiles(dir2).count, 3, "three files in the same second")

    // A line longer than the limit still goes out whole, alone in its file.
    let dir3 = tempDir("long")
    let long = DiagSink(directory: dir3, maxBytes: 10, now: { Date() }, console: nil)
    long.write(String(repeating: "y", count: 30))
    long.write("z")
    long.flush()
    expectEqual(logFiles(dir3).count, 2, "oversize line alone, next line in a new file")
    expectEqual(Diag.maxFileBytes, 20 * 1024 * 1024, "decision 65: rotate at 20 MB")

    // Named sink (brightness trace): <name>-<UTC stamp>.<extension>, same rotation.
    let dir4 = tempDir("named")
    let named = DiagSink(directory: dir4, maxBytes: 50, now: { Date(timeIntervalSince1970: 1_792_500_000) }, console: nil,
                         name: "brighttrace", fileExtension: "jsonl")
    for _ in 0..<2 { named.write(line) }
    named.flush()
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir4.path)) ?? []).sorted()
    expect(names.count == 2 && names.allSatisfy { $0.range(of: #"^brighttrace-\d{8}T\d{6}Z(-\d+)?\.jsonl$"#, options: .regularExpression) != nil },
           "names are brighttrace-<UTC stamp>.jsonl, rotated: \(names)")
}

private func testRetention() {
    // prune: the oldest of this sink's files (modification time) go first until the rest fit; others untouched.
    let dir = tempDir("retention")
    let fm = FileManager.default
    // (file, bytes, seconds since last written)
    for (file, size, age) in [("brighttrace-20261023T000000Z.jsonl", 100, 30.0), ("brighttrace-20261023T000001Z.jsonl", 100, 20),
                              ("brighttrace-20261023T000001Z-1.jsonl", 100, 10), ("brighttrace-20261023T000002Z.jsonl", 0, 0),
                              ("diag-20261023T000000Z.log", 500, 40)] {
        let url = dir.appendingPathComponent(file)
        try? Data(count: size).write(to: url)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }
    DiagSink.prune(directory: dir, name: "brighttrace", fileExtension: "jsonl", budget: 150, keep: "brighttrace-20261023T000002Z.jsonl")
    let left = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    expectEqual(left, ["brighttrace-20261023T000001Z-1.jsonl", "brighttrace-20261023T000002Z.jsonl", "diag-20261023T000000Z.log"],
                "oldest deleted until the others fit the budget; the current file and other sinks kept")
    // A sink with a total limit: rotation keeps the whole set within it (current file at its size limit included).
    let dir2 = tempDir("retention-sink")
    let sink = DiagSink(directory: dir2, maxBytes: 50, now: { Date(timeIntervalSince1970: 1_792_500_000) }, console: nil,
                        name: "brighttrace", fileExtension: "jsonl", maxTotalBytes: 130)
    for i in 0..<8 { sink.write("line \(i) " + String(repeating: "x", count: 30)) }
    sink.flush()
    let files = ((try? fm.contentsOfDirectory(atPath: dir2.path)) ?? [])
    let total = files.reduce(0) { $0 + (((try? fm.attributesOfItem(atPath: dir2.appendingPathComponent($1).path))?[.size] as? Int) ?? 0) }
    expect(total <= 130 && files.count == 3, "total within 130 bytes: \(files.count) files, \(total) bytes")
    // Same-second rotation reuses freed names; age, not name, decides what goes.
    let kept = files.compactMap { try? String(contentsOf: dir2.appendingPathComponent($0), encoding: .utf8) }.map { String($0.prefix(6)) }.sorted()
    expectEqual(kept, ["line 5", "line 6", "line 7"], "the newest lines kept")
}

private func testConsoleSink() {
    let dir = tempDir("console")
    let lock = NSLock()
    var seen: [String] = []
    let sink = DiagSink(directory: dir, maxBytes: 1000, now: { Date() }, console: { line in lock.lock(); seen.append(line); lock.unlock() })
    sink.write("DIAG a t_ms=1")
    sink.write("DIAG b t_ms=2")
    sink.flush()
    lock.lock(); let copy = seen; lock.unlock()
    expectEqual(copy, ["DIAG a t_ms=1", "DIAG b t_ms=2"], "every line also goes to the console sink, in order")
    let text = logFiles(dir).first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    expectEqual(text, "DIAG a t_ms=1\nDIAG b t_ms=2\n", "file has the same lines")
}

private func fileText(_ dir: URL) -> [String] {
    logFiles(dir).map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
}

private func testConcurrentWrites() {
    let dir = tempDir("concurrent")
    let sink = DiagSink(directory: dir, maxBytes: 1 << 20, now: { Date() }, console: nil)
    let group = DispatchGroup()
    for t in 0..<8 {
        group.enter()
        Thread.detachNewThread {
            for i in 0..<250 { sink.write("DIAG c t_ms=0 thread=\(t) i=\(i) pad=\(String(repeating: "p", count: 40))") }
            group.leave()
        }
    }
    group.wait()
    sink.flush()
    let lines = fileText(dir).joined().split(separator: "\n").map(String.init)
    expectEqual(lines.count, 2000, "every line from 8 threads lands")
    var expected = Set<String>()
    for t in 0..<8 { for i in 0..<250 { expected.insert("DIAG c t_ms=0 thread=\(t) i=\(i) pad=\(String(repeating: "p", count: 40))") } }
    expectEqual(Set(lines), expected, "no line torn or interleaved")
}

private func testSuspensionRecovery() {
    // Simulated suspension: the open file descriptor is revoked and new opens fail until resume.
    let dir = tempDir("suspend")
    var clock = Date(timeIntervalSince1970: 1_792_500_000)
    var suspended = false
    var opened: [Int32] = []
    let consoleLock = NSLock()
    var console: [String] = []
    let sink = DiagSink(directory: dir, maxBytes: 1 << 20, now: { clock },
                        console: { line in consoleLock.lock(); console.append(line); consoleLock.unlock() },
                        opener: { path in
                            if suspended { errno = EPERM; return -1 }
                            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                            if fd >= 0 { opened.append(fd) }
                            return fd
                        })
    sink.write("a")
    sink.flush()
    suspended = true
    for fd in opened { close(fd) }
    sink.write("b")  // write fails: dropped
    sink.write("c")  // within the retry interval: dropped without a new open
    sink.flush()
    clock += 2
    sink.write("d")  // retry, open still fails: dropped
    sink.flush()
    suspended = false
    sink.write("e")  // within the retry interval of the failed retry: dropped
    sink.flush()
    clock += 2
    sink.write("f")  // resumed: reopens, reports the gap, writes
    sink.flush()
    let texts = fileText(dir)
    expectEqual(texts.count, 2, "a new file after resume")
    expectEqual(texts.first, "a\n", "first file kept what it had")
    let second = texts.count == 2 ? texts[1] : ""
    expect(second.range(of: #"^DIAG diag t_ms=\d+ file_recovered=true dropped_lines=4\nf\n$"#, options: .regularExpression) != nil,
           "recovery line counts the 4 dropped lines, then the line: \(second)")
    consoleLock.lock(); let seen = console; consoleLock.unlock()
    expectEqual(seen, ["a", "b", "c", "d", "e", "f"], "the console sink never stops")

    // A failure to create the directory is also retried, not permanent.
    let blocked = tempDir("blocked")
    let target = blocked.appendingPathComponent("diag")
    close(open(target.path, O_WRONLY | O_CREAT, 0o644))  // a file where the directory should be
    var t2 = Date(timeIntervalSince1970: 1_792_500_000)
    let sink2 = DiagSink(directory: target, maxBytes: 1 << 20, now: { t2 }, console: nil)
    sink2.write("x")
    sink2.flush()
    try? FileManager.default.removeItem(at: target)
    t2 += 2
    sink2.write("y")
    sink2.flush()
    let recovered = fileText(target)
    expect(recovered.count == 1 && recovered[0].hasSuffix("dropped_lines=1\ny\n"), "directory failure recovers: \(recovered)")
}

private func testOffThenOn() {
    // Off: nothing created, field closures never evaluated.
    let root = tempDir("off")
    let dir = root.appendingPathComponent("diag")
    Diag.start(enabled: false, directory: dir, console: nil)
    expect(!Diag.isOn, "off after start(enabled: false)")
    var evaluated = 0
    func cost() -> Int { evaluated += 1; return 1 }
    Diag.log("m9", ["k": cost()])
    expectEqual(evaluated, 0, "off: fields are not built")
    Diag.background { evaluated += 100 }
    expectEqual(evaluated, 0, "off: background work is never queued")
    expect(!FileManager.default.fileExists(atPath: dir.path), "off: no diag directory, no file")

    // On: directory created on start, a line lands in the file.
    let onDir = tempDir("on").appendingPathComponent("diag")
    Diag.start(enabled: true, directory: onDir, console: nil)
    expect(Diag.isOn, "on")
    Diag.log("m1", ["k": cost()])
    expectEqual(evaluated, 1, "on: fields built once")
    Diag.flush()
    let files = logFiles(onDir)
    expectEqual(files.count, 1, "one file")
    let text = (try? String(contentsOf: files.first ?? onDir, encoding: .utf8)) ?? ""
    expect(text.range(of: #"^DIAG m1 t_ms=\d+ k=1\n$"#, options: .regularExpression) != nil, "line in the file: \(text)")
    // On: background work runs on the Diag queue, off the caller's thread.
    var ranOnCaller = true
    let caller = Thread.current
    Diag.background { ranOnCaller = Thread.current == caller; evaluated += 100 }
    Diag.flush()
    expect(evaluated == 101 && !ranOnCaller, "on: background work ran on the Diag queue")
    // Started once: a second start is ignored.
    Diag.start(enabled: false, directory: onDir, console: nil)
    expect(Diag.isOn, "start is once per process")
}

private func testPercentiles() {
    expect(DiagStats.summary([]) == nil, "no samples, no summary")
    let one = DiagStats.summary([7])!
    expect(one.p50 == 7 && one.p95 == 7 && one.max == 7, "one sample")
    let hundred = DiagStats.summary((1...100).map(Double.init).reversed())!
    expect(hundred.p50 == 50 && hundred.p95 == 95 && hundred.max == 100, "nearest rank on 1..100: \(hundred)")
    let ten = DiagStats.summary([10, 1, 9, 2, 8, 3, 7, 4, 6, 5])!
    expect(ten.p50 == 5 && ten.p95 == 10 && ten.max == 10, "nearest rank on 1..10 (ceil(9.5) = 10th): \(ten)")
}

private func testSchedule() {
    // The first diagnostic frame used to compute now - Int.min and trap.
    var m5 = DiagSchedule(periodMs: 1000, fireOnFirst: true)
    expect(m5.due(nowMs: 123), "first frame samples at once")
    expect(!m5.due(nowMs: 1122), "under the period")
    expect(m5.due(nowMs: 1123), "one period later")
    expect(m5.due(nowMs: 50), "a clock that steps back samples and restarts the period")
    var big = DiagSchedule(periodMs: 5000, fireOnFirst: true)
    expect(big.due(nowMs: Int.max) && !big.due(nowMs: Int.max), "no overflow at the extremes")
    expect(big.due(nowMs: Int.min), "Int.min after Int.max: steps back, no trap")
    var m6 = DiagSchedule(periodMs: 1000, fireOnFirst: false)
    expect(!m6.due(nowMs: 0), "a window schedule only starts on its first call")
    expect(!m6.due(nowMs: 999) && m6.due(nowMs: 1000), "then fires each period")
}

private let ms: UInt64 = 1_000_000

private func testCadenceWindow() {
    let cadence = DiagCadence()
    // 10 drawables 11 ms apart, the 4th 22 ms (a dropped vsync); target 1 ms after predicted, the 10th 5 ms.
    // Source IDs actually encoded: nil = nothing drawn from video (idle, or a frame the renderer rejected).
    let sources: [UInt64?] = [nil, 1, 1, 2, nil, 3, 3, 3, 4, nil]
    var target: UInt64 = 1000 * ms
    for i in 1...10 {
        target += (i == 4 ? 22 : 11) * ms
        cadence.frame(targetNs: target, predictedNs: target - (i == 10 ? 5 : 1) * ms, sourceId: sources[i - 1], clockOffsetNs: 0)
    }
    // GPU done 5 ms before the rendering deadline but the callback arrives after the target: not a missed deadline.
    cadence.completed(gpuStartHostNs: 100 * ms, gpuEndHostNs: 104 * ms, renderingDeadlineNs: 109 * ms, targetNs: 112 * ms, callbackHostNs: 113 * ms, clockOffsetNs: 0)
    // GPU ends 1 ms after the rendering deadline, callback before the target: missed.
    cadence.completed(gpuStartHostNs: 200 * ms, gpuEndHostNs: 206 * ms, renderingDeadlineNs: 205 * ms, targetNs: 210 * ms, callbackHostNs: 207 * ms, clockOffsetNs: 0)
    // No GPU timestamps: neither missed nor a GPU sample.
    cadence.completed(gpuStartHostNs: 0, gpuEndHostNs: 0, renderingDeadlineNs: 1, targetNs: 2, callbackHostNs: 1, clockOffsetNs: 0)
    let raw = cadence.take()!
    let w = DiagCadence.window(raw, requestedHz: 90)
    expectEqual(w.frames, 10, "frames")
    expectEqual(w.fresh, 4, "encoded frames with a source ID not shown before (1, 2, 3, 4)")
    expectEqual(w.repeated, 3, "encoded frames re-showing the previous source ID")
    expectEqual(w.blank, 3, "frames with no video drawn (idle or rejected), not repeats")
    expectEqual(w.missedRenderDeadline, 1, "GPU end after the rendering deadline")
    expectEqual(w.callbackAfterTarget, 1, "completion callback after the target presentation, counted separately")
    expectEqual(w.requestedMs, 1000.0 / 90, "requested interval from the requested rate")
    expect(w.targetInterval?.p50 == 11 && w.targetInterval?.p95 == 22 && w.targetInterval?.max == 22, "drawable target interval \(String(describing: w.targetInterval))")
    expect(w.targetMinusPredicted?.p50 == 1 && w.targetMinusPredicted?.p95 == 5 && w.targetMinusPredicted?.max == 5, "target - predicted \(String(describing: w.targetMinusPredicted))")
    expectEqual(Diag.line(topic: "m6", tMs: 1000, fields: DiagCadence.fields(w)),
                "DIAG m6 t_ms=1000 requested_interval_ms=11.111 target_interval_p50_ms=11.000 target_interval_p95_ms=22.000 target_interval_max_ms=22.000 target_minus_predicted_p50_ms=1.000 target_minus_predicted_p95_ms=5.000 target_minus_predicted_max_ms=5.000 actual_presentation=unavailable frames=10 fresh=4 repeated=3 blank=3 missed_render_deadline=1 callback_after_target=1 clock_offset_ms=0.000 overflow=0",
                "m6 line: drawable targets, not actual presentation")

    cadence.recycle(raw)
    // take() empties the window; the interval continues across the boundary and the last source ID is remembered.
    cadence.frame(targetNs: target + 11 * ms, predictedNs: target + 11 * ms, sourceId: 4, clockOffsetNs: 0)
    let raw2 = cadence.take()!
    let w2 = DiagCadence.window(raw2, requestedHz: 0)
    cadence.recycle(raw2)
    expect(w2.frames == 1 && w2.targetInterval?.max == 11 && w2.missedRenderDeadline == 0, "second window: one frame, interval across the boundary")
    expectEqual(w2.repeated, 1, "source 4 again after the boundary is a repeat")
    expect(w2.requestedMs == nil, "no requested rate: nil")
    expect(Diag.line(topic: "m6", tMs: 0, fields: DiagCadence.fields(w2)).contains("requested_interval_ms=unavailable"), "unavailable requested rate")
    let empty = DiagCadence.window(cadence.take()!, requestedHz: 90)
    expect(empty.frames == 0 && empty.targetInterval == nil, "nothing since the last take")

    // GPU times over the 5 s M9 window, independent of the 1 s cadence windows.
    let gpuRaw = cadence.takeGpu()!
    let gpu = DiagStats.summary(gpuRaw.values)
    cadence.recycleGpu(gpuRaw)
    expect(gpu?.p50 == 4 && gpu?.p95 == 6, "gpu ms p50/p95 \(String(describing: gpu))")
    expect(cadence.takeGpu()!.values.isEmpty, "gpu window taken")
}

private func testCadenceClockOffset() {
    // Host (command buffer) times move to the layer clock with the offset sampled on the render thread.
    let cadence = DiagCadence()
    cadence.frame(targetNs: 200 * ms, predictedNs: 200 * ms, sourceId: 1, clockOffsetNs: Int64(100 * ms))
    // A later submission changes the current offset before the first completes.
    cadence.frame(targetNs: 210 * ms, predictedNs: 210 * ms, sourceId: 2, clockOffsetNs: -Int64(100 * ms))
    cadence.completed(gpuStartHostNs: 40 * ms, gpuEndHostNs: 50 * ms, renderingDeadlineNs: 120 * ms, targetNs: 200 * ms, callbackHostNs: 60 * ms, clockOffsetNs: Int64(100 * ms))
    let w = DiagCadence.window(cadence.take()!, requestedHz: 90)
    expectEqual(w.missedRenderDeadline, 1, "host 50 ms + offset 100 ms is past the 120 ms deadline")
    expectEqual(w.callbackAfterTarget, 0, "host 60 ms + 100 ms is before the 200 ms target")
    expectEqual(w.clockOffsetMs, -100, "latest submission offset logged, completion retains its own")
    let negative = DiagCadence()
    negative.frame(targetNs: 10 * ms, predictedNs: 10 * ms, sourceId: nil, clockOffsetNs: -Int64(100 * ms))
    negative.completed(gpuStartHostNs: 140 * ms, gpuEndHostNs: 150 * ms, renderingDeadlineNs: 60 * ms, targetNs: 70 * ms, callbackHostNs: 160 * ms, clockOffsetNs: -Int64(100 * ms))
    let wn = DiagCadence.window(negative.take()!, requestedHz: 90)
    expect(wn.missedRenderDeadline == 0 && wn.callbackAfterTarget == 0, "negative offset: 50 ms and 60 ms on the layer clock are in time")
}

private func testCadenceBounded() {
    // Fixed capacity: the render thread only appends; past capacity samples are dropped and counted.
    let cadence = DiagCadence(capacity: 4)
    for i in 1...10 {
        cadence.frame(targetNs: UInt64(i) * 11 * ms, predictedNs: UInt64(i) * 11 * ms, sourceId: UInt64(i), clockOffsetNs: 0)
        cadence.completed(gpuStartHostNs: 1, gpuEndHostNs: 2 + UInt64(i), renderingDeadlineNs: UInt64.max, targetNs: UInt64.max, callbackHostNs: 1, clockOffsetNs: 0)
    }
    let raw = cadence.take()!
    expect(raw.targetIntervalsMs.count == 4 && raw.targetMinusPredictedMs.count == 4, "sample buffers stop at capacity")
    expect(raw.targetIntervalsMs.capacity >= 4, "buffers are preallocated")
    expectEqual(raw.frames, 10, "counts stay exact")
    expectEqual(raw.fresh, 10, "fresh stays exact")
    expectEqual(raw.overflow, (9 - 4) + (10 - 4), "dropped samples counted")
    expectEqual(cadence.takeGpu()!.values.count, 4, "gpu buffer bounded too")
}


private func testBufferReuse() {
    let cadence = DiagCadence(capacity: 4)
    var addresses = Set<UInt>()
    var gpuAddresses = Set<UInt>()
    var capacities = Set<Int>()
    for i in 0..<1000 {
        cadence.frame(targetNs: UInt64(i + 1) * ms, predictedNs: UInt64(i) * ms, sourceId: nil, clockOffsetNs: 0)
        cadence.completed(gpuStartHostNs: 1, gpuEndHostNs: 2, renderingDeadlineNs: 3, targetNs: 4, callbackHostNs: 3, clockOffsetNs: 0)
        let raw = cadence.take()!, gpu = cadence.takeGpu()!
        _ = raw.targetMinusPredictedMs.withUnsafeBufferPointer { addresses.insert(UInt(bitPattern: $0.baseAddress!)) }
        _ = gpu.values.withUnsafeBufferPointer { gpuAddresses.insert(UInt(bitPattern: $0.baseAddress!)) }
        capacities.insert(raw.targetMinusPredictedMs.capacity)
        expect(cadence.take() == nil && cadence.takeGpu() == nil, "busy consumer never allocates replacement storage")
        cadence.recycle(raw); cadence.recycleGpu(gpu)
    }
    expectEqual(addresses.count, 2, "exactly two preallocated cadence buffers over 1000 periods")
    expectEqual(gpuAddresses.count, 2, "exactly two preallocated GPU buffers over 1000 periods")
    expectEqual(capacities.count, 1, "no capacity changes")
    var reads = 0
    func read() -> Int { reads += 1; return 42 }
    expect(Diag.capture(enabled: false, read()) == nil, "off deadline/source capture is nil")
    expectEqual(reads, 0, "off path calls neither diagnostic reader")
    expectEqual(Diag.capture(enabled: true, read()), 42, "on path captures input")
    expectEqual(reads, 1, "on path reads once")
}

private func testDrawableSnapshotReuse() {
    let snapshots = DiagDoubleBuffer(DiagDrawableSnapshot<Int, Int>(), DiagDrawableSnapshot<Int, Int>())
    var viewAddresses = Set<UInt>(), mapAddresses = Set<UInt>(), capacities = Set<Int>()
    for _ in 0..<1000 {
        let snapshot = snapshots.take()!
        expect(snapshot.views.isEmpty && snapshot.maps.isEmpty, "returned drawable snapshot is reset")
        for i in 0..<32 { snapshot.views.append(i) }
        for i in 0..<64 { snapshot.maps.append(i) }
        _ = snapshot.views.withUnsafeBufferPointer { viewAddresses.insert(UInt(bitPattern: $0.baseAddress!)) }
        _ = snapshot.maps.withUnsafeBufferPointer { mapAddresses.insert(UInt(bitPattern: $0.baseAddress!)) }
        capacities.insert(snapshot.views.capacity)
        expect(snapshots.take() == nil, "busy drawable consumer does not allocate a replacement")
        snapshots.recycle(snapshot) { $0.reset() }
    }
    expectEqual(viewAddresses.count, 2, "exactly two preallocated view buffers")
    expectEqual(mapAddresses.count, 2, "exactly two preallocated map buffers")
    expectEqual(capacities.count, 1, "drawable snapshot capacity never changes")
}

private func testThermalNames() {
    expectEqual(Diag.thermalName(.nominal), "nominal", "nominal")
    expectEqual(Diag.thermalName(.fair), "fair", "fair")
    expectEqual(Diag.thermalName(.serious), "serious", "serious")
    expectEqual(Diag.thermalName(.critical), "critical", "critical")
    expectEqual(Diag.thermalName(ProcessInfo.ThermalState(rawValue: 42)!), "unknown_42", "unknown raw values are kept")
}

@main
enum DiagTests {
    static func main() {
        testLineFormat()
        testEnabled()
        testRotation()
        testRetention()
        testConsoleSink()
        testConcurrentWrites()
        testSuspensionRecovery()
        testOffThenOn()
        testPercentiles()
        testSchedule()
        testCadenceWindow()
        testCadenceClockOffset()
        testCadenceBounded()
        testBufferReuse()
        testDrawableSnapshotReuse()
        testThermalNames()
        finishTests("Diag")
    }
}
