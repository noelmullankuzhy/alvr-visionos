// SOURCES: tools/diag/clip-inspection.swift
import Foundation

@main enum GridInspectionTests {
    static func main() {
        for (side, expected) in [(28.8, 8), (40.0, 8), (40.1, 9), (91.0736, 19), (203.6468, 41)] {
            expectEqual(gridBodyInset(cellSide: side), expected, "ceil max(8px, 20% side)")
        }
        for area in [1.0, 10, 50] {
            let side = sqrt(1920 * 1080 * area / 100) / 5
            let inset = gridBodyInset(cellSide: side)
            expect(Double(inset) >= 8 && Double(inset) >= 0.2 * side, "inset respects both minima")
            expect(2 * inset < Int(side), "body remains nonempty")
        }
        var stats = GridBodyAccuracy()
        stats.add(code: 720, expected: 723)
        stats.add(code: 724, expected: 723)
        expectEqual(stats.samples, 2, "sample count")
        expectEqual(stats.meanCode, 722, "body mean")
        expectEqual(stats.maxAbsError, 3, "max absolute sample error")
        stats.add(code: 727, expected: 723)
        expectEqual(stats.maxAbsError, 4, "out-of-tolerance sample retained")
        finishTests("GridInspection")
    }
}
