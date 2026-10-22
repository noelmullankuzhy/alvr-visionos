// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/ProjectionOverlay.swift ALVRClient/ViewLayout.swift ALVRClient/CropFov.swift
// Crop FOV to outline: the per-eye tangents sent to the server (bbox of the lens outline + margin, clamped to the device
// frustum), the ALVR center_shift that keeps the 1:1 band on the eye axis inside the cropped frame, and the video quad
// the display draws from the sent tangents. Shared fixture with avp-sharpness.py: tools/diag/fixtures/crop-fov.json.
import Foundation
import simd

@main
enum CropFovTests {
    static func main() {
        func near(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-6) {
            expect(abs(a - b) < tolerance, "\(message): \(a) vs \(b)")
        }
        func near4(_ got: simd_float4?, _ want: [Double], _ message: String, tolerance: Double = 1e-4) {
            guard let got else { return expect(false, "\(message): nil") }
            for (i, side) in ["left", "right", "bottom", "top"].enumerated() {
                near(Double(got[i]), want[i], "\(message) \(side)", tolerance: tolerance)
            }
        }
        func tand(_ d: Double) -> Double { tan(d * .pi / 180) }
        func cosd(_ d: Double) -> Double { cos(d * .pi / 180) }
        func sind(_ d: Double) -> Double { sin(d * .pi / 180) }
        let deviceL = simd_float4(1.7321, 1.0, 1.1918, 1.0), deviceR = simd_float4(1.0, 1.7321, 1.1918, 1.0)

        // Bbox, margin 0: the lens bbox of ProjectionOverlay (L offset 0: left ray 195 ecc 42.5, right ray 0 ecc 37.5,
        // up ray 105 ecc 32.5, down ray 270 ecc 32.5), in gimmeTangents slots (left, right, bottom, top).
        let bboxL = [tand(42.5) * -cosd(195), tand(37.5), tand(32.5), tand(32.5) * sind(105)]
        near4(CropFov.tangents(eye: .left, device: deviceL, offsetDeg: 0, marginDeg: 0), bboxL, "L offset 0 margin 0 = bbox")
        // Margin 2 widens each side by 2 deg: 41.5123 -> 43.5123, 37.5 -> 39.5, 32.5 -> 34.5 (down), 31.6066 -> 33.6066 (up).
        let cropL = CropFov.tangents(eye: .left, device: deviceL, offsetDeg: 0, marginDeg: 2)
        near4(cropL, [tand(43.5123), tand(39.5), tand(34.5), tand(33.6066)], "L offset 0 margin 2 by degrees")
        near4(cropL, [0.949373, 0.824336, 0.687281, 0.664564], "L offset 0 margin 2 in numbers", tolerance: 1e-5)
        // R mirrors L about the vertical: left and right swap.
        let cropR = CropFov.tangents(eye: .right, device: deviceR, offsetDeg: 0, marginDeg: 2)
        near4(cropR, [0.824336, 0.949373, 0.687281, 0.664564], "R offset 0 margin 2 mirrored", tolerance: 1e-5)
        // Clamp: offset +20 puts every side past the device frustum (left tan 62.5 x cos 15 = 1.8555 > 1.7321), so the
        // sent box is the device's.
        near4(CropFov.tangents(eye: .left, device: deviceL, offsetDeg: 20, marginDeg: 2), [1.7321, 1.0, 1.1918, 1.0], "L +20 clamps")
        // Clamp per side: a narrow device frustum (tan 0.8 everywhere) cuts left and right; down and up stay.
        near4(CropFov.tangents(eye: .left, device: simd_float4(0.8, 0.8, 0.8, 0.8), offsetDeg: 0, marginDeg: 2),
              [0.8, 0.8, 0.687281, 0.664564], "clamp per side", tolerance: 1e-5)
        expect(CropFov.tangents(eye: .both, device: deviceL, offsetDeg: 0, marginDeg: 2) == nil, "Both has no crop")
        // A negative or non-finite margin is no margin.
        near4(CropFov.tangents(eye: .left, device: deviceL, offsetDeg: 0, marginDeg: -3), bboxL, "negative margin = 0")
        near4(CropFov.tangents(eye: .left, device: deviceL, offsetDeg: 0, marginDeg: .nan), bboxL, "nan margin = 0")
        expectEqual(CropFov.defaultMarginDeg, 2.0, "default margin")

        // Centre shift: the band [c0(1 + s), 1 - c0(1 - s)], c0 = (1 - c)/2, has its centre at 0.5 + s c0
        // (Shaders.metal:152-157); eye UV x runs from the temporal edge (R mirrored, Shaders.metal:136-140), y from the
        // top row. The axis (tan 0) sits at temporal / (temporal + nasal) and up / (up + down), so
        //   s = (fraction - 0.5) / c0.
        // Device frustum, c 0.5/0.45: x (1.7321/2.7321 - 0.5)/0.25 = 0.536, y (1/2.1918 - 0.5)/0.275 = -0.159 (a100-axis rows).
        let size = SIMD2<Double>(0.5, 0.45)
        let device = CropFov.centerShift(left: deviceL, right: deviceR, centerSize: size)
        near(device.x, (1.7321 / 2.7321 - 0.5) / 0.25, "device shift x")
        near(device.y, (1.0 / 2.1918 - 0.5) / 0.275, "device shift y")
        near(device.x, 0.536, "device shift x = a100-axis", tolerance: 5e-4)
        near(device.y, -0.159, "device shift y = a100-axis", tolerance: 5e-4)
        // Seal-on bbox + 2 deg: x (0.949373/1.773709 - 0.5)/0.25 = 0.140988; y (0.664564/1.351845 - 0.5)/0.275 = -0.030553.
        let crop = CropFov.centerShift(left: cropL!, right: cropR!, centerSize: size)
        near(crop.x, (0.949373 / (0.949373 + 0.824336) - 0.5) / 0.25, "crop shift x", tolerance: 1e-4)
        near(crop.y, (0.664564 / (0.664564 + 0.687281) - 0.5) / 0.275, "crop shift y", tolerance: 1e-4)
        near(crop.x, 0.140988, "crop shift x in numbers", tolerance: 1e-4)
        near(crop.y, -0.030553, "crop shift y in numbers", tolerance: 1e-4)
        // One shift for both eyes (ALVR mirrors x for R): the mean of the per-eye shifts, equal for mirrored eyes.
        let lOnly = CropFov.centerShift(left: cropL!, right: cropL!.yxzw, centerSize: size)
        near(lOnly.x, crop.x, "mirrored eyes give the same shift", tolerance: 1e-6)
        // The band centre lands on the axis: 0.5 + s c0 = temporal / (temporal + nasal).
        near(0.5 + crop.x * 0.25, 0.949373 / 1.773709, "band centre x on the axis", tolerance: 1e-5)
        near(0.5 + crop.y * 0.275, 0.664564 / 1.351845, "band centre y on the axis", tolerance: 1e-5)
        // Centre size 1 (no edges): no shift.
        expectEqual(CropFov.centerShift(left: cropL!, right: cropR!, centerSize: [1, 1]), SIMD2<Double>(0, 0), "c 1: no shift")

        // Which tangents are sent: debug launch tangents first, then the crop, then the device frustum.
        let debug = [simd_float4(1, 1, 1, 1), simd_float4(2, 2, 2, 2)]
        let off = CropFov.choose(device: [deviceL, deviceR], debug: nil, crop: false, offsets: [0, 0], marginDeg: 2)
        expectEqual(off.source, "frustum", "off: frustum")
        expectEqual(off.tangents, [deviceL, deviceR], "off: device tangents")
        let on = CropFov.choose(device: [deviceL, deviceR], debug: nil, crop: true, offsets: [0, 0], marginDeg: 2)
        expectEqual(on.source, "crop", "on: crop")
        near4(on.tangents[0], [0.949373, 0.824336, 0.687281, 0.664564], "on: L crop", tolerance: 1e-5)
        near4(on.tangents[1], [0.824336, 0.949373, 0.687281, 0.664564], "on: R crop", tolerance: 1e-5)
        let shifted = CropFov.choose(device: [deviceL, deviceR], debug: nil, crop: true, offsets: [5, 0], marginDeg: 2)
        near4(shifted.tangents[0], [1.130664, 0.982697, 0.824336, 0.796723], "per-eye offset: L +5", tolerance: 1e-5)
        let dbg = CropFov.choose(device: [deviceL, deviceR], debug: debug, crop: true, offsets: [0, 0], marginDeg: 2)
        expectEqual(dbg.source, "debug", "debug wins")
        expectEqual(dbg.tangents, debug, "debug tangents")

        // Outline offsets recorded from the Boundary dots lens slider (per eye, default 0; Both is ignored).
        CropFov.resetOffsets()
        expectEqual(CropFov.offsets, [0, 0], "default offsets")
        CropFov.recordOffset(.left, deg: 3.5)
        CropFov.recordOffset(.both, deg: 9)
        expectEqual(CropFov.offsets, [3.5, 0], "L offset recorded, Both ignored")
        CropFov.recordOffset(.right, deg: .nan)
        expectEqual(CropFov.offsets, [3.5, 0], "non-finite offset ignored")
        CropFov.resetOffsets()

        // Display: Renderer.swift:708 puts the sent tangents in Uniforms.tangents, packed from the sent Fov by
        // ViewLayout.uniformTangents (left, right, up, down |tan|; Extensions/RealityKit.swift), and the video vertex
        // shader (Shaders.metal:205-216) builds the frame quad from them: x from -[0] to [1], y from -[3] to [2] at
        // depth 1. So the cropped frame lands on its own tangent rectangle; the device projection (real tangents) maps
        // that onto the drawable and the rest of the drawable keeps the black clear (Renderer.swift beginRenderStreamingFrame).
        let angles = ViewLayout.fovAngles(tangents: on.tangents[0], scale: 1)
        let uniform = ViewLayout.uniformTangents(left: angles.left, right: angles.right, up: angles.up, down: angles.down)
        near4(uniform, [0.949373, 0.824336, 0.664564, 0.687281], "uniform order left, right, up, down", tolerance: 1e-5)
        let quad = ViewLayout.videoQuadRect(uniformTangents: uniform)
        near(Double(quad.left), -0.949373, "quad left edge at the sent left tangent", tolerance: 1e-5)
        near(Double(quad.right), 0.824336, "quad right edge", tolerance: 1e-5)
        near(Double(quad.bottom), -0.687281, "quad bottom edge at the sent down tangent", tolerance: 1e-5)
        near(Double(quad.top), 0.664564, "quad top edge", tolerance: 1e-5)
        // FovPacking-style hand values: the device frustum gives the device quad (60/45/50/45 deg).
        let full = ViewLayout.fovAngles(tangents: deviceL, scale: 1)
        let fullQuad = ViewLayout.videoQuadRect(uniformTangents: ViewLayout.uniformTangents(left: full.left, right: full.right, up: full.up, down: full.down))
        near(Double(fullQuad.left), -1.7321, "device quad left", tolerance: 1e-4)
        near(Double(fullQuad.right), 1.0, "device quad right", tolerance: 1e-4)
        near(Double(fullQuad.bottom), -1.1918, "device quad bottom", tolerance: 1e-4)
        near(Double(fullQuad.top), 1.0, "device quad top", tolerance: 1e-4)
        // The cropped quad covers (1.773709 x 1.351845) / (2.7321 x 2.1918) = 40.0% of the device frustum's tangent area.
        let area = Double((quad.right - quad.left) * (quad.top - quad.bottom)) / (2.7321 * 2.1918)
        near(area, 1.773709 * 1.351845 / (2.7321 * 2.1918), "cropped quad area fraction", tolerance: 1e-5)

        // Fixture shared with test_fovmatrix.py (avp-sharpness.py crop): the same inputs give the same numbers.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/diag/fixtures/crop-fov.json").standardized
        if let data = try? Data(contentsOf: fixture),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rays = root["reference_rays"] as? String,
           let devices = root["device_tan_LRDU"] as? [String: [Double]],
           let c = root["center_size"] as? [Double], c.count == 2,
           let cases = root["cases"] as? [[String: Any]], !cases.isEmpty {
            // The fixture's rays are the compiled reference (BoundaryDotsLensReference.left).
            let compiled = BoundaryDotsLensReference.left.keys.sorted()
                .map { String(format: "%g:%g", locale: Locale(identifier: "en_US_POSIX"), $0, BoundaryDotsLensReference.left[$0]!) }
                .joined(separator: ",")
            expectEqual(rays, compiled, "fixture rays = compiled L reference")
            func four(_ v: [Double]?) -> simd_float4? {
                guard let v, v.count == 4 else { return nil }
                return simd_float4(Float(v[0]), Float(v[1]), Float(v[2]), Float(v[3]))
            }
            for item in cases {
                let name = item["name"] as? String ?? "?"
                guard let eye = BoundaryDotsEye(rawValue: item["eye"] as? String ?? ""),
                      let dev = four(devices[eye.rawValue]), let other = four(devices[eye == .left ? "R" : "L"]),
                      let offset = item["offset_deg"] as? Double, let margin = item["margin_deg"] as? Double,
                      let want = item["expect"] as? [String: Any], let sent = want["sent_tan_LRDU"] as? [Double],
                      let shift = want["center_shift"] as? [Double], shift.count == 2 else {
                    expect(false, "fixture case \(name) malformed")
                    continue
                }
                let got = CropFov.tangents(eye: eye, device: dev, offsetDeg: offset, marginDeg: margin)
                near4(got, sent, "fixture \(name) sent", tolerance: 1e-4)
                let mirror = CropFov.tangents(eye: eye == .left ? .right : .left, device: other, offsetDeg: offset, marginDeg: margin)
                if let got, let mirror {
                    let s = eye == .left ? CropFov.centerShift(left: got, right: mirror, centerSize: [c[0], c[1]])
                                         : CropFov.centerShift(left: mirror, right: got, centerSize: [c[0], c[1]])
                    near(s.x, shift[0], "fixture \(name) shift x", tolerance: 1e-3)
                    near(s.y, shift[1], "fixture \(name) shift y", tolerance: 1e-3)
                    if let px = want["render_px"] as? [Int], px.count == 2, let pxdeg = want["pxdeg_centre"] as? Double {
                        let box = ProjectionBox(left: Double(got.x), right: Double(got.y), up: Double(got.w), down: Double(got.z))
                        near(ProjectionOverlay.pxPerDegAxis(render: ProjectionRender(width: px[0], height: px[1]), box: box),
                             pxdeg, "fixture \(name) centre px/deg", tolerance: 0.1)
                    }
                }
            }
        } else {
            expect(false, "fixture \(fixture.path) readable with cases")
        }

        finishTests("CropFov")
    }
}
