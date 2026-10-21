// SOURCES: ALVRClient/EntryEnterPolicy.swift
@main
enum EntryEnterPolicyTests {
    static func main() {
        for connected in [false, true] {
            for diagnostics in [false, true] {
                for realityKit in [false, true] {
                    let expected: EntryEnterPolicy.Mode = connected ? .enter
                        : (diagnostics && !realityKit ? .enterDiagnostics : .connecting)
                    expect(EntryEnterPolicy.mode(connected: connected, diagnostics: diagnostics, realityKit: realityKit) == expected,
                           "connected=\(connected) diagnostics=\(diagnostics) realityKit=\(realityKit)")
                }
            }
        }
        for requested in [false, true] {
            for connected in [false, true] {
                for streaming in [false, true] {
                    expectEqual(EntryEnterPolicy.keepOffline(requested: requested, connected: connected, streaming: streaming),
                                requested && !connected && !streaming,
                                "offline flag clears on connection or stream; online never opts in")
                }
            }
        }
        finishTests("EntryEnterPolicyTests")
    }
}
