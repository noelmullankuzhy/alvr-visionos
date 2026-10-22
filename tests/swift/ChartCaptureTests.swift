// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift ALVRClient/Diagnostics/ResolutionChart.swift
import Foundation

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
// Device values (diag-20261021T135020Z.log): quality 1.0 logical screen, 40 logical px/deg on axis.
private let leftEye = CornerTangents(left: 1.7321, right: 1, bottom: 1.1918, top: 1)
private let rightEye = CornerTangents(left: 1, right: 1.7321, bottom: 1.1918, top: 1)
private let w = 6261.0, h = 5023.0
private func deg(_ r: Double) -> Double { r * 180 / Double.pi }

private func testSetting() {
    expectEqual(ResolutionChartSetting.choices, ["Off", "Both eyes", "Left only", "Right only", "Auto capture"], "picker values")
    expect(ResolutionChartSetting.isAuto("Auto capture") && !ResolutionChartSetting.isAuto("Both eyes"), "auto setting")
    expectEqual(ResolutionChartSetting.mode("Auto capture"), .both, "auto capture lights both eyes")
    expectEqual(ResolutionChartSetting.mode("Left only"), .left, "manual modes unchanged")
    expectEqual(ResolutionChartSetting.mode("nonsense"), .off, "unknown: off")
    expect(GratingChart.foveationDisabled(diagnostics: true, chart: "Auto capture", foveation: false, entry: .diagnostics, connected: false),
           "auto capture may drop foveation like the manual walk")
    expect(!GratingChart.foveationDisabled(diagnostics: true, chart: "Auto capture", foveation: false, entry: .stream, connected: false),
           "never in a streaming space")
}

private func testRectMapping() {
    let v8 = GratingChart.patches.first { $0.position == .axis && $0.cpd == 8 && $0.orientation == .vertical }!
    let t26 = GratingChart.patches.first { $0.position == .temporal20 && $0.cpd == 20 && $0.orientation == .horizontal }!
    for (eye, t) in [(CornerEye.left, leftEye), (.right, rightEye)] {
        // Logical rect: the patch's NDC quad in Metal pixels (origin top left, y down); the axis patch is centred 1 deg up.
        let r = ChartCapture.logicalRect(t, width: w, height: h, eye: eye, patch: v8)
        let a = RateMapSampling.axis(t, width: w, height: h), k = RateMapSampling.pxPerTan(t, width: w, height: h)
        expect(near((r.x0 + r.x1) / 2, a.x, 0.5), "\(eye) axis patch centred on the axis x \(r)")
        expect(near((r.y0 + r.y1) / 2, a.y - tan(1 * Double.pi / 180) * k.y, 0.5), "\(eye) 1 deg up (smaller y) \(r)")
        expect(near(r.x1 - r.x0, 2 * tan(0.75 * Double.pi / 180) * k.x, 0.01), "\(eye) 1.5 deg wide: 60 logical px \(r.x1 - r.x0)")
        expect(r.y1 > r.y0 && r.x1 > r.x0, "ordered")
        // Temporal: screen left for L, right for R.
        let tr = ChartCapture.logicalRect(t, width: w, height: h, eye: eye, patch: t26)
        expect(eye == .left ? tr.x1 < a.x : tr.x0 > a.x, "\(eye) temporal side")
        expect(near(deg(atan(((tr.x0 + tr.x1) / 2 - a.x) / k.x)), eye == .left ? -26 : 26, 0.05), "\(eye) 26 deg temporal")
    }
    // Synthetic separable rate map: x halves left of 3000 logical px and is 1:1 right of it; y at 0.4.
    let map: RateMapSampling.Mapping = { x, y in (x < 3000 ? 0.5 * x : 1500 + (x - 3000), 0.4 * y) }
    let lr = ChartCapture.logicalRect(leftEye, width: w, height: h, eye: .left, patch: v8)
    let pr = ChartCapture.physicalRect(lr, map: map)
    expect(lr.x0 > 3000 && near(pr.x0, 1500 + lr.x0 - 3000) && near(pr.x1, 1500 + lr.x1 - 3000), "x through the map \(pr)")
    expect(near(pr.y0, 0.4 * lr.y0) && near(pr.y1, 0.4 * lr.y1), "y through the map")
    expectEqual(ChartCapture.physicalRect(lr, map: nil), lr, "no rate map: physical = logical")
    // Physical Nyquist: logical Nyquist x the map's rate across the bars (V: x, H: y).
    let nl = GratingChart.nyquistLogical(leftEye, width: w, height: h, eye: .left, patch: v8)
    expect(near(ChartCapture.nyquistPhysical(leftEye, width: w, height: h, eye: .left, patch: v8, map: map)!, nl, 1e-6), "V: x rate 1")
    let h8 = GratingChart.patches.first { $0.position == .axis && $0.cpd == 8 && $0.orientation == .horizontal }!
    let nh = GratingChart.nyquistLogical(leftEye, width: w, height: h, eye: .left, patch: h8)
    expect(near(ChartCapture.nyquistPhysical(leftEye, width: w, height: h, eye: .left, patch: h8, map: map)!, 0.4 * nh, 1e-6), "H: y rate 0.4")
}

