import Foundation
import AVFoundation
import VideoToolbox

struct Invalid: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Invalid(message: message) }
}
// Decode P010 directly: never judge patch codes through a display/RGB conversion.
func checkSplit(_ clip: [String: Any], asset: AVAsset, track: AVAssetTrack) throws {
    let width = clip["width"] as! Int, height = clip["height"] as! Int
    let fps = clip["fps"] as! Int
    let levels: [Double] = [100, 203, 300, 400, 600, 800, 1000, 203]
    guard let schedule = clip["schedule"] as? [[String: Double]],
          let reference = clip["referenceNits"] as? Double, reference.isFinite, reference > 0, reference <= 10000,
          let seconds = clip["seconds"] as? Double,
          let band = clip["labelBandHeight"] as? Int,
          let digits = clip["digitHeight"] as? Int,
          let gapStart = clip["gapStart"] as? Int, let gapWidth = clip["gapWidth"] as? Int else {
        throw Invalid(message: "missing split manifest fields")
    }
    func code(_ nits: Double) -> Int {
        let p = pow(nits / 10000, 2610.0 / 16384)
        return Int((64 + 876 * pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)).rounded())
    }
    try require(digits >= Int(ceil(Double(height) * 0.08)) && band > digits && band < height, "invalid label band")
    try require(gapWidth == 2 * max(1, Int((Double(width) * 0.01).rounded())) && gapStart == (width - gapWidth) / 2, "invalid 2% gap")
    try require(schedule.count == min(8, Int(ceil(seconds / 5))), "split schedule count")
    for (i, step) in schedule.enumerated() {
        try require(step["startSeconds"] == Double(i * 5) && step["durationSeconds"] == (i == 7 ? seconds - 35 : min(5, seconds - Double(i * 5))), "split timing")
        try require(step["nits"] == levels[i] && step["referenceNits"] == reference && step["lumaCode"] == Double(code(levels[i])) && step["referenceLumaCode"] == Double(code(reference)), "split schedule codes")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    reader.add(output)
    try require(reader.startReading(), "split decode start")
    var frame = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw Invalid(message: "missing decoded image") }
        try require(CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "decoder did not return limited P010")
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) / 2
        let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt16.self)
        let step = min(7, frame / (5 * fps))
        // Interior grids avoid HEVC ringing at patch/gap and band boundaries.
        // Check every frame, including both sides of each schedule boundary.
        for line in Swift.stride(from: band + 16, to: height - 16, by: max(1, height / 16)) {
            for (start, end, expected) in [(16, gapStart - 16, code(reference)),
                                           (gapStart + gapWidth + 16, width - 16, code(levels[step])),
                                           (gapStart + gapWidth / 2, gapStart + gapWidth / 2 + 1, 64)] {
                for x in Swift.stride(from: start, to: end, by: max(1, (end - start) / 16)) {
                    let actual = Int(y[line * stride + x] >> 6)
                    try require(abs(actual - expected) <= 3, "split frame \(frame) at (\(x),\(line)): code \(actual), expected \(expected) ±3")
                }
            }
        }
        frame += 1
    }
    try require(reader.status == .completed && frame == clip["frames"] as? Int, "split decode incomplete")
}

