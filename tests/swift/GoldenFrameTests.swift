// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift ALVRClient/Diagnostics/ResolutionChart.swift ALVRClient/Diagnostics/GoldenFrame.swift ALVRClient/StreamReprojection.swift ALVRClient/ColourPipeline.swift
import Foundation
import CoreVideo
import simd

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
// Device frustum (tools/fov-matrix/avp-field.json, golden-frame.py render): L left 1.7321, right 1, bottom 1.1918, top 1.
private let leftEye = CornerTangents(left: 1.7321, right: 1, bottom: 1.1918, top: 1)
private let rightEye = CornerTangents(left: 1, right: 1.7321, bottom: 1.1918, top: 1)

private func lrbt(_ t: CornerTangents) -> [Double] { [t.left, t.right, t.bottom, t.top] }
private func ndc(_ t: CornerTangents, _ x: Double, _ y: Double) -> [Double] { let n = t.ndc(x: x, y: y); return [n.x, n.y] }

// A set as golden-frame.py render + encode --point a100-axis-C writes it (keys and values of a real meta.json; lens
// outline cut to two points per eye). The PNGs are placeholder bytes: the client hashes the files as stored.
private let serverBytes: [String: Data] = ["L.server.png": Data("left server".utf8), "R.server.png": Data("right server".utf8),
                                           "L.png": Data("left golden".utf8), "R.png": Data("right golden".utf8)]

private func metaObject() -> [String: Any] {
    let files = serverBytes.mapValues { ["sha256": GoldenMeta.sha256Hex($0), "bytes": $0.count] as [String: Any] }
    func lens(_ t: CornerTangents, _ points: [(Double, Double)]) -> [String: Any] {
        ["polygon": points.enumerated().map { i, p in
            ["ray_deg": i * 5, "ecc_deg": 37.5, "tan": [p.0, p.1], "ndc": ndc(t, p.0, p.1), "px": [0.0, 0.0]] as [String: Any] }]
    }
    return [
        "set": "chart80", "tool": "tools/golden/golden-frame.py", "created_utc": "2026-10-22T10:13:40Z",
        "frustum": ["tangents_LRBT": ["L": lrbt(leftEye), "R": lrbt(rightEye)], "order": "|tan| left, right, bottom, top"],
        "density": ["px_per_deg_axis": 80, "px_per_tan": 4583.662361046586],
        "golden": ["L": ["png": "L.png", "size": [12523, 10046], "render_s": 5.4], "R": ["png": "R.png", "size": [12523, 10046], "render_s": 5.4]],
        "content": ["kind": "chart", "head_locked": "infinity"],
        "overlays": [
            "ndc_convention": "CornerTangents.ndc",
            "frustum_rect": ["L": ["tangents_LRBT": lrbt(leftEye), "px": [0, 0, 12523, 10046], "ndc": [-1.0, -1.0, 1.0, 1.0]],
                             "R": ["tangents_LRBT": lrbt(rightEye), "px": [0, 0, 12523, 10046], "ndc": [-1.0, -1.0, 1.0, 1.0]]],
            "eye_axis": ["L": ["tan": [0.0, 0.0], "ndc": ndc(leftEye, 0, 0), "px": [7939.4, 4583.7]],
                         "R": ["tan": [0.0, 0.0], "ndc": ndc(rightEye, 0, 0), "px": [4583.7, 4583.7]]],
            "lens_outline": ["L": lens(leftEye, [(0.767327, 0.0), (0.741639, 0.064885)]),
                             "R": lens(rightEye, [(0.8391, 0.0), (0.811512, 0.070998)])],
            "lens_source": "evidence/device-20261021/diag-20261021T152509Z.log"],
        "codec": ["status": "none"],
        "render": ["size": [4176, 3333], "fov_scale": 1.0, "point": "points-chart-avp.tsv a100-axis-C"],
        "foveation": ["enabled": true,
                      "settings": ["center_size_x": 0.5, "center_size_y": 0.45, "edge_ratio_x": 3.0, "edge_ratio_y": 3.0,
                                   "center_shift_x": 0.536, "center_shift_y": -0.159],
                      "aligned": ["x": ["c": 0.5, "s": 0.5373563170433044, "r": 3.0, "f": 0.6666666865348816, "opt": 2784.0, "coded": 2784],
                                  "y": ["c": 0.4491448998451233, "s": -0.1568627506494522, "r": 3.0, "f": 0.6327632665634155,
                                        "opt": 2109.0, "coded": 2112],
                                  "eye_size_ratio": [1.0, 0.9985795454545454]]],
        "server": ["size": [2784, 2112], "png": ["L": "L.server.png", "R": "R.server.png"], "layout": "side by side halves",
                   "stream_tangents_LRBT": ["L": lrbt(leftEye), "R": lrbt(rightEye)]],
        "files": files,
    ]
}

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private func removing(_ path: [String], from object: [String: Any]) -> [String: Any] {
    var out = object
    if path.count == 1 { out.removeValue(forKey: path[0]); return out }
    out[path[0]] = removing(Array(path.dropFirst()), from: object[path[0]] as! [String: Any])
    return out
}

