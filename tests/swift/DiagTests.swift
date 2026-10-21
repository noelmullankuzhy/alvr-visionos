// SOURCES: ALVRClient/Diagnostics/Diag.swift
// Diagnostics core (GM decision 65): the DIAG line format and key/value escaping, the file sink's rotation at its size
// limit, off = no file and no work, the per-second cadence and GPU aggregation (nearest-rank p50/p95) and the thermal
// state names.
import Foundation

private func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-tests-\(name)-\(UUID().uuidString)")
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
    let text = (try? String(contentsOf: logFiles(dir)[0], encoding: .utf8)) ?? ""
    expectEqual(text, "DIAG a t_ms=1\nDIAG b t_ms=2\n", "file has the same lines")
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

private func testCadenceWindow() {
    let ms: UInt64 = 1_000_000
    let cadence = DiagCadence()
    expect(cadence.drain(nowMs: 0, requestedHz: 90) == nil, "first call only starts the window")
    // 10 frames 11 ms apart, the 4th 22 ms (a dropped vsync); drawable 1 ms later than predicted, frame 10 is 5 ms later.
    var present: UInt64 = 1000 * ms
    for i in 1...10 {
        present += (i == 4 ? 22 : 11) * ms
        cadence.frame(presentNs: present, predictedNs: present - (i == 10 ? 5 : 1) * ms, fresh: i % 3 != 0)
    }
    cadence.completed(gpuNs: 4 * ms, late: false)
    cadence.completed(gpuNs: 6 * ms, late: true)
    expect(cadence.drain(nowMs: 999, requestedHz: 90) == nil, "under one second: nothing yet")
    guard let w = cadence.drain(nowMs: 1000, requestedHz: 90) else { expect(false, "window after one second"); return }
    expectEqual(w.frames, 10, "frames")
    expectEqual(w.fresh, 7, "frames with a new decoded video frame (i % 3 != 0)")
    expectEqual(w.repeated, 3, "repeats")
    expectEqual(w.missed, 1, "GPU completions after the presentation time")
    expectEqual(w.requestedMs, 1000.0 / 90, "requested interval from the requested rate")
    // Intervals: 9 deltas (the first frame has no predecessor): eight of 11 ms, one of 22 ms.
    expect(w.interval?.p50 == 11 && w.interval?.p95 == 22 && w.interval?.max == 22, "achieved interval \(String(describing: w.interval))")
    expect(w.presentDelta?.p50 == 1 && w.presentDelta?.p95 == 5 && w.presentDelta?.max == 5, "drawable - predicted \(String(describing: w.presentDelta))")
    let fields = DiagCadence.fields(w)
    expectEqual(Diag.line(topic: "m6", tMs: 1000, fields: fields),
                "DIAG m6 t_ms=1000 requested_ms=11.111 interval_p50_ms=11.000 interval_p95_ms=22.000 interval_max_ms=22.000 present_delta_p50_ms=1.000 present_delta_p95_ms=5.000 present_delta_max_ms=5.000 frames=10 fresh=7 repeated=3 missed=1",
                "m6 line")
    // Next window starts empty; the interval continues from the last frame of the previous one.
    cadence.frame(presentNs: present + 11 * ms, predictedNs: present + 11 * ms, fresh: true)
    let w2 = cadence.drain(nowMs: 2000, requestedHz: 0)
    expect(w2?.frames == 1 && w2?.interval?.max == 11 && w2?.missed == 0, "second window: one frame, interval across the boundary")
    expect(w2?.requestedMs == nil, "no requested rate: nil, logged unavailable")
    expect(Diag.line(topic: "m6", tMs: 0, fields: DiagCadence.fields(w2!)).contains("requested_ms=unavailable"), "unavailable requested rate")

    // GPU times over the 5 s M9 window, independent of the 1 s cadence windows.
    let gpu = cadence.drainGpu()
    expect(gpu?.p50 == 4 && gpu?.p95 == 6, "gpu ms p50/p95 \(String(describing: gpu))")
    expect(cadence.drainGpu() == nil, "gpu window drained")
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
        testConsoleSink()
        testOffThenOn()
        testPercentiles()
        testCadenceWindow()
        testThermalNames()
        finishTests("Diag")
    }
}
