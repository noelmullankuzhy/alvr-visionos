// SOURCES: ALVRClient/DebugEyeTangents.swift ALVRClient/ViewLayout.swift
// DebugEyeTangents: -ALVRDebugEyeTangents "L:l,r,d,u;R:l,r,d,u" -> per-eye |tan| in gimmeTangents slot order
// (left, right, bottom, top), the order W32's ViewLayout.fovAngles packs (up from .w, down from .z);
// anything malformed is off (nil), so production keeps the drawable's own tangents.
import Foundation
import simd

@main
enum DebugEyeTangentsTests {
    static func main() {
        let avp = "L:1.7321,1.0,1.1918,1.0;R:1.0,1.7321,1.1918,1.0"   // device |tan| L,R,D,U
        guard let t = DebugEyeTangents.parse(avp) else { expect(false, "AVP argument parses"); finishTests("DebugEyeTangents") }
        expectEqual(t.count, 2, "two eyes")
        // Argument order L,R,D,U = gimmeTangents slots x=left, y=right, z=bottom, w=top (W32: AlvrFov.up from .w).
        expectEqual(t[0], simd_float4(1.7321, 1.0, 1.1918, 1.0), "left eye: down goes to z, up to w")
        expectEqual(t[1], simd_float4(1.0, 1.7321, 1.1918, 1.0), "right eye")
        expectEqual(DebugEyeTangents.parse(" R:1.0,1.7321,1.1918,1.0 ; L:1.7321,1.0,1.1918,1.0 ")!, t, "eye order and spaces free")

        // Override through the corrected packing (Renderer: ViewLayout.fovAngles, then DIAG fov_sent): d reaches down,
        // u reaches up, ALVR signs (left and down negative), at fovRenderScale 1.
        for (eye, v, left, right) in [("L", t[0], "-60.00", "45.00"), ("R", t[1], "-45.00", "60.00")] {
            let a = ViewLayout.fovAngles(tangents: v, scale: 1.0)
            let sent = Dictionary(ViewLayout.fovSentFields(eye: eye, left: a.left, right: a.right, up: a.up, down: a.down)
                .map { ($0.key, "\($0.value)") }, uniquingKeysWith: { x, _ in x })
            expectEqual(sent["up"], "45.00", "\(eye) override sends up 45.00 (u = 1.0)")
            expectEqual(sent["down"], "-50.00", "\(eye) override sends down -50.00 (d = 1.1918)")
            expectEqual(sent["left"], left, "\(eye) left")
            expectEqual(sent["right"], right, "\(eye) right")
        }

        expect(DebugEyeTangents.parse(nil) == nil, "absent: off")
        expect(DebugEyeTangents.parse("") == nil, "empty: off")
        expect(DebugEyeTangents.parse("L:1,1,1,1") == nil, "one eye only: off")
        expect(DebugEyeTangents.parse("L:1,1,1;R:1,1,1,1") == nil, "three values: off")
        expect(DebugEyeTangents.parse("L:1,1,1,1;R:1,0,1,1") == nil, "zero tangent: off")
        expect(DebugEyeTangents.parse("L:1,1,1,1;R:1,-1,1,1") == nil, "negative tangent: off")
        expect(DebugEyeTangents.parse("L:1,1,1,1;R:1,nan,1,1") == nil, "nan: off")
        expect(DebugEyeTangents.parse("L:1,1,1,1;L:1,1,1,1") == nil, "duplicate eye: off")
        expect(DebugEyeTangents.parse("L:1,1,1,1;X:1,1,1,1") == nil, "unknown eye: off")

        // capture.json record: requested and reported |tan| L,R,D,U per eye; reported from the AlvrFov angles sent
        // (left, right, up, down signed radians), packed as W32's ViewLayout.fovAngles: up = atan(.w), down = -atan(.z).
        let s: Float = 0.85
        let angles = t.map { v -> simd_float4 in let a = atan(v * s); return simd_float4(-a.x, a.y, a.w, -a.z) }
        expect(abs(angles[0].z - atan(Float(0.85))) < 1e-6 && abs(angles[0].w + atan(Float(0.85 * 1.1918))) < 1e-6,
               "left eye sent up 1.0 x s, down 1.1918 x s")
        let rec = DebugEyeTangents.captureRecord(argument: avp, requested: t, fovRenderScale: s, reportedAngles: angles)
        expectEqual(rec["argument"] as? String, avp, "argument kept verbatim")
        expectEqual(rec["fov_render_scale"] as? Double, Double(s), "scale")
        let requested = rec["requested"] as? [String: [Double]], reported = rec["reported"] as? [String: [Double]]
        expectEqual(requested?["L"] ?? [], [1.7321, 1.0, 1.1918, 1.0].map { Double(Float($0)) }, "requested L in L,R,D,U")
        expectEqual(requested?["R"] ?? [], [1.0, 1.7321, 1.1918, 1.0].map { Double(Float($0)) }, "requested R in L,R,D,U")
        for (eye, want) in [("L", [1.7321, 1.0, 1.1918, 1.0]), ("R", [1.0, 1.7321, 1.1918, 1.0])] {
            let got = reported?[eye] ?? []
            expectEqual(got.count, 4, "reported \(eye) has four")
            for (g, w) in zip(got, want) { expect(abs(g - 0.85 * w) < 1e-5, "reported \(eye) \(g) = 0.85 x \(w)") }
        }
        finishTests("DebugEyeTangents")
    }
}
