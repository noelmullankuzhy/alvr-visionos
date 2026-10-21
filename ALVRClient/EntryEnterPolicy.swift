import Foundation

enum EntryEnterPolicy {
    enum Mode: Equatable {
        case enter
        case enterDiagnostics
        case connecting
    }

    static func mode(connected: Bool, diagnostics: Bool, realityKit: Bool) -> Mode {
        if connected { return .enter }
        return diagnostics && !realityKit ? .enterDiagnostics : .connecting
    }

    // The independent offline request never owns an online session.
    static func keepOffline(requested: Bool, connected: Bool, streaming: Bool) -> Bool {
        requested && !connected && !streaming
    }
}
