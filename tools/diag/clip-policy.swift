import Foundation

// Shared by the CLI and encoder-free tests. A successful callback may contain no image.
enum ClipCallbackResult: Equatable {
    case encoded, dropped, failure(Int32)
}
func classifyClipCallback(status: Int32, hasSample: Bool, frameDropped: Bool) -> ClipCallbackResult {
    if status != 0 { return .failure(status) }
    return frameDropped || !hasSample ? .dropped : .encoded
}

struct ClipCalibrationFailure: Error, CustomStringConvertible {
    let description: String
    let droppedFrames: Int
}

// Inject the encoder/file removal so the actual retry loop can be exercised without VT.
func calibrateClip(bitrate: Int, targeted: Bool, overload: Bool,
                   encode: (Double, Int, Bool) throws -> [String: Any], discard: () throws -> Void,
                   reportRetry: (Double, Int, Double) -> Void = { _, _, _ in }) throws -> [String: Any] {
    var amplitude = 1.0, lower = 0.0, upper = 1.0, encoderRate = bitrate, lastDrops = 0
    var history: [[String: Any]] = []
    for attempt in 1...(targeted ? 8 : 1) {
        var clip = try encode(amplitude, encoderRate, targeted)
        guard let achieved = clip["achievedBitrate"] as? Double, achieved.isFinite, achieved >= 0,
              let drops = clip["droppedFrames"] as? Int, drops >= 0,
              let frames = clip["frames"] as? Int, frames >= 0,
              let requested = clip["requestedFrames"] as? Int, requested > 0, frames + drops == requested else {
            throw ClipCalibrationFailure(description: "invalid encoder frame/bitrate accounting", droppedFrames: 0)
        }
        lastDrops = drops
        history.append(["noiseAmplitude": amplitude, "encoderBitrate": encoderRate,
                        "achievedBitrate": achieved, "droppedFrames": drops])
        clip["overload"] = overload; clip["rateLimited"] = targeted
        clip["rateMode"] = overload ? "overload" : (targeted ? "targeted" : "target-hint")
        clip["bitrateTolerance"] = 0.15; clip["encodeAttempts"] = attempt; clip["calibration"] = history
        // Drops take precedence over rate: even an ALL-dropped, zero-byte trial is over budget.
        if targeted && (drops > 0 || achieved > Double(bitrate) * 1.15) {
            upper = amplitude
            try discard(); reportRetry(achieved, drops, amplitude)
            amplitude = (lower + upper) / 2
            continue
        }
        guard frames > 0, achieved > 0, overload || drops == 0 else {
            try discard()
            throw ClipCalibrationFailure(description: "incomplete non-overload clip or no encoded frames; droppedFrames=\(drops)", droppedFrames: drops)
        }
        if !targeted || abs(achieved / Double(bitrate) - 1) <= 0.15 { return clip }
        try discard(); reportRetry(achieved, drops, amplitude)
        lower = amplitude
        if amplitude < upper { amplitude = (lower + upper) / 2 }
        else { encoderRate = Int(min(Double(Int.max / 4), Double(encoderRate) * min(2, Double(bitrate) / achieved))) }
    }
    throw ClipCalibrationFailure(description: "noise bitrate could not reach ±15% with zero drops after 8 encodes; droppedFrames=\(lastDrops); --stress is uncapped overload", droppedFrames: lastDrops)
}

func pqCode(_ nits: Double) -> UInt16 {
    let p = pow(nits / 10000, 2610.0 / 16384)
    let pq = pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)
    return UInt16((64 + 876 * pq).rounded())
}