// Independent reconstruction catches manifest ordering/geometry errors as well as
// decoded luma errors. Sample a dense interior lattice on every decoded frame.
func checkGrid(_ clip: [String: Any], asset: AVAsset, track: AVAssetTrack) throws {
    try require(clip["width"] as? Int == 1920 && clip["height"] as? Int == 1080 && clip["fps"] as? Int == 30 && clip["frames"] as? Int == 900 && clip["seconds"] as? Double == 30, "grid dimensions/cadence/duration")
    try require(clip["transfer"] as? String == "SMPTE ST 2084", "grid must be PQ")
    guard let grid = clip["grid"] as? [String: Any], let area = grid["areaPercent"] as? Int,
          [1, 10, 50].contains(area), let range = grid["rangeName"] as? String,
          ["coarse", "fine"].contains(range), let lo = grid["loNits"] as? Double,
          let hi = grid["hiNits"] as? Double, lo.isFinite, hi.isFinite, lo > 0, lo < hi, hi <= 10000,
          let cells = grid["cells"] as? [[String: Any]], cells.count == 25,
          let labels = grid["labels"] as? [[String: Any]], labels.count == 10 else {
        throw Invalid(message: "invalid grid manifest")
    }
    try require(range != "coarse" || (lo == 100 && hi == 10000), "coarse endpoints")
    func code(_ nits: Double) -> Int {
        let p = pow(nits / 10000, 2610.0 / 16384)
        return Int((64 + 876 * pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)).rounded())
    }
    let side = sqrt(Double(1920 * 1080 * area) / 100) / 5
    let ox = (1920 - side * 5) / 2, oy = (1080 - side * 5) / 2
    func ex(_ i: Int) -> Int { Int((ox + Double(i) * side).rounded()) }
    func ey(_ i: Int) -> Int { Int((oy + Double(i) * side).rounded()) }
    try require(abs((grid["cellSide"] as? Double ?? 0) - side) < 1e-9 && abs((grid["originX"] as? Double ?? 0) - ox) < 1e-9 && abs((grid["originY"] as? Double ?? 0) - oy) < 1e-9, "grid continuous geometry")
    let inset = gridBodyInset(cellSide: side)
    var interiors: [(Int, Int, Int, Int, Int)] = []
    for (i, cell) in cells.enumerated() {
        let row = i / 5, col = row % 2 == 0 ? i % 5 : 4 - i % 5
        let nits = i == 0 ? lo : (i == 24 ? hi : lo * pow(hi / lo, Double(i) / 24))
        let bounds = ["x": ex(col), "y": ey(row), "width": ex(col + 1) - ex(col), "height": ey(row + 1) - ey(row)]
        try require(cell["name"] as? String == String(UnicodeScalar(65 + row)!) + String(col + 1) && cell["row"] as? Int == row && cell["column"] as? Int == col, "grid snake order")
        try require(abs((cell["nits"] as? Double ?? 0) - nits) < 1e-7 && cell["lumaCode"] as? Int == code(nits), "grid cell luminance/code")
        try require(cell["bounds"] as? [String: Int] == bounds, "grid cell raster bounds")
        interiors.append((ex(col) + inset, ex(col + 1) - inset, ey(row) + inset, ey(row + 1) - inset, code(nits)))
    }
    var exclusions: [(Int, Int, Int, Int)] = [(ex(0) - 8, ex(5) + 8, ey(0) - 8, ey(5) + 8)]
    for (i, label) in labels.enumerated() {
        let j = i % 5
        let x = i < 5 ? ex(0) - 18 : Int((ox + (Double(j) + 0.5) * side).rounded()) - 5
        let y = i < 5 ? Int((oy + (Double(j) + 0.5) * side).rounded()) - 7 : ey(0) - 22
        let text = i < 5 ? String(UnicodeScalar(65 + j)!) : String(j + 1)
        try require(label["text"] as? String == text && label["bounds"] as? [String: Int] == ["x": x, "y": y, "width": 10, "height": 14], "grid label bounds/text")
        exclusions.append((x - 8, x + 18, y - 8, y + 22))
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    reader.add(output)
    try require(reader.startReading(), "grid decode start")
    var accuracy = Array(repeating: GridBodyAccuracy(), count: 25)
    var frame = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw Invalid(message: "grid missing decoded image") }
        try require(CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "grid decoder must return limited P010")
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let pitch = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) / 2
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt16.self)
        func verify(_ x: Int, _ y: Int, _ expected: Int) throws {
            let actual = Int(luma[y * pitch + x] >> 6)
            try require(abs(actual - expected) <= 3, "grid frame \(frame) at (\(x),\(y)): code \(actual), expected \(expected) ±3")
        }
        for (index, body) in interiors.enumerated() {
            let (x0, x1, y0, y1, expected) = body
            for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 8)) {
                for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 8)) {
                    accuracy[index].add(code: Int(luma[y * pitch + x] >> 6), expected: expected)
                }
            }
        }
        for y in stride(from: 0, to: 1080, by: 8) {
            for x in stride(from: 0, to: 1920, by: 8) where !exclusions.contains(where: { x >= $0.0 && x < $0.1 && y >= $0.2 && y < $0.3 }) { try verify(x, y, 64) }
        }
        frame += 1
    }
    try require(reader.status == .completed && frame == 900, "grid decode incomplete")
    for (index, stats) in accuracy.enumerated() {
        let name = cells[index]["name"] as! String
        print(String(format: "GRID_BODY %@ cell=%@ meanCode=%.3f expected=%d maxAbsError=%d samples=%d insetPx=%d", clip["file"] as! String, name, stats.meanCode, interiors[index].4, stats.maxAbsError, stats.samples, inset))
    }
    try require(accuracy.allSatisfy { $0.samples > 0 && $0.maxAbsError <= 3 }, "grid cell body exceeds ±3 codes; see GRID_BODY accuracy")
}

