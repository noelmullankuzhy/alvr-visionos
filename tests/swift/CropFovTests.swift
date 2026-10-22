// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/BoundaryDotsLensModel.swift ALVRClient/Diagnostics/ProjectionOverlay.swift ALVRClient/ViewLayout.swift ALVRClient/CropFov.swift
// Crop FOV to outline: the per-eye tangents sent to the server (the model lens's inset rectangle + margin, clamped to the
// device frustum), the ALVR center_shift that keeps the 1:1 band on the eye axis inside the cropped frame, and the video
// quad the display draws from the sent tangents. Shared fixture with avp-sharpness.py: tools/diag/fixtures/crop-fov.json.
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
        func deg(_ t: Double) -> Double { atan(t) * 180 / .pi }
        let deviceL = simd_float4(1.7321, 1.0, 1.1918, 1.0), deviceR = simd_float4(1.0, 1.7321, 1.1918, 1.0)

        // Margin 0: the model lens's inset rectangle (BoundaryDotsLensModel.insetRect), inset 15 on the device frustum
        // (tan 60.0007 / 45 / 50.0011 / 45): temporal 45.0007 (L left), nasal 30 (L right), down 35.0011, up 30, in
        // gimmeTangents slots (left, right, bottom, top).
        let rectL = [tand(deg(1.7321) - 15), tand(30), tand(deg(1.1918) - 15), tand(30)]
        near4(CropFov.tangents(eye: .left, device: deviceL, insetDeg: 15, marginDeg: 0), rectL, "L inset 15 margin 0 = inset rect")
        // Margin 2 widens each side by 2 deg: 47 / 32 / 37 / 32 (L left, right, bottom, top).
        let cropL = CropFov.tangents(eye: .left, device: deviceL, insetDeg: 15, marginDeg: 2)
        near4(cropL, [tand(47), tand(32), tand(37), tand(32)], "L inset 15 margin 2 = tan 47/32/37/32")
        near4(cropL, [1.072395, 0.624869, 0.753584, 0.624869], "L inset 15 margin 2 in numbers", tolerance: 1e-5)
        // R mirrors L about the vertical: left and right swap.
        let cropR = CropFov.tangents(eye: .right, device: deviceR, insetDeg: 15, marginDeg: 2)
        near4(cropR, [0.624869, 1.072395, 0.753584, 0.624869], "R inset 15 margin 2 mirrored", tolerance: 1e-5)
        // Clamp: inset 0 or 1 + margin 2 puts every side past the device frustum, so the sent box is the device's.
        near4(CropFov.tangents(eye: .left, device: deviceL, insetDeg: 0, marginDeg: 2), [1.7321, 1.0, 1.1918, 1.0], "L inset 0 clamps")
        near4(CropFov.tangents(eye: .left, device: deviceL, insetDeg: 1, marginDeg: 2), [1.7321, 1.0, 1.1918, 1.0], "L inset 1 clamps")
        // The rectangle comes from the frustum it is given: a narrow one (tan 0.8 = 38.66 deg) at inset 15 + 2.
        near4(CropFov.tangents(eye: .left, device: simd_float4(0.8, 0.8, 0.8, 0.8), insetDeg: 15, marginDeg: 2),
              [Double](repeating: tand(deg(0.8) - 13), count: 4), "rect of the given frustum", tolerance: 1e-5)
        // Each rectangle edge keeps at least 1 deg: inset 50 leaves temporal 10.0007 and 1 deg elsewhere, then + 2.
        near4(CropFov.tangents(eye: .left, device: deviceL, insetDeg: 50, marginDeg: 2),
              [tand(deg(1.7321) - 48), tand(3), tand(3), tand(3)], "edges >= 1 deg", tolerance: 1e-5)
        expect(CropFov.tangents(eye: .both, device: deviceL, insetDeg: 15, marginDeg: 2) == nil, "Both has no crop")
        // A negative or non-finite margin is no margin.
        near4(CropFov.tangents(eye: .left, device: deviceL, insetDeg: 15, marginDeg: -3), rectL, "negative margin = 0")
        near4(CropFov.tangents(eye: .left, device: deviceL, insetDeg: 15, marginDeg: .nan), rectL, "nan margin = 0")
        expectEqual(CropFov.defaultMarginDeg, 2.0, "default margin")
        // The setting's default (GlobalSettings.cropFovToOutline): on, so the lens style streams cropped unless turned off.
        expectEqual(CropFov.defaultEnabled, true, "crop defaults on")

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
        // Inset 15 rect + 2 deg: x (1.072395/1.697264 - 0.5)/0.25 = 0.527350; y (0.624869/1.378453 - 0.5)/0.275 = -0.169775.
        let crop = CropFov.centerShift(left: cropL!, right: cropR!, centerSize: size)
        near(crop.x, (1.072395 / (1.072395 + 0.624869) - 0.5) / 0.25, "crop shift x", tolerance: 1e-4)
        near(crop.y, (0.624869 / (0.624869 + 0.753584) - 0.5) / 0.275, "crop shift y", tolerance: 1e-4)
        near(crop.x, 0.527350, "crop shift x in numbers", tolerance: 1e-4)
        near(crop.y, -0.169775, "crop shift y in numbers", tolerance: 1e-4)
        // One shift for both eyes (ALVR mirrors x for R): the mean of the per-eye shifts, equal for mirrored eyes.
        let lOnly = CropFov.centerShift(left: cropL!, right: simd_float4(cropL!.y, cropL!.x, cropL!.z, cropL!.w), centerSize: size)
        near(lOnly.x, crop.x, "mirrored eyes give the same shift", tolerance: 1e-6)
        // The band centre lands on the axis: 0.5 + s c0 = temporal / (temporal + nasal).
        near(0.5 + crop.x * 0.25, 1.072395 / 1.697264, "band centre x on the axis", tolerance: 1e-5)
        near(0.5 + crop.y * 0.275, 0.624869 / 1.378453, "band centre y on the axis", tolerance: 1e-5)
        // Centre size 1 (no edges): no shift.
        expectEqual(CropFov.centerShift(left: cropL!, right: cropR!, centerSize: [1, 1]), SIMD2<Double>(0, 0), "c 1: no shift")

        // Which tangents are sent: debug launch tangents first, then the crop, then the device frustum.
        let debug = [simd_float4(1, 1, 1, 1), simd_float4(2, 2, 2, 2)]
        let off = CropFov.choose(device: [deviceL, deviceR], debug: nil, crop: false, insetDeg: 15, marginDeg: 2)
        expectEqual(off.source, "frustum", "off: frustum")
        expectEqual(off.tangents, [deviceL, deviceR], "off: device tangents")
        let on = CropFov.choose(device: [deviceL, deviceR], debug: nil, crop: true, insetDeg: 15, marginDeg: 2)
        expectEqual(on.source, "crop", "on: crop")
        near4(on.tangents[0], [1.072395, 0.624869, 0.753584, 0.624869], "on: L crop", tolerance: 1e-5)
        near4(on.tangents[1], [0.624869, 1.072395, 0.753584, 0.624869], "on: R crop", tolerance: 1e-5)
        let tenInset = CropFov.choose(device: [deviceL, deviceR], debug: nil, crop: true, insetDeg: 10, marginDeg: 2)
        near4(tenInset.tangents[0], [1.279974, 0.753554, 0.900439, 0.753554], "shared inset 10: L", tolerance: 1e-5)
        near4(tenInset.tangents[1], [0.753554, 1.279974, 0.900439, 0.753554], "shared inset 10: R mirrors L", tolerance: 1e-5)
        let dbg = CropFov.choose(device: [deviceL, deviceR], debug: debug, crop: true, insetDeg: 15, marginDeg: 2)
        expectEqual(dbg.source, "debug", "debug wins")
        expectEqual(dbg.tangents, debug, "debug tangents")

        // One model inset for both eyes, recorded from the Boundary dots lens slider (default 15; non-finite ignored).
        CropFov.resetInset()
        expectEqual(CropFov.inset, 15, "default inset")
        CropFov.recordInset(13.5)
        expectEqual(CropFov.inset, 13.5, "inset recorded")
        CropFov.recordInset(.nan)
        expectEqual(CropFov.inset, 13.5, "non-finite inset ignored")
        CropFov.resetInset()

        // The slider on either eye sets the one inset: both eyes' rectangles and both eyes' sent tangents change.
        var slider = BoundaryDotsSession()
        let frustumL = BoundaryDotsFrustum(left: 1.7321, right: 1.0, bottom: 1.1918, top: 1.0)
        let frustumR = BoundaryDotsFrustum(left: 1.0, right: 1.7321, bottom: 1.1918, top: 1.0)
        slider.eye = .left
        let rectL15 = slider.lensRect(.left, frustum: frustumL), rectR15 = slider.lensRect(.right, frustum: frustumR)
        slider.sliderValue = 10
        CropFov.recordInset(slider.lensInset)
        expect(slider.lensRect(.left, frustum: frustumL) != rectL15, "L rectangle changes with the L slider")
        expect(slider.lensRect(.right, frustum: frustumR) != rectR15, "R rectangle changes with the L slider")
        expectEqual(slider.lensRect(.right, frustum: frustumR), BoundaryDotsLensModel.insetRect(.right, frustum: frustumR, insetDeg: 10), "R rectangle at inset 10")
        let viaSlider = CropFov.choose(device: [deviceL, deviceR], debug: nil, crop: true, insetDeg: CropFov.inset, marginDeg: 2)
        near4(viaSlider.tangents[0], [1.279974, 0.753554, 0.900439, 0.753554], "L sent tangents follow the L slider", tolerance: 1e-5)
        near4(viaSlider.tangents[1], [0.753554, 1.279974, 0.900439, 0.753554], "R sent tangents follow the L slider", tolerance: 1e-5)
        CropFov.resetInset()

        // Every sent tangent is >= 0 and every edge angle < 89 deg: a device side past 89 deg, or a margin that would
        // push one there, is held at tan 89; a negative device side is 0.
        let tan89 = Float(tand(89))
        near4(CropFov.tangents(eye: .left, device: simd_float4(100, 100, 100, 100), insetDeg: 0, marginDeg: 2),
              [Double(tan89), Double(tan89), Double(tan89), Double(tan89)], "edge angle < 89 deg", tolerance: 1e-3)
        near4(CropFov.tangents(eye: .left, device: simd_float4(100, 100, 100, 100), insetDeg: 15, marginDeg: 60),
              [Double(tan89), Double(tan89), Double(tan89), Double(tan89)], "margin cannot pass 89 deg", tolerance: 1e-3)
        let negative = CropFov.tangents(eye: .left, device: simd_float4(-0.5, 1.0, 1.0, -0.2), insetDeg: 15, marginDeg: 2)
        expect(negative != nil && negative!.x >= 0 && negative!.w >= 0, "sent tangents are >= 0")
        expect(negative!.x == 0 && negative!.w == 0, "a negative device side is sent as 0")

        // Display: Renderer.swift:708 puts the sent tangents in Uniforms.tangents, packed from the sent Fov by
        // ViewLayout.uniformTangents (left, right, up, down |tan|; Extensions/RealityKit.swift), and the video vertex
        // shader (Shaders.metal:205-216) builds the frame quad from them: x from -[0] to [1], y from -[3] to [2] at
        // depth 1. So the cropped frame lands on its own tangent rectangle; the device projection (real tangents) maps
        // that onto the drawable and the rest of the drawable keeps the black clear (Renderer.swift beginRenderStreamingFrame).
        let angles = ViewLayout.fovAngles(tangents: on.tangents[0], scale: 1)
        let uniform = ViewLayout.uniformTangents(left: angles.left, right: angles.right, up: angles.up, down: angles.down)
        near4(uniform, [1.072395, 0.624869, 0.624869, 0.753584], "uniform order left, right, up, down", tolerance: 1e-5)
        let quad = ViewLayout.videoQuadRect(uniformTangents: uniform)
        near(Double(quad.left), -1.072395, "quad left edge at the sent left tangent", tolerance: 1e-5)
        near(Double(quad.right), 0.624869, "quad right edge", tolerance: 1e-5)
        near(Double(quad.bottom), -0.753584, "quad bottom edge at the sent down tangent", tolerance: 1e-5)
        near(Double(quad.top), 0.624869, "quad top edge", tolerance: 1e-5)
        // FovPacking-style hand values: the device frustum gives the device quad (60/45/50/45 deg).
        let full = ViewLayout.fovAngles(tangents: deviceL, scale: 1)
        let fullQuad = ViewLayout.videoQuadRect(uniformTangents: ViewLayout.uniformTangents(left: full.left, right: full.right, up: full.up, down: full.down))
        near(Double(fullQuad.left), -1.7321, "device quad left", tolerance: 1e-4)
        near(Double(fullQuad.right), 1.0, "device quad right", tolerance: 1e-4)
        near(Double(fullQuad.bottom), -1.1918, "device quad bottom", tolerance: 1e-4)
        near(Double(fullQuad.top), 1.0, "device quad top", tolerance: 1e-4)
        // The cropped quad covers (1.697264 x 1.378453) / (2.7321 x 2.1918) = 39.1% of the device frustum's tangent area.
        let area = Double((quad.right - quad.left) * (quad.top - quad.bottom)) / (2.7321 * 2.1918)
        near(area, 1.697264 * 1.378453 / (2.7321 * 2.1918), "cropped quad area fraction", tolerance: 1e-5)

        // Fixture shared with test_fovmatrix.py (avp-sharpness.py crop): the same inputs give the same numbers.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/diag/fixtures/crop-fov.json").standardized
        if let data = try? Data(contentsOf: fixture),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = root["device_tan_LRDU"] as? [String: [Double]],
           let c = root["center_size"] as? [Double], c.count == 2,
           let cases = root["cases"] as? [[String: Any]], !cases.isEmpty {
            // The fixture's crop is the model lens's inset rectangle.
            expectEqual(root["model"] as? String, BoundaryDotsLensModel.tag, "fixture model = compiled model")
            func four(_ v: [Double]?) -> simd_float4? {
                guard let v, v.count == 4 else { return nil }
                return simd_float4(Float(v[0]), Float(v[1]), Float(v[2]), Float(v[3]))
            }
            for item in cases {
                let name = item["name"] as? String ?? "?"
                guard let eye = BoundaryDotsEye(rawValue: item["eye"] as? String ?? ""),
                      let dev = four(devices[eye.rawValue]), let other = four(devices[eye == .left ? "R" : "L"]),
                      let inset = item["inset_deg"] as? Double, let margin = item["margin_deg"] as? Double,
                      let want = item["expect"] as? [String: Any], let sent = want["sent_tan_LRDU"] as? [Double],
                      let shift = want["center_shift"] as? [Double], shift.count == 2 else {
                    expect(false, "fixture case \(name) malformed")
                    continue
                }
                let got = CropFov.tangents(eye: eye, device: dev, insetDeg: inset, marginDeg: margin)
                near4(got, sent, "fixture \(name) sent", tolerance: 1e-4)
                let mirror = CropFov.tangents(eye: eye == .left ? .right : .left, device: other, insetDeg: inset, marginDeg: margin)
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