private func view(_ eye: CornerEye, map: RateMapSampling.Mapping?) -> ChartCapture.View {
    ChartCapture.View(eye: eye, view: eye == .left ? 0 : 1, slice: eye == .left ? 0 : 1, textureIndex: 0,
                      tangents: eye == .left ? leftEye : rightEye, viewport: [0, 0, w, h], screen: [6261, 5023], physical: [2432, 2368],
                      map: map)
}

private func testMetadata() {
    let map: RateMapSampling.Mapping = { x, y in (0.4 * x, 0.45 * y) }
    let meta = ChartCapture.metadata(views: [view(.left, map: map), view(.right, map: nil)], requested: 0.75, actual: 0.75,
                                     confirmed: true, foveation: true, frames: 31, settle: "rate_map", expectedScreen: [5479, 4395])
    expect(JSONSerialization.isValidJSONObject(meta), "capture.json serialisable")
    expectEqual(Set(meta.keys), ["mode", "rq", "rq_set", "rq_confirmed", "fov", "settle_frames", "settle", "expected_screen", "patch_deg",
                                 "views"], "chart_capture keys")
    expectEqual(meta["settle"] as? String, "rate_map", "settle reason")
    expectEqual(meta["expected_screen"] as? [Int], [5479, 4395], "expected screen")
    expectEqual(meta["rq"] as? String, "0.750", "rq read back")
    expectEqual(meta["fov"] as? String, "on", "fov")
    let views = meta["views"] as! [[String: Any]]
    expectEqual(views.count, 2, "one entry per eye")
    let l = views[0]
    expectEqual(Set(l.keys), ["eye", "view", "slice", "texture_index", "tangents", "viewport", "screen", "physical", "mapped", "patches"],
                "view keys")
    expectEqual(l["eye"] as? String, "L", "eye")
    expectEqual(l["screen"] as? [Int], [6261, 5023], "screen size")
    expectEqual(l["physical"] as? [Int], [2432, 2368], "physical size")
    let patches = l["patches"] as! [[String: Any]]
    expectEqual(patches.count, 24, "every patch")
    let p = patches[0]
    expectEqual(Set(p.keys), ["position", "cpd", "orientation", "temporal_deg", "up_deg", "logical_rect", "physical_rect",
                              "nyquist_logical_cpd", "nyquist_physical_cpd", "expected_bars"], "patch keys")
    expectEqual(p["position"] as? String, "axis", "position")
    expectEqual(p["cpd"] as? Int, 8, "cpd")
    expectEqual(p["orientation"] as? String, "V", "orientation")
    expectEqual(p["expected_bars"] as? Int, 12, "ceil(1.5 x 8)")
    let lr = p["logical_rect"] as! [Double], pr = p["physical_rect"] as! [Double]
    expect(lr.count == 4 && pr.count == 4 && near(pr[0], 0.4 * lr[0], 1e-9) && near(pr[3], 0.45 * lr[3], 1e-9), "rects \(lr) \(pr)")
    expectEqual(patches.map { $0["expected_bars"] as! Int }.prefix(6).map { $0 }, [12, 15, 18, 21, 26, 30], "expected counts")
    expect(near(p["nyquist_physical_cpd"] as! Double, 0.4 * (p["nyquist_logical_cpd"] as! Double), 1e-9), "physical Nyquist")
    expectEqual((views[1]["mapped"] as? Bool), false, "right view without a map")
    let unconfirmed = ChartCapture.metadata(views: [], requested: 0.5, actual: nil, confirmed: false, foveation: false, frames: 600)
    expect(unconfirmed["rq"] as? String == "unavailable" && unconfirmed["fov"] as? String == "off"
           && unconfirmed["rq_confirmed"] as? Bool == false, "no read back")
    expect(unconfirmed["settle"] as? String == "none" && unconfirmed["expected_screen"] is NSNull, "defaults")
    let line = Diag.line(topic: "chartcap", tMs: 5, fields: ChartCapture.fields(eye: .left, requested: 0.5, actual: 0.5, confirmed: true,
                                                                               foveation: true, dir: "chart-x", slice: 0, physical: [1952, 1888],
                                                                               screen: [4696, 3767], expectedScreen: [4696, 3767], settle: "rate_map"))
    expectEqual(line, "DIAG chartcap t_ms=5 eye=L rq=0.500 rq_set=0.500 confirmed=yes fov=on dir=chart-x slice=0 screen=4696x3767 "
                + "physical=1952x1888 expected_screen=4696x3767 settle=rate_map patches=24", "chartcap line with the settled sizes")
    let bare = Diag.line(topic: "chartcap", tMs: 5, fields: ChartCapture.fields(eye: .right, requested: 0.5, actual: nil, confirmed: false,
                                                                               foveation: false, dir: "d", slice: 1, physical: [8, 8]))
    expect(bare.hasSuffix("screen=none physical=8x8 expected_screen=none settle=none patches=24"), "no sizes: none \(bare)")
    expectEqual(ChartCapture.directoryName(stamp: "20261022T101010Z", quality: 0.75, foveation: true), "chart-20261022T101010Z-rq0.75-fovon", "dir")
}

