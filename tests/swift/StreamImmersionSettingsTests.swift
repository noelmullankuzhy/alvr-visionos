// SOURCES: ALVRClient/GlobalSettings.swift ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift
import Foundation

@main enum StreamImmersionSettingsTests {
    static func main() throws {
        expect(!GlobalSettings().streamFullImmersion, "full immersion defaults off")
        let legacy = try JSONDecoder().decode(GlobalSettings.self, from: Data("{\"hdrPQ\":true}".utf8))
        expect(!legacy.streamFullImmersion && legacy.hdrPQ, "legacy settings retain HDR and default to mixed")
        var settings = legacy
        settings.streamFullImmersion = true
        let restored = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        expect(restored.streamFullImmersion, "full immersion persists")
        finishTests("StreamImmersionSettings")
    }
}
