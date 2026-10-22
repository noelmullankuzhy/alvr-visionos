// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagFrameCapture.swift ALVRClient/Diagnostics/DiagCapturePose.swift
// The PNG write path of DiagFrameCapture without a GPU: raw readback bytes -> RGBA8 as written to the PNG.
// A linear rgba16Float drawable must come out sRGB-encoded (alpha stays linear); *_srgb bytes are copied; BGRA is swizzled.
import Foundation
import Metal

@main enum DiagCaptureConvertTests {
    static func main() {
        // rgba16Float, 2 pixels, padded row: linear 0.06 / 0.5 / 1.0 / alpha 0.5, then 0 / 0.0031308 / 0.25 / alpha 1.
        let values: [Float16] = [0.06, 0.5, 1.0, 0.5, 0, 0.0031308, 0.25, 1.0]
        var bytes = values.map { $0.bitPattern }
        bytes += [UInt16](repeating: 0, count: 8)   // row padding
        let out = bytes.withUnsafeBytes {
            DiagFrameCapture.rgbaBytes(from: $0.baseAddress!, rowBytes: 32, width: 2, height: 1, format: .rgba16Float)
        }
        expectEqual(out.count, 8, "2 pixels x 4 bytes")
        expectEqual(Array(out[0..<3]), [69, 188, 255], "linear 0.06/0.5/1.0 -> sRGB bytes 69/188/255, not the linear 15/128/255")
        expectEqual(out[3], 128, "alpha 0.5 stays linear (128), not sRGB encoded")
        expectEqual(Array(out[4..<7]), [0, 10, 137], "linear 0 / 0.0031308 / 0.25 -> 0/10/137")
        expectEqual(out[7], 255, "alpha 1 -> 255")

        // 8-bit formats: bytes copied, BGRA swizzled to RGBA.
        let px: [UInt8] = [10, 20, 30, 40]
        let bgra = px.withUnsafeBytes { DiagFrameCapture.rgbaBytes(from: $0.baseAddress!, rowBytes: 4, width: 1, height: 1, format: .bgra8Unorm_srgb) }
        expectEqual(bgra, [30, 20, 10, 40], "bgra8Unorm_srgb copied and swizzled, no second encode")
        let rgba = px.withUnsafeBytes { DiagFrameCapture.rgbaBytes(from: $0.baseAddress!, rowBytes: 4, width: 1, height: 1, format: .rgba8Unorm) }
        expectEqual(rgba, px, "rgba8Unorm copied as is")
        finishTests("DiagCaptureConvert")
    }
}
