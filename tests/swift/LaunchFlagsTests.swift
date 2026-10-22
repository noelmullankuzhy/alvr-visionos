// SOURCES: ALVRClient/LaunchFlags.swift ALVRClient/GlobalSettings.swift ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift ALVRClient/CropFov.swift ALVRClient/ViewLayout.swift ALVRClient/Diagnostics/ResolutionChart.swift ALVRClient/Diagnostics/GoldenFrame.swift ALVRClient/StreamReprojection.swift ALVRClient/ColourPipeline.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/BoundaryDotsLensModel.swift ALVRClient/Diagnostics/ProjectionOverlay.swift
// Launch argument (argument domain) beats the persisted setting; absent -> the setting; old settings data keeps defaults.
import Foundation

private func testBoolResolver() {
    let key = "ALVRAsyncDecode"
    expect(LaunchFlags.bool(key, setting: false, arguments: ["ALVRAsyncDecode": "YES"]), "argument YES overrides setting off")
    expect(!LaunchFlags.bool(key, setting: true, arguments: ["ALVRAsyncDecode": "NO"]), "argument NO overrides setting on")
    expect(LaunchFlags.bool(key, setting: false, arguments: ["ALVRAsyncDecode": true]), "argument true (NSNumber) overrides setting off")
    expect(!LaunchFlags.bool(key, setting: true, arguments: ["ALVRAsyncDecode": false]), "argument false overrides setting on")
    expect(LaunchFlags.bool(key, setting: true, arguments: [:]), "argument absent -> setting on")
    expect(!LaunchFlags.bool(key, setting: false, arguments: ["Other": "YES"]), "other arguments ignored -> setting off")
    expect(LaunchFlags.isOverridden(key, arguments: ["ALVRAsyncDecode": "NO"]), "present argument marks the control overridden")
    expect(!LaunchFlags.isOverridden(key, arguments: [:]), "absent argument leaves the control editable")
}

private func testDoubleResolver() {
    let key = "ALVRHDRHeadroom"
    expectEqual(LaunchFlags.double(key, setting: 0, arguments: ["ALVRHDRHeadroom": "2.5"]), 2.5, "argument string overrides setting")
    expectEqual(LaunchFlags.double(key, setting: 3, arguments: ["ALVRHDRHeadroom": "0"]), 0, "argument 0 overrides setting 3 (0 = automatic)")
    expectEqual(LaunchFlags.double(key, setting: 3, arguments: ["ALVRHDRHeadroom": 1.8]), 1.8, "argument number overrides setting")
    expectEqual(LaunchFlags.double(key, setting: 3, arguments: [:]), 3, "argument absent -> setting")
}

private func testOldSettingsDecodeWithDefaults() {
    let old = Data(#"{"hdrPQ":true,"streamFPS":"90"}"#.utf8)
    guard let s = try? JSONDecoder().decode(GlobalSettings.self, from: old) else { return expect(false, "old data decodes") }
    expect(s.hdrPQ && s.streamFPS == "90", "existing keys kept")
    expect(!s.asyncDecode && !s.deadlineSelect && !s.decodeRealTime && !s.displayP3Output, "stream/colour flags default off")
    expectEqual(s.hdrHeadroom, 0, "headroom default automatic")
    expectEqual(s.hdrReferenceWhiteNits, 0, "reference white default stream value")
    expect(!s.eyeBadges && !s.hdrProbe && !s.brightnessTrace, "diagnostics flags default off")
    let new = Data(#"{"asyncDecode":true,"hdrHeadroom":2,"brightnessTrace":true}"#.utf8)
    let t = try? JSONDecoder().decode(GlobalSettings.self, from: new)
    expect(t?.asyncDecode == true && t?.hdrHeadroom == 2 && t?.brightnessTrace == true, "new keys round-trip from data")
    expect(LaunchFlags.bool("ALVRBrightTrace", setting: false, arguments: ["ALVRBrightTrace": "YES"]), "-ALVRBrightTrace YES turns the trace on")
}

@main
enum LaunchFlagsTests {
    static func main() {
        testBoolResolver()
        testDoubleResolver()
        testOldSettingsDecodeWithDefaults()
        finishTests("LaunchFlags")
    }
}
