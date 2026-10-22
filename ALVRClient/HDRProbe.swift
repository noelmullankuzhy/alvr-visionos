//
//  HDRProbe.swift
//
// HDR oracle log (GM decision 63): with ALVR_HDR_PROBE on (env or UserDefaults, HDRPipeline.probeEnabled), every
// 250 ms one line per eye for the centre of each eye image of the decoded frame:
//   HDRPROBE t_ms=<unix ms> eye=<L|R> code=<Y,Cb,Cr> nits=<R,G,B>
// code: the decoded Y'CbCr codes read from the bound pixel buffer, at its plane depth (10-bit; 8-bit when the decoder
// returned 8-bit planes for a PQ stream, announced once by an `HDRPROBE plane_bits=8` line); nits: those codes through the shader's
// colour conversion (HDRPipeline.decodeNits: yuvToRGB + ST 2084 EOTF, linear BT.2020, before the output matrix and
// roll-off). The eye centre is the centre of each half of the side-by-side frame; with foveated encoding that is the
// foveation centre only when CENTER_SHIFT is 0, which the decision-63 full-field frames make irrelevant.
// Every 1 s, a utility-queue scan also emits HDRSTATS per eye (step=4, decoded max-channel nits).
// Counts are grid samples, not full-resolution source pixels; see HDRPipeline.frameStats for cost/percentiles.
// Sink: alvr_log at Info, which ALVR forwards to the streamer ("Client <host>: [Info] [ALVR NATIVE] HDRPROBE ...")
// when the session's extra.logging.client_log_report_level is Info or lower (default Error), and session_log.txt
// keeps it with extra.logging.log_to_disk; ALVR's logger also writes it to the device console. Off: nothing per frame.
//

import Foundation
import CoreVideo
import simd

final class HDRProbe {
    private static let flag = HDRProbeFlag(
        environment: ProcessInfo.processInfo.environment,
        defaultsValue: LaunchFlags.bool(HDRPipeline.probeKey, setting: ALVRClientApp.gStore.settings.hdrProbe))
    static let shared = HDRProbe()

    static var enabled: Bool { flag.enabled }

    static func updateEnabled(defaultsValue: Bool) {
        flag.update(defaultsValue: defaultsValue)
    }

    private var clock = HDRProbeClock()
    private var statsClock = HDRProbeClock(intervalMs: 1000)
    private let statsQueue = DispatchQueue(label: "ALVR.HDRStats", qos: .utility)
    private let statsAvailable = DispatchSemaphore(value: 1)
    private var loggedUnavailable = false
    private var loggedEightBit = false

    // Render thread, after the frame's planes are bound. Cadence on the monotonic clock; t_ms is wall-clock Unix ms.
    func sample(pixelBuffer: CVPixelBuffer, colour: StreamColourState) {
        guard Self.enabled else { return }
        let monotonicMs = HDRProbeClock.monotonicMs()
        // Independent of the centre cadence, including when a stats sample is dropped as busy.
        if colour.hdrPQ, colour.selection.planeBitDepth == 10,
           HDRPipeline.pqPlaneBitDepth(pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)) == 10,
           CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
           statsClock.shouldSample(nowMs: monotonicMs) {
            scheduleStats(pixelBuffer: pixelBuffer, selection: colour.selection)
        }
        guard clock.shouldSample(nowMs: monotonicMs) else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let selection = colour.selection
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        // hdrPQ: raw 8- or 10-bit planes, checked against this frame's actual pixel format (StreamColourState).
        guard colour.hdrPQ, CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            if !loggedUnavailable {
                loggedUnavailable = true
                emit("HDRPROBE unavailable transfer=\(selection.transfer.rawValue) pixel_format=\(ColourPipeline.fourCC(format)) dropped=\(colour.dropFrames)")
            }
            return
        }
        let bits = selection.planeBitDepth
        if bits == 8 && !loggedEightBit {
            loggedEightBit = true
            emit("HDRPROBE plane_bits=8 pixel_format=\(ColourPipeline.fourCC(format)): codes below are 8-bit")
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let shift = bits <= 8 ? 1 : Double(1 << (16 - bits))
        for (eye, x) in [("L", width / 4), ("R", width * 3 / 4)] {
            guard let luma = word(pixelBuffer, plane: 0, x: x, y: height / 2, component: 0, bytes: bits <= 8 ? 1 : 2),
                  let cb = word(pixelBuffer, plane: 1, x: x, y: height / 2, component: 0, bytes: bits <= 8 ? 1 : 2),
                  let cr = word(pixelBuffer, plane: 1, x: x, y: height / 2, component: 1, bytes: bits <= 8 ? 1 : 2) else { return }
            let code = simd_double3(Double(luma) / shift, Double(cb) / shift, Double(cr) / shift)
            emit(HDRPipeline.probeLine(tMs: nowMs, eye: eye, code: code, nits: HDRPipeline.decodeNits(codes: code, selection: selection)))
        }
    }

    // Only admission/dispatch happens on the render thread. The closure strongly retains the decoded
    // buffer until the scan completes. One in-flight buffer, no backlog; busy samples are dropped.
    private func scheduleStats(pixelBuffer: CVPixelBuffer, selection: ColourSelection) {
        guard statsAvailable.wait(timeout: .now()) == .success else { return }
        let tMs = Int(Date().timeIntervalSince1970 * 1000)
        statsQueue.async(execute: DispatchWorkItem { [self, pixelBuffer] in
            defer { statsAvailable.signal() }
            guard Self.enabled,
                  CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / 2
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / 2
            let luma = UnsafeBufferPointer(start: yBase.assumingMemoryBound(to: UInt16.self), count: yStride * height)
            let chroma = UnsafeBufferPointer(start: uvBase.assumingMemoryBound(to: UInt16.self), count: uvStride * chromaHeight)
            let stats = HDRPipeline.frameStats(luma: luma, lumaStride: yStride, chroma: chroma, chromaStride: uvStride,
                                              width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height: height,
                                              chromaWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), chromaHeight: chromaHeight,
                                              selection: selection)
            guard Self.enabled else { return }
            for eye in stats { emit(eye.line(tMs: tMs)) }
        })
    }

    // 8- or 16-bit component at luma coordinates (x, y), scaled to the plane's own size (chroma subsampling).
    private func word(_ buffer: CVPixelBuffer, plane: Int, x: Int, y: Int, component: Int, bytes: Int) -> UInt16? {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
        let px = x * CVPixelBufferGetWidthOfPlane(buffer, plane) / CVPixelBufferGetWidthOfPlane(buffer, 0)
        let py = y * CVPixelBufferGetHeightOfPlane(buffer, plane) / CVPixelBufferGetHeightOfPlane(buffer, 0)
        let components = plane == 0 ? 1 : 2
        let offset = py * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) + (px * components + component) * bytes
        return bytes == 1 ? UInt16(base.load(fromByteOffset: offset, as: UInt8.self)) : base.load(fromByteOffset: offset, as: UInt16.self)
    }

    private func emit(_ line: String) {
        alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), line)
    }
}
