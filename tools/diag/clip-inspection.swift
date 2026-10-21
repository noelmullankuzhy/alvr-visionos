import Foundation

// Round upward so an integer sample is never closer than 20% of the ideal side.
func gridBodyInset(cellSide: Double) -> Int {
    max(8, Int(ceil(cellSide * 0.2)))
}

// Aggregated over each cell's interior lattice on all decoded frames.
struct GridBodyAccuracy {
    private(set) var samples = 0
    private var sum: Int64 = 0
    private(set) var maxAbsError = 0
    var meanCode: Double { samples == 0 ? 0 : Double(sum) / Double(samples) }
    mutating func add(code: Int, expected: Int) {
        samples += 1
        sum += Int64(code)
        maxAbsError = max(maxAbsError, abs(code - expected))
    }
}
