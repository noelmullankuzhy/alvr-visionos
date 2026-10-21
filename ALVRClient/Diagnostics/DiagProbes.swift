//
//  DiagProbes.swift
//
// Device-side diagnostics (GM decision 65, slice D1), all behind Diag.isOn:
// - m1 / m1_config: OS, device model, Metal device, HDR playback flags, hdrHeadroomUsageLimit (26+) at startup; the
//   layer's supported colour/depth formats and layouts, the chosen ones, foveation and render quality per configuration.
// - m5 / m5_view / m5_vrr (Metal renderer, 1 s): per view texture size/array length/slice, viewport, projection
//   tangents; per rate map screenSize and physicalSize per layer; renderQuality vs configured max (26+).
// - m6 (1 s): requested vs drawable target interval, target minus predicted presentation (actual photon time
//   unavailable), fresh/repeated/blank encoded source IDs, GPU end after rendering deadline, callback after target.
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
        CodecSupport.start()
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
            RQRenderer.configure(defaultQuality: capabilities.defaultRenderQuality.rawValue)
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

// One per Metal renderer; Renderer creates it only when Diag.isOn. The render thread appends to the cadence buffers,
// checks the schedules and, when one is due, copies plain values; formatting, percentiles and resource queries run
// in Diag.background.
final class DiagRenderProbe {
    private struct ViewSnap {
        let drawable, view, texture, slice, width, height, arrayLength: Int
        let format: MTLPixelFormat?
        let viewport: MTLViewport
        let tangents: simd_float4
    }

    private struct MapSnap {
        let drawable, map: Int
        let screen: MTLSize
        let physical: MTLSize
        let layer, layerCount: Int
    }

    private let snapshots = DiagDoubleBuffer(DiagDrawableSnapshot<ViewSnap, MapSnap>(), DiagDrawableSnapshot<ViewSnap, MapSnap>())
    struct Timing {
        let deadline, target: UInt64
        let offset: Int64
    }
    static func timing(for drawable: LayerRenderer.Drawable) -> Timing {
        Timing(deadline: ns(drawable.frameTiming.renderingDeadline), target: ns(drawable.frameTiming.presentationTime),
               offset: Int64(ns(LayerRenderer.Clock().now)) - Int64(CACurrentMediaTime() * Double(NSEC_PER_SEC)))
    }

    let cadence = DiagCadence()
    private let device: MTLDevice
    private var m5 = DiagSchedule(periodMs: 1000, fireOnFirst: true)
    private var m6 = DiagSchedule(periodMs: 1000, fireOnFirst: false)
    private var m9 = DiagSchedule(periodMs: 5000, fireOnFirst: true)

    init(device: MTLDevice) {
        self.device = device
    }

    // Render thread, after the frame's drawables are encoded. sourceId: timestamp of the video frame encoded into
    // them, nil when no video was drawn (idle, or the frame was rejected).
    func frame(layerRenderer: LayerRenderer, drawables: [LayerRenderer.Drawable], predicted: LayerRenderer.Frame.Timing, sourceId: UInt64?, timing: Timing) {
        guard let main = drawables.first else { return }
        cadence.frame(targetNs: Self.ns(main.frameTiming.presentationTime), predictedNs: Self.ns(predicted.presentationTime),
                      sourceId: sourceId, clockOffsetNs: timing.offset)
        let now = Diag.monotonicMs()
        if m6.due(nowMs: now), let raw = cadence.take() {
            let hz = Double(refreshRate)
            Diag.background { [self] in
                defer { cadence.recycle(raw) }
                Diag.log("m6", DiagCadence.fields(DiagCadence.window(raw, requestedHz: hz)))
            }
        }
        if m5.due(nowMs: now) {
            snapshotDrawables(layerRenderer, drawables)
        }
        if m9.due(nowMs: now), let gpu = cadence.takeGpu() {
            let device = device
            Diag.background { [self] in
                defer { cadence.recycleGpu(gpu) }
                let summary = DiagStats.summary(gpu.values)
                Diag.log("m9", ["thermal": Diag.thermalName(ProcessInfo.processInfo.thermalState),
                                "available_memory": os_proc_available_memory(), "phys_footprint": DiagProbes.physFootprint().map { "\($0)" } ?? "unavailable",
                                "metal_allocated": device.currentAllocatedSize, "metal_recommended_working_set": device.recommendedMaxWorkingSetSize,
                                "gpu_p50_ms": summary.map { $0.p50 as Any } ?? "unavailable", "gpu_p95_ms": summary.map { $0.p95 as Any } ?? "unavailable",
                                "gpu_samples": gpu.values.count])
            }
        }
    }

