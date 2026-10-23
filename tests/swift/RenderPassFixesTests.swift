// SOURCES: ALVRClient/LaunchFlags.swift
// Render-pass A/B fixes (RenderPassFixes in LaunchFlags.swift): launch-argument parsing, both off by default, and the
// depth-only pass's colour attachment and pipeline colour writes under each -ALVRDepthPassFix value. No Metal device.
import Foundation
import Metal

private func testFlagParsing() {
    for key in [RenderPassFixes.depthPassKey, RenderPassFixes.uniformSnapshotKey] {
        expect(!RenderPassFixes.enabled(key, arguments: [:]), "\(key) absent -> off")
        expect(RenderPassFixes.enabled(key, arguments: [key: "YES"]), "\(key) YES -> on")
        expect(!RenderPassFixes.enabled(key, arguments: [key: "NO"]), "\(key) NO -> off")
        expect(RenderPassFixes.enabled(key, arguments: [key: true]), "\(key) true (NSNumber) -> on")
        expect(!RenderPassFixes.enabled(key, arguments: ["ALVRBrightTrace": "YES"]), "\(key): other flags ignored")
    }
    expectEqual(RenderPassFixes.depthPassKey, "ALVRDepthPassFix", "-ALVRDepthPassFix")
    expectEqual(RenderPassFixes.uniformSnapshotKey, "ALVRUniformSnapshot", "-ALVRUniformSnapshot")
    let both = ["ALVRDepthPassFix": "YES", "ALVRUniformSnapshot": "NO"]
    expect(RenderPassFixes.enabled(RenderPassFixes.depthPassKey, arguments: both)
           && !RenderPassFixes.enabled(RenderPassFixes.uniformSnapshotKey, arguments: both), "each flag independent")
}

private func testDepthPassDescriptor() {
    for fix in [false, true] {
        let pass = MTLRenderPassDescriptor()
        RenderPassFixes.configureDepthPass(pass, fix: fix)
        let colour = pass.colorAttachments[0]!
        expectEqual(colour.loadAction, .load, "fix=\(fix): colour loaded")
        expectEqual(colour.storeAction, fix ? .store : .dontCare, "fix=\(fix): colour \(fix ? "stored" : "discarded (today)")")
        // Depth exactly as before under both values.
        expectEqual(pass.depthAttachment.loadAction, .clear, "fix=\(fix): depth cleared")
        expectEqual(pass.depthAttachment.storeAction, .store, "fix=\(fix): depth stored")
        expectEqual(pass.depthAttachment.clearDepth, 0.000000001, "fix=\(fix): depth clear value unchanged")
    }
}

private func testDepthPipelineColourWrites() {
    let off = MTLRenderPipelineDescriptor()
    RenderPassFixes.configureDepthPipeline(off, fix: false)
    expectEqual(off.colorAttachments[0].writeMask, .all, "off: colour writes enabled (today)")
    let on = MTLRenderPipelineDescriptor()
    RenderPassFixes.configureDepthPipeline(on, fix: true)
    expectEqual(on.colorAttachments[0].writeMask, [], "on: no colour writes")
    expect(!on.colorAttachments[0].isBlendingEnabled, "on: no blending either")
}

// -ALVRUniformSnapshot covers every ring binding only if each goes through Renderer.bindUniforms/bindPlaneUniforms: the
// raw ring binds appear once each, inside those helpers.
private func testUniformBindingsGoThroughHelpers() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let source = try? String(contentsOf: root.appendingPathComponent("ALVRClient/Renderer.swift"), encoding: .utf8) else {
        return expect(false, "Renderer.swift readable")
    }
    func count(_ needle: String) -> Int { source.components(separatedBy: needle).count - 1 }
    expectEqual(count("setVertexBuffer(dynamicUniformBuffer"), 1, "uniform ring bound only in bindUniforms")
    expectEqual(count("setVertexBuffer(dynamicPlaneUniformBuffer"), 1, "plane ring bound only in bindPlaneUniforms")
    expectEqual(count("setVertexBufferOffset(planeUniformBufferOffset"), 1, "plane ring offset moved only in bindPlaneUniforms")
    expect(count("bindUniforms(renderEncoder)") >= 6 && count("bindPlaneUniforms(renderEncoder") >= 9, "call sites use the helpers")
}

@main
enum RenderPassFixesTests {
    static func main() {
        testFlagParsing()
        testDepthPassDescriptor()
        testDepthPipelineColourWrites()
        testUniformBindingsGoThroughHelpers()
        finishTests("RenderPassFixes")
    }
}
