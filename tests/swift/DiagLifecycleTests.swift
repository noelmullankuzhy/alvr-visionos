// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagMeasurements.swift ALVRClient/Diagnostics/DiagNetSink.swift
import Foundation

private final class State {
    let lock = NSLock()
    var created = 0, invalidated = 0, callbacks = 0
    func change(_ body: (State) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
}

private func waitForStage(_ semaphore: DispatchSemaphore) { _ = semaphore.wait(timeout: .now() + 10) }

@main enum DiagLifecycleTests {
    static func main() async {
        Diag.start(enabled: true, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), console: nil)
        for duringCreation in [true, false] {
            let lifetime = DiagDecodeLifetime(), id = UUID(), state = State()
            let entered = DispatchSemaphore(value: 0), resumeOperation = DispatchSemaphore(value: 0)
            let cancelled = DispatchSemaphore(value: 0), draining = DispatchSemaphore(value: 0)
            let drainCallbacks = DispatchSemaphore(value: 0), invalidating = DispatchSemaphore(value: 0)
            let finishInvalidation = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
            lifetime.cancellation.cancellationHandler = { cancelled.signal() }
            // Same lifetime wrapper as the real bench. Fake blocking create/submit calls
            // exercise cancellation at both boundaries without requiring VideoToolbox hardware.
            var worker: Task<Void, Never>?
            expect(DiagWorkGate.start(id: id) {
                worker = Task.detached {
                    await lifetime.run { progress in
                        state.change { $0.created = duringCreation ? 1 : 2; $0.callbacks = duringCreation ? 0 : 8 }
                        entered.signal()
                        waitForStage(resumeOperation) // in create / in submit
                        if duringCreation { state.change { $0.created += 1 } }
                        // Cancellation may race the return from either hardware API.
                        if progress.isCancelled {
                            draining.signal(); waitForStage(drainCallbacks)
                            state.change { $0.callbacks = 0; $0.invalidated = 1 }
                            invalidating.signal(); waitForStage(finishInvalidation)
                            state.change { $0.invalidated = $0.created }
                        }
                    }
                }
                return { lifetime.cancelAndWait() }
            }, "start decoder worker")
            expect(entered.wait(timeout: .now() + 5) == .success, "worker in hardware operation")
            Thread.detachNewThread { DiagWorkGate.setStreaming(true); stopped.signal() }
            expect(cancelled.wait(timeout: .now() + 5) == .success, "stream requests cancellation")
            expect(stopped.wait(timeout: .now()) == .timedOut, "stream waits for blocked operation")
            DiagWorkGate.setStreaming(false)
            // Admission must refuse promptly while stop waits, not block on the stop mutex.
            let refused = DispatchSemaphore(value: 0)
            Thread.detachNewThread { if !DiagWorkGate.start({ return {} }) { refused.signal() } }
            expect(refused.wait(timeout: .now() + 1) == .success, "gate stays closed during cancellation")
            resumeOperation.signal()
            expect(draining.wait(timeout: .now() + 5) == .success, "draining callbacks after operation returns")
            expect(stopped.wait(timeout: .now()) == .timedOut, "callback drain retains exclusion")
            drainCallbacks.signal()
            expect(invalidating.wait(timeout: .now() + 5) == .success, "invalidating sessions")
            DiagWorkGate.finish(id) // stale/early completion cannot override an in-progress stop
            expect(!DiagWorkGate.start { return {} }, "partial invalidation retains exclusion")
            expect(stopped.wait(timeout: .now()) == .timedOut, "stop still waiting for all sessions")
            finishInvalidation.signal()
            expect(stopped.wait(timeout: .now() + 5) == .success, "stream released after teardown")
            await worker?.value
            state.change {
                expectEqual($0.created, 2, "both sessions accounted for")
                expectEqual($0.invalidated, 2, "all sessions invalidated before release")
                expectEqual($0.callbacks, 0, "no outstanding callbacks")
            }
            expect(DiagWorkGate.start { return {} }, "gate reopens after teardown")
            DiagWorkGate.stop()
        }
        finishTests("DiagLifecycle")
    }
}