// Integer P010 layout and a tiny bitmap alphabet keep labels independent of RGB conversion.
struct SplitClip {
    static let levels: [Double] = [100, 203, 300, 400, 600, 800, 1000, 203]
    let referenceNits: Double
    func gap(width: Int) -> Range<Int> {
        let halfGap = max(1, Int((Double(width) * 0.01).rounded()))
        return (width / 2 - halfGap)..<(width / 2 + halfGap)
    }
    static func digitHeight(height: Int) -> Int { 7 * max(1, Int(ceil(Double(height) * 0.08 / 7))) }
    static func bandHeight(height: Int) -> Int { digitHeight(height: height) + 2 * max(1, height / 50) }
    func patchCode(x: Int, width: Int, step: Int) -> UInt16 {
        if gap(width: width).contains(x) { return 64 }
        return pqCode(x < width / 2 ? referenceNits : Self.levels[min(7, step)])
    }
    func schedule(seconds: Double) -> [[String: Double]] {
        Self.levels.enumerated().filter { Double($0.offset * 5) < seconds }.map {
            let start = Double($0.offset * 5)
            return ["startSeconds": start, "durationSeconds": $0.offset == 7 ? seconds - start : min(5, seconds - start),
                    "nits": $0.element, "lumaCode": Double(pqCode($0.element)),
                    "referenceNits": referenceNits, "referenceLumaCode": Double(pqCode(referenceNits))]
        }
    }
    func labelRows(width: Int, height: Int, step: Int) -> [[UInt16]] {
        let scale = Self.digitHeight(height: height) / 7
        let padding = max(1, height / 50)
        var rows = Array(repeating: Array(repeating: UInt16(64 << 6), count: width), count: Self.bandHeight(height: height))
        let glyphs: [Character: [String]] = [
            "0": ["11111","10001","10011","10101","11001","10001","11111"],
            "1": ["00100","01100","00100","00100","00100","00100","01110"],
            "2": ["11110","00001","00001","11110","10000","10000","11111"],
            "3": ["11110","00001","00001","01110","00001","00001","11110"],
            "4": ["10010","10010","10010","11111","00010","00010","00010"],
            "5": ["11111","10000","10000","11110","00001","00001","11110"],
            "6": ["01111","10000","10000","11110","10001","10001","01110"],
            "7": ["11111","00001","00010","00100","01000","01000","01000"],
            "8": ["01110","10001","10001","01110","10001","10001","01110"],
            "9": ["01110","10001","10001","01111","00001","00001","11110"],
            "R": ["11110","10001","10001","11110","10100","10010","10001"],
            "E": ["11111","10000","10000","11110","10000","10000","11111"],
            "F": ["11111","10000","10000","11110","10000","10000","10000"],
            ".": ["00000","00000","00000","00000","00000","00100","00100"]]
        let ref = referenceNits == referenceNits.rounded() ? String(Int(referenceNits)) : String(referenceNits)
        for (half, text) in ["REF " + ref, String(Int(Self.levels[min(7, step)]))].enumerated() {
            let origin = half * width / 2 + (width / 2 - (text.count * 6 - 1) * scale) / 2
            for (index, character) in text.enumerated() {
                guard let glyph = glyphs[character] else { continue }
                for (gy, line) in glyph.enumerated() {
                    for (gx, bit) in line.enumerated() where bit == "1" {
                        for dy in 0..<scale { for dx in 0..<scale {
                            let x = origin + (index * 6 + gx) * scale + dx
                            if x >= half * width / 2 && x < (half + 1) * width / 2 && !gap(width: width).contains(x) {
                                rows[padding + gy * scale + dy][x] = pqCode(203) << 6
                            }
                        } }
                    }
                }
            }
        }
        return rows
    }
}

struct GridRect {
    let x, y, width, height: Int
    func intersects(_ other: GridRect) -> Bool {
        x < other.x + other.width && x + width > other.x && y < other.y + other.height && y + height > other.y
    }
    var fields: [String: Int] { ["x": x, "y": y, "width": width, "height": height] }
}