// $TMPDIR first: a sandboxed run may only write there, not to the per-user temporary directory. Removed at the end of the run.
private let testRoot = (ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory)
    .appendingPathComponent("golden-tests-\(UUID().uuidString)")

private func writeSet(_ object: [String: Any], files: [String: Data] = serverBytes) -> URL {
    let dir = testRoot.appendingPathComponent("\(UUID().uuidString)/chart80")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! json(object).write(to: dir.appendingPathComponent("meta.json"))
    for (name, data) in files { try! data.write(to: dir.appendingPathComponent(name)) }
    return dir
}

private func testSha256() {
    expectEqual(GoldenMeta.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "FIPS 180-2 abc")
    expectEqual(GoldenMeta.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty")
    let long = Data(String(repeating: "a", count: 1_000_000).utf8)
    expectEqual(GoldenMeta.sha256Hex(long), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "a x 1e6 (multi-block)")
}

private func testParse() {
    guard let meta = try? GoldenMeta.parse(json(metaObject())) else { expect(false, "meta parses"); return }
    expectEqual(meta.set, "chart80", "set")
    expectEqual(meta.contentKind, "chart", "content kind")
    expect(near(meta.pxPerDeg, 80), "density")
    expectEqual(meta.frustum[.left], leftEye, "L frustum (l, r, b, t)")
    expectEqual(meta.frustum[.right], rightEye, "R frustum mirrored")
    expectEqual(meta.streamTangents[.left], leftEye, "stream tangents at fov scale 1")
    expectEqual(meta.serverSize, [2784, 2112], "coded eye size")
    expectEqual(meta.serverPNG[.left], "L.server.png", "L server png")
    expectEqual(meta.renderSize, [4176, 3333], "render size")
    expectEqual(meta.goldenSize[.left], [12523, 10046], "golden size")
    expectEqual(meta.overlays.frustumRect[.right], rightEye, "frustum rectangle")
    expect(near(meta.overlays.eyeAxis[.left]!.x, 0) && near(meta.overlays.eyeAxis[.left]!.y, 0), "eye axis tan")
    expectEqual(meta.overlays.lens?[.left]?.count, 2, "lens outline points")
    expect(near(meta.overlays.lens![.right]![1].x, 0.811512) && near(meta.overlays.lens![.right]![1].y, 0.070998), "lens tan")
    expectEqual(meta.files["L.server.png"], GoldenMeta.sha256Hex(serverBytes["L.server.png"]!), "file hash")
    // Sent tangents in the order the stream's vertex shader reads them (left, right, top, bottom).
    let sent = meta.sentTangents(.left)
    expect(sent == SIMD4<Float>(1.7321, 1, 1, 1.1918), "sent (l, r, t, b) \(sent)")
    // Lens outline null (no reference found): parsed as none, not an error.
    var noLens = metaObject()
    var overlays = noLens["overlays"] as! [String: Any]
    overlays["lens_outline"] = NSNull()
    noLens["overlays"] = overlays
    expect((try? GoldenMeta.parse(json(noLens)))?.overlays.lens == nil, "null lens outline")
}

private func testMissingKeyAndSha() {
    for path in [["server", "stream_tangents_LRBT", "L"], ["foveation", "aligned", "y"], ["files"], ["density", "px_per_deg_axis"],
                 ["overlays", "eye_axis", "R"], ["render", "size"]] {
        do {
            _ = try GoldenMeta.parse(json(removing(path, from: metaObject())))
            expect(false, "missing \(path) must fail")
        } catch let error as GoldenMetaError {
            expectEqual(error, .missingKey(path.joined(separator: ".")), "missing key named")
        } catch { expect(false, "unexpected error \(error)") }
    }
    do { _ = try GoldenMeta.parse(Data("{".utf8)); expect(false, "bad JSON") }
    catch let error as GoldenMetaError { expectEqual(error, .unreadable("meta.json"), "bad JSON") } catch { expect(false, "\(error)") }

    // load: parse + every listed file hashed; a server PNG that differs from its sha256 fails loudly.
    let ok = writeSet(metaObject())
    expect((try? GoldenMeta.load(directory: ok)) != nil, "intact set loads")
    var bytes = serverBytes
    bytes["R.server.png"] = Data("tampered".utf8)
    let bad = writeSet(metaObject(), files: bytes)
    do { _ = try GoldenMeta.load(directory: bad); expect(false, "sha mismatch must fail") }
    catch let error as GoldenMetaError { expectEqual(error, .shaMismatch("R.server.png"), "mismatch names the file") }
    catch { expect(false, "\(error)") }
    var missing = serverBytes
    missing.removeValue(forKey: "L.server.png")
    do { _ = try GoldenMeta.load(directory: writeSet(metaObject(), files: missing)); expect(false, "absent server png") }
    catch let error as GoldenMetaError { expectEqual(error, .unreadable("L.server.png"), "absent server png") }
    catch { expect(false, "\(error)") }
    // The golden PNGs are not displayed: absent is fine, present must match.
    var noGolden = serverBytes
    noGolden.removeValue(forKey: "L.png")
    expect((try? GoldenMeta.load(directory: writeSet(metaObject(), files: noGolden))) != nil, "golden png absent: loads")

    let line = Diag.line(topic: "golden", tMs: 7, fields: GoldenMetaError.shaMismatch("R.server.png").fields(set: "chart80"))
    expectEqual(line, "DIAG golden t_ms=7 step=error why=sha_mismatch key=R.server.png set=chart80 sha_ok=false", "error line")
    let missingLine = Diag.line(topic: "golden", tMs: 7, fields: GoldenMetaError.missingKey("server.size").fields(set: "x"))
    expectEqual(missingLine, "DIAG golden t_ms=7 step=error why=missing_key key=server.size set=x sha_ok=unknown", "missing key line")

    // The picker's sets: subdirectories holding a meta.json, sorted, after Off.
    let root = ok.deletingLastPathComponent()
    try! FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
    _ = try? json(metaObject()).write(to: root.appendingPathComponent("a-set/meta.json").creatingDirectory())
    expectEqual(GoldenFrameSetting.choices(root: root), ["Off", "a-set", "chart80"], "picker choices")
    expectEqual(GoldenFrameSetting.choices(root: root.appendingPathComponent("none")), ["Off"], "no golden dir")
}

private extension URL {
    func creatingDirectory() -> URL {
        try! FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

private func testFoveationOverride() {
    let meta = try! GoldenMeta.parse(json(metaObject()))
    let f = meta.foveation
    // FFR.swift FoveationVars from the aligned values: centre size / shift (c, s), edge ratio r, eye size ratio opt/coded.
    expect(f.enabled, "enabled")
    expectEqual(f.targetEye, [4176, 3333], "target eye = render size")
    expectEqual(f.optimizedEye, [2784, 2112], "optimized eye = coded")
    expect(f.centerSize == SIMD2<Float>(0.5, 0.4491448998451233) && f.centerShift == SIMD2<Float>(0.5373563170433044, -0.1568627506494522)
           && f.edgeRatio == SIMD2<Float>(3, 3) && f.eyeSizeRatio == SIMD2<Float>(1, 0.9985795454545454), "aligned values \(f)")
    var off = metaObject()
    var fov = off["foveation"] as! [String: Any]
    fov["enabled"] = false
    off["foveation"] = fov
    expect(!(try! GoldenMeta.parse(json(off))).foveation.enabled, "foveation off in meta")

    // While golden mode is on its foveation is the one in force; exit restores the live parameters untouched.
    let live = GoldenFoveation(enabled: true, targetEye: [3648, 2912], optimizedEye: [2432, 1856], eyeSizeRatio: [1, 1],
                               centerSize: [0.4, 0.35], centerShift: [0.4, 0.1], edgeRatio: [4, 5])
    var override = FoveationOverride<GoldenFoveation>()
    expectEqual(override.effective(live: live), live, "off: live")
    expectEqual(override.effective(live: nil), nil, "off, no stream: none")
    override.begin(f)
    expect(override.active, "active")
    expectEqual(override.effective(live: live), f, "on: golden overrides live")
    expectEqual(override.effective(live: nil), f, "on with no stream: golden")
    override.end()
    expect(!override.active, "ended")
    expectEqual(override.effective(live: live), live, "exit: live restored")
}

private func testOverlayGeometry() {
    let meta = try! GoldenMeta.parse(json(metaObject()))
    // The device tangents equal the set's frustum: the client's NDC is the NDC meta.json records.
    for (eye, t) in [(CornerEye.left, leftEye), (.right, rightEye)] {
        let axis = GoldenOverlay.ndc(t, meta.overlays.eyeAxis[eye]!)
        expect(near(axis.x, ndc(t, 0, 0)[0]) && near(axis.y, ndc(t, 0, 0)[1]), "\(eye) eye axis \(axis)")
        for p in meta.overlays.lens![eye]! {
            let n = GoldenOverlay.ndc(t, p), want = ndc(t, p.x, p.y)
            expect(near(n.x, want[0]) && near(n.y, want[1]), "\(eye) lens point")
        }
        // Head-locked (frame rotation identity): the frustum rectangle is the view's [-1, 1] square.
        let rect = GoldenOverlay.frustumCorners(t, rect: meta.overlays.frustumRect[eye]!, frameToView: matrix_identity_float3x3)!
        let want: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        expect(zip(rect, want).allSatisfy { near($0.x, $1.0, 1e-5) && near($0.y, $1.1, 1e-5) }, "\(eye) frustum corners \(rect)")
    }
    expect(near(GoldenOverlay.ndc(leftEye, CornerChart.Point(x: 0, y: 0)).x, 0.2679623732659859, 1e-9), "meta's eye-axis ndc (L)")
    // World-locked, head turned: corners move with the frame. Frame-to-view rotation of 10 deg about +y on the (1, 1) corner:
    // v = (cos - sin, 1, -(sin + cos)), tan = (v.x, v.y) / -v.z.
    let a = 10.0 * Double.pi / 180
    let yaw = simd_float3x3(simd_quatf(angle: Float(a), axis: [0, 1, 0]))
    let corners = GoldenOverlay.frustumCorners(leftEye, rect: leftEye, frameToView: yaw)!
    let tx = (cos(a) - sin(a)) / (cos(a) + sin(a)), ty = 1 / (cos(a) + sin(a))
    let want = ndc(leftEye, tx, ty)
    expect(near(corners[2].x, want[0], 1e-5) && near(corners[2].y, want[1], 1e-5), "rotated corner \(corners[2]) vs \(want)")
    // A corner behind the eye cannot be drawn: no rectangle.
    let behind = simd_float3x3(simd_quatf(angle: Float.pi, axis: [0, 1, 0]))
    expect(GoldenOverlay.frustumCorners(leftEye, rect: leftEye, frameToView: behind) == nil, "behind the eye")
    // Segments as quads: the axis cross is two strokes, the lens outline closed.
    let cross = GoldenOverlay.axisCross(leftEye, meta.overlays.eyeAxis[.left]!)
    expectEqual(cross.count, 2, "cross strokes")
    expectEqual(GoldenOverlay.closed(meta.overlays.lens![.left]!.map { GoldenOverlay.ndc(leftEye, $0) }).count, 2, "closed outline")
    let quads = GoldenOverlay.quads(cross, widthPx: 1000, heightPx: 800, strokePx: 4, color: [1, 1, 0, 1])
    expectEqual(quads.count, 2, "one quad per stroke")
    let q = quads[0].vertices
    // Horizontal stroke of the cross: 4 px thick = 8 / 800 in NDC.
    expect(near(abs(q[0].y - q[2].y), 8.0 / 800, 1e-9), "stroke thickness \(q)")
}

private func rot(_ deg: Float, _ axis: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: deg * .pi / 180, axis: simd_normalize(axis))) }
private func translated(_ m: simd_float4x4, _ t: SIMD3<Float>) -> simd_float4x4 { var o = m; o.columns.3 = SIMD4<Float>(t, 1); return o }
private func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tol: Float = 1e-5) -> Bool { simd_length(a - b) <= tol }

