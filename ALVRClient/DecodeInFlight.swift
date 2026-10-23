//
//  DecodeInFlight.swift
//
// Accounting for asynchronous hardware decode (`-ALVRAsyncDecode YES`): at most `limit` frames in flight, outputs in
// submit order (ALVR streams have no B-frames), the per-frame submit time for the overrun check, and a drain on reset.
//
// Foundation-only so it is unit tested on macOS (tests/swift/DecodeInFlightTests.swift).
//

import Foundation

struct DecodeInFlight {
    // Opt-in switches, both off by default (synchronous decode, no real-time hint).
    static let asyncDefaultsKey = "ALVRAsyncDecode"
    static let realTimeDefaultsKey = "ALVRDecodeRealTime"
    static let defaultLimit = 2
    // Launch-only A/B flags: frames in flight (1...8) and how long the input thread waits for a slot (0...100 ms).
    static let inFlightKey = "ALVRDecodeInFlight"
    static let slotWaitKey = "ALVRDecodeSlotWaitMs"

    static func configuredLimit(_ arguments: [String: Any]) -> Int {
        guard let value = number(arguments[inFlightKey]) else { return defaultLimit }
        return Int(min(max(value, 1), 8))
    }

    static func configuredSlotWait(_ arguments: [String: Any]) -> TimeInterval {
        guard let value = number(arguments[slotWaitKey]) else { return 0.1 }
        return min(max(value, 0), 100) / 1000
    }

    // Finite values only: nan and inf fall back to the default (Int(nan) would trap).
    private static func number(_ raw: Any?) -> Double? {
        let parsed: Double?
        switch raw {
        case let value as NSNumber: parsed = value.doubleValue
        case let value as String: parsed = Double(value.trimmingCharacters(in: .whitespaces))
        default: parsed = nil
        }
        return parsed.flatMap { $0.isFinite ? $0 : nil }
    }

    struct Frame: Equatable {
        let token: UInt64
        let timestampNs: UInt64
        let submitNs: UInt64
    }

    enum Output: Equatable {
        case inOrder(Frame)
        case outOfOrder(Frame)  // not the oldest in flight, or its timestamp is older than the last output's
        case unknown            // cancelled, drained or already output
    }

    let limit: Int

    init(limit: Int = DecodeInFlight.defaultLimit) {
        self.limit = limit
    }

    private var frames: [Frame] = []
    private var nextToken: UInt64 = 1
    private var lastOutputTimestampNs: UInt64? = nil
    private(set) var maxCount = 0

    var count: Int { frames.count }
    var canSubmit: Bool { frames.count < limit }

    // nil when `limit` frames are already in flight.
    mutating func submit(timestampNs: UInt64, submitNs: UInt64) -> UInt64? {
        guard canSubmit else { return nil }
        let token = nextToken
        nextToken += 1
        frames.append(Frame(token: token, timestampNs: timestampNs, submitNs: submitNs))
        maxCount = max(maxCount, frames.count)
        return token
    }

    // The decode call itself failed: no output will be counted for it.
    mutating func cancel(_ token: UInt64) {
        frames.removeAll { $0.token == token }
    }

    mutating func output(_ token: UInt64) -> Output {
        guard let index = frames.firstIndex(where: { $0.token == token }) else { return .unknown }
        let frame = frames.remove(at: index)
        let backwards = lastOutputTimestampNs.map { frame.timestampNs < $0 } ?? false
        lastOutputTimestampNs = frame.timestampNs
        return index == 0 && !backwards ? .inOrder(frame) : .outOfOrder(frame)
    }

    // After VTDecompressionSessionWaitForAsynchronousFrames on a session being dropped; returns the frames forgotten.
    mutating func drain() -> Int {
        let dropped = frames.count
        frames.removeAll()
        lastOutputTimestampNs = nil
        return dropped
    }
}

// The decoder input callback's NALs are only valid during the callback; an asynchronous decode reads them later, so
// it decodes from this copy, freed when the last reference (the output handler) goes.
final class DecodeInputCopy {
    let buffer: UnsafeMutableBufferPointer<UInt8>

    init(_ source: UnsafeMutableBufferPointer<UInt8>) {
        buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: source.count)
        _ = buffer.initialize(from: source)
    }

    deinit { buffer.deallocate() }
}

// Thread-safe DecodeInFlight: the decoder input thread blocks in `acquire` while `limit` frames are in flight and
// the decoder output handler releases the slot in `complete`.
final class DecodeGate {
    private let condition = NSCondition()
    private var flight: DecodeInFlight

    init(limit: Int = DecodeInFlight.defaultLimit) {
        flight = DecodeInFlight(limit: limit)
    }

    var limit: Int { flight.limit }

    var maxInFlight: Int {
        condition.lock()
        defer { condition.unlock() }
        return flight.maxCount
    }

    // Waits up to `timeout` s for a slot; the submit time is taken once the slot is held. nil on timeout.
    func acquire(timestampNs: UInt64, timeout: TimeInterval) -> (token: UInt64, inFlight: Int)? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !flight.canSubmit {
            if !condition.wait(until: deadline) { return nil }
        }
        guard let token = flight.submit(timestampNs: timestampNs, submitNs: DispatchTime.now().uptimeNanoseconds) else { return nil }
        return (token, flight.count)
    }

    func complete(_ token: UInt64) -> DecodeInFlight.Output {
        condition.lock()
        defer { condition.unlock() }
        condition.broadcast()
        return flight.output(token)
    }

    func cancel(_ token: UInt64) {
        condition.lock()
        defer { condition.unlock() }
        flight.cancel(token)
        condition.broadcast()
    }

    func drain() -> Int {
        condition.lock()
        defer { condition.unlock() }
        condition.broadcast()
        return flight.drain()
    }
}
