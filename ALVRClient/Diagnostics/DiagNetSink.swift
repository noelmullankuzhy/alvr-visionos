import Foundation
import Darwin

// Keep ownership through synchronous teardown, but never hold the mutex while waiting
// for workers: admission can refuse promptly and worker completion cannot deadlock.
enum DiagWorkGate {
    private static let condition = NSCondition()
    private static var streaming = false, stopping = false
    private static var owner: UUID?
    private static var stopAction: (() -> Void)?
    static func start(id: UUID = UUID(), _ action: () -> (() -> Void)?) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard Diag.isOn, !streaming, !stopping, owner == nil else { return false }
        stopAction = action(); owner = stopAction == nil ? nil : id; return owner != nil
    }
    static func stop() {
        condition.lock()
        let target = owner
        while stopping && owner == target { condition.wait() }
        guard owner == target, let action = stopAction else { condition.unlock(); return }
        stopping = true
        condition.unlock()
        action() // decoder cancellation waits for drain + invalidation, net stop closes sockets
        condition.lock()
        stopAction = nil; owner = nil; stopping = false
        condition.broadcast(); condition.unlock()
    }
    static func finish(_ id: UUID) {
        condition.lock(); defer { condition.unlock() }
        if owner == id && !stopping { stopAction = nil; owner = nil }
    }
    static func setStreaming(_ active: Bool) {
        condition.lock(); streaming = active; condition.unlock()
        if active { stop() } // EventHandler publishes streamingActive only after this returns
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
                    self.closeRun()
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
                             "hist_error_ms": BoundedDistribution.errorMs, "hist_overflow": stats.distributionOverflow,
                             "stale": stats.stale, "invalid": invalid, "foreign": foreign, "jitter_ms": stats.jitterMs,
                             "frame_complete": stats.completed, "spread_p95_ms": stats.spreads.percentile(0.95), "spread_p99_ms": stats.spreads.percentile(0.99),
                             "owdv_ms": stats.delayVariationMs, "owdv_p95_ms": stats.tail(0.95), "owdv_p99_ms": stats.tail(0.99),
                             "burst_tail_p95_ms": stats.spreads.percentile(0.95), "burst_tail_p99_ms": stats.spreads.percentile(0.99)])
        }
        lastNs = now; lastBytes = bytes
    }
}
