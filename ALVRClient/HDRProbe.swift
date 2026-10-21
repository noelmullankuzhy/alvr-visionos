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
// Sink: alvr_log at Info, which ALVR forwards to the streamer ("Client <host>: [Info] [ALVR NATIVE] HDRPROBE ...")
// when the session's extra.logging.client_log_report_level is Info or lower (default Error), and session_log.txt
// keeps it with extra.logging.log_to_disk; ALVR's logger also writes it to the device console. Off: nothing per frame.
//

import Foundation
import CoreVideo
import simd

final class HDRProbe {
    static let enabled = HDRPipeline.probeEnabled(
        environment: ProcessInfo.processInfo.environment,
        defaultsValue: UserDefaults.standard.object(forKey: HDRPipeline.probeKey) == nil ? nil : UserDefaults.standard.bool(forKey: HDRPipeline.probeKey))
    static let shared = HDRProbe()

    private var clock = HDRProbeClock()
    private var loggedUnavailable = false
    private var loggedEightBit = false

    // Render thread, after the frame's planes are bound. Cadence on the monotonic clock; t_ms is wall-clock Unix ms.
    func sample(pixelBuffer: CVPixelBuffer, colour: StreamColourState) {
        guard clock.shouldSample(nowMs: HDRProbeClock.monotonicMs()) else { return }
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
