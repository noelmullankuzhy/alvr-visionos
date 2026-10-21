import Foundation

// Immutable attribution captured by asynchronous callbacks for one player item.
struct PQPlaybackContext {
    let clip, path: String
    func statusFields(status: Int, error: String) -> KeyValuePairs<String, Any> {
        ["path": path, "clip": clip, "status": status, "error": error]
    }
    func metadataErrorFields(_ error: String) -> KeyValuePairs<String, Any> {
        ["path": path, "clip": clip, "metadata_error": error]
    }
}

// tools/diag/clip-engine.swift: seven two-second levels, last level held on extension.
enum PQSchedule {
    static func step(time: Double, isSteps: Bool) -> Int {
        guard isSteps, time.isFinite, time >= 0 else { return -1 }
        return Int(min(6, time / 2))
    }
}

enum EDRLayout: String, CaseIterable {
    case onePercent = "1%", tenPercent = "10%", full = "100%", split, checkerboard
    case pairOne = "pair 1%", pairFive = "pair 5%", pairTwenty = "pair 20%"
    case gridOne = "grid 1%", gridTen = "grid 10%", gridFifty = "grid 50%"
    var pairArea: Double? {
        switch self { case .pairOne: return 0.01; case .pairFive: return 0.05; case .pairTwenty: return 0.2; default: return nil }
    }
    var gridArea: Double? {
        switch self { case .gridOne: return 0.01; case .gridTen: return 0.1; case .gridFifty: return 0.5; default: return nil }
    }
    var isComparison: Bool { self == .split || pairArea != nil }
    struct Patch {
        let x, y, width, height: Double
        let value: Float
    }
    func patches(value: Float, centre: SIMD2<Double> = SIMD2(0.5, 0.5), aspect: Double = 1,
                 grid: EDRGrid = EDRGrid(), pixelHeight: Double = 1000) -> [Patch] {
        if let area = pairArea {
            let w = sqrt(area / 2 / aspect), h = w * aspect
            return [Patch(x: centre.x - 1.5 * w, y: centre.y - h / 2, width: w, height: h, value: 1),
                    Patch(x: centre.x + 0.5 * w, y: centre.y - h / 2, width: w, height: h, value: value)]
        }
        if let area = gridArea {
            // Twenty-five lit squares plus four 2-physical-pixel seams per axis.
            let w = sqrt(area / 25 / aspect), h = w * aspect
            let pitchX = w + 2 / (pixelHeight * aspect), pitchY = h + 2 / pixelHeight
            return grid.entries.enumerated().map { i, entry in
                Patch(x: centre.x + Double(i % 5 - 2) * pitchX - w / 2,
                      y: centre.y + Double(i / 5 - 2) * pitchY - h / 2,
                      width: w, height: h, value: entry.value)
            }
        }

        if self == .split {
            return [Patch(x: 0, y: 0, width: 0.5, height: 1, value: 1),
                    Patch(x: 0.5, y: 0, width: 0.5, height: 1, value: value)]
        }
        if self == .checkerboard {
            return (0..<64).map { i in
                let column = i % 8, row = i / 8
                let bright = (column + row) % 2 != 0
                return Patch(x: Double(column) / 8, y: Double(row) / 8, width: 0.125, height: 0.125, value: bright ? value : 0)
            }
        }
        let side = sqrt(self == .onePercent ? 0.01 : self == .tenPercent ? 0.1 : 1)
        return [Patch(x: (1 - side) / 2, y: (1 - side) / 2, width: side, height: side, value: value)]
    }
}

// Normalized top-left viewport coordinates of the projection's tangent origin.
enum EDRView {
    static func centre(left: Double, right: Double, top: Double, bottom: Double) -> SIMD2<Double> {
        SIMD2(left / (left + right), top / (top + bottom))
    }
    static func centre(projectionX: Double, projectionY: Double) -> SIMD2<Double> {
        SIMD2((1 - projectionX) / 2, (1 + projectionY) / 2)
    }
}

enum EDRImmersion: String, CaseIterable {
    case full, mixed
    static let defaultStyle = EDRImmersion.full
}

