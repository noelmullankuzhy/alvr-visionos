// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/EDRDiagnostic.swift
import Foundation

@main enum EDRDiagnosticTests {
    static func main() {
        for layout in EDRLayout.allCases {
            for running in [false, true] {
                var expected: Set<EDRControl> = layout == .match ? [.matchOptions] : layout.gridArea != nil ? [.gridOptions] : [.steps]
                if running {
                    if layout == .match { expected.insert(.matchActions) }
                    else if layout.gridArea != nil { expected.insert(.gridHint) }
                    else if layout.isComparison { expected.formUnion([.answers, .navigation]) }
                    else { expected.formUnion([.navigation, .mark]) }
                }
                expectEqual(edrVisibleControls(layout: layout, running: running), expected, "only relevant EDR controls for \(layout.rawValue), running=\(running)")
            }
        }
        for layout in EDRLayout.allCases {
            for space in [nil, "EDRDiagnostic", "PQDiagnostic", "Other"] as [String?] {
                expectEqual(pqWindowPlaybackAllowed(space: space, layout: layout),
                            space == nil || (space == "EDRDiagnostic" && layout == .match), "window playback rule")
            }
        }
        for tangents in [(1.2, 0.8, 1.1, 0.9), (0.8, 1.3, 0.9, 1.2)] {
            let (left, right, top, bottom) = tangents
            let centre = EDRView.centre(left: left, right: right, top: top, bottom: bottom, horizontalDegrees: -12)
            expect(abs((centre.x * (left + right) - left) - tan(-12 * .pi / 180)) < 1e-12, "12 degrees left in tangent space")
            let projected = EDRView.centre(projectionX: 1 - 2 * left / (left + right),
                                          projectionY: 2 * top / (top + bottom) - 1,
                                          horizontalScale: 2 / (left + right), horizontalDegrees: -12)
            expect(abs(projected.x - centre.x) < 1e-12 && abs(projected.y - centre.y) < 1e-12, "projection and tangents agree")
            let patches = EDRLayout.match.patches(value: 1.2, centre: centre, aspect: 1.25)
            expectEqual(patches.count, 1, "one match patch, no labels")
            let patch = patches[0]
            expect(abs(patch.width * patch.height - 0.05) < 1e-12, "five percent eye area")
            expect(abs(patch.width * 1.25 - patch.height) < 1e-12, "square viewport pixels")
            expect(abs(patch.x + patch.width / 2 - centre.x) < 1e-12 && abs(patch.y + patch.height / 2 - centre.y) < 1e-12, "match at tangent centre")
        }
        var match = EDRMatch()
        expectEqual(match.value, 1, "match starts at SDR white")
        match.adjust(up: true)
        expectEqual(match.value, 1.02, "fine step")
        match.coarse = true
        match.adjust(up: false)
        expectEqual(match.value, 0.92, "coarse step")
        for _ in 0..<100 { match.adjust(up: false) }
        expectEqual(match.value, 0.1, "lower clamp")
        for _ in 0..<100 { match.adjust(up: true) }
        expectEqual(match.value, 4, "upper clamp")
        for result in EDRMatchResult.allCases {
            expectEqual(Diag.line(topic: "edr", tMs: 1, fields: match.fields(result, clip: "level-100-pq.mov", immersion: "full")),
                        "DIAG edr t_ms=1 match=\(result.rawValue) metal_value=4.000 clip=level-100-pq.mov clip_nits=100 immersion=full", "match log")
        }
        expectEqual(EDRMatch.clipNits("level-1000-pq.mp4"), 1000, "clip nits")
        expectEqual(EDRMatch.clipNits("steps-pq.mov"), nil, "non-level clip")
        expectEqual(EDRMatch.clipNits("level-bad-pq.mov"), nil, "invalid level")
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
            expect(abs((l.x + r.x + r.width) / 2 - min(centre.x, 1 - 1.5 * l.width)) < 2e-12, "pair centre fits inward")
            expect(abs(l.y + l.height / 2 - centre.y) < 1e-12, "pair tangent centre y")
        }
        expectEqual(EDRGridRange.allCases.map(\.rawValue), ["fine", "coarse", "knee", "wide"], "grid ranges")
        expect(!EDRGrid().borders, "seamless by default")
        for range in EDRGridRange.allCases {
            let grid = EDRGrid(range: range, mirror: false)
            let mirrored = EDRGrid(range: range, mirror: true)
            expectEqual(grid.entries.count, 25, "25 cells")
            expectEqual(grid.entries.map(\.cell), (0..<25).map { "\(String(UnicodeScalar(65 + $0 / 5)!))\($0 % 5 + 1)" }, "row/column addresses")
            for i in 0..<25 {
                let row = i / 5, col = i % 5
                let snake = row * 5 + (row % 2 == 0 ? col : 4 - col)
                let expected: Double
                switch range {
                case .fine: expected = 1 + Double(snake) / 24
                case .coarse: expected = 0.5 + Double(snake) / 10
                case .knee: expected = 1.30 + Double(snake) / 60
                case .wide: expected = (100.0 / 203.0) * pow(100, Double(snake) / 24)
                }
                expect(abs(Double(grid.entries[i].value) - expected) < 1e-6 * max(1, expected), "snake range")
                if range == .coarse {
                    expectEqual(grid.entries[i].value, Float(5 + snake) / 10, "coarse values match decimal tenths without accumulation")
                }
                expectEqual(mirrored.entries[i].value, grid.entries[24 - i].value, "mirror reverses all 25")
            }
            expectEqual(Diag.line(topic: "edr", tMs: 1, fields: grid.fields(grid.entries[0], layout: .gridTen, immersion: "full")),
                        "DIAG edr t_ms=1 grid=\"grid 10%\" range=\(range.rawValue) surround=black mirror=0 borders=0 cell=A1 value=\(range == .fine ? "1.000" : range == .coarse ? "0.500" : range == .wide ? "0.493" : "1.300") immersion=full", "grid log")
            for (layout, area) in [(EDRLayout.gridOne, 0.01), (.gridTen, 0.1), (.gridFifty, 0.5)] {
                let patches = layout.patches(value: 4, centre: centre, aspect: 1.25, grid: EDRGrid(range: range, borders: true), pixelHeight: 1000)
                expect(abs(patches.reduce(0) { $0 + $1.width * $1.height } - area) < 1e-12, "grid total lit area excludes lines")
                let minX = patches.map(\.x).min()!, maxX = patches.map { $0.x + $0.width }.max()!
                let minY = patches.map(\.y).min()!, maxY = patches.map { $0.y + $0.height }.max()!
                expect(abs((minX + maxX) / 2 - min(centre.x, 1 - (maxX - minX) / 2)) < 2e-12, "grid centre fits inward")
                expect(abs((minY + maxY) / 2 - centre.y) < 1e-12, "grid tangent centre y")
                expect(patches.allSatisfy { abs($0.width * 1250 - $0.height * 1000) < 1e-10 }, "physical squares")
                expect(abs((patches[1].x - patches[0].x - patches[0].width) * 1250 - 2) < 1e-10, "2 physical pixel vertical lines")
                expect(abs((patches[5].y - patches[0].y - patches[0].height) * 1000 - 2) < 1e-10, "2 physical pixel horizontal lines")
                for label in grid.labels(patches: patches) {
                    expect(patches.allSatisfy { p in label.x + label.width <= p.x || label.x >= p.x + p.width || label.y + label.height <= p.y || label.y >= p.y + p.height }, "labels outside every patch")
                    expectEqual(label.value, range == .wide ? Float(100.0 / 203.0) : 0.15, "label level: 0.15, or 100 nits on the wide range")
                }
            }
        }
        // Seamless rectangles partition the cluster, including non-centred, non-square viewports.
        for (layout, area) in [(EDRLayout.gridOne, 0.01), (.gridTen, 0.1), (.gridFifty, 0.5)] {
            for aspect in [0.8, 1.0, 1.25, 1.777] {
                for origin in [SIMD2(0.5, 0.5), centre] {
                    let patches = layout.patches(value: 4, centre: origin, aspect: aspect, pixelHeight: 1837)
                    expectEqual(patches.count, 25, "seamless cell count")
                    let left = patches[0].x, top = patches[0].y
                    let right = patches[4].x + patches[4].width
                    let bottom = patches[20].y + patches[20].height
                    let total = (right - left) * (bottom - top)
                    let sum = patches.reduce(0) { $0 + $1.width * $1.height }
                    expect(abs(total - area) < 1e-12, "seamless cluster area")
                    expect(abs(sum - total) < 1e-12, "union area equals total area")
                    expect(abs((left + right) / 2 - min(origin.x, 1 - (right - left) / 2)) < 2e-12, "seamless fitted centre x")
                    expect(abs((top + bottom) / 2 - min(max(origin.y, (bottom - top) * 0.556), 1 - (bottom - top) / 2)) < 2e-12, "seamless fitted centre y")
                    for (i, patch) in patches.enumerated() {
                        expect(patch.width > 0 && patch.height > 0, "positive cell area")
                        expect(abs(patch.width * aspect - patch.height) < 1e-12, "seamless physical square")
                        if i % 5 < 4 {
                            expectEqual(patch.x + patch.width, patches[i + 1].x, "exact shared vertical edge")
                        }
                        if i / 5 < 4 {
                            expectEqual(patch.y + patch.height, patches[i + 5].y, "exact shared horizontal edge")
                        }
                        for other in patches.dropFirst(i + 1) {
                            let w = min(patch.x + patch.width, other.x + other.width) - max(patch.x, other.x)
                            let h = min(patch.y + patch.height, other.y + other.height) - max(patch.y, other.y)
                            expect(w <= 0 || h <= 0, "no pair of cells overlaps")
                        }
                    }
                }
            }
        }
        // This headset's tangent origin differs per eye. Keep all comparison patches in view.
        for leftEye in [true, false] {
            let eyeCentre = EDRView.centre(left: leftEye ? 1.7321 : 1.0, right: leftEye ? 1.0 : 1.7321,
                                           top: 1.0, bottom: 1.1918)
            for layout in EDRLayout.allCases where layout.pairArea != nil || layout.gridArea != nil {
                for borders in [false, true] {
                    let frame = EDRFrame(step: EDRStep(startMs: 0, automatic: false), layout: layout,
                                         grid: EDRGrid(borders: borders))
                    let aspect = 2.7321 / 2.1918
                    for requested in [eyeCentre, SIMD2(0.02, 0.98), SIMD2(0.98, 0.02)] {
                        let patches = frame.patches(centre: requested, aspect: aspect, pixelHeight: 1000)
                        for patch in patches {
                            expect(patch.x >= 0 && patch.y >= 0 && patch.x + patch.width <= 1 && patch.y + patch.height <= 1,
                                   "every pair/grid patch and label fits viewport for both eyes")
                        }
                        let fields = frame.shiftFields(centre: requested, aspect: aspect, pixelHeight: 1000,
                                                       view: leftEye ? 0 : 1, immersion: "full")
                        if requested != eyeCentre || layout == .pairTwenty {
                            expect(fields != nil, "clipped cluster reports shift")
                            if let fields {
                                let line = Diag.line(topic: "edr", tMs: 1, fields: fields)
                                expect(line.contains(" shifted=1 ") && line.contains("view=\(leftEye ? 0 : 1)"), "shift log identifies eye view")
                            }
                        } else {
                            expect(fields == nil, "fitting cluster needs no shift log")
                        }
                    }
                }
            }
        }
        let wide = EDRGrid(range: .wide).entries.map(\.value).sorted()
        expectEqual(wide.count, 25, "wide has 25 cells")
        expect(abs(wide[0] - 100.0 / 203.0) < 1e-6, "wide first cell is 100 nits = 0.493x")
        expect(abs(wide[12] - 1000.0 / 203.0) < 1e-5, "wide middle is 1,000 nits = 4.926x")
        expect(abs(wide[24] - 10000.0 / 203.0) < 1e-4, "wide last cell is 10,000 nits = 49.26x")
        for i in 1..<25 { expect(wide[i] > wide[i - 1], "wide increases monotonically"); expect(abs(Double(wide[i] / wide[i - 1]) - pow(100, 1.0 / 24)) < 1e-5, "wide x1.212 steps") }
        expectEqual(EDRSurround.allCases.map(\.rawValue), ["black", "sdrWhite"], "surround options")
        expectEqual(EDRSurround.black.value, 0, "black surround is 0")
        expectEqual(EDRSurround.sdrWhite.value, 1, "SDR white surround is 1.0 (203 nits)")
        expectEqual(EDRGrid().surround, .black, "black surround by default")
        expectEqual(Diag.line(topic: "edr", tMs: 1, fields: EDRGrid(range: .wide, surround: .sdrWhite).fields(EDRGrid(range: .wide).entries[24], layout: .gridTen, immersion: "full")),
                    "DIAG edr t_ms=1 grid=\"grid 10%\" range=wide surround=sdrWhite mirror=0 borders=0 cell=E5 value=49.261 immersion=full", "surround logged next to range")
        let knee = EDRGrid(range: .knee).entries.map(\.value).sorted()
        expectEqual(knee.first!, Float(1.30), "knee minimum")
        expectEqual(knee.last!, Float(1.70), "knee maximum")
        for i in 1..<25 {
            expect(abs(Double(knee[i] - knee[i - 1]) - 1.0 / 60) < 2e-7, "equal knee increments")
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
        for (time, index) in [(0.0, 0), (4.999, 0), (5, 1), (35, 7), (40, 7), (60, 7)] {
            expectEqual(PQSchedule.step(time: time, clip: "split-1920x1080-30.mov"), index, "split five-second boundaries")
        }
        expectEqual(PQSchedule.step(time: -1, clip: "split.mov"), -1, "negative split time")
        expectEqual(PQSchedule.step(time: .infinity, clip: "split.mov"), -1, "invalid split time")
        expectEqual(PQSchedule.step(time: 2, clip: "steps.mov"), 1, "existing steps filename")
        expectEqual(PQSchedule.step(time: 2, clip: "gradient.mov"), -1, "gradient filename")
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
        session.configure(layout: .gridTen, automatic: false, sustained: false, gridRange: .knee, mirror: true, borders: true)
        expect(session.frame().grid.borders, "borders reaches submitted frame")
        session.configure(layout: .gridTen, automatic: false, sustained: false, gridRange: .knee, mirror: true, borders: false)
        expect(!session.frame().grid.borders, "borders can be turned off")
        Diag.flush()
        let gridLines = lines.filter { $0.contains(" grid=") }
        expectEqual(gridLines.count, 125, "range and border changes log every cell")
        expectEqual(gridLines.filter { $0.contains(" borders=1 ") }.count, 25, "bordered log batch")
        expectEqual(gridLines.filter { $0.contains(" borders=0 ") }.count, 100, "seamless log batches")
        session.beginRun()
        _ = session.frame()
        Diag.flush()
        expectEqual(lines.filter { $0.contains(" grid=") }.count, 150, "all grid values on new run")
        expect(lines.allSatisfy { $0.hasSuffix("immersion=full") }, "every EDR session line attributes immersion")
        expectEqual(session.frame().surround, 0, "grid surround defaults to black")
        session.configure(layout: .gridTen, automatic: false, sustained: false, gridRange: .wide, surround: .sdrWhite)
        let white = session.frame()
        expectEqual(white.surround, 1, "surround follows the picker")
        expect(abs(white.grid.entries[24].value - 10000.0 / 203.0) < 1e-4, "wide range reaches the frame")
        Diag.flush()
        expect(lines.contains { $0.contains(" range=wide surround=sdrWhite ") }, "surround logged with the grid")
        session.configure(layout: .onePercent, automatic: false, sustained: false, surround: .sdrWhite)
        expectEqual(session.frame().surround, 0, "non-grid layouts keep the black surround")
        session.configure(layout: .match, automatic: true, sustained: false)
        session.beginRun()
        expectEqual(session.frame().matchValue, 1, "new match run starts at one")
        session.next()
        session.recordMatch(.equal, clip: "level-100-pq.mov")
        Diag.flush()
        expect(!lines.contains { $0.contains(" match=") }, "no match while changed value awaits frame")
        let matchFrame = session.frame()
        expectEqual(matchFrame.matchValue, 1.02, "session pinch up")
        expectEqual(matchFrame.patches(centre: SIMD2(0.4, 0.5), aspect: 1, pixelHeight: 1000)[0].value, 1.02, "renderer uses match value")
        session.recordMatch(.equal, clip: "level-100-pq.mov")
        Diag.flush()
        expect(lines.last!.contains("match=1 metal_value=1.020 clip=level-100-pq.mov clip_nits=100 immersion=full"), "records presented match")
        session.back()
        expectEqual(session.frame().matchValue, 1, "session pinch down")
        try? FileManager.default.removeItem(at: logDirectory)
        finishTests("EDRDiagnostic")
    }
}