func checkLevel(_ clip: [String: Any], asset: AVAsset, track: AVAssetTrack) throws {
    try require(clip["width"] as? Int == 1920 && clip["height"] as? Int == 1080 && clip["fps"] as? Int == 30 && clip["frames"] as? Int == 1800 && clip["seconds"] as? Double == 60 && clip["transfer"] as? String == "SMPTE ST 2084", "level format/duration")
    guard let level = clip["level"] as? [String: Any], let nits = level["nits"] as? Double,
          nits.isFinite, nits > 0, nits <= 10000 else { throw Invalid(message: "invalid level manifest") }
    let p = pow(nits / 10000, 2610.0 / 16384)
    let expected = Int((64 + 876 * pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)).rounded())
    let side = sqrt(1920.0 * 1080 * 0.1), ox = (1920 - side) / 2, oy = (1080 - side) / 2
    let x0 = Int(ox.rounded()), x1 = Int((ox + side).rounded())
    let y0 = Int(oy.rounded()), y1 = Int((oy + side).rounded())
    let text = nits == nits.rounded() ? String(Int(nits)) : String(nits)
    let labelWidth = (text.count * 6 - 1) * 4, labelX = (1920 - labelWidth) / 2
    try require(level["lumaCode"] as? Int == expected && level["areaPercent"] as? Int == 10, "level code/area")
    try require(abs((level["side"] as? Double ?? 0) - side) < 1e-9 && abs((level["originX"] as? Double ?? 0) - ox) < 1e-9 && abs((level["originY"] as? Double ?? 0) - oy) < 1e-9, "level continuous geometry")
    try require(level["bounds"] as? [String: Int] == ["x": x0, "y": y0, "width": x1 - x0, "height": y1 - y0], "level raster bounds")
    try require(level["label"] as? String == text && level["labelBounds"] as? [String: Int] == ["x": labelX, "y": 32, "width": labelWidth, "height": 28] && level["labelNits"] as? Int == 100 && level["labelLumaCode"] as? Int == 509, "level label")
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    reader.add(output)
    try require(reader.startReading(), "level decode start")
    var frame = 0
    while let sample = output.copyNextSampleBuffer() {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw Invalid(message: "level missing image") }
        try require(CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "level decoder must return limited P010")
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let pitch = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) / 2
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt16.self)
        for y in stride(from: 0, to: 1080, by: 8) { for x in stride(from: 0, to: 1920, by: 8) {
            let interior = x >= x0 + 8 && x < x1 - 8 && y >= y0 + 8 && y < y1 - 8
            let nearPatch = x >= x0 - 8 && x < x1 + 8 && y >= y0 - 8 && y < y1 + 8
            let nearLabel = x >= labelX - 8 && x < labelX + labelWidth + 8 && y >= 24 && y < 68
            if nearLabel || (nearPatch && !interior) { continue }
            let actual = Int(luma[y * pitch + x] >> 6), target = interior ? expected : 64
            try require(abs(actual - target) <= 3, "level frame \(frame) at (\(x),\(y)): code \(actual), expected \(target) ±3")
        } }
        frame += 1
    }
    try require(reader.status == .completed && frame == 1800, "level decode incomplete")
}

func check(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let clips = root["clips"] as! [[String: Any]]
    try require(!clips.isEmpty, "empty manifest")
    for clip in clips {
        let file = url.deletingLastPathComponent().appendingPathComponent(clip["file"] as! String)
        let asset = AVURLAsset(url: file)
        guard let track = asset.tracks(withMediaType: .video).first,
              let rawDescription = track.formatDescriptions.first else { throw Invalid(message: "missing video format") }
        let desc = rawDescription as! CMFormatDescription
        let ext = (CMFormatDescriptionGetExtensions(desc) as NSDictionary?) ?? [:]
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
        guard let config = atoms?["hvcC"] as? Data, config.count >= 23 else { throw Invalid(message: "missing hvcC") }
        try require(config[1] & 31 == 2, "not Main10")
        try require(config[16] & 3 == 1, "not 4:2:0")
        try require(config[17] & 7 == 2 && config[18] & 7 == 2, "not 10-bit")
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        try require(Int(dimensions.width) == clip["width"] as? Int && Int(dimensions.height) == clip["height"] as? Int, "dimensions differ")
        let recorded = clip["format"] as! [String: Any]
        try require(recorded["levelIDC"] as? Int == Int(config[12]), "manifest level differs")
        if clip["transfer"] as? String == "SMPTE ST 2084" {
            try require(ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String == kCVImageBufferColorPrimaries_ITU_R_2020 as String, "missing BT.2020 primaries")
            try require(ext[kCMFormatDescriptionExtension_TransferFunction] as? String == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, "missing PQ transfer")
            try require(ext[kCMFormatDescriptionExtension_YCbCrMatrix] as? String == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String, "missing BT.2020 NCL matrix")
        }
        try require((ext[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool) != true, "unexpected full range")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try require(reader.startReading(), "reader failed")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(sample)
        }
        try require(reader.status == .completed, "read failed")
        try require(count == clip["frames"] as? Int, "frame count differs")
        let duration = Double(count) / Double(clip["fps"] as! Int)
        try require(abs(CMTimeGetSeconds(track.timeRange.duration) - duration) < 0.002, "duration/fps differs")
        if clip["kind"] as? String == "level" { try checkLevel(clip, asset: asset, track: track) }
        if clip["kind"] as? String == "grid" { try checkGrid(clip, asset: asset, track: track) }
        if clip["kind"] as? String == "split" { try checkSplit(clip, asset: asset, track: track) }
        print("PASS \(file.lastPathComponent): Main10 4:2:0, \(count) frames, levelIDC=\(config[12]), \(clip["transfer"]!)")
    }
}
do {
    if CommandLine.arguments.count < 2 { throw Invalid(message: "usage: swift check-clips.swift MANIFEST ...") }
    for path in CommandLine.arguments.dropFirst() { try check(path) }
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
