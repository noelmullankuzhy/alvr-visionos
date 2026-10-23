// SOURCES: ALVRClient/DecodeInFlight.swift
// In-flight accounting, back-pressure, submit-order check and reset drain for the -ALVRAsyncDecode pipeline.
import Foundation

private func testSubmitAndOutput() {
    var flight = DecodeInFlight()
    expectEqual(flight.count, 0, "starts empty")
    guard let a = flight.submit(timestampNs: 100, submitNs: 10) else { return expect(false, "first submit accepted") }
    expectEqual(flight.count, 1, "one in flight")
    expectEqual(flight.output(a), .inOrder(DecodeInFlight.Frame(token: a, timestampNs: 100, submitNs: 10)),
                "output returns the frame with its own submit time")
    expectEqual(flight.count, 0, "output frees the slot")
    expectEqual(flight.output(a), .unknown, "a second output for the same token is ignored")
}

private func testBackPressureAtTwo() {
    var flight = DecodeInFlight()
    expectEqual(DecodeInFlight.defaultLimit, 2, "two frames in flight")
    let a = flight.submit(timestampNs: 100, submitNs: 10)
    let b = flight.submit(timestampNs: 200, submitNs: 20)
    expect(a != nil && b != nil, "two submits accepted")
    expect(!flight.canSubmit, "full at two")
    expect(flight.submit(timestampNs: 300, submitNs: 30) == nil, "third submit refused until an output")
    expectEqual(flight.count, 2, "refused submit is not counted")
    _ = flight.output(a!)
    expect(flight.canSubmit, "an output frees a slot")
    expect(flight.submit(timestampNs: 300, submitNs: 30) != nil, "third submit accepted after one output")
    expectEqual(flight.maxCount, 2, "max in flight seen")
    flight.cancel(b!)
    expectEqual(flight.count, 1, "a failed submit releases its slot")
}

private func testOutOfOrder() {
    var flight = DecodeInFlight()
    let a = flight.submit(timestampNs: 100, submitNs: 10)!
    let b = flight.submit(timestampNs: 200, submitNs: 20)!
    expectEqual(flight.output(b), .outOfOrder(DecodeInFlight.Frame(token: b, timestampNs: 200, submitNs: 20)),
                "newer frame output before the older one")
    expectEqual(flight.output(a), .outOfOrder(DecodeInFlight.Frame(token: a, timestampNs: 100, submitNs: 10)),
                "timestamp went backwards")
    let c = flight.submit(timestampNs: 50, submitNs: 30)!
    if case .outOfOrder = flight.output(c) {} else { expect(false, "timestamp older than the last output is out of order") }
}

private func testDrainOnReset() {
    var flight = DecodeInFlight()
    let a = flight.submit(timestampNs: 100, submitNs: 10)!
    _ = flight.submit(timestampNs: 200, submitNs: 20)
    expectEqual(flight.drain(), 2, "drain reports frames still in flight")
    expectEqual(flight.count, 0, "drain empties")
    expect(flight.canSubmit, "submits allowed after drain")
    expectEqual(flight.output(a), .unknown, "a late output from before the reset is ignored")
    let b = flight.submit(timestampNs: 10, submitNs: 30)!
    if case .inOrder = flight.output(b) {} else { expect(false, "drain forgets the last timestamp (new stream may restart)") }
}

private func testGateBlocksThirdSubmit() {
    let gate = DecodeGate()
    let a = gate.acquire(timestampNs: 100, timeout: 0.5)
    _ = gate.acquire(timestampNs: 200, timeout: 0.5)
    expect(gate.acquire(timestampNs: 300, timeout: 0.01) == nil, "third acquire times out while two are in flight")
    let done = DispatchSemaphore(value: 0)
    var third: (token: UInt64, inFlight: Int)?
    Thread.detachNewThread {
        third = gate.acquire(timestampNs: 300, timeout: 5)
        done.signal()
    }
    _ = gate.complete(a!.token)
    expect(done.wait(timeout: .now() + 5) == .success, "blocked acquire wakes on output")
    expectEqual(third?.inFlight, 2, "and gets a slot")
    expectEqual(gate.maxInFlight, 2, "gate reports max in flight")
}

private func testConfiguredLimit() {
    expectEqual(DecodeInFlight.inFlightKey, "ALVRDecodeInFlight", "in flight key")
    expectEqual(DecodeInFlight.configuredLimit([:]), 2, "missing key keeps two")
    expectEqual(DecodeInFlight.configuredLimit([DecodeInFlight.inFlightKey: "4"]), 4, "numeric string")
    expectEqual(DecodeInFlight.configuredLimit([DecodeInFlight.inFlightKey: NSNumber(value: 3)]), 3, "NSNumber")
    expectEqual(DecodeInFlight.configuredLimit([DecodeInFlight.inFlightKey: "0"]), 1, "clamped up to 1")
    expectEqual(DecodeInFlight.configuredLimit([DecodeInFlight.inFlightKey: "99"]), 8, "clamped down to 8")
    expectEqual(DecodeInFlight.configuredLimit([DecodeInFlight.inFlightKey: "abc"]), 2, "non-numeric keeps two")
}

private func testConfiguredSlotWait() {
    expectEqual(DecodeInFlight.slotWaitKey, "ALVRDecodeSlotWaitMs", "slot wait key")
    expectEqual(DecodeInFlight.configuredSlotWait([:]), 0.1, "missing key keeps 100 ms")
    expectEqual(DecodeInFlight.configuredSlotWait([DecodeInFlight.slotWaitKey: "0"]), 0, "0 ms refuses at once")
    expectEqual(DecodeInFlight.configuredSlotWait([DecodeInFlight.slotWaitKey: "5"]), 0.005, "5 ms")
    expectEqual(DecodeInFlight.configuredSlotWait([DecodeInFlight.slotWaitKey: "250"]), 0.1, "clamped to 100 ms")
    expectEqual(DecodeInFlight.configuredSlotWait([DecodeInFlight.slotWaitKey: "abc"]), 0.1, "non-numeric keeps 100 ms")
}

private func testConfiguredLimitInFlight() {
    var four = DecodeInFlight(limit: 4)
    for i in 1...4 { expect(four.submit(timestampNs: UInt64(i), submitNs: 1) != nil, "limit 4 accepts submit \(i)") }
    expect(four.submit(timestampNs: 5, submitNs: 1) == nil, "limit 4 refuses the fifth")
    var two = DecodeInFlight()
    _ = two.submit(timestampNs: 1, submitNs: 1)
    _ = two.submit(timestampNs: 2, submitNs: 1)
    expect(two.submit(timestampNs: 3, submitNs: 1) == nil, "default still refuses the third")
}

private func testGateRefusesAtOnceWithZeroTimeout() {
    let gate = DecodeGate(limit: 1)
    _ = gate.acquire(timestampNs: 1, timeout: 0.5)
    let start = DispatchTime.now().uptimeNanoseconds
    let second = gate.acquire(timestampNs: 2, timeout: 0)
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    expect(second == nil, "full gate refuses with timeout 0")
    expect(elapsedMs < 20, "and does not wait (\(elapsedMs) ms)")
}

@main
enum DecodeInFlightTests {
    static func main() {
        testSubmitAndOutput()
        testBackPressureAtTwo()
        testOutOfOrder()
        testDrainOnReset()
        testGateBlocksThirdSubmit()
        testConfiguredLimit()
        testConfiguredSlotWait()
        testConfiguredLimitInFlight()
        testGateRefusesAtOnceWithZeroTimeout()
        finishTests("DecodeInFlightTests")
    }
}
