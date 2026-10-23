// SOURCES: ALVRClient/GlobalSettings.swift ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/CornerChart.swift ALVRClient/CropFov.swift ALVRClient/LaunchFlags.swift ALVRClient/ViewLayout.swift ALVRClient/Diagnostics/ResolutionChart.swift ALVRClient/Diagnostics/GoldenFrame.swift ALVRClient/StreamReprojection.swift ALVRClient/ColourPipeline.swift ALVRClient/Diagnostics/BoundaryDots.swift ALVRClient/Diagnostics/BoundaryDotsLensModel.swift ALVRClient/Diagnostics/ProjectionOverlay.swift
import Foundation

@main enum ChromaKeyTests {
    static func main() throws {
        var settings = GlobalSettings()
        settings.chromaKeyEnabled = true
        settings.chromaKeyColorR = 0.2
        settings.chromaKeyDistRangeMax = 0.8
        let snapshot = ChromaKeySnapshot(settings: settings)
        let first = snapshot.colour
        settings.chromaKeyColorR = 0.9
        settings.chromaKeyDistRangeMax = 0.1
        settings.chromaKeyEnabled = false
        expectEqual(snapshot.colour, first, "settings mutation between two shader reads cannot mix colour")
        expectEqual(snapshot.colour.x, 0.2, "captured colour")
        expectEqual(snapshot.range.y, 0.8, "captured range")
        expect(snapshot.enabled, "captured enable")
        expectEqual(ChromaKeySnapshot(settings: settings).colour.x, 0.9, "next frame sees new settings")
        let source = try String(contentsOfFile: "ALVRClient/Renderer.swift", encoding: .utf8)
        let video = source.components(separatedBy: "func buildRenderPipelineForVideoFrameWithDevice")[1].components(separatedBy: "// Writes FOV")[0]
        expect(!video.contains("gStore.settings"), "video pipelines consume immutable snapshot")
        expect(!video.contains("&chromaKeyEnabled") && !video.contains("&chromaKeyLerpDistRange"), "function constants use local snapshot, not shared mutable renderer fields")
        expect(source.contains("rebuildRenderPipelines(chromaKey: chromaKey)"), "frame snapshot forwarded to asynchronous build")
        finishTests("ChromaKey")
    }
}
