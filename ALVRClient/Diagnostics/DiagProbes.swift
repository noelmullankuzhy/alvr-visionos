//
//  DiagProbes.swift
//
// Device-side diagnostics (GM decision 65, slice D1), all behind Diag.isOn:
// - m1 / m1_config: OS, device model, Metal device, HDR playback flags, hdrHeadroomUsageLimit (26+) at startup; the
//   layer's supported colour/depth formats and layouts, the chosen ones, foveation and render quality per configuration.
// - m5 / m5_view / m5_vrr (Metal renderer, 1 s): per view texture size/array length/slice, viewport, projection
//   tangents; per rate map screenSize and physicalSize per layer; renderQuality vs configured max (26+).
// - m6 (1 s): requested vs achieved frame interval, drawable vs predicted presentation, fresh vs repeated, missed.
// - m9 (5 s): thermal state, os_proc_available_memory, phys_footprint, Metal allocation and working set, GPU p50/p95.
// An API the running OS lacks is logged as "unavailable", never estimated.
//

import Foundation
import CompositorServices
import Metal
import AVFoundation
import UIKit
import os

enum DiagProbes {
    private static let unavailable = "unavailable"

    // Main thread, once ALVR's logger is up and before any render thread starts.
    @MainActor static func start() {
        guard !Diag.isOn, Diag.enabled(environment: ProcessInfo.processInfo.environment, setting: ALVRClientApp.gStore.settings.diagnostics) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        Diag.start(enabled: true, directory: docs.appendingPathComponent("diag"),
                   console: { alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), $0) })
        let device = MTLCreateSystemDefaultDevice()
        var headroom = unavailable
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            switch UITraitCollection.current.hdrHeadroomUsageLimit {
            case .unspecified: headroom = "unspecified"
            case .active: headroom = "active"
            case .inactive: headroom = "inactive"
            @unknown default: headroom = "unknown_\(UITraitCollection.current.hdrHeadroomUsageLimit.rawValue)"
            }
        }
#endif
        Diag.log("m1", ["os": ProcessInfo.processInfo.operatingSystemVersionString, "model": modelIdentifier(),
                        "app": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? unavailable,
                        "metal_device": device?.name ?? unavailable, "apple9": device?.supportsFamily(.apple9) ?? false,
                        "apple10": device?.supportsFamily(.apple10) ?? false,
                        "eligible_for_hdr_playback": AVPlayer.eligibleForHDRPlayback, "hdr_headroom_usage_limit": headroom,
                        "hdr_setting": ALVRClientApp.gStore.settings.hdrPQ, "thermal": Diag.thermalName(ProcessInfo.processInfo.thermalState)])
    }

    static func configuration(_ capabilities: LayerRenderer.Capabilities, _ configuration: LayerRenderer.Configuration, immersion: String) {
        var colourFormats = capabilities.supportedColorFormats
        var progressiveColourFormats = unavailable
        var defaultQuality = unavailable
        var maxQuality = unavailable
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            colourFormats = capabilities.supportedColorFormats(options: [])
            progressiveColourFormats = formats(capabilities.supportedColorFormats(options: [.progressiveImmersionEnabled]))
            defaultQuality = String(format: "%.3f", capabilities.defaultRenderQuality.rawValue)
            maxQuality = String(format: "%.3f", configuration.maxRenderQuality.rawValue)
        }