private func testPosePinning() {
    // P: head pose when the set was shown; Q: the head now (both with translation, which the stream path drops).
    let p = translated(rot(10, [0, 1, 0]) * rot(3, [1, 0, 0]), [0.1, 1.6, -0.2])
    let q = translated(rot(25, [0, 1, 0]) * rot(-5, [1, 0, 0]), [0.3, 1.5, 0.1])
    let view = translated(rot(1.5, [0, 0, 1]), [-0.032, 0, 0])   // eye in the head frame
    let m = StreamReprojection.viewMatrixFrame(framePose: p, deviceAnchor: q, viewTransform: view)
    // Same formula as Renderer.updateGameStateForVideoFrame: (P0^-1 * Q0 * V)^-1, P0/Q0 without translation.
    var p0 = p, q0 = q
    p0.columns.3 = [0, 0, 0, 1]; q0.columns.3 = [0, 0, 0, 1]
    let live = (p0.inverse * q0 * view).inverse
    expect((0..<4).allSatisfy { close(m[$0], live[$0]) }, "live reprojection transform")
    // World-locked: a frame direction d lands in the world at P d whatever Q is.
    for d in [SIMD4<Float>(0, 0, -1, 0), SIMD4<Float>(0.7, 0.4, -1, 0), SIMD4<Float>(-1.2, -0.9, -1, 0)] {
        let world = q * view * (m * d)
        expect(close(world, p * d), "pinned in the world: \(world) vs \(p * d)")
    }
    let rk = StreamReprojection.viewMatrixFrameRealityKit(framePose: p, deviceAnchor: q)
    expect((0..<4).allSatisfy { close(rk[$0], (p0.inverse * q0).inverse[$0]) }, "RealityKit form")

    var pose = GoldenPose(shownAt: p)
    expect(pose.worldLocked, "world-locked by default")
    expect(pose.framePose(current: q) == p, "world-locked: frame pose stays P")
    pose.setWorldLocked(false, current: q)
    expect(pose.framePose(current: q) == q, "head-locked: frame pose follows the head")
    let headLocked = StreamReprojection.viewMatrixFrame(framePose: pose.framePose(current: q), deviceAnchor: q, viewTransform: view)
    let d = SIMD4<Float>(0.3, -0.2, -1, 0)
    expect(close(headLocked * d, view.inverse * d), "head-locked: only the eye's own transform remains")
    let q2 = translated(rot(-40, [0, 1, 0]), [0, 1.6, 0])
    pose.setWorldLocked(true, current: q2)
    expect(pose.framePose(current: q) == q2, "world-locked again: re-pinned at the current pose")
    pose.repin(current: q)
    expect(pose.framePose(current: q2) == q, "re-pin")
}

