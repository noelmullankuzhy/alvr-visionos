// SOURCES: tools/diag/clip-policy.swift
import Foundation

@main enum SplitClipTests {
    static func main() throws {
        let split = SplitClip(referenceNits: 203)
        expectEqual(SplitClip.levels, [100, 203, 300, 400, 600, 800, 1000, 203], "ordered levels and final reference")
        let schedule = split.schedule(seconds: 40)
        expectEqual(schedule.count, 8, "eight five-second holds")
        let expectedCodes = [509, 573, 609, 636, 674, 701, 723, 573]
        for i in 0..<8 {
            expectEqual(schedule[i]["startSeconds"], Double(i * 5), "boundary")
            expectEqual(schedule[i]["durationSeconds"], 5, "hold")
            expectEqual(schedule[i]["nits"], SplitClip.levels[i], "test nits")
            expectEqual(schedule[i]["referenceNits"], 203, "reference nits")
            expectEqual(schedule[i]["referenceLumaCode"], 573, "left code")
            expectEqual(schedule[i]["lumaCode"], Double(expectedCodes[i]), "right code")
            expectEqual(split.patchCode(x: 100, width: 1920, step: i), 573, "left stays fixed")
            expectEqual(split.patchCode(x: 1800, width: 1920, step: i), UInt16(expectedCodes[i]), "right follows schedule")
        }
        expectEqual(split.patchCode(x: 960, width: 1920, step: 0), 64, "black gap")
        expectEqual(split.gap(width: 1920).count, 38, "2% gap rounded to even pixels")
        expectEqual(SplitClip(referenceNits: 100).patchCode(x: 0, width: 1920, step: 0), 509, "selectable reference")
        expectEqual(split.schedule(seconds: 6).last?["durationSeconds"], 1, "truncated hold")
        expectEqual(split.schedule(seconds: 45).last?["durationSeconds"], 10, "final level extended")
        let data = try JSONSerialization.data(withJSONObject: split.schedule(seconds: 40))
        let decoded = try JSONSerialization.jsonObject(with: data) as! [[String: Double]]
        expectEqual(decoded, schedule, "manifest schedule round trip")
        expect(SplitClip.digitHeight(height: 1080) >= 87, "digits at least 8% high")
        finishTests("SplitClip")
    }
}
