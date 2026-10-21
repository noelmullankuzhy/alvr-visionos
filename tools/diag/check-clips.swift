#!/usr/bin/env swift
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
        if clip["kind"] as? String == "split" { try checkSplit(clip, asset: asset, track: track) }
        print("PASS \(file.lastPathComponent): Main10 4:2:0, \(count) frames, levelIDC=\(config[12]), \(clip["transfer"]!)")
    }
}
do {
    if CommandLine.arguments.count < 2 { throw Invalid(message: "usage: swift check-clips.swift MANIFEST ...") }
    for path in CommandLine.arguments.dropFirst() { try check(path) }
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
