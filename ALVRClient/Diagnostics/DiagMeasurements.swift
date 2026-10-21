import Foundation

struct DecodeMeasurement {
    let frames, submitted: Int
    let seconds: Double
    let width, height: Int
    let latencies: [Double]
    var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }
    var mpix: Double { fps * Double(width) * Double(height) / 1e6 }
    var dropped: Int { max(0, submitted - frames) }
    var p50: Double { NetMeasurement().percentile(latencies, 0.5) }
    var p95: Double { NetMeasurement().percentile(latencies, 0.95) }
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
    private var tails: [Double] = []
    private(set) var bytes = 0, reordered = 0, duplicates = 0, stale = 0
    private(set) var jitterMs = 0.0
    private(set) var spreads: [Double] = []
    var loss: UInt64 { highest.map { $0 - (unique - 1) } ?? 0 }
    var delayVariationMs: Double { previousTransit == nil ? 0 : maxTransit - minTransit }
    func mbps(seconds: Double) -> Double { seconds > 0 ? Double(bytes) * 8 / seconds / 1e6 : 0 }
    func percentile(_ values: [Double], _ q: Double) -> Double {
        let s = values.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, max(0, Int(ceil(Double(s.count) * q)) - 1))]
    }
    func tail(_ q: Double) -> Double { tails.isEmpty ? 0 : percentile(tails, q) - minTransit }
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
        previousTransit = transit; minTransit = min(minTransit, transit); maxTransit = max(maxTransit, transit)
        if frames[p.frame] == nil && frames.count >= 256 { frames.removeValue(forKey: frames.min { $0.value.first < $1.value.first }!.key) }
        var f = frames[p.frame] ?? Frame(indices: [], count: p.count, first: nowNs, last: nowNs, transit: transit)
        guard f.count == p.count, f.indices.insert(p.index).inserted else { return }
        f.last = max(f.last, nowNs); f.transit = max(f.transit, transit)
        if f.indices.count == f.count {
            spreads.append(Double(f.last - f.first) / 1e6); tails.append(f.transit)
            frames.removeValue(forKey: p.frame)
        } else { frames[p.frame] = f }
    }
}
