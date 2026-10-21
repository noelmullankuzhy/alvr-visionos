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

struct OfflineDiagnosticsLifecycle {
    enum Phase { case idle, offline, dismissing }
    private(set) var phase = Phase.idle
    var ownsSpace: Bool { phase != .idle }

    mutating func begin(diagnostics: Bool, connected: Bool, streaming: Bool) -> Bool {
        guard diagnostics, !ownsSpace,
              EntryEnterPolicy.keepOffline(requested: true, connected: connected, streaming: streaming) else { return false }
        phase = .offline
        return true
    }

    mutating func connectionArrived(connected: Bool, streaming: Bool) -> Bool {
        guard phase == .offline, connected || streaming else { return false }
        phase = .dismissing
        return true
    }

    mutating func dismissed() { phase = .idle }
}

struct MetalRenderOwnership {
    let offlineDiagnostics: Bool
    var publishesRenderStarted: Bool { !offlineDiagnostics }
    func shouldRun(onlineRenderStarted: Bool, connected: Bool = false, streaming: Bool = false) -> Bool {
        offlineDiagnostics ? !connected && !streaming : onlineRenderStarted
    }
}
