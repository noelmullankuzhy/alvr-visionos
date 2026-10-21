import Foundation
import VideoToolbox

// Generated on the Mac by tools/diag/make-codec-audit.swift. A refusal records
// encoder provenance; it says nothing about the headset's decoder support.
struct CodecFixture: Codable {
    let chroma: String
    let bitDepth: Int
    let parameterSets: [Data]
    let encoderStatus: Int32
    let reason: String
}

enum CodecSupport {
    static func start() {
        guard Diag.isOn else { return }
        Diag.background {
            let url = Bundle.main.url(forResource: "codec-audit", withExtension: "json")
            let fixtures = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([CodecFixture].self, from: $0) } ?? []
            let types = ["hevc": kCMVideoCodecType_HEVC, "av1": kCMVideoCodecType_AV1, "h264": kCMVideoCodecType_H264]
            for fields in CodecAudit.lines(hardware: { VTIsHardwareDecodeSupported(types[$0]!) }, session: { chroma in
                guard let fixture = fixtures.first(where: { $0.chroma == chroma && $0.bitDepth == 10 }) else { return .unavailable }
                if fixture.encoderStatus != 0 { return .refused }
                return .status(createSession(fixture.parameterSets))
            }) { Diag.log("codec", fields) }
        }
    }
    static func createSession(_ sets: [Data]) -> OSStatus {
        guard sets.count >= 3, sets.allSatisfy({ !$0.isEmpty }) else { return -50 }
        // NSData retains stable storage for the duration of the CoreMedia call.
        let storage = sets.map { $0 as NSData }
        var pointers = storage.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = storage.map(\.length)
        var format: CMFormatDescription?
        let status = withExtendedLifetime(storage) { CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: storage.count,
            parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format) }
        guard status == 0, let format else { return status == 0 ? -50 : status }
        var session: VTDecompressionSession?
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let result = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: specification,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return result
    }
}
