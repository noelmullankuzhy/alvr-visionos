//
//  LaunchFlags.swift
//
// Effective value of an option that has both a launch argument and a persisted settings control: the launch argument
// when it is present in the argument domain (`-Key value` on the devicectl command line), else the UI setting.
//

import Foundation
import Metal

enum LaunchFlags {
    static var currentArguments: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    static func isOverridden(_ key: String, arguments: [String: Any] = currentArguments) -> Bool {
        arguments[key] != nil
    }

    static func bool(_ key: String, setting: Bool, arguments: [String: Any] = currentArguments) -> Bool {
        switch arguments[key] {
        case let value as NSNumber: return value.boolValue
        case let value as String: return (value as NSString).boolValue
        default: return setting
        }
    }

    static func double(_ key: String, setting: Double, arguments: [String: Any] = currentArguments) -> Double {
        switch arguments[key] {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return (value as NSString).doubleValue
        default: return setting
        }
    }
}

// Render-pass fixes for the one-eye brightness flicker (rdr2-overnight/report-right-eye.md), launch-only for headset A/B:
// no settings control, so with no argument the renderer is today's.
// -ALVRDepthPassFix YES: the "Rerender depth" pass writes depth only (colour writeMask []) and loads and stores colour,
// instead of discarding colour (.dontCare) with colour writes on, which leaves each TBDR tile/slice's colour undefined.
// -ALVRUniformSnapshot YES: Renderer binds geometry uniforms with setVertexBytes copies, not ring slots the GPU may
// still be reading.
enum RenderPassFixes {
    static let depthPassKey = "ALVRDepthPassFix"
    static let uniformSnapshotKey = "ALVRUniformSnapshot"

    static func enabled(_ key: String, arguments: [String: Any] = LaunchFlags.currentArguments) -> Bool {
        LaunchFlags.bool(key, setting: false, arguments: arguments)
    }

    // The depth-only pass: depth is cleared, written and stored under both values.
    static func configureDepthPass(_ pass: MTLRenderPassDescriptor, fix: Bool) {
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = fix ? .store : .dontCare
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 0.000000001
    }

    static func configureDepthPipeline(_ pipeline: MTLRenderPipelineDescriptor, fix: Bool) {
        pipeline.colorAttachments[0].writeMask = fix ? [] : .all
    }
}