#endif
        Diag.log("m1_config", ["immersion": immersion, "color_formats": formats(colourFormats),
                               "color_formats_progressive": progressiveColourFormats, "depth_formats": formats(capabilities.supportedDepthFormats),
                               "layouts": layouts(capabilities.supportedLayouts(options: [])),
                               "layouts_foveated": capabilities.supportsFoveation ? layouts(capabilities.supportedLayouts(options: [.foveationEnabled])) : unavailable,
                               "supports_foveation": capabilities.supportsFoveation,
                               "chosen_color": formatName(configuration.colorFormat), "chosen_depth": formatName(configuration.depthFormat),
                               "chosen_layout": layouts([configuration.layout]), "foveation": configuration.isFoveationEnabled,
                               "default_render_quality": defaultQuality, "max_render_quality": maxQuality])
    }

    static func formats(_ list: [MTLPixelFormat]) -> String {
        list.isEmpty ? "none" : list.map(formatName).joined(separator: ",")
    }

    // Names for the formats a layer can offer; anything else as raw<value> (MTLPixelFormat rawValue).
    private static let formatNames: [MTLPixelFormat: String] = [
        .bgra8Unorm: "bgra8Unorm", .bgra8Unorm_srgb: "bgra8Unorm_srgb", .rgba8Unorm: "rgba8Unorm", .rgba8Unorm_srgb: "rgba8Unorm_srgb",
        .rgba16Float: "rgba16Float", .rgb10a2Unorm: "rgb10a2Unorm", .bgr10a2Unorm: "bgr10a2Unorm", .bgr10_xr: "bgr10_xr",
        .bgr10_xr_srgb: "bgr10_xr_srgb", .bgra10_xr: "bgra10_xr", .bgra10_xr_srgb: "bgra10_xr_srgb", .rg11b10Float: "rg11b10Float",
        .depth16Unorm: "depth16Unorm", .depth32Float: "depth32Float", .depth32Float_stencil8: "depth32Float_stencil8"]

    static func formatName(_ format: MTLPixelFormat) -> String {
        formatNames[format] ?? "raw\(format.rawValue)"
    }

    static func layouts(_ list: [LayerRenderer.Layout]) -> String {
        list.map { layout -> String in
            switch layout {
            case .dedicated: return "dedicated"
            case .shared: return "shared"
            case .layered: return "layered"
            @unknown default: return "unknown"
            }
        }.joined(separator: ",")
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

// One per Metal renderer; Renderer creates it only when Diag.isOn.
final class DiagRenderProbe {
    let cadence = DiagCadence()
    private var lastM5Ms = Int.min
    private var lastM9Ms = Int.min

    // Render thread, once per frame after the drawables are queried.
    func frame(layerRenderer: LayerRenderer, drawables: [LayerRenderer.Drawable], predicted: LayerRenderer.Frame.Timing, fresh: Bool, device: MTLDevice) {
        guard let main = drawables.first else { return }
        cadence.frame(presentNs: Self.ns(main.frameTiming.presentationTime), predictedNs: Self.ns(predicted.presentationTime), fresh: fresh)
        let now = Diag.monotonicMs()
        if let window = cadence.drain(nowMs: now, requestedHz: Double(refreshRate)) {
            Diag.log("m6", DiagCadence.fields(window))
        }
        if now - lastM5Ms >= 1000 || now < lastM5Ms {
            lastM5Ms = now
            logDrawables(layerRenderer, drawables)
        }
        if now - lastM9Ms >= 5000 || now < lastM9Ms {
            lastM9Ms = now
            let gpu = cadence.drainGpu()
            let available = os_proc_available_memory()
            Diag.log("m9", ["thermal": Diag.thermalName(ProcessInfo.processInfo.thermalState),
                            "available_memory": available, "phys_footprint": DiagProbes.physFootprint().map { "\($0)" } ?? "unavailable",
                            "metal_allocated": device.currentAllocatedSize, "metal_recommended_working_set": device.recommendedMaxWorkingSetSize,
                            "gpu_p50_ms": gpu.map { $0.p50 as Any } ?? "unavailable", "gpu_p95_ms": gpu.map { $0.p95 as Any } ?? "unavailable"])
        }
    }

    // Command buffer completion.
    func completed(_ commandBuffer: MTLCommandBuffer, vsyncNs: UInt64, completionNs: UInt64) {
        let gpuNs = commandBuffer.gpuEndTime > commandBuffer.gpuStartTime ? UInt64((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * Double(NSEC_PER_SEC)) : 0
        cadence.completed(gpuNs: gpuNs, late: FramePacing.isLate(vsyncNs: vsyncNs, completionNs: completionNs))
    }

    private func logDrawables(_ layerRenderer: LayerRenderer, _ drawables: [LayerRenderer.Drawable]) {
        var quality = "unavailable"
        var maxQuality = "unavailable"
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            quality = String(format: "%.3f", layerRenderer.renderQuality.rawValue)
            maxQuality = String(format: "%.3f", layerRenderer.configuration.maxRenderQuality.rawValue)
        }
#endif
        Diag.log("m5", ["drawables": drawables.count, "render_quality": quality, "max_render_quality": maxQuality,
                        "foveation": layerRenderer.configuration.isFoveationEnabled])
        for (d, drawable) in drawables.enumerated() {
            for (v, view) in drawable.views.enumerated() {
                let map = view.textureMap
                let texture = Int(map.textureIndex) < drawable.colorTextures.count ? drawable.colorTextures[Int(map.textureIndex)] : nil
                let vp = map.viewport
                let t = drawable.gimmeTangents(viewIndex: v)
                Diag.log("m5_view", ["drawable": d, "view": v, "texture": map.textureIndex, "slice": map.sliceIndex,
                                     "tex_w": texture?.width ?? 0, "tex_h": texture?.height ?? 0, "tex_array": texture?.arrayLength ?? 0,
                                     "tex_format": texture.map { DiagProbes.formatName($0.pixelFormat) } ?? "unavailable",
                                     "viewport": String(format: "%.0f,%.0f,%.0f,%.0f", vp.originX, vp.originY, vp.width, vp.height),
                                     "tangents": String(format: "%.4f,%.4f,%.4f,%.4f", t.x, t.y, t.z, t.w)])
            }
            for (m, rateMap) in drawable.rasterizationRateMaps.enumerated() {
                let physical = (0..<rateMap.layerCount).map { layer -> String in
                    let size = rateMap.physicalSize(layer: layer)
                    return "\(size.width)x\(size.height)"
                }
                Diag.log("m5_vrr", ["drawable": d, "map": m, "screen": "\(rateMap.screenSize.width)x\(rateMap.screenSize.height)",
                                    "layers": rateMap.layerCount, "physical": physical.joined(separator: ";")])
            }
            if drawable.rasterizationRateMaps.isEmpty {
                Diag.log("m5_vrr", ["drawable": d, "map": "none"])
            }
        }
    }

    private static func ns(_ instant: LayerRenderer.Clock.Instant) -> UInt64 {
        UInt64(max(LayerRenderer.Clock.Instant.epoch.duration(to: instant).timeInterval, 0) * Double(NSEC_PER_SEC))
    }
}
