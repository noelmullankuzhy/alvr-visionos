// Run: xcrun swift tools/diag/make-codec-audit.swift <output.json>
// Attempts one 64x64 HEVC frame per actual 10-bit input chroma. Never synthesizes
// parameter sets or relabels a converted 4:2:0 result as 4:2:2/4:4:4.
import Foundation
import VideoToolbox

struct Fixture: Codable {
    let chroma: String
    let bitDepth: Int
    let parameterSets: [Data]
    let encoderStatus: Int32
    let reason: String
}
final class Output {
    var sample: CMSampleBuffer?
    var status: OSStatus = 0
}
struct EncoderError: Error { let code: OSStatus; let reason: String }
func check(_ status: OSStatus, _ reason: String) throws {
    if status != 0 { throw EncoderError(code: status, reason: reason) }
}
func make(_ chroma: String, _ pixelFormat: OSType) -> Fixture {
    do {
        let output = Output()
        var session: VTCompressionSession?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                     kCVPixelBufferWidthKey: 64, kCVPixelBufferHeightKey: 64] as CFDictionary
        try check(VTCompressionSessionCreate(allocator: nil, width: 64, height: 64, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: attrs, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, sample in
                let out = Unmanaged<Output>.fromOpaque(ref!).takeUnretainedValue()
                out.status = status; out.sample = sample
            }, refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &session), "create")
        guard let session else { throw EncoderError(code: -1, reason: "no_session") }
        defer { VTCompressionSessionInvalidate(session) }
        // VT publishes Main10 and Main42210; 4:4:4 is attempted with the encoder's
        // automatic profile selection and rejected below if it converts the input.
        if chroma != "444" {
            try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                value: chroma == "420" ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main42210_AutoLevel), "profile")
        }
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), "reorder")
        try check(VTCompressionSessionPrepareToEncodeFrames(session), "prepare")
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 64, 64, pixelFormat, nil, &pixel), "pixel")
        guard let pixel else { throw EncoderError(code: -1, reason: "no_pixel") }
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
            let height = CVPixelBufferGetHeightOfPlane(pixel, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
            let data = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!.assumingMemoryBound(to: UInt16.self)
            for i in 0..<(height * stride / 2) { data[i] = UInt16(512) << 6 }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        try check(VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), "encode")
        try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), "complete")
        try check(output.status, "callback")
        guard let sample = output.sample, let format = CMSampleBufferGetFormatDescription(sample),
              let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any],
              let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
              let config = atoms["hvcC"] as? Data, config.count >= 19 else { throw EncoderError(code: -1, reason: "missing_hvcC") }
        let expected = ["420": 1, "422": 2, "444": 3][chroma]!
        guard config[16] & 3 == expected, config[17] & 7 == 2, config[18] & 7 == 2 else {
            throw EncoderError(code: -1, reason: "encoder_converted_chroma_or_depth")
        }
        var count = 0
        try check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil), "count")
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            try check(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), "parameter_set")
            sets.append(Data(bytes: pointer!, count: size))
        }
        return Fixture(chroma: chroma, bitDepth: 10, parameterSets: sets, encoderStatus: 0, reason: "verified_hvcC")
    } catch let error as EncoderError {
        return Fixture(chroma: chroma, bitDepth: 10, parameterSets: [], encoderStatus: error.code, reason: error.reason)
    } catch { fatalError("Unexpected error: \(error)") }
}
let fixtures = [("420", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                ("422", kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
                ("444", kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)].map { make($0.0, $0.1) }
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(fixtures).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
for f in fixtures { print("chroma=\(f.chroma) bit_depth=10 encoder_status=\(f.encoderStatus) reason=\(f.reason) sets=\(f.parameterSets.count)") }