enum EDRGridRange: String, CaseIterable { case fine, coarse }

struct EDRGrid {
    struct Entry: Equatable {
        let cell: String
        let value: Float
    }
    var range = EDRGridRange.fine
    var mirror = false
    var entries: [Entry] {
        (0..<25).map { i in
            let row = i / 5, column = i % 5
            let snake = row * 5 + (row % 2 == 0 ? column : 4 - column)
            let index = mirror ? 24 - snake : snake
            let value = range == .fine ? 1 + Double(index) / 24 : 0.5 + Double(index) / 10
            return Entry(cell: "\(String(UnicodeScalar(65 + row)!))\(column + 1)", value: Float(value))
        }
    }
    func fields(_ entry: Entry, layout: EDRLayout, immersion: String) -> KeyValuePairs<String, Any> {
        ["grid": layout.rawValue, "range": range.rawValue, "mirror": mirror ? 1 : 0,
         "cell": entry.cell, "value": entry.value, "immersion": immersion]
    }
    // Small 3x5 glyphs outside the cluster, rendered through the same raw-value pipeline.
    func labels(patches: [EDRLayout.Patch]) -> [EDRLayout.Patch] {
        guard patches.count == 25 else { return [] }
        let glyphs = ["010101111101101", "110101110101110", "011100100100011", "110101101101110", "111100110100111",
                      "010110010010111", "110001010100111", "110001010001110", "101101111001001", "111100110001110"]
        let first = patches[0]
        let pixelW = first.width * 0.04, pixelH = first.height * 0.04
        return (0..<10).flatMap { index -> [EDRLayout.Patch] in
            let rowLabel = index < 5
            let patch = patches[rowLabel ? index * 5 : index - 5]
            let x = rowLabel ? first.x - pixelW * 5 : patch.x + (patch.width - pixelW * 3) / 2
            let y = rowLabel ? patch.y + (patch.height - pixelH * 5) / 2 : first.y - pixelH * 7
            return Array(glyphs[index]).enumerated().compactMap { i, bit in
                guard bit == "1" else { return nil }
                return EDRLayout.Patch(x: x + Double(i % 3) * pixelW, y: y + Double(i / 3) * pixelH,
                                       width: pixelW, height: pixelH, value: 0.15)
            }
        }
    }
}

enum EDRAnswer: String, CaseIterable { case brighter, same, darker }

struct EDRStep {
    static let values: [Float] = [0, 0.25, 0.5, 1, 1.25, 1.5, 1.75, 2, 2.5, 4]
    static let fineValues: [Float] = [0.5, 1, 1.25, 1.5, 1.6, 1.7, 1.8, 1.9, 2, 2.2, 2.5, 3, 4]
    var startMs: Int
    var automatic: Bool
    var sustained = false
    var fine = false
    private(set) var index = 0
    var activeValues: [Float] { fine ? Self.fineValues : Self.values }
    mutating func selectFine(_ fine: Bool) {
        if self.fine != fine { self.fine = fine; index = 0 }
    }
    var value: Float { activeValues[index] }
    mutating func next(nowMs: Int) { index = (index + 1) % activeValues.count; startMs = nowMs }
    mutating func back(nowMs: Int) { index = (index + activeValues.count - 1) % activeValues.count; startMs = nowMs }
    mutating func tick(nowMs: Int) -> Bool {
        guard automatic, nowMs - startMs >= (sustained ? 60000 : 4000) else { return false }
        next(nowMs: nowMs)
        return true
    }
    func fields(layout: EDRLayout, immersion: String = "mixed") -> KeyValuePairs<String, Any> {
        ["step": index, "value": value, "layout": layout.rawValue, "mode": automatic ? "auto" : "manual", "hold_s": sustained ? 60 : 4, "immersion": immersion]
    }
    func markFields(layout: EDRLayout, immersion: String = "mixed") -> KeyValuePairs<String, Any> {
        ["mark": true, "value": value, "layout": layout.rawValue, "immersion": immersion]
    }
    func answerFields(_ answer: EDRAnswer, layout: EDRLayout, immersion: String) -> KeyValuePairs<String, Any> {
        ["answer": answer.rawValue, "step": index, "value": value, "layout": layout.rawValue, "immersion": immersion]
    }
}