private func testNV12() {
    func px(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Int, Int, Int) { GoldenNV12.code(r: r, g: g, b: b) }
    expect(px(255, 255, 255) == (255, 128, 128), "white")
    expect(px(0, 0, 0) == (0, 128, 128), "black")
    expect(px(100, 100, 100) == (100, 128, 128), "grey")
    let red = px(255, 0, 0)
    expect(red.0 == 54 && red.2 == 255, "red: Y 0.2126, Cr clamps \(red)")
    // Round trip through the stream shader's matrix (ColourPipeline, BT.709 full range, 8-bit planes).
    let m = ColourPipeline.yuvToRGBMatrix(matrix: .bt709, fullRange: true, bitDepth: 8)
    for rgb in [(200, 100, 50), (30, 180, 220), (128, 128, 128)] {
        let c = px(UInt8(rgb.0), UInt8(rgb.1), UInt8(rgb.2))
        let back = m * SIMD4<Float>(Float(c.0) / 255, Float(c.1) / 255, Float(c.2) / 255, 1)
        expect(abs(back.x * 255 - Float(rgb.0)) < 1.5 && abs(back.y * 255 - Float(rgb.1)) < 1.5 && abs(back.z * 255 - Float(rgb.2)) < 1.5,
               "round trip \(rgb) -> \(c) -> \(back * 255)")
    }
    // Side by side L|R (the stream's layout), 4:2:0 chroma: each CbCr sample the box average of its 2x2 luma block.
    let left = GoldenNV12.Image(width: 4, height: 2, channels: 1, bytesPerRow: 4, pixels: [255, 0, 10, 10, 255, 0, 10, 10])
    let right = GoldenNV12.Image(width: 4, height: 2, channels: 3, bytesPerRow: 12,
                                 pixels: [255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255])
    guard let f = GoldenNV12.frame(left: left, right: right) else { expect(false, "frame"); return }
    expectEqual(f.width, 8, "two eyes wide")
    expectEqual(f.height, 2, "height")
    expectEqual(Array(f.luma[0..<8]), [255, 0, 10, 10, 54, 54, 18, 18], "luma row 0")
    expectEqual(f.chroma.count, 8, "4 x 1 CbCr pairs")
    expectEqual(Array(f.chroma[0..<4]), [128, 128, 128, 128], "grey eye: neutral chroma")
    let blue = px(0, 0, 255)
    expectEqual(Int(f.chroma[6]), blue.1, "blue Cb")
    expectEqual(Int(f.chroma[7]), blue.2, "blue Cr")
    expect(GoldenNV12.frame(left: left, right: GoldenNV12.Image(width: 2, height: 2, channels: 1, bytesPerRow: 2, pixels: [0, 0, 0, 0])) == nil,
           "eyes of different sizes")
    testPixelBuffer(f)
}