private func testAutoSession() {
    let s = AutoCaptureSession(restore: 0.75)
    expectEqual(s.frame(actual: 1.0, max: 1.0), .setQuality(0.5), "first step sets 0.5")
    for _ in 0..<5 { expect(s.frame(actual: 1.0, max: 1.0) == nil, "waits for the read-back") }
    for i in 0..<30 {
        let step = s.frame(actual: 0.5, max: 1.0)
        expect(i < 29 ? step == nil : step == .capture(quality: 0.5, confirmed: true, frames: 35), "30 confirmed frames, then capture \(i) \(String(describing: step))")
    }
    expect(s.frame(actual: 0.5, max: 1.0) == nil, "one capture in flight")
    s.captured(ok: true)
    expectEqual(s.frame(actual: 0.5, max: 1.0), .setQuality(0.75), "next quality")
    // Clamped to the layer's maximum: 1.0 with max 0.8 is confirmed at 0.8.
    for _ in 0..<30 { _ = s.frame(actual: 0.75, max: 0.8) }
    s.captured(ok: true)
    expectEqual(s.frame(actual: 0.75, max: 0.8), .setQuality(1.0), "last quality")
    var step: AutoCaptureSession.Step?
    for _ in 0..<30 { step = s.frame(actual: 0.8, max: 0.8) }
    expectEqual(step, .capture(quality: 1.0, confirmed: true, frames: 30), "clamped quality confirmed")
    s.captured(ok: true)
    expectEqual(s.frame(actual: 0.8, max: 0.8), .done(restore: 0.75), "done after three, restoring the entry quality")
    expect(s.frame(actual: 0.8, max: 0.8) == nil && s.finished && s.captures == 3 && s.failures == 0, "finished")
    // No read-back (non-26 SDK): capture unconfirmed after the timeout.
    let n = AutoCaptureSession(restore: nil)
    _ = n.frame(actual: nil, max: nil)
    var last: AutoCaptureSession.Step?
    for _ in 0..<AutoCaptureSession.timeoutFrames { last = n.frame(actual: nil, max: nil) ?? last }
    expectEqual(last, .capture(quality: 0.5, confirmed: false, frames: AutoCaptureSession.timeoutFrames), "timeout capture")
    expectEqual(AutoCaptureSession(restore: nil).statusText, "0.50", "status shows the quality")
}

