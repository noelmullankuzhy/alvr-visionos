//
//  GlobalSettings.swift
//
// Client-side settings and defaults
//

import Foundation
import SwiftUI

struct GlobalSettings: Codable {
    var keepSteamVRCenter: Bool = false
    var showHandsOverlaid: Bool = false
    var disablePersistentSystemOverlays: Bool = true
    var enableDoubleTapForHands: Bool = false
    var streamFPS: String = "Default"
    var realityKitRenderer: Bool = false
    var chromaKeyEnabled: Bool = false
    var chromaKeyDistRangeMin: Float = 0.35
    var chromaKeyDistRangeMax: Float = 0.7
    var chromaKeyColorR: Float = 16.0 / 255.0
    var chromaKeyColorG: Float = 124.0 / 255.0
    var chromaKeyColorB: Float = 16.0 / 255.0
    var dismissWindowOnEnter: Bool = true
    var emulatedPinchInteractions: Bool = false
    var fovRenderScale: Float = 1.0
    var forceMipmapEyeTracking = false
    var targetHandsAtRoundtripLatency = false
    var enablePersonaFaceTracking = false
    var showFaceTrackingDebug = false
    var enableProgressive = false
    var lastUsedAppVersion = "never launched"
    var chaperoneDistanceCm: Int = 0
    var showPerformanceHud: Bool = false
    var claimControllerHomeButton: Bool = true
    // Sent as prefer_hdr at ALVR initialisation (GM decision 63); off = SDR request as before.
    var hdrPQ: Bool = false
    var streamFullImmersion: Bool = false
    // "Diagnostics" (GM decision 65): DIAG lines to alvr_log and Documents/diag; read once at launch.
    var diagnostics: Bool = false
    var captureDiagnosticFrames: Bool = false
    var renderQualitySweep: Bool = false
    // Corner chart (decision 65, CornerChartMode raw value): with Diagnostics on and no stream; read at renderer start.
    var cornerChart: String = CornerChartMode.off.rawValue
    // Resolution chart (ResolutionChart.swift, CornerChartMode raw value) and its foveation choice: Diagnostics only,
    // no stream; read at renderer start / layer configuration.
    var resolutionChart: String = CornerChartMode.off.rawValue
    var resolutionFoveation: Bool = true
    // Crop FOV to outline (CropFov.swift, docs/lumen/crop-fov.md): report the model lens's inset rectangle + margin as each eye's
    // FOV instead of the device frustum; on by default (CropFov.defaultEnabled); read when the view config is sent (stream start).
    var cropFovToOutline: Bool = CropFov.defaultEnabled
    var cropMarginDeg: Double = CropFov.defaultMarginDeg
    // Golden frame set (GoldenFrame.swift): a Documents/diag/golden/<set> directory name, or Off; Diagnostics only, both
    // charts off; read at renderer start.
    var goldenFrameSet: String = GoldenFrameSetting.off
    // Two windows with the decoded left and right eye images and per-eye counters (EyeDecodeWindows.swift).
    var eyeDecodeWindows: Bool = GlobalSettings.eyeDecodeWindowsDefault

    // Launch-argument options with a settings control (LaunchFlags.swift); a launch argument still wins. Read once at stream /
    // session start, so a change applies at the next connect. 0 = automatic for the two HDR numbers.
    var asyncDecode: Bool = false
    var deadlineSelect: Bool = false
    var decodeRealTime: Bool = false
    var displayP3Output: Bool = false
    var hdrHeadroom: Double = 0
    var hdrReferenceWhiteNits: Double = 0
    var eyeBadges: Bool = false
    var hdrProbe: Bool = false
    var brightnessTrace: Bool = false

