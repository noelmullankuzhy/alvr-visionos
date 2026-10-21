/*
Abstract:
Controls that allow entry into the ALVR environment.
*/

import SwiftUI

/// Controls that allow entry into the ALVR environment.
struct EntryControls: View {
    @Environment(ViewModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject var eventHandler = EventHandler.shared
    @EnvironmentObject var gStore: GlobalSettingsStore
    
    @State private var showImmersiveSpace = false
    @State private var immersiveSpaceIsShown = false
    // Scripted launches (-ALVRAutoEnter YES) enter on their own; there is no tap in the simulator.
    @State private var autoEnter = AutoEnterPolicy(enabled: UserDefaults.standard.bool(forKey: "ALVRAutoEnter"))

    let saveAction: ()->Void

    /// -ALVRAutoEnterRenderer metal|realitykit overrides the saved setting for this launch only (never written back).
    private var useRealityKit: Bool {
        switch UserDefaults.standard.string(forKey: "ALVRAutoEnterRenderer")?.lowercased() {
        case "realitykit": return true
        case "metal": return false
        default: return gStore.settings.realityKitRenderer
        }
    }

    private func autoEnterIfDue() {
        guard !model.isShowingDiagnosticsOffline else { return }
        if autoEnter.update(connected: eventHandler.connectionState == .connected, showing: model.isShowingClient) {
            print("ALVRAUTO entering immersive renderer=\(useRealityKit ? "realitykit" : "metal")")
            model.isShowingClient = true
        }
    }

    private func enterOffline(_ space: OfflineDiagnosticsLifecycle.Space) {
        Task { @MainActor in
            guard model.offlineDiagnostics.begin(space: space, diagnostics: Diag.isOn,
                      connected: eventHandler.connectionState == .connected,
                      streaming: eventHandler.streamingActive, onlineShowing: model.isShowingClient) else { return }
            // Manual entry consumes auto-enter for an arriving connection, even
            // if its publication lands after offline dismissal has finished.
            _ = autoEnter.update(connected: true, showing: true)
            switch await openImmersiveSpace(id: space.rawValue) {
            case .opened:
                while model.offlineDiagnostics.space == space {
                    if model.offlineDiagnostics.connectionArrived(
                            connected: eventHandler.connectionState == .connected,
                            streaming: eventHandler.streamingActive) {
                        await dismissImmersiveSpace()
                        model.offlineDiagnostics.dismissed()
                        break
                    }
                    do { try await Task.sleep(nanoseconds: 100_000_000) }
                    catch { break }
                }
            default: model.offlineDiagnostics.dismissed()
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        
        HStack(spacing: 17) {
            if eventHandler.connectionState == .connected {
                Toggle(isOn: $model.isShowingClient) {
                    Label("Enter", systemImage: "visionpro")
                        .labelStyle(.titleAndIcon)
                        .padding(15)
                }
                .disabled(model.isShowingDiagnosticsOffline)
            } else {
                Label("Connecting...", systemImage: "visionpro")
                    .labelStyle(.titleOnly)
                    .padding(15)
            }

            if EntryEnterPolicy.mode(connected: eventHandler.connectionState == .connected,
                                     diagnostics: Diag.isOn, realityKit: useRealityKit) == .enterDiagnostics,
               !eventHandler.streamingActive {
                Button {
                    enterOffline(.metal)
                } label: {
                    Label("Enter diagnostics", systemImage: "visionpro")
                        .labelStyle(.titleAndIcon)
                        .padding(15)
                }
                .disabled(model.isShowingDiagnosticsOffline || model.isShowingClient)
            }
            if EntryEnterPolicy.boundaryDotsVisible(diagnostics: Diag.isOn,
                    connected: eventHandler.connectionState == .connected, streaming: eventHandler.streamingActive) {
                Button {
                    enterOffline(.boundaryDots)
                } label: {
                    Label("Boundary dots", systemImage: "circle.dotted")
                        .labelStyle(.titleAndIcon)
                        .padding(15)
                }
                .disabled(model.isShowingDiagnosticsOffline || model.isShowingClient)
            }
            
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .glassBackgroundEffect(in: .rect(cornerRadius: 50))

        .onChange(of: eventHandler.connectionState, initial: true) { autoEnterIfDue() }
        .onChange(of: model.isShowingClient) { autoEnterIfDue() }

        //Enable Client
        .onChange(of: model.isShowingClient) { _, isShowing in
            Task {
                if isShowing {

                    saveAction()
                    print("Opening Immersive Space")
                    if useRealityKit {
                        if !DummyMetalRenderer.haveRenderInfo {
                            var dummySpaceIsOpened = false
                            while !dummySpaceIsOpened {
                                switch await openImmersiveSpace(id: "DummyImmersiveSpace") {
                                case .opened:
                                    dummySpaceIsOpened = true
                                case .error, .userCancelled:
                                    fallthrough
                                @unknown default:
                                    dummySpaceIsOpened = false
                                }
                            }
                            
                            while dummySpaceIsOpened && !DummyMetalRenderer.haveRenderInfo {
                                try! await Task.sleep(nanoseconds: 1_000_000)
                            }
                            
                            await dismissImmersiveSpace()
                            try! await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        
                        if !DummyMetalRenderer.haveRenderInfo {
                            print("MISSING VIEW INFO!!")
                        }
                        
                        WorldTracker.shared.worldTrackingAddedOriginAnchor = false
                        
                        print("Open real immersive space")
                        
                        switch await openImmersiveSpace(id: "RealityKitClient") {
                        case .opened:
                            immersiveSpaceIsShown = true
                        case .error, .userCancelled:
                            fallthrough
                        @unknown default:
                            immersiveSpaceIsShown = false
                            showImmersiveSpace = false
                        }
                    }
                    else {
                        let spaceID = gStore.settings.streamFullImmersion ? "MetalClientFull" : "MetalClient"
                        await openImmersiveSpace(id: spaceID)
                    }
                    VideoHandler.applyRefreshRate(videoFormat: EventHandler.shared.videoFormat)
                    if gStore.settings.dismissWindowOnEnter {
                        dismissWindow(id: "Entry")
                    }
                }
            }
        }

    }
}