// Walk q through set -> 30 confirmed frames -> capture; returns the capture step.
private func toCapture(_ s: AutoCaptureSession, _ q: Float) -> AutoCaptureSession.Step? {
    expectEqual(s.frame(actual: 1.0, max: 1.0), .setQuality(q), "set \(q)")
    var step: AutoCaptureSession.Step?
    for _ in 0..<30 { step = s.frame(actual: q, max: 1.0) }
    return step
}

private func testAutoSessionFailuresAndRetry() {
    // A nil encoder (or a failed write) on step 2 counts as a failed capture; the walk continues, reaches done and restores.
    let s = AutoCaptureSession(restore: 0.9)
    expectEqual(toCapture(s, 0.5), .capture(quality: 0.5, confirmed: true, frames: 30), "step 1")
    s.captured(ok: true)
    expectEqual(toCapture(s, 0.75), .capture(quality: 0.75, confirmed: true, frames: 30), "step 2")
    s.captured(ok: false)
    expectEqual(toCapture(s, 1.0), .capture(quality: 1.0, confirmed: true, frames: 30), "step 3 after the failure")
    s.captured(ok: true)
    expectEqual(s.frame(actual: 1.0, max: 1.0), .done(restore: 0.9), "done restores the entry quality")
    expect(s.captures == 2 && s.failures == 1, "two written, one failed")
    // Readback slot busy: the capture is deferred and offered again on the next frame, nothing counted.
    let r = AutoCaptureSession(restore: nil)
    _ = toCapture(r, 0.5)
    r.deferCapture()
    expectEqual(r.frame(actual: 0.5, max: 1.0), .capture(quality: 0.5, confirmed: true, frames: 31), "retried next frame")
    expect(r.captures == 0 && r.failures == 0, "a deferral is not a capture")
    // Every quality failing still ends in done with the restore.
    let f = AutoCaptureSession(restore: 0.5)
    for q in GratingChart.qualities { _ = toCapture(f, q); f.captured(ok: false) }
    expectEqual(f.frame(actual: 1.0, max: 1.0), .done(restore: 0.5), "all failed: still done and restored")
}

