import Foundation
import Darwin

// Stream transitions and UI starts share this lock. Stop closes the listeners synchronously
// before EventHandler publishes streamingActive=true; off never touches the gate.
enum DiagWorkGate {
    private static let lock = NSLock()
    private static var streaming = false
    private static var owner: UUID?
    private static var stopAction: (() -> Void)?
    static func start(id: UUID = UUID(), _ action: () -> (() -> Void)?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Diag.isOn, !streaming, stopAction == nil else { return false }
        stopAction = action(); owner = stopAction == nil ? nil : id; return stopAction != nil
    }
    static func stop() {
        lock.lock(); defer { lock.unlock() }
        stopAction?(); stopAction = nil; owner = nil
    }
    static func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == id { stopAction = nil; owner = nil }
    }
    static func setStreaming(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        streaming = active
        if active { stopAction?(); stopAction = nil; owner = nil }
    }
}

final class DiagNetSink {
    private let queue = DispatchQueue(label: "uk.lumenio.alvr.diag.net", qos: .userInitiated)
    private var fd: Int32 = -1, client: Int32 = -1
    private var source: DispatchSourceRead?, clientSource: DispatchSourceRead?, timer: DispatchSourceTimer?
    private var stats = NetMeasurement()
    private var bytes = 0, lastBytes = 0, invalid = 0, foreign = 0
    private var peer: Data?, mode = "udp"
    private var startNs: UInt64 = 0, lastNs: UInt64 = 0, firstReceive: UInt64 = 0, lastReceive: UInt64 = 0
    private var onStop: (() -> Void)?
    func start(port: UInt16, tcp: Bool, onStop: @escaping () -> Void) -> String? {
        queue.sync {
            guard Diag.isOn else { return "Diagnostics is off" }
            self.mode = tcp ? "tcp" : "udp"; self.onStop = onStop
            stats = NetMeasurement(); firstReceive = 0; lastReceive = 0; bytes = 0; lastBytes = 0; invalid = 0; foreign = 0; peer = nil
            fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard fd >= 0, bound == 0, !tcp || listen(fd, 1) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                let message = String(cString: strerror(errno)); if fd >= 0 { close(fd) }; fd = -1
                Diag.log("net", ["mode": mode, "err": message]); return message
            }
            var buffer: Int32 = 4 * 1024 * 1024
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout.size(ofValue: buffer)))
            startNs = DispatchTime.now().uptimeNanoseconds; lastNs = startNs
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source?.setEventHandler { [weak self] in if tcp { self?.acceptClient() } else { self?.readUDP() } }; source?.resume()
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer?.schedule(deadline: .now() + 1, repeating: 1)
            timer?.setEventHandler { [weak self] in
                guard let self else { return }
                self.report(summary: false)
                if DispatchTime.now().uptimeNanoseconds - self.startNs >= 60_000_000_000 {
                    self.closeRun(); DispatchQueue.main.async { DiagWorkGate.stop() }
                }
            }; timer?.resume()
            return nil
        }
    }
    func stop() { queue.sync { closeRun() } }
    private func closeRun() {
        guard fd >= 0 else { return }
        report(summary: true)
        source?.cancel(); clientSource?.cancel(); timer?.cancel()
        close(fd); if client >= 0 { close(client) }; fd = -1; client = -1
        source = nil; clientSource = nil; timer = nil
        let callback = onStop; onStop = nil; DispatchQueue.main.async { callback?() }
    }
    private func readUDP() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<256 {
            var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
            guard n > 0 else { break }
            guard let packet = NetPacket(Data(buffer.prefix(n))) else { invalid += 1; continue }
            let sender = withUnsafeBytes(of: address) { Data($0) }
            if let peer, peer != sender { foreign += 1; continue }; peer = sender
            received(n); stats.receive(packet, bytes: n, nowNs: lastReceive)
        }
    }
    private func acceptClient() {
        guard fd >= 0 else { return }
        let incoming = accept(fd, nil, nil); guard incoming >= 0 else { return }
        guard client < 0, fcntl(incoming, F_SETFL, O_NONBLOCK) == 0 else { close(incoming); return }
        client = incoming; clientSource = DispatchSource.makeReadSource(fileDescriptor: incoming, queue: queue)
        clientSource?.setEventHandler { [weak self] in
            guard let self, self.client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            for _ in 0..<256 {
                let n = recv(self.client, &buffer, buffer.count, 0)
                if n > 0 { self.received(n) }
                else if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    self.clientSource?.cancel(); close(self.client); self.client = -1; self.clientSource = nil; break
                } else { break }
            }
        }; clientSource?.resume()
    }
    private func received(_ count: Int) {
        lastReceive = DispatchTime.now().uptimeNanoseconds
        if firstReceive == 0 { firstReceive = lastReceive }; bytes += count
    }
    private func report(summary: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let active = Double(lastReceive - firstReceive) / 1e9
        let seconds = summary ? active : Double(now - lastNs) / 1e9
        let mbps = seconds > 0 ? Double(bytes - (summary ? 0 : lastBytes)) * 8 / seconds / 1e6 : 0
        if mode == "tcp" {
            Diag.log("net", ["mode": mode, "summary": summary, "seconds": Double(now - startNs) / 1e9, "active_seconds": active, "mbps": mbps, "bytes": bytes])
        } else {
            Diag.log("net", ["mode": mode, "summary": summary, "seconds": Double(now - startNs) / 1e9,
                             "active_seconds": active, "mbps": mbps,
                             "bytes": bytes, "loss": stats.loss, "reorder": stats.reordered, "duplicates": stats.duplicates,
                             "stale": stats.stale, "invalid": invalid, "foreign": foreign, "jitter_ms": stats.jitterMs,
                             "frame_complete": stats.spreads.count, "spread_p95_ms": stats.percentile(stats.spreads, 0.95), "spread_p99_ms": stats.percentile(stats.spreads, 0.99),
                             "owdv_ms": stats.delayVariationMs, "owdv_p95_ms": stats.tail(0.95), "owdv_p99_ms": stats.tail(0.99),
                             "burst_tail_p95_ms": stats.percentile(stats.spreads, 0.95), "burst_tail_p99_ms": stats.percentile(stats.spreads, 0.99)])
        }
        lastNs = now; lastBytes = bytes
    }
}
