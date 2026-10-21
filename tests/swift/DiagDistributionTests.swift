// SOURCES: ALVRClient/Diagnostics/DiagMeasurements.swift
import Foundation

@main enum DiagDistributionTests {
    static func main() {
        var latency = BoundedDistribution(), signed = BoundedDistribution(minimum: -65536)
        let capacity = latency.storageBytes, signedCapacity = signed.storageBytes
        for i in 0..<1_000_000 {
            latency.append(Double(i % 100_000) / 1000)
            signed.append(Double(i % 100_000) / 1000 - 50)
        }
        expectEqual(latency.count, 1_000_000, "all latency observations counted separately from bins")
        expectEqual(latency.storageBytes, capacity, "one million decode latencies use fixed storage")
        expectEqual(signed.storageBytes, signedCapacity, "signed distribution uses fixed storage")
        for q in [0.5, 0.95, 0.99] {
            let expected = q * 100 - 0.001
            expect(abs(latency.percentile(q) - expected) <= BoundedDistribution.errorMs, "latency quantile within 0.0625 ms")
            expect(abs(signed.percentile(q) - (expected - 50)) <= BoundedDistribution.errorMs, "signed quantile within error bound")
        }
        var net = NetMeasurement()
        let netCapacity = net.distributionStorageBytes
        for i in 0..<1_000_000 {
            let now = UInt64(i) * 1_000_000 + 1_000_000_000
            let delay = UInt64(i % 10_000) * 10_000
            net.receive(NetPacket(sequence: UInt64(i), sentNs: now - delay, frame: UInt32(i), index: 0, count: 1), bytes: 1200, nowNs: now)
        }
        expectEqual(net.completed, 1_000_000, "completion total independent of distribution capacity")
        expectEqual(net.distributionStorageBytes, netCapacity, "line rate cannot grow completion storage")
        expect(netCapacity <= 13 * 1024 * 1024, "two histograms stay under 13 MiB")
        expectEqual(net.spreads.percentile(0.99), 0, "single-packet completion spread")
        expect(abs(net.tail(0.95) - 94.99) <= BoundedDistribution.errorMs, "million-frame relative p95 within stated error")
        expect(abs(net.tail(0.99) - 98.99) <= BoundedDistribution.errorMs, "million-frame relative p99 within stated error")
        expectEqual(net.loss, 0, "history pruning retains correct loss")
        var overflow = BoundedDistribution()
        overflow.append(-1); overflow.append(100_000)
        expectEqual(overflow.outOfRange, 2, "out of range observations counted")
        expect(overflow.percentile(0.5).isNaN, "overflow quantiles are unavailable, never clipped values")
        finishTests("DiagDistribution")
    }
}
