// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/MaxSweep.swift ALVRClient/Diagnostics/CodecSupport.swift
import Foundation
import VideoToolbox

@main enum CodecFixtureTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "ALVRClient/Diagnostics/codec-audit.json"))
        // Use the same Codable model and decoder as the bundled client loader.
        let fixtures = try JSONDecoder().decode([CodecFixture].self, from: data)
        expectEqual(fixtures.map(\.chroma), ["420", "422", "444"], "all generated formats load")
        for fixture in fixtures {
            expectEqual(fixture.bitDepth, 10, "10-bit fixture")
            expectEqual(fixture.encoderStatus, 0, "Mac encoder accepted format")
            expectEqual(fixture.reason, "verified_hvcC", "generator verified encoded format")
            expectEqual(fixture.parameterSets.count, 3, "VPS SPS PPS present")
            expectEqual(fixture.parameterSets.map { Int(($0.first ?? 0) >> 1 & 63) }, [32, 33, 34], "base64 decoded HEVC NAL types")
            let storage = fixture.parameterSets.map { $0 as NSData }
            var pointers = storage.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            var sizes = storage.map(\.length)
            var format: CMFormatDescription?
            let status = withExtendedLifetime(storage) {
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: storage.count,
                    parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4,
                    extensions: nil, formatDescriptionOut: &format)
            }
            expectEqual(status, 0, "CoreMedia accepts generated parameter sets without hardware decoder")
            guard let format else { expect(false, "format description created"); continue }
            guard let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any],
                  let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
                  let config = atoms["hvcC"] as? Data, config.count >= 19 else {
                expect(false, "CoreMedia exposes hvcC"); continue
            }
            expectEqual(Int(config[16] & 3), ["420": 1, "422": 2, "444": 3][fixture.chroma]!, "encoded chroma preserved")
            expectEqual(Int(config[17] & 7) + 8, 10, "encoded luma depth")
            expectEqual(Int(config[18] & 7) + 8, 10, "encoded chroma depth")
        }
        finishTests("CodecFixture")
    }
}
