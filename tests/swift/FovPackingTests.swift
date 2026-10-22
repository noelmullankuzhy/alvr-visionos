// SOURCES: ALVRClient/ViewLayout.swift
// ViewLayout.fovAngles: gimmeTangents magnitudes (left, right, bottom, top) -> ALVR Fov angles (radians, left/down < 0).
// Device tangents from DIAG corner (diag-20261021T135020Z.log): tan_left 1.7321, tan_right 1.0, tan_bottom 1.1918, tan_top 1.0
// for the left eye, i.e. 60 deg temporal, 45 deg nasal, 50 deg down, 45 deg up. docs/lumen/fov-updown.md.
import simd

@main
enum FovPackingTests {
    static func deg(_ rad: Float) -> Double { Double(rad) * 180 / Double.pi }

    static func near(_ a: Double, _ b: Double, _ what: String) {
        expect(abs(a - b) < 0.01, "\(what): \(a) vs \(b)")
    }

    static func main() {
        let leftEye = simd_float4(1.7321, 1.0, 1.1918, 1.0)
        let l = ViewLayout.fovAngles(tangents: leftEye, scale: 1.0)
        near(deg(l.up), 45.00, "left eye up is tan_top")
        near(deg(l.down), -50.00, "left eye down is -tan_bottom")
        near(deg(l.left), -60.00, "left eye left (temporal)")
        near(deg(l.right), 45.00, "left eye right (nasal)")

        let rightEye = simd_float4(1.0, 1.7321, 1.1918, 1.0)
        let r = ViewLayout.fovAngles(tangents: rightEye, scale: 1.0)
        near(deg(r.up), 45.00, "right eye up")
        near(deg(r.down), -50.00, "right eye down")
        near(deg(r.left), -45.00, "right eye left (nasal)")
        near(deg(r.right), 60.00, "right eye right (temporal)")

        // fovRenderScale scales the tangents before atan.
        let s = ViewLayout.fovAngles(tangents: leftEye, scale: 0.5)
        near(Double(tan(s.up)), 0.5, "scaled up tangent")
        near(Double(tan(-s.down)), 0.5959, "scaled down tangent")

        // DIAG fov_sent fields: degrees, ALVR signs, two decimals; then where the tangents came from (frustum, crop or
        // debug), the crop margin and the center_shift that centres the band on the axis vs the session's.
        let fields = ViewLayout.fovSentFields(eye: "L", left: l.left, right: l.right, up: l.up, down: l.down)
        let dict = Dictionary(fields.map { ($0.key, "\($0.value)") }, uniquingKeysWith: { a, _ in a })
        expectEqual(fields.map { $0.key }, ["eye", "up", "down", "left", "right", "units", "source", "margin_deg", "offset_deg",
                                            "axis_center_shift", "session_center_shift"], "fov_sent key order")
        expectEqual(dict["eye"], "L", "eye")
        expectEqual(dict["up"], "45.00", "up deg")
        expectEqual(dict["down"], "-50.00", "down deg")
        expectEqual(dict["left"], "-60.00", "left deg")
        expectEqual(dict["right"], "45.00", "right deg")
        expectEqual(dict["units"], "deg", "units")
        expectEqual(dict["source"], "frustum", "default source")
        expectEqual(dict["margin_deg"], "off", "no margin without crop")
        expectEqual(dict["offset_deg"], "off", "no offset without crop")
        expectEqual(dict["axis_center_shift"], "off", "no shift without foveation")
        expectEqual(dict["session_center_shift"], "off", "no session shift without foveation")
        let crop = ViewLayout.fovSentFields(eye: "R", left: l.left, right: l.right, up: l.up, down: l.down, source: "crop",
                                            marginDeg: 2, offsetDeg: -1.5, axisCenterShift: [0.140988, -0.030553],
                                            sessionCenterShift: [0.536, -0.159])
        let cropDict = Dictionary(crop.map { ($0.key, "\($0.value)") }, uniquingKeysWith: { a, _ in a })
        expectEqual(cropDict["source"], "crop", "crop source")
        expectEqual(cropDict["margin_deg"], "2", "margin")
        expectEqual(cropDict["offset_deg"], "-1.5", "offset")
        expectEqual(cropDict["axis_center_shift"], "0.141,-0.031", "axis shift, three decimals")
        expectEqual(cropDict["session_center_shift"], "0.536,-0.159", "session shift")

        // Uniform tangents (the video quad's |tan| left, right, up, down; Shaders.metal:205-216) from the sent Fov.
        let u = ViewLayout.uniformTangents(left: l.left, right: l.right, up: l.up, down: l.down)
        near(Double(u.x), 1.7321, "uniform left")
        near(Double(u.y), 1.0, "uniform right")
        near(Double(u.z), 1.0, "uniform up")
        near(Double(u.w), 1.1918, "uniform down")

        finishTests("FovPacking")
    }
}
