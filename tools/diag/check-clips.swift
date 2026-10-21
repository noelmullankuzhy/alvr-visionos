#!/usr/bin/env swift
import Foundation
import AVFoundation
import VideoToolbox

struct Invalid: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Invalid(message: message) }
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
        print("PASS \(file.lastPathComponent): Main10 4:2:0, \(count) frames, levelIDC=\(config[12]), \(clip["transfer"]!)")
    }
}
do {
    if CommandLine.arguments.count < 2 { throw Invalid(message: "usage: swift check-clips.swift MANIFEST ...") }
    for path in CommandLine.arguments.dropFirst() { try check(path) }
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