// The buffer handed to the stream path: '420f' planes as packed, tagged as the live decoder output is
// (VideoHandler.swift:383-385: primaries BT.709, transfer sRGB, matrix BT.709), so the YCbCr sampler converts it the same way.
private func testPixelBuffer(_ f: GoldenNV12.Frame) {
    guard let buffer = GoldenNV12.pixelBuffer(f) else { expect(false, "pixel buffer"); return }
    expectEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "420f")
    expectEqual(CVPixelBufferGetWidth(buffer), f.width, "width")
    expectEqual(CVPixelBufferGetHeight(buffer), f.height, "height")
    func tag(_ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil).flatMap { $0 as? String }
    }
    expectEqual(tag(kCVImageBufferYCbCrMatrixKey), kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "matrix as live")
    expectEqual(tag(kCVImageBufferColorPrimariesKey), kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "primaries as live")
    expectEqual(tag(kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_sRGB as String, "transfer as live")
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    for (plane, bytes) in [f.luma, f.chroma].enumerated() {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane), rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
        let copied = (0..<rows).flatMap { row in (0..<f.width).map { base[row * stride + $0] } }
        expectEqual(copied, bytes, "plane \(plane) bytes")
    }
}

private func testSession() {
    let s = GoldenFrameSession(quality: 0.75)
    expectEqual(s.control, .lock, "starts on the lock control")
    expectEqual(s.statusText, "UorLd", "world-locked status")
    expectEqual(s.apply(.apply), [.setting(key: "world_locked", value: "false")], "hold right: head-locked")
    expectEqual(s.statusText, "HEAd", "head-locked status")
    expectEqual(s.apply(.apply), [.setting(key: "world_locked", value: "true"), .repin], "back to world: re-pin")
    expectEqual(s.apply(.back), [.setting(key: "repin", value: "true"), .repin], "hold left: re-pin")
    expectEqual(s.apply(.next), [], "selection is not a setting")
    expectEqual(s.control, .quality, "quality")
    expectEqual(s.statusText, "rq 0.75", "quality status")
    expectEqual(s.apply(.apply), [.setting(key: "rq", value: "1.000"), .quality(1.0)], "quality up")
    expectEqual(s.apply(.apply), [.setting(key: "rq", value: "0.500"), .quality(0.5)], "wraps")
    expectEqual(s.apply(.back), [.setting(key: "rq", value: "1.000"), .quality(1.0)], "quality down wraps")
    _ = s.apply(.next)
    expectEqual(s.statusText, "OL 111", "all overlays")
    expectEqual(s.apply(.apply), [.setting(key: "overlays", value: "100")], "frustum only")
    expectEqual(s.apply(.apply), [.setting(key: "overlays", value: "010")], "axis only")
    expectEqual(s.apply(.apply), [.setting(key: "overlays", value: "001")], "lens only")
    expectEqual(s.apply(.apply), [.setting(key: "overlays", value: "000")], "none")
    expectEqual(s.apply(.back), [.setting(key: "overlays", value: "001")], "back")
    expectEqual(s.overlays, GoldenFrameSession.Overlays(frustum: false, axis: false, lens: true), "overlay flags")
    _ = s.apply(.next)
    expectEqual(s.statusText, "CAP", "capture")
    expectEqual(s.apply(.apply), [.setting(key: "capture", value: "start"), .capture], "capture")
    _ = s.apply(.next)
    expectEqual(s.statusText, "End", "exit")
    expectEqual(s.apply(.next), [], "last control")
    expectEqual(s.apply(.apply), [.setting(key: "exit", value: "live"), .exit], "exit")
    _ = s.apply(.previous)
    expectEqual(s.control, .capture, "previous")
    // Entry quality off the three steps snaps to the nearest.
    expectEqual(GoldenFrameSession(quality: 0.8).quality, 0.75, "snap")
    expectEqual(GoldenFrameSession(quality: nil).quality, 1.0, "no read-back: 1.0")
    for ch in ["U", "o", "r", "L", "d", "H", "E", "A", "q", "O", "C", "P", "n"] {
        expect(!CornerChart.text(ch, in: CornerChart.Rect(x0: 0, y0: 0, x1: 1, y1: 1), vertical: false, color: [1, 1, 1, 1]).isEmpty, "glyph \(ch)")
    }

    let line = Diag.line(topic: "golden", tMs: 9, fields: GoldenFrame.fields(step: "show", set: "chart80", eyePx: [2784, 2112], density: 80,
                                                                              rq: 0.75, worldLocked: true, overlays: s.overlays, shaOK: true))
    expectEqual(line, "DIAG golden t_ms=9 step=show set=chart80 eye_px=2784x2112 density=80 rq=0.750 world_locked=true overlays=001 sha_ok=true",
                "show line")
    let setting = Diag.line(topic: "golden", tMs: 9, fields: GoldenFrame.settingFields(set: "chart80", key: "rq", value: "0.500"))
    expectEqual(setting, "DIAG golden t_ms=9 step=setting set=chart80 key=rq value=0.500", "setting line")
}

