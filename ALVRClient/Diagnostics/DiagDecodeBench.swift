import AVFoundation
import VideoToolbox

private final class DecodeRun {
    let lock = NSLock()
    var submitted = 0, frames = 0
    var latencies = BoundedDistribution()
    var formats = Set<String>()
    var error: OSStatus = 0
    func update(_ body: (DecodeRun) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
}

enum DiagDecodeBench {
    static func run(cancel: Progress) async -> String {
        guard Diag.isOn else { return "Diagnostics is off" }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag-clips")
        do {
            let clips = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            for clip in clips {
                do {
                    let asset = AVURLAsset(url: clip)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "DecodeBench.no_video", code: -4) }
                    let fps = Double(try await track.load(.nominalFrameRate))
                    guard fps > 0, fps.isFinite else { throw NSError(domain: "DecodeBench.invalid_fps", code: -5) }
                    for count in 1...2 { for paced in [false, true] {
                        if cancel.isCancelled { return "Decode bench stopped" }
                        do { try trial(asset, track, fps: fps, count: count, paced: paced, cancel: cancel) }
                        catch { Diag.log("decode", ["clip": clip.lastPathComponent, "sessions": count, "mode": paced ? "paced" : "max", "err": String(describing: error)]) }
                    } }
                } catch { Diag.log("decode", ["clip": clip.lastPathComponent, "err": String(describing: error)]) }
            }
            return clips.isEmpty ? "No MOV/MP4 clips in Documents/diag-clips" : "Decode bench finished: \(clips.count) clips; inspect errors in Documents/diag"
        } catch {
            Diag.log("decode", ["err": String(describing: error)])
            return "Decode bench: \(error.localizedDescription)"
        }
    }

    private static func trial(_ asset: AVURLAsset, _ track: AVAssetTrack, fps: Double, count: Int, paced: Bool, cancel: Progress) throws {
        let stats = DecodeRun(), group = DispatchGroup()
        var jobs: [(AVAssetReader, AVAssetReaderTrackOutput, CMSampleBuffer, VTDecompressionSession)] = []
        defer { for (reader, _, _, session) in jobs { reader.cancelReading(); VTDecompressionSessionInvalidate(session) } }
        var dimensions = CMVideoDimensions(width: 0, height: 0)
        for _ in 0..<count {
            if cancel.isCancelled { return }
            let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading(), let first = output.copyNextSampleBuffer(), let format = CMSampleBufferGetFormatDescription(first) else {
                throw reader.error ?? NSError(domain: "DecodeBench", code: -1)
            }
            dimensions = CMVideoFormatDescriptionGetDimensions(format)
            var session: VTDecompressionSession?
            let err = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
                imageBufferAttributes: VideoDecoderOutput.attributes(format) as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
            guard err == 0, let session else {
                if let session { VTDecompressionSessionInvalidate(session) }; reader.cancelReading()
                Diag.log("decode", ["clip": asset.url.lastPathComponent, "sessions": count, "mode": paced ? "paced" : "max", "fps": 0, "mpix_s": 0,
                                    "lat_p50_ms": 0, "lat_p95_ms": 0, "dropped": 0, "out_format": "none", "hw": false, "err": err])
                return
            }
            jobs.append((reader, output, first, session))
            if cancel.isCancelled { return }
        }
        let start = ProcessInfo.processInfo.systemUptime
        func pace(_ deadline: Double) {
            while !cancel.isCancelled {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }; Thread.sleep(forTimeInterval: min(0.02, remaining))
            }
        }
        for (reader, output, first, session) in jobs {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let callbacks = DispatchGroup()
                let slots = DispatchSemaphore(value: 8) // bounded outstanding depth per independent session
                var sample: CMSampleBuffer? = first, index = 0
                while let frame = sample, !cancel.isCancelled {
                    if paced && fps > 0 { pace(start + Double(index) / fps) }
                    if cancel.isCancelled { break }
                    guard slots.wait(timeout: .now() + 5) == .success else { stats.update { $0.error = -1 }; break }
                    if cancel.isCancelled { slots.signal(); break }
                    let submittedAt = ProcessInfo.processInfo.systemUptime
                    stats.update { $0.submitted += 1 }; callbacks.enter()
                    let err = VTDecompressionSessionDecodeFrame(session, sampleBuffer: frame, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, flags, image, _, _ in
                        defer { slots.signal(); callbacks.leave() }
                        stats.update { s in
                            if status != 0 { s.error = status }
                            if status == 0, !flags.contains(.frameDropped), let image {
                                s.frames += 1; s.latencies.append((ProcessInfo.processInfo.systemUptime - submittedAt) * 1000)
                                let raw = CVPixelBufferGetPixelFormatType(image)
                                s.formats.insert(String(bytes: [24,16,8,0].map { UInt8((raw >> $0) & 255) }, encoding: .ascii) ?? "\(raw)")
                            }
                        }
                    }
                    if err != 0 { stats.update { $0.error = err }; slots.signal(); callbacks.leave() }
                    index += 1; sample = output.copyNextSampleBuffer()
                }
                if paced && fps > 0 { pace(start + Double(index) / fps) }
                let finish = VTDecompressionSessionFinishDelayedFrames(session)
                let wait = VTDecompressionSessionWaitForAsynchronousFrames(session)
                callbacks.wait() // also cover an unsuccessful VT wait; accepted submissions promise a callback
                stats.update { if finish != 0 || wait != 0 { $0.error = finish != 0 ? finish : wait }; if reader.status == .failed { $0.error = -2 } }
                group.leave()
            }
        }
        group.wait()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        var hardware = true
        for (_, _, _, session) in jobs {
            var property: Unmanaged<CFTypeRef>?
            let err = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &property)
            let value = property?.takeRetainedValue()
            hardware = hardware && err == 0 && (value as? Bool == true)
            stats.update { if err != 0 { $0.error = err }; if err == 0 && value as? Bool != true { $0.error = -3 } }
        }
        stats.update { s in
            let m = DecodeMeasurement(frames: s.frames, submitted: s.submitted, seconds: seconds,
                                      width: Int(dimensions.width), height: Int(dimensions.height), latencies: s.latencies)
            Diag.log("decode", ["clip": asset.url.lastPathComponent, "sessions": count, "mode": paced ? "paced" : "max", "fps": m.fps, "mpix_s": m.mpix,
                                "hist_error_ms": BoundedDistribution.errorMs, "hist_overflow": s.latencies.outOfRange,
                                "lat_p50_ms": m.p50, "lat_p95_ms": m.p95, "dropped": m.dropped, "out_format": s.formats.sorted().joined(separator: ","),
                                "hw": hardware, "err": cancel.isCancelled ? "cancelled" : "\(s.error)", "width": dimensions.width, "height": dimensions.height, "source_fps": fps, "depth_limit": 8])
        }
    }
}