// The 22 Oct device run (diag-20261022T085526Z.log): the quality read-back echoes the setter at once while visionOS animates
// the rate map over many frames; settled screens 6261x5023 (1.0), 5479x4395 (0.75), 4696x3767 (0.5).
private func testRateMapSettle() {
    expectEqual(AutoCaptureSession.expectedScreen(quality: 0.5, reference: [6261, 5023], referenceQuality: 1.0), [4696, 3767], "0.5 from 1.0")
    expectEqual(AutoCaptureSession.expectedScreen(quality: 0.75, reference: [6261, 5023], referenceQuality: 1.0), [5478, 4395], "0.75 from 1.0")
    expectEqual(AutoCaptureSession.expectedScreen(quality: 0.5, reference: [5479, 4395], referenceQuality: 0.75), [4696, 3767], "0.5 from 0.75")
    expect(AutoCaptureSession.matches([5479, 4395], [5478, 4395]) && AutoCaptureSession.matches([4740, 3802], [4696, 3767]),
           "within 1 %")
    expect(!AutoCaptureSession.matches([4750, 3767], [4696, 3767]) && !AutoCaptureSession.matches([4696], [4696, 3767]), "outside 1 %")

    let s = AutoCaptureSession(restore: 1.0, reference: [6261, 5023])
    expectEqual(s.frame(actual: 1.0, max: 1.0, screen: [6261, 5023]), .setQuality(0.5), "set 0.5")
    expectEqual(s.expectedScreen, [4696, 3767], "expected for the step")
    // The device sequence: the property reads 0.5 at once, the map shrinks 6220x4990 ... 5321x4269. The old rule captured
    // here (30 frames of rq=0.500, physical 2176x2080); the map rule waits.
    var w = 6220, h = 4990
    while w > 5321 {
        expect(s.frame(actual: 0.5, max: 1.0, screen: [w, h]) == nil, "animating \(w)x\(h): no capture")
        w -= 12; h -= 10
    }
    for _ in 0..<40 { expect(s.frame(actual: 0.5, max: 1.0, screen: [4800, 3850]) == nil, "2 % off: no capture") }
    for _ in 0..<29 { expect(s.frame(actual: 0.5, max: 1.0, screen: [4700, 3770]) == nil, "in band, under 30 frames") }
    expect(s.frame(actual: 0.5, max: 1.0, screen: [4800, 3850]) == nil, "out of band again: the count restarts")
    for i in 0..<30 {
        let step = s.frame(actual: 0.5, max: 1.0, screen: [4696, 3767])
        if i < 29 { expect(step == nil, "settling \(i)") } else {
            if case .capture(0.5, true, _)? = step {} else { expect(false, "30 consecutive matching frames: capture \(String(describing: step))") }
        }
    }
    expectEqual(s.settle, "rate_map", "confirmed by the map")
    s.captured(ok: true)
    // The read-back alone never confirms in map mode: wrong property, right map still captures.
    expectEqual(s.frame(actual: 0.5, max: 1.0, screen: [4696, 3767]), .setQuality(0.75), "set 0.75")
    var step: AutoCaptureSession.Step?
    for _ in 0..<30 { step = s.frame(actual: 0.5, max: 1.0, screen: [5479, 4395]) }
    if case .capture(0.75, true, 30)? = step {} else { expect(false, "map settled at 0.75 \(String(describing: step))") }
    s.captured(ok: true)
    // Clamped by the layer maximum: 1.0 with max 0.8 settles at the 0.8 size (6261 x 0.9).
    _ = s.frame(actual: 0.75, max: 0.8, screen: [5479, 4395])
    expectEqual(s.expectedScreen, [5635, 4521], "clamped target size")
    for _ in 0..<30 { step = s.frame(actual: 0.8, max: 0.8, screen: [5635, 4521]) }
    if case .capture(1.0, true, 30)? = step {} else { expect(false, "clamped size confirmed") }
    s.captured(ok: true)
    expectEqual(s.frame(actual: 0.8, max: 0.8, screen: [5635, 4521]), .done(restore: 1.0), "done")

    // A map that never settles: unconfirmed capture at the timeout.
    let t = AutoCaptureSession(restore: 1.0, reference: [6261, 5023])
    _ = t.frame(actual: 1.0, max: 1.0, screen: [6261, 5023])
    var last: AutoCaptureSession.Step?
    for _ in 0..<AutoCaptureSession.timeoutFrames { last = t.frame(actual: 0.5, max: 1.0, screen: [5321, 4269]) ?? last }
    expectEqual(last, .capture(quality: 0.5, confirmed: false, frames: AutoCaptureSession.timeoutFrames), "timeout")
    expectEqual(t.settle, "timeout", "settle reason")
    // No map on a frame (nil screen) never counts in map mode.
    let n = AutoCaptureSession(restore: 1.0, reference: [6261, 5023])
    _ = n.frame(actual: 1.0, max: 1.0, screen: nil)
    for _ in 0..<40 { expect(n.frame(actual: 0.5, max: 1.0, screen: nil) == nil, "no map: no confirmation") }
    // Without a reference (no map at the start) the read-back confirms, as before.
    let p = AutoCaptureSession(restore: 1.0)
    _ = p.frame(actual: 1.0, max: 1.0)
    for _ in 0..<30 { step = p.frame(actual: 0.5, max: 1.0, screen: [5321, 4269]) }
    if case .capture(0.5, true, 30)? = step {} else { expect(false, "property fallback") }
    expectEqual(p.settle, "render_quality", "fallback reason")
}