struct EDRFrame {
    let step: EDRStep
    let layout: EDRLayout
    let grid: EDRGrid
    func patches(centre: SIMD2<Double>, aspect: Double, pixelHeight: Double) -> [EDRLayout.Patch] {
        let patches = layout.patches(value: step.value, centre: centre, aspect: aspect, grid: grid, pixelHeight: pixelHeight)
        return layout.gridArea == nil ? patches : patches + grid.labels(patches: patches)
    }
}

// Only instantiated by the diagnostic window/scene; one lock for UI and compositor render thread.
final class EDRSession {
    static let shared = EDRSession()
    private let lock = NSLock()
    private var step = EDRStep(startMs: 0, automatic: false)
    private var layout = EDRLayout.onePercent
    private var dirty = true
    private var presented: (EDRStep, EDRLayout)?
    private var runID = UUID()
    private var grid = EDRGrid()
    private var immersion = EDRImmersion.defaultStyle.rawValue
    private var gridNeedsLog = true
    func setImmersion(_ immersion: String) {
        lock.lock(); defer { lock.unlock() }
        guard self.immersion != immersion else { return }
        self.immersion = immersion
        dirty = true
        gridNeedsLog = true
    }
    private func logGrid() {
        guard layout.gridArea != nil else { return }
        for entry in grid.entries { Diag.log("edr", grid.fields(entry, layout: layout, immersion: immersion)) }
    }
    var currentRun: UUID {
        lock.lock(); defer { lock.unlock() }
        return runID
    }
    func beginRun() {
        lock.lock(); defer { lock.unlock() }
        runID = UUID()
        presented = nil
        gridNeedsLog = true
        dirty = true
    }
    var currentValue: Float? {
        lock.lock(); defer { lock.unlock() }
        return presented?.0.value
    }
    func configure(layout: EDRLayout, automatic: Bool, sustained: Bool, fine: Bool = false, gridRange: EDRGridRange = .fine, mirror: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let changedLayout = self.layout != layout
        self.layout = layout
        step.selectFine(fine)
        let changedGrid = changedLayout || grid.range != gridRange || grid.mirror != mirror
        grid = EDRGrid(range: gridRange, mirror: mirror)
        if changedGrid {
            gridNeedsLog = true
            if presented != nil {
                logGrid()
                gridNeedsLog = false
            }
        }
        step.automatic = automatic; step.sustained = sustained; step.startMs = Diag.monotonicMs(); dirty = true
    }
    func next() {
        lock.lock(); defer { lock.unlock() }
        guard layout.gridArea == nil else { return }
        step.next(nowMs: Diag.monotonicMs()); dirty = true
    }
    func back() {
        lock.lock(); defer { lock.unlock() }
        guard layout.gridArea == nil else { return }
        step.back(nowMs: Diag.monotonicMs()); dirty = true
    }
    func answer(_ answer: EDRAnswer) {
        lock.lock(); defer { lock.unlock() }
        guard let (shown, shownLayout) = presented, shownLayout.isComparison, !dirty else { return }
        Diag.log("edr", shown.answerFields(answer, layout: shownLayout, immersion: immersion))
        step.next(nowMs: Diag.monotonicMs()); dirty = true
    }
    func frame() -> EDRFrame {
        lock.lock(); defer { lock.unlock() }
        if gridNeedsLog { logGrid(); gridNeedsLog = false }
        let now = Diag.monotonicMs()
        if dirty { step.startMs = now }
        let changed = layout.gridArea == nil && step.tick(nowMs: now)
        if dirty || changed { Diag.log("edr", step.fields(layout: layout, immersion: immersion)); dirty = false }
        presented = (step, layout)
        return EDRFrame(step: step, layout: layout, grid: grid)
    }
    func mark() {
        lock.lock(); defer { lock.unlock() }
        if let (step, layout) = presented { Diag.log("edr", step.markFields(layout: layout, immersion: immersion)) }
    }
}
