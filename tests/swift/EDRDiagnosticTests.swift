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
        expectEqual(EDRImmersion.defaultStyle, .full, "EDR defaults to full immersion")
        expectEqual(EDRImmersion.allCases.map(\.rawValue), ["full", "mixed"], "log immersion values")
        let centre = EDRView.centre(projectionX: -0.4, projectionY: 0.2)
        expect(abs(centre.x - 0.7) < 1e-12 && abs(centre.y - 0.6) < 1e-12, "projection tangent origin, top-left viewport")
        expectEqual(EDRView.centre(left: 3, right: 2, top: 4, bottom: 1), SIMD2(0.6, 0.8), "asymmetric tangent ratios")
        for (layout, area) in [(EDRLayout.pairOne, 0.01), (.pairFive, 0.05), (.pairTwenty, 0.2)] {
            let patches = layout.patches(value: 2, centre: centre, aspect: 1.25)
            let l = patches[0], r = patches[1]
            expectEqual(patches.map(\.value), [1, 2], "pair reference and test")
            expect(abs(l.width * l.height * 2 - area) < 1e-12, "total pair area")
            expect(abs(l.width * 1.25 - l.height) < 1e-12, "square in viewport pixels")
            expect(abs(r.x - l.x - 2 * l.width) < 1e-12, "gap equals patch width")
            expect(abs((l.x + r.x + r.width) / 2 - centre.x) < 1e-12, "pair tangent centre x")
            expect(abs(l.y + l.height / 2 - centre.y) < 1e-12, "pair tangent centre y")
        }
        for range in EDRGridRange.allCases {
            let grid = EDRGrid(range: range, mirror: false)
            let mirrored = EDRGrid(range: range, mirror: true)
            expectEqual(grid.entries.count, 25, "25 cells")
            expectEqual(grid.entries.map(\.cell), (0..<25).map { "\(String(UnicodeScalar(65 + $0 / 5)!))\($0 % 5 + 1)" }, "row/column addresses")
            for i in 0..<25 {
                let row = i / 5, col = i % 5
                let snake = row * 5 + (row % 2 == 0 ? col : 4 - col)
                let expected = range == .fine ? 1 + Double(snake) / 24 : 0.5 + Double(snake) / 10
                expect(abs(Double(grid.entries[i].value) - expected) < 1e-6, "snake range")
                expectEqual(mirrored.entries[i].value, grid.entries[24 - i].value, "mirror reverses all 25")
            }
            expectEqual(Diag.line(topic: "edr", tMs: 1, fields: grid.fields(grid.entries[0], layout: .gridTen, immersion: "full")),
                        "DIAG edr t_ms=1 grid=\"grid 10%\" range=\(range.rawValue) mirror=0 cell=A1 value=\(range == .fine ? "1.000" : "0.500") immersion=full", "grid log")
            for (layout, area) in [(EDRLayout.gridOne, 0.01), (.gridTen, 0.1), (.gridFifty, 0.5)] {
                let patches = layout.patches(value: 4, centre: centre, aspect: 1.25, grid: grid, pixelHeight: 1000)
                expect(abs(patches.reduce(0) { $0 + $1.width * $1.height } - area) < 1e-12, "grid total lit area excludes lines")
                let minX = patches.map(\.x).min()!, maxX = patches.map { $0.x + $0.width }.max()!
                let minY = patches.map(\.y).min()!, maxY = patches.map { $0.y + $0.height }.max()!
                expect(abs((minX + maxX) / 2 - centre.x) < 1e-12, "grid tangent centre x")
                expect(abs((minY + maxY) / 2 - centre.y) < 1e-12, "grid tangent centre y")
                expect(patches.allSatisfy { abs($0.width * 1250 - $0.height * 1000) < 1e-10 }, "physical squares")
                expect(abs((patches[1].x - patches[0].x - patches[0].width) * 1250 - 2) < 1e-10, "2 physical pixel vertical lines")
                expect(abs((patches[5].y - patches[0].y - patches[0].height) * 1000 - 2) < 1e-10, "2 physical pixel horizontal lines")
                for label in grid.labels(patches: patches) {
                    expect(patches.allSatisfy { p in label.x + label.width <= p.x || label.x >= p.x + p.width || label.y + label.height <= p.y || label.y >= p.y + p.height }, "labels outside every patch")
                    expectEqual(label.value, 0.15, "dim label")
                }
            }
        }
        expectEqual(EDRStep.fineValues, [0.5, 1, 1.25, 1.5, 1.6, 1.7, 1.8, 1.9, 2, 2.2, 2.5, 3, 4], "fine list")
        var fine = EDRStep(startMs: 0, automatic: false, fine: true)
        fine.back(nowMs: 10)
        expectEqual(fine.value, 4, "back wraps")
        fine.next(nowMs: 20)
        expectEqual(fine.value, 0.5, "next wraps fine")
        expectEqual(fine.startMs, 20, "manual timer reset")
        for answer in EDRAnswer.allCases {
            expectEqual(Diag.line(topic: "edr", tMs: 1, fields: fine.answerFields(answer, layout: .pairOne, immersion: "full")),
                        "DIAG edr t_ms=1 answer=\(answer.rawValue) step=0 value=0.500 layout=\"pair 1%\" immersion=full", "answer log")
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
                    "DIAG edr t_ms=42 step=0 value=0.000 layout=split mode=auto hold_s=60 immersion=mixed", "step log contract")
        expectEqual(Diag.line(topic: "edr", tMs: 43, fields: step.markFields(layout: .split)),
                    "DIAG edr t_ms=43 mark=true value=0.000 layout=split immersion=mixed", "visual threshold marker")
        for (time, index) in [(0.0, 0), (1.999, 0), (2, 1), (12, 6), (14, 6), (60, 6)] {
            expectEqual(PQSchedule.step(time: time, isSteps: true), index, "generator's two-second schedule")
        }
        expectEqual(PQSchedule.step(time: .nan, isSteps: true), -1, "indefinite time")
        expectEqual(PQSchedule.step(time: 2, isSteps: false), -1, "gradient has no steps")
        let window = PQPlaybackContext(clip: "first steps.mov", path: "window")
        let immersive = PQPlaybackContext(clip: "second.mov", path: "realitykit")
        expectEqual(Diag.line(topic: "pq", tMs: 44, fields: window.statusFields(status: 2, error: "cannot open")),
                    "DIAG pq t_ms=44 path=window clip=\"first steps.mov\" status=2 error=\"cannot open\"", "status/error retains originating playback")
        expectEqual(Diag.line(topic: "pq", tMs: 45, fields: immersive.metadataErrorFields("bad format")),
                    "DIAG pq t_ms=45 path=realitykit clip=second.mov metadata_error=\"bad format\"", "metadata failure attribution")
        expectEqual(Diag.line(topic: "pq", tMs: 46, fields: window.metadataErrorFields("late failure")),
                    "DIAG pq t_ms=46 path=window clip=\"first steps.mov\" metadata_error=\"late failure\"", "late callback cannot inherit the next playback's path")
        // Exercise the actual shader entry and make bypass regressions fail without needing a Metal device.
        let shader = try! String(contentsOfFile: "ALVRClient/Shaders.metal", encoding: .utf8)
        let ramp = shader.components(separatedBy: "fragment float4 diagEDRFragment").last!
        expect(ramp.contains("return float4(value, value, value, 1.0)"), "ramp writes raw value")
        expect(!ramp.contains("EDRRollOff") && !ramp.contains("VideoLinearToOutput"), "no shoulder in ramp")
        expect(shader.contains("VideoLinearToOutput(linearSource, gamutToOutput, !REALITYKIT_ENABLED || HDR_PQ, HDR_PQ, EDR_HEADROOM)"), "stream still uses its original shoulder")
        // Exercise actual session events, including submitted attribution and repeated grid toggles.
        let logDirectory = URL(fileURLWithPath: "build/edr-test-logs").appendingPathComponent(UUID().uuidString)
        var lines: [String] = [] // only read after Diag.flush's serial-queue barrier
        Diag.start(enabled: true, directory: logDirectory, console: { lines.append($0) })
        let session = EDRSession()
        session.setImmersion("full")
        session.beginRun()
        session.configure(layout: .pairFive, automatic: false, sustained: false, fine: true)
        session.answer(.brighter)
        Diag.flush()
        expect(lines.isEmpty, "no answer before submission")
        _ = session.frame()
        session.answer(.brighter)
        Diag.flush()
        expect(lines.last!.contains("answer=brighter step=0 value=0.500 layout=\"pair 5%\" immersion=full"), "answer records shown step before advancing")
        expectEqual(session.frame().step.value, 1, "answer advances next step")
        session.back()
        expectEqual(session.frame().step.value, 0.5, "session back")
        session.configure(layout: .gridTen, automatic: false, sustained: false)
        _ = session.frame()
        Diag.flush()
        let initialGridLines = lines.filter { $0.contains(" grid=") }.count
        expectEqual(initialGridLines, 25, "all grid values on entry")
        session.configure(layout: .gridTen, automatic: false, sustained: false, mirror: true)
        session.configure(layout: .gridTen, automatic: false, sustained: false, gridRange: .coarse, mirror: true)
        _ = session.frame()
        Diag.flush()
        expectEqual(lines.filter { $0.contains(" grid=") }.count, 75, "every toggle logged, even between frames")
        session.beginRun()
        _ = session.frame()
        Diag.flush()
        expectEqual(lines.filter { $0.contains(" grid=") }.count, 100, "all grid values on new run")
        expect(lines.allSatisfy { $0.hasSuffix("immersion=full") }, "every EDR session line attributes immersion")
        try? FileManager.default.removeItem(at: logDirectory)
        finishTests("EDRDiagnostic")
    }
}
