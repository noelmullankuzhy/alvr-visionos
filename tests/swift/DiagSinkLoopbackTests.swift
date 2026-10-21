// SOURCES: ALVRClient/Diagnostics/DiagMeasurements.swift ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagNetSink.swift
import Foundation
import Darwin

private final class Reports {
    let lock = NSLock(), tick = DispatchSemaphore(value: 0)
    var lines: [String] = []
    func receive(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
        if line.contains("DIAG net ") && line.contains("summary=false") { tick.signal() }
    }
    func summary() -> String { lock.lock(); defer { lock.unlock() }; return lines.last { $0.contains("summary=true") } ?? "" }
}

@main enum DiagSinkLoopbackTests {
    static func main() {
        guard ProcessInfo.processInfo.environment["DIAG_LOOPBACK"] == "1" else {
            print("SKIP DiagSinkLoopback (opt-in: DIAG_LOOPBACK=1)"); finishTests("DiagSinkLoopback")
        }
        let reports = Reports(), sink = DiagNetSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        Diag.start(enabled: true, directory: directory, console: reports.receive)
        for tcp in [false, true] {
            let port = UInt16.random(in: 40000...60000)
            let error = sink.start(port: port, tcp: tcp, onStop: {})
            expect(error == nil, "listen: \(error ?? "ok")")
            if error != nil { continue }
            let sender = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
            var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = port.bigEndian
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sender, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            expectEqual(connected, 0, "connect sender")
            if tcp {
                let buffer = [UInt8](repeating: 0, count: 4096)
                expectEqual(send(sender, buffer, buffer.count, 0), buffer.count, "send bulk")
                shutdown(sender, SHUT_WR)
            } else {
                for seq in [1,2,0,0] {
                    // Same network-order bytes as the Python encoder; one reordered complete frame + duplicate.
                    let packet: [UInt8] = [65,86,80,68, 0,0,0,0,0,0,0,UInt8(seq), 0,0,0,0,0,0,0,1, 0,0,0,0, 0,UInt8(seq),0,3]
                    expectEqual(send(sender, packet, packet.count, 0), 28, "send UDP")
                }
                let bad: [UInt8] = [0,0,0,0]
                expectEqual(send(sender, bad, bad.count, 0), 4, "send malformed UDP")
            }
            expect(reports.tick.wait(timeout: .now() + 5) == .success, "one-second net report")
            sink.stop(); close(sender); Diag.flush()
            let summary = reports.summary()
            expect(summary.contains("mode=\(tcp ? "tcp" : "udp")"), "mode logged")
            expect(summary.contains("bytes=\(tcp ? 4096 : 112)"), "receiver byte count: \(summary)")
            if !tcp {
                expect(summary.contains("loss=0 "), "late packet repairs loss")
                expect(summary.contains("reorder=1 "), "reorder counted")
                expect(summary.contains("duplicates=1 "), "duplicate counted")
                expect(summary.contains("invalid=1 "), "malformed packet excluded")
                expect(summary.contains("frame_complete=1 "), "complete frame counted once")
            }
        }
        finishTests("DiagSinkLoopback")
    }
}
