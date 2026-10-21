// SOURCES: tools/diag/clip-policy.swift
import Foundation

@main enum HDRMetadataTests {
    static func main() throws {
        let metadata = try HDRStaticMetadata(masteringPeak: 1000, maxCLL: 1000, maxFALL: 400)
        expectEqual(Array(metadata.masteringDisplayBytes), [
            0x21,0x34, 0x9b,0xaa, 0x19,0x96, 0x08,0xfc, 0x8a,0x48, 0x39,0x08,
            0x3d,0x13, 0x40,0x42, 0x00,0x98,0x96,0x80, 0x00,0x00,0x00,0x32
        ], "ST 2086 byte order and units")
        expectEqual(Array(metadata.contentLightBytes), [0x03,0xe8,0x01,0x90], "CEA-861.3 byte order")
        expectEqual(metadata.filenameSuffix, "-md1000-cll1000-fall400", "metadata filename suffix")
        expectEqual(try HDRStaticMetadata.parse(masteringPeak: nil, maxCLL: nil, maxFALL: nil), nil, "metadata absent")
        expectEqual(try HDRStaticMetadata.parse(masteringPeak: "1000", maxCLL: "1000", maxFALL: "400")?.filenameSuffix,
                    "-md1000-cll1000-fall400", "parse options")
        let surrounded = try GridClip(area: 10, range: "coarse", surround: 203)
        expectEqual(surrounded.manifest["surroundLumaCode"] as? Int, Int(pqCode(203)), "surround PQ code")
        expectEqual(surrounded.manifest["surroundNits"] as? Double, 203, "surround sidecar value")
        expectEqual(surrounded.filenameSuffix, "-sur203", "surround filename suffix")
        expectEqual(try GridClip(area: 10, range: "coarse", surround: 0).manifest["surroundLumaCode"] as? Int, 64, "default black code")
        let invalid: [(String?, String?, String?)] = [("0", nil, nil), ("10001", nil, nil), (nil, "0", nil), (nil, "10001", nil), (nil, "100", "101"), (nil, nil, "10001")]
        for args in invalid {
            do {
                _ = try HDRStaticMetadata.parse(masteringPeak: args.0, maxCLL: args.1, maxFALL: args.2)
                expect(false, "invalid metadata options rejected: \(args)")
            } catch { expect(true, "invalid metadata options rejected") }
        }
        do { _ = try GridClip(area: 10, range: "coarse", surround: 10001); expect(false, "invalid surround rejected") }
        catch { expect(true, "invalid surround rejected") }
        finishTests("HDRMetadata")
    }
}