    // On in the simulator, where there is no headset to judge decoding by; off on device.
    static let eyeDecodeWindowsDefault: Bool = {
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }()

    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.keepSteamVRCenter = try container.decodeIfPresent(Bool.self, forKey: .keepSteamVRCenter) ?? self.keepSteamVRCenter
        self.showHandsOverlaid = try container.decodeIfPresent(Bool.self, forKey: .showHandsOverlaid) ?? self.showHandsOverlaid
        self.disablePersistentSystemOverlays = try container.decodeIfPresent(Bool.self, forKey: .disablePersistentSystemOverlays) ?? self.disablePersistentSystemOverlays
        self.enableDoubleTapForHands = try container.decodeIfPresent(Bool.self, forKey: .enableDoubleTapForHands) ?? self.enableDoubleTapForHands
        self.streamFPS = try container.decodeIfPresent(String.self, forKey: .streamFPS) ?? self.streamFPS
        self.realityKitRenderer = try container.decodeIfPresent(Bool.self, forKey: .realityKitRenderer) ?? self.realityKitRenderer
        self.chromaKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .chromaKeyEnabled) ?? self.chromaKeyEnabled
        self.chromaKeyDistRangeMin = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMin) ?? self.chromaKeyDistRangeMin
        self.chromaKeyDistRangeMax = try container.decodeIfPresent(Float.self, forKey: .chromaKeyDistRangeMax) ?? self.chromaKeyDistRangeMax
        self.chromaKeyColorR = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorR) ?? self.chromaKeyColorR
        self.chromaKeyColorG = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorG) ?? self.chromaKeyColorG
        self.chromaKeyColorB = try container.decodeIfPresent(Float.self, forKey: .chromaKeyColorB) ?? self.chromaKeyColorB
        self.dismissWindowOnEnter = try container.decodeIfPresent(Bool.self, forKey: .dismissWindowOnEnter) ?? self.dismissWindowOnEnter
        self.emulatedPinchInteractions = try container.decodeIfPresent(Bool.self, forKey: .emulatedPinchInteractions) ?? self.emulatedPinchInteractions
        self.fovRenderScale = try container.decodeIfPresent(Float.self, forKey: .fovRenderScale) ?? self.fovRenderScale
        self.forceMipmapEyeTracking = try container.decodeIfPresent(Bool.self, forKey: .forceMipmapEyeTracking) ?? self.forceMipmapEyeTracking
        self.targetHandsAtRoundtripLatency = try container.decodeIfPresent(Bool.self, forKey: .targetHandsAtRoundtripLatency) ?? self.targetHandsAtRoundtripLatency
        self.enablePersonaFaceTracking = try container.decodeIfPresent(Bool.self, forKey: .enablePersonaFaceTracking) ?? self.enablePersonaFaceTracking
        self.showFaceTrackingDebug = try container.decodeIfPresent(Bool.self, forKey: .showFaceTrackingDebug) ?? self.showFaceTrackingDebug
        self.enableProgressive = try container.decodeIfPresent(Bool.self, forKey: .enableProgressive) ?? self.enableProgressive
        self.lastUsedAppVersion = try container.decodeIfPresent(String.self, forKey: .lastUsedAppVersion) ?? self.lastUsedAppVersion
        self.chaperoneDistanceCm = try container.decodeIfPresent(Int.self, forKey: .chaperoneDistanceCm) ?? self.chaperoneDistanceCm
        self.showPerformanceHud = try container.decodeIfPresent(Bool.self, forKey: .showPerformanceHud) ?? self.showPerformanceHud
        self.claimControllerHomeButton = try container.decodeIfPresent(Bool.self, forKey: .claimControllerHomeButton) ?? self.claimControllerHomeButton
        self.streamFullImmersion = try container.decodeIfPresent(Bool.self, forKey: .streamFullImmersion) ?? self.streamFullImmersion
        self.hdrPQ = try container.decodeIfPresent(Bool.self, forKey: .hdrPQ) ?? self.hdrPQ
        self.renderQualitySweep = try container.decodeIfPresent(Bool.self, forKey: .renderQualitySweep) ?? self.renderQualitySweep
        self.diagnostics = try container.decodeIfPresent(Bool.self, forKey: .diagnostics) ?? self.diagnostics
        self.captureDiagnosticFrames = try container.decodeIfPresent(Bool.self, forKey: .captureDiagnosticFrames) ?? self.captureDiagnosticFrames
        self.cornerChart = try container.decodeIfPresent(String.self, forKey: .cornerChart) ?? self.cornerChart
        self.resolutionChart = try container.decodeIfPresent(String.self, forKey: .resolutionChart) ?? self.resolutionChart
        self.resolutionFoveation = try container.decodeIfPresent(Bool.self, forKey: .resolutionFoveation) ?? self.resolutionFoveation
        self.cropFovToOutline = try container.decodeIfPresent(Bool.self, forKey: .cropFovToOutline) ?? self.cropFovToOutline
        self.cropMarginDeg = try container.decodeIfPresent(Double.self, forKey: .cropMarginDeg) ?? self.cropMarginDeg
        self.goldenFrameSet = try container.decodeIfPresent(String.self, forKey: .goldenFrameSet) ?? self.goldenFrameSet
        self.eyeDecodeWindows = try container.decodeIfPresent(Bool.self, forKey: .eyeDecodeWindows) ?? self.eyeDecodeWindows
        self.asyncDecode = try container.decodeIfPresent(Bool.self, forKey: .asyncDecode) ?? self.asyncDecode
        self.deadlineSelect = try container.decodeIfPresent(Bool.self, forKey: .deadlineSelect) ?? self.deadlineSelect
        self.decodeRealTime = try container.decodeIfPresent(Bool.self, forKey: .decodeRealTime) ?? self.decodeRealTime
        self.displayP3Output = try container.decodeIfPresent(Bool.self, forKey: .displayP3Output) ?? self.displayP3Output
        self.hdrHeadroom = try container.decodeIfPresent(Double.self, forKey: .hdrHeadroom) ?? self.hdrHeadroom
        self.hdrReferenceWhiteNits = try container.decodeIfPresent(Double.self, forKey: .hdrReferenceWhiteNits) ?? self.hdrReferenceWhiteNits
        self.eyeBadges = try container.decodeIfPresent(Bool.self, forKey: .eyeBadges) ?? self.eyeBadges
        self.hdrProbe = try container.decodeIfPresent(Bool.self, forKey: .hdrProbe) ?? self.hdrProbe
        self.brightnessTrace = try container.decodeIfPresent(Bool.self, forKey: .brightnessTrace) ?? self.brightnessTrace
    }
}