// Continuous squares give the exact requested area. Shared rounded boundaries
// rasterize them without seams; a raster cell can differ by one pixel per axis.
struct GridClip {
    struct Cell {
        let name: String
        let row, column: Int
        let nits: Double
        var code: UInt16 { pqCode(nits) }
    }
    struct Label {
        let text: String
        let rect: GridRect
    }
    struct InvalidGrid: Error { let message: String }
    let area: Int
    let range: String
    let lo, hi: Double
    let width = 1920, height = 1080
    var side: Double { sqrt(Double(width * height * area) / 100) / 5 }
    var originX: Double { (Double(width) - 5 * side) / 2 }
    var originY: Double { (Double(height) - 5 * side) / 2 }
    init(area: Int, range: String, lo: Double = 600, hi: Double = 2000) throws {
        guard [1, 10, 50].contains(area), ["coarse", "fine"].contains(range),
              lo.isFinite, hi.isFinite, lo > 0, lo < hi, hi <= 10000 else {
            throw InvalidGrid(message: "grid requires --area 1|10|50, --range coarse|fine, 0 < --lo < --hi <= 10000")
        }
        self.area = area; self.range = range
        self.lo = range == "coarse" ? 100 : lo
        self.hi = range == "coarse" ? 10000 : hi
    }
    var cells: [Cell] {
        (0..<25).map { i in
            let row = i / 5, column = row % 2 == 0 ? i % 5 : 4 - i % 5
            let nits = i == 0 ? lo : (i == 24 ? hi : lo * pow(hi / lo, Double(i) / 24))
            return Cell(name: String(UnicodeScalar(65 + row)!) + String(column + 1), row: row, column: column, nits: nits)
        }
    }
    private func edgeX(_ index: Int) -> Int { Int((originX + Double(index) * side).rounded()) }
    private func edgeY(_ index: Int) -> Int { Int((originY + Double(index) * side).rounded()) }
    var gridBounds: GridRect { GridRect(x: edgeX(0), y: edgeY(0), width: edgeX(5) - edgeX(0), height: edgeY(5) - edgeY(0)) }
    func bounds(_ cell: Cell) -> GridRect {
        GridRect(x: edgeX(cell.column), y: edgeY(cell.row), width: edgeX(cell.column + 1) - edgeX(cell.column), height: edgeY(cell.row + 1) - edgeY(cell.row))
    }
    var labels: [Label] {
        let b = gridBounds
        return (0..<5).map { i in
            Label(text: String(UnicodeScalar(65 + i)!), rect: GridRect(x: b.x - 18, y: Int((originY + (Double(i) + 0.5) * side).rounded()) - 7, width: 10, height: 14))
        } + (0..<5).map { i in
            Label(text: String(i + 1), rect: GridRect(x: Int((originX + (Double(i) + 0.5) * side).rounded()) - 5, y: b.y - 22, width: 10, height: 14))
        }
    }
    func raster() -> [UInt16] {
        var pixels = [UInt16](repeating: 64 << 6, count: width * height)
        for cell in cells {
            let r = bounds(cell)
            let value = cell.code << 6
            for y in r.y..<(r.y + r.height) { for x in r.x..<(r.x + r.width) { pixels[y * width + x] = value } }
        }

        for label in labels {
            for (gy, line) in clipGlyphs[label.text]!.enumerated() {
                for (gx, bit) in line.enumerated() where bit == "1" {
                    for dy in 0..<2 { for dx in 0..<2 {
                        pixels[(label.rect.y + gy * 2 + dy) * width + label.rect.x + gx * 2 + dx] = pqCode(100) << 6
                    } }
                }
            }
        }
        return pixels
    }
    var manifest: [String: Any] {
        ["areaPercent": area, "rangeName": range, "loNits": lo, "hiNits": hi,
         "cellSide": side, "originX": originX, "originY": originY,
         "rasterBounds": gridBounds.fields, "rasterAreaPercent": Double(gridBounds.width * gridBounds.height) * 100 / Double(width * height),
         "labelNits": 100, "labelLumaCode": Int(pqCode(100)),
         "labels": labels.map { ["text": $0.text, "bounds": $0.rect.fields] as [String: Any] },
         "cells": cells.map { ["name": $0.name, "row": $0.row, "column": $0.column, "nits": $0.nits, "lumaCode": Int($0.code), "bounds": bounds($0).fields] as [String: Any] }]
    }
}

