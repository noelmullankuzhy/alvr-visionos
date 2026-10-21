// SOURCES: ALVRClient/EntryEnterPolicy.swift ALVRClient/AutoEnterPolicy.swift
@main
enum OfflineDiagnosticsLifecycleTests {
    static func main() {
        var session = OfflineDiagnosticsLifecycle()
        expectEqual(session.phase, .idle)
        expect(!session.begin(diagnostics: false, connected: false, streaming: false), "startup requires Diag.isOn")
        expect(!session.begin(diagnostics: true, connected: true, streaming: false), "never enter over a connection")
        expect(session.begin(diagnostics: true, connected: false, streaming: false), "idle -> offline")
        var autoEnter = AutoEnterPolicy(enabled: true)
        expect(!autoEnter.update(connected: true, showing: true), "manual offline entry consumes auto-enter")
        expectEqual(session.phase, .offline)
        expect(!session.begin(diagnostics: true, connected: false, streaming: false), "only one offline owner")
        expect(!session.connectionArrived(connected: false, streaming: false), "idle frames keep the space")
        expect(session.connectionArrived(connected: true, streaming: false), "connection requests dismissal")
        expectEqual(session.phase, .dismissing)
        expect(session.ownsSpace, "retain offline ownership until dismissal finishes")
        expect(!session.connectionArrived(connected: true, streaming: true), "dismiss exactly once")
        session.dismissed()
        expectEqual(session.phase, .idle)
        expect(!session.ownsSpace, "clear flags after awaited dismissal")
        expectEqual(EntryEnterPolicy.mode(connected: true, diagnostics: true, realityKit: false), .enter, "online Enter available")
        expect(!autoEnter.update(connected: true, showing: false), "late connection publication cannot auto-open online space")

        for previousRenderStarted in [false, true] {
            expect(session.begin(diagnostics: true, connected: false, streaming: false), "offline session preserves prior ownership")
            let offline = MetalRenderOwnership(offlineDiagnostics: true)
            var renderStarted = previousRenderStarted
            if offline.publishesRenderStarted { renderStarted = true }
            expect(offline.shouldRun(onlineRenderStarted: renderStarted), "offline frames independent of online renderStarted")
            session.dismissed()
            expectEqual(renderStarted, previousRenderStarted, "offline leaves online ownership untouched")
            // EventHandler.updateConnectionState's existing gate must still allow publication.
            expectEqual(!renderStarted, !previousRenderStarted, "connection publication unchanged during and after offline")
        }
        let offline = MetalRenderOwnership(offlineDiagnostics: true)
        expect(!offline.shouldRun(onlineRenderStarted: false, connected: true), "offline draw stops on connection")
        expect(!offline.shouldRun(onlineRenderStarted: false, streaming: true), "offline draw stops on stream race")
        let online = MetalRenderOwnership(offlineDiagnostics: false)
        expect(online.shouldRun(onlineRenderStarted: true, connected: true, streaming: true), "online connection gates unchanged")
        expect(online.publishesRenderStarted, "online initialization unchanged")
        expect(!online.shouldRun(onlineRenderStarted: false), "online loop still uses shared gate")
        expect(online.shouldRun(onlineRenderStarted: true), "online rendering unchanged")

        expect(session.begin(diagnostics: true, connected: false, streaming: false), "reenter after dismissal")
        session.dismissed()
        expect(!session.ownsSpace, "offline -> leave resets ownership")
        expect(session.begin(diagnostics: true, connected: false, streaming: false), "enter for stream race")
        expect(session.connectionArrived(connected: false, streaming: true), "stream arrival also serializes dismissal")
        expect(session.ownsSpace, "stream does not clear flags before dismissal")
        session.dismissed()
        expectEqual(session.phase, .idle)
        finishTests("OfflineDiagnosticsLifecycleTests")
    }
}