// MetalClientSystem's spatial event routing: while golden is shown its controls consume the pinches (the game never sees
// them, it can be streaming underneath); otherwise forwarding is as before (online: every event, offline: none).
private func testEventRouting() {
    func forwarded(_ events: Int, goldenActive: Bool, offline: Bool) -> Int {
        (0..<events).filter { _ in GoldenFrame.forwardToGame(goldenActive: goldenActive, offlineDiagnostics: offline) }.count
    }
    expectEqual(forwarded(5, goldenActive: true, offline: false), 0, "golden active: nothing reaches the game")
    expectEqual(forwarded(5, goldenActive: false, offline: false), 5, "golden inactive: every event, as before")
    expectEqual(forwarded(5, goldenActive: false, offline: true), 0, "offline diagnostics: none, as before")
    expectEqual(forwarded(5, goldenActive: true, offline: true), 0, "offline and golden: none")
}

private func testQualitySettle() {
    // W33 rule: settled when the rate map's screen size is within 1 % of reference x (0.5 + 0.5 q) / (0.5 + 0.5 q_ref)
    // for 30 consecutive frames; unconfirmed after 600.
    var settle = GoldenQualitySettle(reference: [5479, 4395], referenceQuality: 0.75)
    settle.set(1.0)
    expectEqual(settle.expected, [6262, 5023], "expected at 1.0 (5479 / 0.875 = 6261.7)")
    for _ in 0..<10 { expect(settle.frame(screen: [5479, 4395], actual: 1.0) == nil, "map not moved yet") }
    var out: GoldenQualitySettle.Result?
    for i in 0..<30 { out = settle.frame(screen: [6250, 5020], actual: 1.0); if i < 29 { expect(out == nil, "settling \(i)") } }
    expectEqual(out, GoldenQualitySettle.Result(quality: 1.0, frames: 40, settle: "rate_map", screen: [6250, 5020]), "settled")
    expect(settle.frame(screen: [6250, 5020], actual: 1.0) == nil, "reported once")
    var none = GoldenQualitySettle(reference: nil, referenceQuality: nil)
    none.set(0.5)
    var last: GoldenQualitySettle.Result?
    for _ in 0..<600 { last = none.frame(screen: nil, actual: nil) ?? last }
    expectEqual(last?.settle, "timeout", "no map, no read-back: timeout")
}