let clipGlyphs: [String: [String]] = [
            "e": ["00000","00000","01110","10001","11111","10000","01111"],
            "-": ["00000","00000","00000","11111","00000","00000","00000"],
            "+": ["00000","00100","00100","11111","00100","00100","00000"],
            "A": ["01110","10001","10001","11111","10001","10001","10001"],
            "B": ["11110","10001","10001","11110","10001","10001","11110"],
            "C": ["01111","10000","10000","10000","10000","10000","01111"],
            "D": ["11110","10001","10001","10001","10001","10001","11110"],
            "E": ["11111","10000","10000","11110","10000","10000","11111"],
            "1": ["00100","01100","00100","00100","00100","00100","01110"],
            "2": ["11110","00001","00001","11110","10000","10000","11111"],
            "3": ["11110","00001","00001","01110","00001","00001","11110"],
            "4": ["10010","10010","10010","11111","00010","00010","00010"],
            "5": ["11111","10000","10000","11110","00001","00001","11110"],
            "0": ["01110","10001","10011","10101","11001","10001","01110"],
            "6": ["01111","10000","10000","11110","10001","10001","01110"],
            "7": ["11111","00001","00010","00100","01000","01000","01000"],
            "8": ["01110","10001","10001","01110","10001","10001","01110"],
            "9": ["01110","10001","10001","01111","00001","00001","11110"],
            ".": ["00000","00000","00000","00000","00000","00100","00100"]]

struct LevelClip {
    let nits: Double
    let width = 1920, height = 1080
    var code: UInt16 { pqCode(nits) }
    var side: Double { sqrt(Double(width * height) * 0.1) }
    var originX: Double { (Double(width) - side) / 2 }
    var originY: Double { (Double(height) - side) / 2 }
    var text: String { nits == nits.rounded() ? String(Int(nits)) : String(nits) }
    init(nits: Double) throws {
        guard nits.isFinite, nits > 0, nits <= 10000 else { throw GridClip.InvalidGrid(message: "level requires 0 < --nits <= 10000") }
        self.nits = nits
    }
    var bounds: GridRect {
        let x = Int(originX.rounded()), y = Int(originY.rounded())
        return GridRect(x: x, y: y, width: Int((originX + side).rounded()) - x, height: Int((originY + side).rounded()) - y)
    }
    var labelBounds: GridRect {
        let w = (text.count * 6 - 1) * 4
        return GridRect(x: (width - w) / 2, y: 32, width: w, height: 28)
    }
    func raster() -> [UInt16] {
        var pixels = [UInt16](repeating: 64 << 6, count: width * height)
        let b = bounds, value = code << 6
        for y in b.y..<(b.y + b.height) { for x in b.x..<(b.x + b.width) { pixels[y * width + x] = value } }
        for (i, character) in text.enumerated() {
            for (gy, line) in clipGlyphs[String(character)]!.enumerated() {
                for (gx, bit) in line.enumerated() where bit == "1" {
                    for dy in 0..<4 { for dx in 0..<4 {
                        pixels[(labelBounds.y + gy * 4 + dy) * width + labelBounds.x + (i * 6 + gx) * 4 + dx] = pqCode(100) << 6
                    } }
                }
            }
        }
        return pixels
    }
    var manifest: [String: Any] {
        ["nits": nits, "lumaCode": Int(code), "areaPercent": 10, "side": side,
         "originX": originX, "originY": originY, "bounds": bounds.fields,
         "rasterAreaPercent": Double(bounds.width * bounds.height) * 100 / Double(width * height),
         "label": text, "labelBounds": labelBounds.fields, "labelNits": 100, "labelLumaCode": Int(pqCode(100))]
    }
}
