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

    static func boundaryDotsVisible(diagnostics: Bool, connected: Bool, streaming: Bool) -> Bool {
        diagnostics && keepOffline(requested: true, connected: connected, streaming: streaming)
    }
}

struct OfflineDiagnosticsLifecycle {
    enum Space: String { case metal = "MetalDiagnosticsOffline", boundaryDots = "BoundaryDotsOffline" }
    enum Phase { case idle, offline, dismissing }
    private(set) var phase = Phase.idle
    private(set) var space: Space?
    var ownsSpace: Bool { phase != .idle }

    mutating func begin(space: Space = .metal, diagnostics: Bool, connected: Bool, streaming: Bool, onlineShowing: Bool = false) -> Bool {
        guard diagnostics, !ownsSpace, !onlineShowing,
              EntryEnterPolicy.keepOffline(requested: true, connected: connected, streaming: streaming) else { return false }
        self.space = space
        phase = .offline
        return true
    }

    mutating func connectionArrived(connected: Bool, streaming: Bool) -> Bool {
        guard phase == .offline, connected || streaming else { return false }
        return requestDismissal()
    }

    mutating func requestDismissal() -> Bool {
        guard phase == .offline else { return false }
        phase = .dismissing
        return true
    }

    mutating func dismissed() {
        phase = .idle
        space = nil
    }
}

struct MetalRenderOwnership {
    let offlineDiagnostics: Bool
    var publishesRenderStarted: Bool { !offlineDiagnostics }
    func shouldRun(onlineRenderStarted: Bool, connected: Bool = false, streaming: Bool = false) -> Bool {
        offlineDiagnostics ? !connected && !streaming : onlineRenderStarted
    }
}
