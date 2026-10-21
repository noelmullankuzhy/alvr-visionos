//
//  MetalClientSystem.swift
//
// MetalClientSystem generally matches the Renderer abstraction
// that RealityKitClientSystem requires, to allow as much code
// shared for both input and rendering as possible.
//

import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import ARKit
import VideoToolbox
import ObjectiveC

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

class MetalClientSystem {

    var renderer: Renderer;
    let layerRenderer: LayerRenderer

    init(_ layerRenderer: LayerRenderer, offlineDiagnostics: Bool = false) {
        self.renderer = Renderer(layerRenderer, offlineDiagnostics: offlineDiagnostics)
        self.layerRenderer = layerRenderer
    }

    func startRenderLoop() {
        Task(priority: .userInteractive) {
            renderer.rebuildRenderPipelines()
            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }
    
    func renderLoop() {
        defer { renderer.stopQualitySweep() }
    
        layerRenderer.waitUntilRunning()
        
        layerRenderer.onSpatialEvent = { eventCollection in
            for event in eventCollection {
                self.renderer.cornerChart?.spatialEvent(event)
                if !self.renderer.renderOwnership.offlineDiagnostics {
                    RealityKitClientView.handleSpatialEvent(nil, event)
                }
            }
        }
        
        if !renderer.renderOwnership.offlineDiagnostics {
            EventHandler.shared.handleHeadsetRemovedOrReentry()
        }
        let timeSinceLastLoop = CACurrentMediaTime()
        while renderer.renderOwnership.shouldRun(onlineRenderStarted: EventHandler.shared.renderStarted,
                connected: EventHandler.shared.connectionState == .connected,
                streaming: EventHandler.shared.streamingActive) {
            if layerRenderer.state == .invalidated {
                if renderer.renderOwnership.offlineDiagnostics { break }
                print("Layer is invalidated")
                //EventHandler.shared.stop()
                EventHandler.shared.handleHeadsetRemovedOrReentry()
                EventHandler.shared.handleHeadsetRemoved()
                WorldTracker.shared.resetPlayspace()
                alvr_pause()

                // visionOS sometimes sends these invalidated things really fkn late...
                // But generally, we want to exit fully when the user exits.
                if CACurrentMediaTime() - timeSinceLastLoop < 1.0 {
                    exit(0)
                }
                break
            } else if layerRenderer.state == .paused {
                renderer.stopQualitySweep()
                layerRenderer.waitUntilRunning()
                //EventHandler.shared.handleHeadsetRemovedOrReentry()
                continue
            } else {
                autoreleasepool {
                    renderer.renderFrame()
                }
            }
        }
    }
}
