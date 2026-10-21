import Foundation

// A decoder lease is registered before its detached worker is launched. Cancellation
// waits even during session creation; the worker signals only after all teardown defers.
final class DiagDecodeLifetime {
    let cancellation = Progress(totalUnitCount: 1)
    private let done = DispatchGroup()
    init() { done.enter() }
    func run<T>(_ work: (Progress) async -> T) async -> T {
        defer { done.leave() }
        return await work(cancellation)
    }
    func cancelAndWait() { cancellation.cancel(); done.wait() }
}

// Fixed 0.125 ms bins with nearest-bin quantization: <= 0.0625 ms value error
// for every in-range quantile, independent of sample count/distribution. Block totals
// avoid scanning all bins per percentile. No sample arrays, sorting or growth.
struct BoundedDistribution {
    static let errorMs = 0.0625
    private static let step = 0.125, maximum = 65536.0, blockSize = 256
    private let minimum: Double
    private var bins: [UInt64], blocks: [UInt64]
    private var below: UInt64 = 0, above: UInt64 = 0
    private(set) var count = 0
    var outOfRange: UInt64 { below + above }
    var storageBytes: Int { (bins.capacity + blocks.capacity) * MemoryLayout<UInt64>.stride }
    init(minimum: Double = 0) {
        precondition(minimum == 0 || minimum == -65536)
        self.minimum = minimum
        let size = Int((Self.maximum - minimum) / Self.step) + 1
        bins = Array(repeating: 0, count: size)
        blocks = Array(repeating: 0, count: (size + Self.blockSize - 1) / Self.blockSize)
    }
    init(_ samples: [Double]) { self.init(); for sample in samples { append(sample) } }
    mutating func append(_ value: Double) {
        count += 1
        guard value.isFinite, value >= minimum else { below += 1; return }
        guard value <= Self.maximum else { above += 1; return }
        let index = Int(((value - minimum) / Self.step).rounded())
        bins[index] += 1; blocks[index / Self.blockSize] += 1
    }
    func percentile(_ q: Double) -> Double {
        guard count > 0 else { return 0 }
        var rank = UInt64(max(1, ceil(Double(count) * min(1, max(0, q)))))
        if rank <= below { return .nan }; rank -= below
        for block in blocks.indices {
            if rank > blocks[block] { rank -= blocks[block]; continue }
            for bin in (block * Self.blockSize)..<min((block + 1) * Self.blockSize, bins.count) {
                if rank <= bins[bin] { return minimum + Double(bin) * Self.step }
                rank -= bins[bin]
            }
        }
        return .nan // requested rank is outside the representable range
    }
}

struct DecodeMeasurement {
    let frames, submitted: Int
    let seconds: Double
    let width, height: Int
    let latencies: BoundedDistribution
    var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }
    var mpix: Double { fps * Double(width) * Double(height) / 1e6 }
    var dropped: Int { max(0, submitted - frames) }
    var p50: Double { latencies.percentile(0.5) }
    var p95: Double { latencies.percentile(0.95) }
}

struct NetPacket {
    let sequence, sentNs: UInt64
    let frame: UInt32
    let index, count: Int
    init(sequence: UInt64, sentNs: UInt64, frame: UInt32, index: Int, count: Int) {
        self.sequence = sequence; self.sentNs = sentNs; self.frame = frame; self.index = index; self.count = count
    }
    init?(_ data: Data) {
        guard data.count >= 28, Array(data.prefix(4)) == [65,86,80,68] else { return nil }
        let b = Array(data.prefix(28))
        func read(_ start: Int, _ length: Int) -> UInt64 { b[start..<(start + length)].reduce(0) { ($0 << 8) | UInt64($1) } }
        self.init(sequence: read(4, 8), sentNs: read(12, 8), frame: UInt32(read(20, 4)), index: Int(read(24, 2)), count: Int(read(26, 2)))
        guard count > 0, index < count else { return nil }
    }
}

// Per run (sink caps runs at 60 s). Sequence history is a sliding 65536-packet window;
// packets older than it count as stale, not unique. Missing trailing packets are unknowable.
struct NetMeasurement {
    private struct Frame { var indices: Set<Int>; let count: Int; let first: UInt64; var last: UInt64; var transit: Double }
    private var seen = Set<UInt64>()
    private var frames: [UInt32: Frame] = [:]
    private var highest: UInt64?
    private var unique: UInt64 = 0
    private var previousTransit: Double?
    private var minTransit = Double.infinity, maxTransit = -Double.infinity
    private var tails = BoundedDistribution(minimum: -65536)
    private var referenceTransit: Double?
    private(set) var bytes = 0, reordered = 0, duplicates = 0, stale = 0
    private(set) var jitterMs = 0.0
    private(set) var spreads = BoundedDistribution()
    private(set) var completed = 0
    var distributionStorageBytes: Int { spreads.storageBytes + tails.storageBytes }
    var distributionOverflow: UInt64 { spreads.outOfRange + tails.outOfRange }
    var loss: UInt64 { highest.map { $0 - (unique - 1) } ?? 0 }
    var delayVariationMs: Double { previousTransit == nil ? 0 : maxTransit - minTransit }
    func mbps(seconds: Double) -> Double { seconds > 0 ? Double(bytes) * 8 / seconds / 1e6 : 0 }
    func tail(_ q: Double) -> Double {
        guard tails.count > 0 else { return 0 }
        let percentile = tails.percentile(q)
        return percentile.isNaN ? .nan : max(0, percentile + (referenceTransit ?? 0) - minTransit)
    }
    mutating func receive(_ p: NetPacket, bytes size: Int, nowNs: UInt64) {
        bytes += size
        if let high = highest, high > 65536, p.sequence < high - 65536 { stale += 1; return }
        guard seen.insert(p.sequence).inserted else { duplicates += 1; return }
        if let high = highest, p.sequence < high { reordered += 1 }
        highest = max(highest ?? 0, p.sequence); unique += 1
        // Prune in batches, rather than scanning the history per datagram.
        if seen.count > 131072 { let floor = highest! > 65536 ? highest! - 65536 : 0; seen = seen.filter { $0 >= floor } }
        let transit = (Double(nowNs) - Double(p.sentNs)) / 1e6
        if let last = previousTransit { jitterMs += (abs(transit - last) - jitterMs) / 16 }
        if referenceTransit == nil { referenceTransit = transit }
        previousTransit = transit; minTransit = min(minTransit, transit); maxTransit = max(maxTransit, transit)
        if frames[p.frame] == nil && frames.count >= 256 { frames.removeValue(forKey: frames.min { $0.value.first < $1.value.first }!.key) }
        var f = frames[p.frame] ?? Frame(indices: [], count: p.count, first: nowNs, last: nowNs, transit: transit)
        guard f.count == p.count, f.indices.insert(p.index).inserted else { return }
        f.last = max(f.last, nowNs); f.transit = max(f.transit, transit)
        if f.indices.count == f.count {
            completed += 1; spreads.append(Double(f.last - f.first) / 1e6); tails.append(f.transit - referenceTransit!)
            frames.removeValue(forKey: p.frame)
        } else { frames[p.frame] = f }
    }
}
