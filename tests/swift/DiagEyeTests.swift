// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagEye.swift ALVRClient/Diagnostics/DiagEyeRenderer.swift ALVRClient/Diagnostics/EDRDiagnostic.swift
import Foundation
import Metal
import simd

@main enum DiagEyeTests {
    static func main() throws {
        let flag = EyeBadgeFlag(defaultsValue: nil)
        expect(!flag.enabled, "eye badges default off when no persisted value exists")
        expect(!EyeBadgeFlag(defaultsValue: false).enabled, "persisted off")
        expect(EyeBadgeFlag(defaultsValue: true).enabled, "persisted on restored")
        for enabled in [true, false, true, false] {
            flag.update(defaultsValue: enabled)
            expectEqual(flag.enabled, enabled, "live on/off uses the same cached flag")
        }
        // Diagnostics and stream state must never supply implicit permission to draw.
        for diagnostics in [false, true] {
            for streaming in [false, true] {
                for enabled in [false, true] {
                    expectEqual(DiagEye.shouldDraw(badgesEnabled: enabled, isRealityKit: false), enabled,
                                "explicit setting wins: diagnostics=\(diagnostics), streaming=\(streaming)")
                    expect(!DiagEye.shouldDraw(badgesEnabled: enabled, isRealityKit: true), "RealityKit never draws badges")
                }
            }
        }
        let defaults = UserDefaults(suiteName: "EyeBadgeTests.\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: EyeBadgeFlag.defaultsKey) }
        defaults.set(true, forKey: EyeBadgeFlag.defaultsKey)
        expect(EyeBadgeFlag(defaultsValue: defaults.object(forKey: EyeBadgeFlag.defaultsKey) as? Bool).enabled,
               "persisted opt-in survives flag recreation")
        defaults.set(false, forKey: EyeBadgeFlag.defaultsKey)
        expect(!EyeBadgeFlag(defaultsValue: defaults.object(forKey: EyeBadgeFlag.defaultsKey) as? Bool).enabled,
               "persisted opt-out survives flag recreation")
        // Creating a descriptor needs no Metal device; exercise the factory used by every badge pipeline.
        for format in [MTLPixelFormat.rgba16Float, .bgra8Unorm_srgb] {
            let descriptor = DiagEyeDrawing.pipelineDescriptor(colourFormat: format, depthFormat: .depth32Float)
            expectEqual(descriptor.inputPrimitiveTopology, .triangle, "layer-index vertex output requires triangle topology")
            expectEqual(descriptor.colorAttachments[0].pixelFormat, format, "badge drawable format")
        }
        expectEqual(DiagEye.assign(view: 0, x: -0.032).eye, .left, "left index and offset agree")
        expectEqual(DiagEye.assign(view: 1, x: 0.032).eye, .right, "right index and offset agree")
        expectEqual(DiagEye.assign(view: 0, x: 0.032).eye, .right, "offset wins over reversed view index")
        expect(DiagEye.assign(view: 1, x: -0.032).mismatch, "reversed eye order reports mismatch")
        expect(!DiagEye.assign(view: 0, x: 0).mismatch, "mono view falls back to index")
        expectEqual(DiagEye.left.colour, SIMD4<Float>(0, 1, 1, 1), "cyan at SDR white")
        expectEqual(DiagEye.right.colour, SIMD4<Float>(1, 0, 1, 1), "magenta at SDR white")
        expectEqual(DiagEye.left.glyph, "L", "left glyph")
        expectEqual(DiagEye.right.glyph, "R", "right glyph")
        expect(DiagEye.left.glyphBits != DiagEye.right.glyphBits, "different raster glyphs")
        for t in [SIMD4<Float>(1, 1, 1, 1), SIMD4(1.394, 1.292, 1.3, 1.1), SIMD4(1.292, 1.394, 1.3, 1.1), SIMD4(0.6, 0.8, 0.7, 0.8)] {
            let badge = DiagEye.placement(tangents: t)
            expect(abs(badge.tanX - Double(t.y - t.x) / 2) < 1e-6, "horizontal view centre")
            expect(abs(badge.tanY - Double(t.z) * 0.25) < 1e-6, "quarter of top tangent")
            expect(abs(badge.sizeDegrees - 3) < 1e-9, "three-degree angular size")
            expect(badge.areaFraction > 0 && badge.areaFraction < 0.005, "below 0.5% of field")
            let r = badge.rect, p = EDRLayout.onePercent.patches(value: 4)[0]
            let intersects = r.x < p.x + p.width && r.x + r.z > p.x && r.y < p.y + p.height && r.y + r.w > p.y
            expect(!intersects, "badge never intersects 1% measurement patch")
            expect(r.x > 0.25 && r.x + r.z < 0.75 && r.y > 0.25 && r.y + r.w < 0.75, "inside centred mirror crop")
            let line = Diag.line(topic: "eye_badge", tMs: 1, fields: badge.fields(eye: .left, view: 0, mode: "idle"))
            expect(line.contains("eye=L view=0 colour=cyan") && line.contains("area_frac=") && line.contains("mode=idle"), "badge log contract")
        }
        var logs = DiagEye.LogState()
        expect(logs.shouldLog(eye: .left, mode: "idle", generation: nil), "first eye logged")
        expect(!logs.shouldLog(eye: .left, mode: "idle", generation: nil), "no duplicate")
        expect(logs.shouldLog(eye: .right, mode: "idle", generation: nil), "other eye logged")
        expect(logs.shouldLog(eye: .left, mode: "streaming", generation: 1), "mode transition")
        expect(!logs.shouldLog(eye: .left, mode: "streaming", generation: 1), "same stream")
        expect(logs.shouldLog(eye: .left, mode: "streaming", generation: 2), "restart without idle frame")
        let renderer = try String(contentsOfFile: "ALVRClient/Renderer.swift", encoding: .utf8)
        expect(renderer.contains("Diag.capture(enabled: diagProbe != nil, DiagRenderProbe.timing"), "actual deadline/offset reads gated")
        expect(renderer.contains("Diag.capture(enabled: diagProbe != nil, queuedFrame?.timestamp)"), "actual source ID read gated")
        expect(renderer.contains("diagEye?.encode"), "streaming and idle draw before present")
        expect(renderer.contains("DiagEye.shouldDraw(badgesEnabled: EyeBadgeFlag.shared.enabled, isRealityKit: isRealityKit)"),
               "main renderer gates creation and encoding on live flag")
        expect(!renderer.contains("self.diagEye = layerRenderer != nil && Diag.isOn"), "Diagnostics does not create badges")
        let entry = try String(contentsOfFile: "ALVRClient/Entry/Entry.swift", encoding: .utf8)
        expect(entry.contains("$gStore.settings.eyeBadges"), "UI persists eye badge setting")
        expect(entry.contains("Eye badges (L/R)"), "explicit Advanced Settings label")
        expect(entry.contains("EyeBadgeFlag.shared.update(defaultsValue: LaunchFlags.bool(EyeBadgeFlag.defaultsKey, setting: gStore.settings.eyeBadges))"), "UI updates live cache")
        let ramp = try String(contentsOfFile: "ALVRClient/Diagnostics/EDRRenderer.swift", encoding: .utf8)
        expect(ramp.contains("badge?.encode"), "EDR uses same badge")
        expect(ramp.contains("DiagEye.shouldDraw(badgesEnabled: EyeBadgeFlag.shared.enabled, isRealityKit: false)"),
               "EDR uses the same live opt-in")
        expect(!ramp.contains("badge = Diag.isOn ?"), "EDR Diagnostics does not create badges")
        finishTests("DiagEye")
    }
}