private func testCapture() {
    expectEqual(GoldenFrame.directoryName(set: "chart80", stamp: "20261022T101010Z", quality: 0.5), "golden-chart80-20261022T101010Z-rq0.50", "dir")
    let line = Diag.line(topic: "chartcap", tMs: 5, fields: ChartCapture.goldenFields(eye: .left, requested: 0.5, actual: 0.5, confirmed: true,
                                                                                     foveation: true, dir: "golden-x", slice: 0, physical: [1952, 1888],
                                                                                     screen: [4696, 3767], expectedScreen: [4696, 3767], settle: "rate_map",
                                                                                     set: "chart80"))
    expectEqual(line, "DIAG chartcap t_ms=5 eye=L rq=0.500 rq_set=0.500 confirmed=yes fov=on dir=golden-x slice=0 screen=4696x3767 "
                + "physical=1952x1888 expected_screen=4696x3767 settle=rate_map patches=24 source=golden set=chart80", "golden chartcap line")
    let meta = try! GoldenMeta.parse(json(metaObject()))
    let chart = ChartCapture.metadata(views: [], requested: 0.5, actual: 0.5, confirmed: true, foveation: true, frames: 31)
    let settings = GoldenFrame.settings(meta: meta, requested: 0.5, actual: 0.5, worldLocked: false,
                                        overlays: GoldenFrameSession.Overlays(frustum: false, axis: false, lens: false))
    let record = GoldenFrame.captureMetadata(chart: chart, meta: meta, settings: settings)
    expect(JSONSerialization.isValidJSONObject(record), "capture.json serialisable")
    expectEqual(record["golden_set"] as? String, "chart80", "golden_set for golden-frame.py measure")
    let cc = record["chart_capture"] as! [String: Any]
    expectEqual(cc["source"] as? String, "golden", "chart_capture source")
    expectEqual(cc["set"] as? String, "chart80", "chart_capture set")
    expectEqual(cc["rq"] as? String, "0.500", "chart keys kept")
    expectEqual((record["trigger"] as? [String: String])?["reason"], "chartcap", "trigger")
    let s = record["golden"] as! [String: Any]
    expectEqual(s["world_locked"] as? Bool, false, "settings: lock")
    expectEqual(s["overlays"] as? String, "000", "settings: overlays")
    expectEqual(s["eye_px"] as? [Int], [2784, 2112], "settings: eye px")
    expectEqual(s["density_px_per_deg"] as? Double, 80, "settings: density")
    expectEqual(s["render_size"] as? [Int], [4176, 3333], "settings: render")
    expectEqual(s["rq_set"] as? String, "0.500", "settings: rq")
    expectEqual((s["foveation"] as? [String: Any])?["enabled"] as? Bool, true, "settings: foveation")
    expectEqual(s["content"] as? String, "chart", "settings: content")
    expectEqual(s["colour"] as? String, "nv12 420f bt709 full range, sRGB transfer, encoding gamma 1", "settings: colour")
}

@main
enum GoldenFrameTests {
    static func main() {
        testSha256()
        testParse()
        testMissingKeyAndSha()
        testFoveationOverride()
        testOverlayGeometry()
        testPosePinning()
        testNV12()
        testSession()
        testEventRouting()
        testQualitySettle()
        testCapture()
        try? FileManager.default.removeItem(at: testRoot)
        finishTests("GoldenFrame")
    }
}
