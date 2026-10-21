// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/EDRDiagnostic.swift
import Foundation

@main enum EDRDiagnosticTests {
    static func main() {
        expectEqual(EDRStep.values, [0, 0.25, 0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 4], "M2 levels")
        for (layout, area) in [(EDRLayout.onePercent, 0.01), (.tenPercent, 0.1), (.full, 1.0)] {
            let rect = layout.patches(value: 4)[0]
            expect(abs(rect.width * rect.height - area) < 1e-12, "patch area is fraction of each view")
            expect(abs(rect.x + rect.width / 2 - 0.5) < 1e-12, "centred horizontally")
            expect(abs(rect.y + rect.height / 2 - 0.5) < 1e-12, "centred vertically")
            expectEqual(rect.value, Float(4), "raw EDR value above headroom")
        }
        let split = EDRLayout.split.patches(value: 4)
        expectEqual(split.map(\.value), [1, 4], "left SDR reference, right raw test value")
        expectEqual(split.map(\.x), [0, 0.5], "split positions")
        expect(split.allSatisfy { $0.width == 0.5 && $0.height == 1 }, "halves fill view")
        let board = EDRLayout.checkerboard.patches(value: 2.5)
        expectEqual(board.count, 64, "8 by 8 board")
        expectEqual(board.filter { $0.value == 2.5 }.count, 32, "half bright")
        expectEqual(board.prefix(2).map(\.value), [0, 2.5], "alternating columns")
        expectEqual(board[8].value, 2.5, "alternating rows")
        expectEqual(board.reduce(0) { $0 + $1.width * $1.height }, 1, "board covers field")
        var step = EDRStep(startMs: 100, automatic: true)
        expect(!step.tick(nowMs: 4099), "4s boundary exclusive")
        expect(step.tick(nowMs: 4100), "4s boundary inclusive")
        expectEqual(step.index, 1, "one advance")
        expect(step.tick(nowMs: 100000), "late render advances once, never skips unseen values")
        expectEqual(step.index, 2, "no catch-up")
        step = EDRStep(startMs: 0, automatic: false)
        expect(!step.tick(nowMs: 100000), "manual never auto advances")
        step.next(nowMs: 100000)
        expectEqual(step.value, 0.25, "pinch/tap advance")
        step = EDRStep(startMs: 0, automatic: true, sustained: true)
        expect(!step.tick(nowMs: 59999), "sustained 60s")
        expect(step.tick(nowMs: 60000), "sustained boundary")
        for _ in 0..<9 { step.next(nowMs: 60000) }
        expectEqual(step.index, 0, "loop all ten values")
        expectEqual(Diag.line(topic: "edr", tMs: 42, fields: step.fields(layout: .split)),
                    "DIAG edr t_ms=42 step=0 value=0.000 layout=split mode=auto hold_s=60", "step log contract")
        expectEqual(Diag.line(topic: "edr", tMs: 43, fields: step.markFields(layout: .split)),
                    "DIAG edr t_ms=43 mark=true value=0.000 layout=split", "visual threshold marker")
        // Exercise the actual shader entry and make bypass regressions fail without needing a Metal device.
        let shader = try! String(contentsOfFile: "ALVRClient/Shaders.metal")
        let ramp = shader.components(separatedBy: "fragment float4 diagEDRFragment").last!
        expect(ramp.contains("return float4(value, value, value, 1.0)"), "ramp writes raw value")
        expect(!ramp.contains("EDRRollOff") && !ramp.contains("VideoLinearToOutput"), "no shoulder in ramp")
        expect(shader.contains("VideoLinearToOutput(linearSource, gamutToOutput, !REALITYKIT_ENABLED || HDR_PQ, HDR_PQ, EDR_HEADROOM)"), "stream still uses its original shoulder")
        finishTests("EDRDiagnostic")
    }
}
