//
//  ALVRClientApp.swift
//
// High-level application stuff, notably includes:
// - Changelogs (incl app version checks)
// - GlobalSettings save/load hooks
// - Each different space:
//   - DummyImmersiveSpace: Literally just fetches FOV information/view transforms and exits
//   - RealityKitClient: The RealityKit renderer.
//   - MetalClient: Old reliable, the Metal renderer.
// - Metal Layer config (ContentStageConfiguration)
//

import SwiftUI
import CompositorServices

struct ContentStageConfiguration: CompositorLayerConfiguration {
    // Immersion style of the space this layer is in, for the diagnostics log only.
    var immersion = "unknown"

    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
    
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            if foveationEnabled {
                configuration.maxRenderQuality = .init(1.0)
            }
            //configuration.drawableRenderContextRasterSampleCount = 1
        }
#endif
        
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)
        
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
        
        configuration.colorFormat = .rgba16Float
        if Diag.isOn {
            DiagProbes.configuration(capabilities, configuration, immersion: immersion)
        }
    }
}

@main
struct ALVRClientApp: App {
    @State private var model = ViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    static var gStore = GlobalSettingsStore()
    @ObservedObject private var edrPresentation = EDRPresentation.shared
    // Triggers body re-evaluation, and the .upper​Limb​Visibility modifiers will pick up the new show​Hands​Overlaid or progressive value live
    @ObservedObject private var observedGStore = ALVRClientApp.gStore

    private var clientImmersionStyle: Binding<ImmersionStyle> {
        .constant(observedGStore.openedStreamFullImmersion ? .full : .mixed)
    }
    @State private var realityKitImmersionStyle: ImmersionStyle = ALVRClientApp.gStore.settings.enableProgressive ? .progressive : .mixed
    
    static let shared = ALVRClientApp()
    static var showedChangelog = false
    @State private var showChangelog = false
    
    let testChangelog = false
    let changelogText = """
    See the Help and Information tab for wiki links on setting up your PC and network for ALVR.\n\
    \n\
    ________________________________\n\
    \n\
    What's changed?\n\
    \n\
    • Improved face tracking quality, particularly for asymmetry, eye winking and squinting, and gaze tracking.\n\
    \n\
    ________________________________\n\
    \n\
    Bug fixes:\n\
    \n\
    • Fixed a bug where the room would randomly recenter when encoding errors happened.\n\
    • Fixed a bug where the SteamVR dashboard would be sunk into the ground when entering.\n\
    • Fixed a bug where the gaze-pinch system button gesture (pinching both hands and moving them apart) would not trigger.\n\
    \n\
    ________________________________\n\
    \n\
    Known issues:\n\
    \n\
    • Hands may still show despite the hand visibility being set to off. This is a longstanding visionOS bug. Open and close the Control Center to fix.\n\
    • The client may fail to connect to the streamer is microphone streaming is enabled. Add the client IP address manually to the streamer to resolve the issue.\n\
    • PSVR2 controllers are currently missing full support for button touches and grip/trigger proximity, please file feedback with Apple if this feature is important to you.\n\
    
    """
    
    func saveSettings() {
        do {
            try ALVRClientApp.gStore.save(settings: ALVRClientApp.gStore.settings)
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    func loadSettings() {
        do {
            try ALVRClientApp.gStore.load()
        } catch {
            fatalError(error.localizedDescription)
        }
        // Check if the app version has changed and show a changelog if so
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            if let buildVersionNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                let currentVersion = appVersion + " build " + buildVersionNumber
                print("Previous version:", ALVRClientApp.gStore.settings.lastUsedAppVersion)
                print("Current version:", currentVersion)
                if currentVersion != ALVRClientApp.gStore.settings.lastUsedAppVersion || (testChangelog && !ALVRClientApp.showedChangelog) {
                    ALVRClientApp.gStore.settings.lastUsedAppVersion = currentVersion
                    saveSettings()
                    
                    if !ALVRClientApp.showedChangelog {
                        showChangelog = true
                    }
                    ALVRClientApp.showedChangelog = true
                }
            }
        }
    }

