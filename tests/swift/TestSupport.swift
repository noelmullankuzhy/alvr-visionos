import Foundation

// Minimal assertion support for tests/swift (no XCTest on this path).
var testChecks = 0
var testFailures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    testChecks += 1
    if !condition() {
        testFailures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

// Render-target conversion may choose either adjacent binary16 value. Keep the tolerance
// local to GPU patch assertions; integer colours, alpha and unrelated tests remain exact.
func withinFloat16ULP(_ actual: Float, _ expected: Float) -> Bool {
    let half = Float16(expected)
    guard actual.isFinite, half.isFinite else { return false }
    return abs(actual - expected) <= Float(half.ulp)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    expect(actual == expected, "\(message) expected \(expected), got \(actual)", file: file, line: line)
}

/// Forces one lock order between two lock-guarded calls on two threads, with the gate's test seams and semaphores (no sleeps):
/// the holder takes the gate lock at `holderEntry` and stays in the critical section until the waiter has reached
/// the lock at `waiterEntry`, so the waiter's call runs strictly after the holder's.
final class LockOrder {
    private let mutex = NSLock()
    private var holderEntry: String?
    private var waiterEntry: String?
    private let holderIn = DispatchSemaphore(value: 0)
    private let waiterEntered = DispatchSemaphore(value: 0)
    private var waiterWasWaiting = false

    func beforeLock(_ entry: String) {
        mutex.lock()
        let hit = entry == waiterEntry
        if hit { waiterEntry = nil }
        mutex.unlock()
        if hit { waiterEntered.signal() }
    }

    func inLock(_ entry: String) {
        mutex.lock()
        let hit = entry == holderEntry
        if hit { holderEntry = nil }
        mutex.unlock()
        guard hit else { return }
        holderIn.signal()
        waiterWasWaiting = waiterEntered.wait(timeout: .now() + 10) == .success
    }

    /// True when both calls finished and the waiter reached the lock while the holder held it.
    func run(holderEntry: String, _ holder: @escaping () -> Void, waiterEntry: String, _ waiter: @escaping () -> Void) -> Bool {
        mutex.lock()
        self.holderEntry = holderEntry
        self.waiterEntry = waiterEntry
        waiterWasWaiting = false
        mutex.unlock()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { holder(); done.signal() }
        guard holderIn.wait(timeout: .now() + 10) == .success else { return false }
        Thread.detachNewThread { waiter(); done.signal() }
        let finished = done.wait(timeout: .now() + 10) == .success && done.wait(timeout: .now() + 10) == .success
        return finished && waiterWasWaiting
    }
}

func finishTests(_ name: String) -> Never {
    print("\(name): \(testChecks) checks, \(testFailures) failures")
    exit(testFailures == 0 ? 0 : 1)
}
