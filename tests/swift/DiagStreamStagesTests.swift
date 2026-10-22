// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagFrameCapture.swift ALVRClient/Diagnostics/DiagCapturePose.swift
// Sharpness chain (docs/lumen/sharpness-chain.md): the per-eye stage plan the renderer draws on a capture frame, the
// capture.json records tools/diag/fov-overlay.py chain reads, and the sampler state recorded against Shaders.metal.
import Foundation
import Metal

@main enum DiagStreamStagesTests {
    static func main() {
        // m7 f070: decoded 4864x1856 (both eyes side by side), stream view 3648x2912, FFR on.
        let plans = DiagStreamStages.plans(decodedWidth: 4864, decodedHeight: 1856, viewWidth: 3648, viewHeight: 2912, ffr: true)
        expectEqual(plans.map { "\($0.stage)-\($0.eye)" }, ["decoded-L", "expanded-L", "decoded-R", "expanded-R"], "two stages per eye")
        let decodedL = plans[0], expandedL = plans[1], decodedR = plans[2]
        expectEqual([decodedL.width, decodedL.height], [2432, 1856], "decoded: the eye's half of the decoded frame, 1:1")
        expect(!decodedL.ffr, "decoded: FFR off (the frame as decoded)")
        expectEqual([expandedL.width, expandedL.height], [3648, 2912], "expanded: the stream view size")
        expect(expandedL.ffr, "expanded: the stream's FFR decompress")
        expectEqual(decodedL.uvRect, SIMD4<Float>(0, 0, 0.5, 1), "left eye: left half of the frame")
        expectEqual(decodedR.uvRect, SIMD4<Float>(0.5, 0, 0.5, 1), "right eye: right half of the frame")
        let off = DiagStreamStages.plans(decodedWidth: 4000, decodedHeight: 2000, viewWidth: 2000, viewHeight: 2000, ffr: false)
        expectEqual([off[1].width, off[1].height], [2000, 2000], "FFR off: expanded is the decoded eye at 1:1")
        expect(!off[1].ffr, "FFR off: no decompress")

        expectEqual(DiagStreamStages.pngName(stage: "decoded", eye: "L"), "stage-decoded-L.png", "PNG name the chain tool expects")
        let sampler = DiagStreamStages.sampler
        expectEqual(Set(sampler.keys), ["min_filter", "mag_filter", "mip_filter", "address", "coord"], "sampler keys")
        expectEqual(sampler["min_filter"] as? String, "linear", "min filter")
        expectEqual(sampler["mag_filter"] as? String, "linear", "mag filter")
        expectEqual(sampler["mip_filter"] as? String, "none", "mip filter")
        expectEqual(sampler["address"] as? String, "clamp_to_edge", "address (Metal default)")
        expectEqual(sampler["coord"] as? String, "normalized", "coord (Metal default)")

        // The recorded sampler is the one the stream shaders declare (both variants), with Metal's default address and coord.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let metal = (try? String(contentsOf: root.appendingPathComponent("ALVRClient/Shaders.metal"), encoding: .utf8)) ?? ""
        for variant in ["YpCbCrBiPlanar", "SecretYpCbCrFormats"] {
            guard let start = metal.range(of: "fragment half4 videoFrameFragmentShader_" + variant),
                  let decl = metal.range(of: "constexpr sampler colorSampler(", range: start.upperBound..<metal.endIndex),
                  let close = metal.range(of: ");", range: decl.upperBound..<metal.endIndex) else {
                expect(false, "\(variant): colorSampler declaration not found in Shaders.metal"); continue
            }
            let args = metal[decl.upperBound..<close.lowerBound].filter { !$0.isWhitespace }
            expectEqual(Set(args.split(separator: ",").map(String.init)), ["mip_filter::none", "mag_filter::linear", "min_filter::linear"],
                        "\(variant): sampler as recorded (no address/coord: Metal defaults)")
        }

        let entry = DiagStreamStages.record(expandedL, planes: [("r8Unorm", 4864, 1856), ("rg8Unorm", 2432, 928)],
                                           shader: "videoFrameFragmentShader_YpCbCrBiPlanar", decoderPixelFormat: "420v")
        for key in ["stage", "eye", "sampler", "source", "encoding"] { expect(entry[key] != nil, "stage record has \(key)") }
        expectEqual(entry["stage"] as? String, "expanded", "stage")
        expectEqual(entry["eye"] as? String, "L", "eye")
        expectEqual(entry["encoding"] as? String, "srgb", "PNG values are sRGB-encoded (DiagFrameCapture.submit)")
        let source = entry["source"] as? [String: Any] ?? [:]
        expectEqual(source["ffr"] as? Bool, true, "source.ffr")
        expectEqual(source["chroma_subsampling"] as? String, "4:2:0", "chroma plane at half size both ways")
        expectEqual(source["uv_rect"] as? [Double], [0, 0, 0.5, 1], "source.uv_rect")
        expectEqual((source["planes"] as? [[String: Any]])?.count, 2, "both planes recorded")
        expectEqual(source["shader"] as? String, "videoFrameFragmentShader_YpCbCrBiPlanar", "shader")
        expectEqual(source["decoder_pixel_format"] as? String, "420v", "decoder pixel format")
        let secret = DiagStreamStages.record(decodedL, planes: [("format_520", 4864, 1856)], shader: "videoFrameFragmentShader_SecretYpCbCrFormats",
                                             decoderPixelFormat: "&8v0")
        expectEqual((secret["source"] as? [String: Any])?["chroma_subsampling"] as? String, "in driver sampler (private YCbCr format)",
                    "private formats: chroma handled by the driver's sampler")

        expectEqual(DiagStreamStages.resampleChain.compactMap { $0["step"] as? String }, ["decode_chroma", "ffr_expand_and_warp", "compositor"],
                    "resample chain steps")
        expect(JSONSerialization.isValidJSONObject(["stages": [entry, secret], "resample_chain": DiagStreamStages.resampleChain]),
               "records serialise to capture.json")
        finishTests("DiagStreamStages")
    }
}