    var body: some Scene {
        //Entry point, this is the default window chosen in Info.plist from UIApplicationPreferredDefaultSceneSessionRole
        WindowGroup(id: "Entry") {
            Entry {
                Task {
                    saveSettings()
                }
            }
            // Keep the window and auto-enter state alive, but clear the field
            // while measuring. Dismissing/recreating Entry would rearm auto-enter.
            .opacity(model.offlineDiagnostics.space == .boundaryDots ? 0 : 1)
            .allowsHitTesting(model.offlineDiagnostics.space != .boundaryDots)
            .task {
                model.isShowingClient = false
                EventHandler.shared.initializeAlvr()
                DiagProbes.start()
                if Diag.isOn { EventHandler.shared.objectWillChange.send() } // reveal the gated diagnostic controls
                await WorldTracker.shared.initializeAr()
                EventHandler.shared.start()
            }
            .onChange(of: observedGStore.settings.enableProgressive) {
                realityKitImmersionStyle = ALVRClientApp.gStore.settings.enableProgressive ? .progressive : .mixed
            }
            .environment(model)
            .environmentObject(EventHandler.shared)
            .environmentObject(ALVRClientApp.gStore)
            .fixedSize()
            .alert(isPresented: $showChangelog) {
                Alert(
                    title: Text("ALVR v" + ALVRClientApp.gStore.settings.lastUsedAppVersion),
                    message: Text(changelogText),
                    dismissButton: .default(
                        Text("Dismiss"),
                        action: {
                            
                        }
                    )
                )
            }
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)

        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background:
                // TODO: revisit if we decide to let app run in background (ie, keep it open + reconnect when headset is donned)
                /*if !model.isShowingClient {
                    //Lobby closed manually: disconnect ALVR
                    //EventHandler.shared.stop()
                    if EventHandler.shared.alvrInitialized {
                        alvr_pause()
                    }
                }
                if !EventHandler.shared.streamingActive {
                    EventHandler.shared.handleHeadsetRemoved()
                }*/
                break
            case .inactive:
                // Scene inactive, currently no action for this
                break
            case .active:
                // Scene active, make sure everything is started if it isn't
                // TODO: revisit if we decide to let app run in background (ie, keep it open + reconnect when headset is donned)
                /*if !model.isShowingClient {
                    WorldTracker.shared.resetPlayspace()
                    EventHandler.shared.initializeAlvr()
                    EventHandler.shared.start()
                    EventHandler.shared.handleHeadsetRemovedOrReentry()
                }
                if EventHandler.shared.alvrInitialized {
                    alvr_resume()
                }*/
                EventHandler.shared.handleHeadsetEntered()
                break
            @unknown default:
                break
            }
        }
        
        // Offline exercise harness for the controller input stack. Deliberately
        // a plain window rather than an ImmersiveSpace: it needs to be readable
        // alongside the lobby with no renderer running, and it must not compete
        // with the client space for the single immersive slot.
        WindowGroup(id: "InputDebug") {
            InputDebugView()
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "BrightnessDiagnostics") {
            BrightnessDiagnostics()
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: "EDRDiagnostic") {
            CompositorLayer(configuration: EDRConfiguration()) { layer in
                guard Diag.isOn else { return }
                EDRSession.shared.setImmersion(edrPresentation.immersion.rawValue)
                do { try EDRRenderer(layer, immersion: edrPresentation.immersion.rawValue).start() }
                catch { Diag.log("edr", ["error": error.localizedDescription, "immersion": edrPresentation.immersion.rawValue]) }
            }
        }
        .immersionStyle(selection: .constant(edrPresentation.style), in: .full, .mixed)
        .upperLimbVisibility(.hidden)

        ImmersiveSpace(id: "PQDiagnostic") {
            PQImmersiveView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // Offline test space: the real Metal renderer, entered with no streamer
        // connected, which is the state that already draws the room wireframe.
        // Deliberately contains no UI of its own — the input debug window stays
        // open in front of it, which is the whole point of entering from there.
        //
        // Pinned to .mixed rather than sharing clientImmersionStyle: a .full
        // space would hide that window.
        ImmersiveSpace(id: "InputDebugSpace") {
            CompositorLayer(configuration: ContentStageConfiguration(immersion: "mixed")) { layerRenderer in
                let system = MetalClientSystem(layerRenderer)
                system.startRenderLoop()
            }
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)

        ImmersiveSpace(id: "DummyImmersiveSpace") {
            CompositorLayer(configuration: ContentStageConfiguration(immersion: "full")) { layerRenderer in
                let renderer = DummyMetalRenderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)

        ImmersiveSpace(id: "RealityKitClient") {
            RealityKitClientView()
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: $realityKitImmersionStyle, in: .mixed, .progressive)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)

        // Independent entry for offline diagnostics; the online Enter path is unchanged.
        ImmersiveSpace(id: "MetalDiagnosticsOffline") {
            CompositorLayer(configuration: ContentStageConfiguration(immersion: "mixed")) { layerRenderer in
                guard Diag.isOn else { return }
                let system = MetalClientSystem(layerRenderer, offlineDiagnostics: true)
                system.startRenderLoop()
                // Manual leave releases ownership. Connection dismissal is awaited by the
                // entry action, which retains ownership until dismissImmersiveSpace returns.
                Task { @MainActor in
                    while layerRenderer.state != .invalidated && !Task.isCancelled {
                        guard model.offlineDiagnostics.space == .metal, model.offlineDiagnostics.phase == .offline else { return }
                        do { try await Task.sleep(nanoseconds: 100_000_000) }
                        catch { break }
                    }
                    if model.offlineDiagnostics.space == .metal, model.offlineDiagnostics.phase == .offline { model.offlineDiagnostics.dismissed() }
                }
            }
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)

        // Own RealityKit input scene: system gaze hover + targeted pinch, offline only.
        ImmersiveSpace(id: "BoundaryDotsOffline") {
            BoundaryDotsView()
                .environment(model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.hidden)

        ImmersiveSpace(id: "MetalClient") {
            let fullImmersion = observedGStore.openedStreamFullImmersion
            CompositorLayer(configuration: ContentStageConfiguration(immersion: fullImmersion ? "full" : "mixed")) { layerRenderer in
                EventHandler.streamImmersion.opened(fullImmersion: fullImmersion)
                let system = MetalClientSystem(layerRenderer)
                system.startRenderLoop()
            }
        }
        .disablePersistentSystemOverlaysForVisionOS2(shouldDisable: ALVRClientApp.gStore.settings.disablePersistentSystemOverlays ? .hidden : .automatic)
        .immersionStyle(selection: clientImmersionStyle, in: .mixed, .full)
        .upperLimbVisibility(ALVRClientApp.gStore.settings.showHandsOverlaid ? .visible : .hidden)
    }
}