    // Command buffer completion: host-clock GPU times and callback time against the frame's layer-clock deadline/target.
    func completed(_ commandBuffer: MTLCommandBuffer, timing: Timing, callbackHostNs: UInt64) {
        cadence.completed(gpuStartHostNs: UInt64(max(commandBuffer.gpuStartTime, 0) * Double(NSEC_PER_SEC)),
                          gpuEndHostNs: UInt64(max(commandBuffer.gpuEndTime, 0) * Double(NSEC_PER_SEC)),
                          renderingDeadlineNs: timing.deadline, targetNs: timing.target, callbackHostNs: callbackHostNs, clockOffsetNs: timing.offset)
    }

    private func snapshotDrawables(_ layerRenderer: LayerRenderer, _ drawables: [LayerRenderer.Drawable]) {
        var quality: Float?
        var maxQuality: Float?
#if XCODE_BETA_26
        if #available(visionOS 26.0, *) {
            quality = layerRenderer.renderQuality.rawValue
            maxQuality = layerRenderer.configuration.maxRenderQuality.rawValue
        }
#endif
        let foveation = layerRenderer.configuration.isFoveationEnabled
        guard let snapshot = snapshots.take() else { return }
        for (d, drawable) in drawables.enumerated() {
            for (v, view) in drawable.views.enumerated() {
                let map = view.textureMap
                let texture = Int(map.textureIndex) < drawable.colorTextures.count ? drawable.colorTextures[Int(map.textureIndex)] : nil
                guard snapshot.views.count < 32 else { continue }
                snapshot.views.append(ViewSnap(drawable: d, view: v, texture: Int(map.textureIndex), slice: Int(map.sliceIndex),
                                      width: texture?.width ?? 0, height: texture?.height ?? 0, arrayLength: texture?.arrayLength ?? 0,
                                      format: texture?.pixelFormat, viewport: map.viewport, tangents: drawable.gimmeTangents(viewIndex: v)))
            }
            for (m, rateMap) in drawable.rasterizationRateMaps.enumerated() {
                for layer in 0..<rateMap.layerCount where snapshot.maps.count < 64 {
                    snapshot.maps.append(MapSnap(drawable: d, map: m, screen: rateMap.screenSize,
                                                 physical: rateMap.physicalSize(layer: layer), layer: layer, layerCount: rateMap.layerCount))
                }
            }
        }
        let drawableCount = drawables.count
        Diag.background { [self] in
            defer { snapshots.recycle(snapshot) { $0.reset() } }
            func q(_ x: Float?) -> Any { x.map { Double($0) as Any } ?? "unavailable" }
            Diag.log("m5", ["drawables": drawableCount, "render_quality": q(quality), "max_render_quality": q(maxQuality), "foveation": foveation])
            for s in snapshot.views {
                let vp = s.viewport
                let t = s.tangents
                Diag.log("m5_view", ["drawable": s.drawable, "view": s.view, "texture": s.texture, "slice": s.slice,
                                     "tex_w": s.width, "tex_h": s.height, "tex_array": s.arrayLength,
                                     "tex_format": s.format.map(DiagProbes.formatName) ?? "unavailable",
                                     "viewport": String(format: "%.0f,%.0f,%.0f,%.0f", vp.originX, vp.originY, vp.width, vp.height),
                                     "tangents": String(format: "%.4f,%.4f,%.4f,%.4f", t.x, t.y, t.z, t.w)])
            }
            for d in 0..<drawableCount where !snapshot.maps.contains(where: { $0.drawable == d }) {
                Diag.log("m5_vrr", ["drawable": d, "map": "none"])
            }
            for s in snapshot.maps where s.layer == 0 {
                Diag.log("m5_vrr", ["drawable": s.drawable, "map": s.map, "screen": "\(s.screen.width)x\(s.screen.height)",
                                    "layers": s.layerCount, "physical": snapshot.maps.filter { $0.drawable == s.drawable && $0.map == s.map }.map { "\($0.physical.width)x\($0.physical.height)" }.joined(separator: ";")])
            }
        }
    }

    private static func ns(_ instant: LayerRenderer.Clock.Instant) -> UInt64 {
        UInt64(max(LayerRenderer.Clock.Instant.epoch.duration(to: instant).timeInterval, 0) * Double(NSEC_PER_SEC))
    }
}
