// SOURCES: ALVRClient/ColourPipeline.swift ALVRClient/HDRPipeline.swift ALVRClient/VideoDecoderOutput.swift ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagMeasurements.swift ALVRClient/Diagnostics/DiagDecodeBench.swift
import AVFoundation

@main enum DecoderOutputTests {
    static func main() async {
        // Compiles the actual bench (including code generation), without requiring a decoder.
        for pq in [false, true] { for full in [false, true] {
            var format: CMFormatDescription?
            let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_TransferFunction: pq ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,
                                              "FullRangeVideo" as CFString: full]
            expectEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 1920, height: 1080,
                                                       extensions: extensions as CFDictionary, formatDescriptionOut: &format), 0, "test format")
            let attrs = VideoDecoderOutput.attributes(format!)
            expectEqual(attrs[kCVPixelBufferMetalCompatibilityKey] as? Bool, true, "Metal compatibility unchanged")
            expectEqual(attrs[kCVPixelBufferPoolMinimumBufferCountKey] as? Int, 3, "pool count unchanged")
            if pq {
                expectEqual(attrs[kCVPixelBufferPixelFormatTypeKey] as? UInt32,
                            full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "PQ explicit planes")
            } else {
                expect(attrs[kCVPixelBufferPixelFormatTypeKey] == nil, "SDR native output, no conversion request")
            }
        } }
        let result = await DiagDecodeBench.run(cancel: Progress(totalUnitCount: 1))
        expectEqual(result, "Diagnostics is off", "bench off does not read clips or start sessions")
        finishTests("DecoderOutput")
    }
}
