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

        // DIAG fov_sent fields: degrees, ALVR signs, two decimals.
        let fields = ViewLayout.fovSentFields(eye: "L", left: l.left, right: l.right, up: l.up, down: l.down)
        let dict = Dictionary(fields.map { ($0.key, "\($0.value)") }, uniquingKeysWith: { a, _ in a })
        expectEqual(fields.map { $0.key }, ["eye", "up", "down", "left", "right", "units"], "fov_sent key order")
        expectEqual(dict["eye"], "L", "eye")
        expectEqual(dict["up"], "45.00", "up deg")
        expectEqual(dict["down"], "-50.00", "down deg")
        expectEqual(dict["left"], "-60.00", "left deg")
        expectEqual(dict["right"], "45.00", "right deg")
        expectEqual(dict["units"], "deg", "units")

        finishTests("FovPacking")
    }
}