extension GlobalSettingsStore {
    static let sampleData: GlobalSettingsStore =
    GlobalSettingsStore()
}

class GlobalSettingsStore: ObservableObject {
    @Published var settings: GlobalSettings = GlobalSettings()
    
    init() {
        try? load()
    }

    private static func fileURL() throws -> URL {
        try FileManager.default.url(for: .documentDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        .appendingPathComponent("globalsettings.data")
    }
    
    func load() throws {
        let fileURL = try Self.fileURL()
        guard let data = try? Data(contentsOf: fileURL) else {
            return self.settings = GlobalSettings()
        }
        let globalSettings = try JSONDecoder().decode(GlobalSettings.self, from: data)
        self.settings = globalSettings
    }
    
    func save(settings: GlobalSettings) throws {
        let data = try JSONEncoder().encode(settings)
        let outfile = try Self.fileURL()
        try data.write(to: outfile)
    }
}

// Value captured once for a frame/build. Shader variants never reread settings or mutable Renderer fields.
struct ChromaKeySnapshot: Equatable {
    let enabled: Bool
    let colour: SIMD3<Float>
    let range: SIMD2<Float>
    init(settings: GlobalSettings) {
        enabled = settings.chromaKeyEnabled
        colour = SIMD3(settings.chromaKeyColorR, settings.chromaKeyColorG, settings.chromaKeyColorB)
        range = SIMD2(settings.chromaKeyDistRangeMin, settings.chromaKeyDistRangeMax)
    }
}
