// SOURCES: ALVRClient/DebugEyeTangents.swift
// DebugEyeTangents: -ALVRDebugEyeTangents "L:l,r,d,u;R:l,r,d,u" -> per-eye |tan| in Renderer slot order (l, r, up, down);
// anything malformed is off (nil), so production keeps the drawable's own tangents.
import Foundation
import simd

@main
enum DebugEyeTangentsTests {
    static func main() {
        let avp = "L:1.7321,1.0,1.1918,1.0;R:1.0,1.7321,1.1918,1.0"   // device |tan| L,R,D,U
        guard let t = DebugEyeTangents.parse(avp) else { expect(false, "AVP argument parses"); finishTests("DebugEyeTangents") }
        expectEqual(t.count, 2, "two eyes")
        // Argument order L,R,D,U; Renderer slots x=left, y=right, z=up (AlvrFov.up), w=down.
        expectEqual(t[0], simd_float4(1.7321, 1.0, 1.0, 1.1918), "left eye: up goes to z, down to w")
        expectEqual(t[1], simd_float4(1.0, 1.7321, 1.0, 1.1918), "right eye")
        expectEqual(DebugEyeTangents.parse(" R:1.0,1.7321,1.1918,1.0 ; L:1.7321,1.0,1.1918,1.0 ")!, t, "eye order and spaces free")

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
        // (left, right, up, down signed radians).
        let s: Float = 0.85
        let angles = t.map { v -> simd_float4 in let a = atan(v * s); return simd_float4(-a.x, a.y, a.z, -a.w) }
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