private func testReadbackSlot() {
    let slot = DiagReadbackSlot()
    let requests = DiagCaptureRequests(acceptsMarks: true)
    let gate = DiagCaptureGate(requests: requests, slot: slot)
    _ = gate.next(nowMs: 0, idle: true, streamFrame: false)   // first idle frame starts the 3 s timer
    expect(slot.holder == nil, "no request: the gate does not keep the slot")
    expect(slot.acquire("chartcap") && slot.holder == "chartcap", "free slot taken")
    expect(!slot.acquire("frame_capture"), "one readback in flight")
    // The frame-capture gate waits (request kept pending, not consumed) while the chart capture holds the slot.
    if case .waiting(let why) = gate.next(nowMs: 3000, idle: true, streamFrame: false) {
        expectEqual(why, "readback_in_flight", "waits for the chart capture")
    } else { expect(false, "gate must wait while the slot is held") }
    slot.release("chartcap")
    if case .request(let r) = gate.next(nowMs: 3100, idle: true, streamFrame: false) {
        expect(r.reason == "start_timer" && r.number == 1, "pending request taken after release")
    } else { expect(false, "request after release") }
    expect(slot.holder == "frame_capture", "the gate holds the slot for its capture")
    expect(!slot.acquire("chartcap"), "chart capture deferred while the frame capture is in flight")
    gate.finished()
    expect(slot.holder == nil && slot.acquire("chartcap"), "released when the frame capture finishes")
    slot.release("frame_capture")
    expect(slot.holder == "chartcap", "release by a non-holder is ignored")
    // Chart capture in flight and no frame-capture request: nothing to wait for (no waiting line), slot untouched.
    let quiet = DiagReadbackSlot()
    let idleGate = DiagCaptureGate(requests: DiagCaptureRequests(acceptsMarks: true), slot: quiet)
    expect(quiet.acquire("chartcap"), "chart capture holds the slot")
    if case .none = idleGate.next(nowMs: 0, idle: true, streamFrame: false) {} else { expect(false, "no request: .none, not waiting") }
    if case .none = idleGate.next(nowMs: 2999, idle: true, streamFrame: false) {} else { expect(false, "still no request before 3 s") }
    if case .none = idleGate.next(nowMs: 100, idle: false, streamFrame: true) {} else { expect(false, "stream frame, no request: .none") }
    expect(quiet.holder == "chartcap", "the gate never touched the chart's slot")
    // A streaming request with no stream frame still reports no_stream_frame, slot held or not.
    let streaming = DiagCaptureRequests(acceptsMarks: true)
    streaming.requestStreaming()
    if case .waiting(let why) = DiagCaptureGate(requests: streaming, slot: quiet).next(nowMs: 0, idle: false, streamFrame: false) {
        expectEqual(why, "no_stream_frame", "streaming request waits for a stream frame")
    } else { expect(false, "no_stream_frame wait") }
    // The same request on a stream frame while the chart holds the slot: readback_in_flight, request kept.
    let streamGate = DiagCaptureGate(requests: streaming, slot: quiet)
    if case .waiting(let why) = streamGate.next(nowMs: 0, idle: false, streamFrame: true) {
        expectEqual(why, "readback_in_flight", "real request waits for the chart capture")
    } else { expect(false, "stream request waits on the slot") }
    expect(streaming.streamingPending, "request kept pending")
    quiet.release("chartcap")
    if case .request(let r) = streamGate.next(nowMs: 11, idle: false, streamFrame: true) {
        expectEqual(r.reason, "request_file", "taken once the slot is free")
    } else { expect(false, "stream request taken after release") }
    // Without a slot the gate behaves as before.
    let plain = DiagCaptureGate(requests: DiagCaptureRequests(acceptsMarks: true))
    _ = plain.next(nowMs: 0, idle: true, streamFrame: false)
    if case .request = plain.next(nowMs: 3000, idle: true, streamFrame: false) {} else { expect(false, "no slot: unchanged") }
}

private func testGeometryWithoutHighlight() {
    let session = GratingSession(mode: .both)
    let framed = GratingChart.geometry(leftEye, eye: .left, session: session, fixation: nil)
    let plain = GratingChart.geometry(leftEye, eye: .left, session: session, fixation: nil, highlight: false, status: "0.50")
    let frame = GratingChart.frame(GratingChart.patches[0]).count
    let statusDiff = CornerChart.text(session.statusText, in: CornerChart.Rect(x0: 0, y0: 0, x1: 1, y1: 1), vertical: false, color: [1, 1, 1, 1]).count
        - CornerChart.text("0.50", in: CornerChart.Rect(x0: 0, y0: 0, x1: 1, y1: 1), vertical: false, color: [1, 1, 1, 1]).count
    expectEqual(framed.count - plain.count, frame + statusDiff, "no yellow frame, custom status")
}

@main enum ChartCaptureTests {
    static func main() {
        testSetting()
        testRectMapping()
        testMetadata()
        testAutoSession()
        testAutoSessionFailuresAndRetry()
        testRateMapSettle()
        testReadbackSlot()
        testGeometryWithoutHighlight()
        finishTests("ChartCapture")
    }
}
