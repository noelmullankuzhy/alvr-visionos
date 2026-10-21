import ARKit
import QuartzCore
import RealityKit
import SwiftUI

/// World-space entities follow the device pose; no head anchor or gaze data is used.
@MainActor
private final class BoundaryDotsScene {
    let root = Entity()
    private var subscription: EventSubscription?
    private var session = BoundaryDotsSession()
    private var dotEntities: [ModelEntity] = []
    private var pinches = BoundaryDotsPinches<SpatialEventCollection.Event.ID>()
    private let cursorEntity = ModelEntity()
    private let statusEntity = ModelEntity()
    private var eyeEntities: [BoundaryDotsEye: ModelEntity] = [:]
    private var started = false
    private var finished = false
    private var poseAvailable = false

    private let dim = UnlitMaterial(color: UIColor(white: 0.18, alpha: 1))
    private let white = UnlitMaterial(color: .white)

    func install(in content: RealityViewContent) {
        guard !started else { return }
        started = true
        Diag.log("dots_session", ["event": "begin", "radius_m": BoundaryDots.radius,
                                   "pose": "device", "angles": "projected_tangent"])
        // The backdrop receives indirect pinches even when no dot is targeted.
        let backdrop = ModelEntity(mesh: .generateSphere(radius: 11), materials: [UnlitMaterial(color: .black)])
        backdrop.name = "backdrop"
        backdrop.scale = [-1, 1, 1]
        backdrop.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        backdrop.components.set(CollisionComponent(shapes: [.generateSphere(radius: 11)]))
        root.addChild(backdrop)

        let mesh = MeshResource.generateSphere(radius: Float(BoundaryDots.visualRadius))
        for (index, dot) in BoundaryDots.layout.enumerated() {
            let entity = ModelEntity(mesh: mesh, materials: [dim])
            entity.name = "dot_\(index)"
            entity.position = SIMD3<Float>(dot.direction * BoundaryDots.radius)
            makeInteractive(entity)
            dotEntities.append(entity)
            root.addChild(entity)
        }

        installCursor()
        root.addChild(cursorEntity)
        statusEntity.position = [-0.65, -0.27, -9.9]
        root.addChild(statusEntity)
        refresh()

        for size in [SIMD3<Float>(0.09, 0.015, 0.01), SIMD3<Float>(0.015, 0.09, 0.01)] {
            let cross = ModelEntity(mesh: .generateBox(size: size), materials: [white])
            cross.position = [0, 0, -10]
            root.addChild(cross)
        }
        for (index, eye) in BoundaryDotsEye.allCases.enumerated() {
            let button = ModelEntity(mesh: mesh, materials: [eye == session.eye ? white : dim])
            button.name = "eye_\(eye.rawValue)"
            button.position = [Float(index - 1) * 0.6, -0.5, -10]
            makeInteractive(button)
            addLabel(eye.rawValue, to: button)
            eyeEntities[eye] = button
            root.addChild(button)
        }
        let exit = ModelEntity(mesh: mesh, materials: [dim])
        exit.name = "leave"
        exit.position = [0, -1.05, -10]
        makeInteractive(exit)
        addLabel("Done", to: exit)
        root.addChild(exit)
        root.isEnabled = false
        content.add(root)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.followDevice()
        }
    }

    private func makeInteractive(_ entity: Entity) {
        entity.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: Float(BoundaryDots.collisionRadius))]))
        entity.components.set(HoverEffectComponent())
    }

    private func addLabel(_ text: String, to parent: Entity) {
        let label = ModelEntity(mesh: .generateText(text, extrusionDepth: 0.001,
                                                   font: .systemFont(ofSize: 0.11)), materials: [white])
        let bounds = label.visualBounds(relativeTo: label)
        label.position = [-bounds.center.x, 0.16, 0]
        parent.addChild(label)
    }

    private func followDevice() {
        guard !finished, EntryEnterPolicy.boundaryDotsVisible(diagnostics: Diag.isOn,
                  connected: EventHandler.shared.connectionState == .connected,
                  streaming: EventHandler.shared.streamingActive) else {
            root.isEnabled = false
            return
        }
        let provider = WorldTracker.shared.worldTracking
        if let provider, provider.state == .running,
           let pose = provider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()), pose.isTracked {
            root.transform = Transform(matrix: pose.originFromAnchorTransform)
            poseAvailable = true
        } else {
            poseAvailable = false
        }
        // The simulator can lack ARKit device anchors. This stationary harness
        // permits pointer hover/tap checks; headset measurements require a pose.
#if targetEnvironment(simulator)
        if !poseAvailable {
            root.transform = Transform(translation: [0, 1.6, 0])
            poseAvailable = true
        }
#endif
        root.isEnabled = poseAvailable
    }

    // A ring in the tangent plane, slightly in front of the dot field. It has
    // no hover or input component and remains visible regardless of gaze.
    private func installCursor() {
        let outer = Float(9.95 * tan(BoundaryDots.cursorDiameterDeg * .pi / 360))
        let inner = Float(9.95 * tan(0.68 * .pi / 180))
        var positions: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        for segment in 0..<64 {
            let angle = Float(segment) * 2 * .pi / 64
            for radius in [outer, inner] {
                positions.append([radius * cos(angle), radius * sin(angle), 0])
            }
            let a = UInt32(segment * 2), b = UInt32(((segment + 1) % 64) * 2)
            triangles += [a, b, a + 1, a + 1, b, b + 1]
        }
        var descriptor = MeshDescriptor(name: "boundary_cursor")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(triangles)
        if let mesh = try? MeshResource.generate(from: [descriptor]) {
            cursorEntity.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: .yellow)])
        }
    }

    /// Hand and elapsed time come from the spatial events, including events on
    /// empty black backdrop. Only a short right pinch consults the initial target.
    func spatialEvent(_ event: SpatialEventCollection.Event, target: Entity) -> Bool {
        guard !finished, poseAvailable, root.isEnabled,
              EntryEnterPolicy.boundaryDotsVisible(diagnostics: Diag.isOn,
                  connected: EventHandler.shared.connectionState == .connected,
                  streaming: EventHandler.shared.streamingActive) else {
            pinches = BoundaryDotsPinches()
            return false
        }
        guard event.kind == .indirectPinch else { return false }
        let hand: BoundaryDotsHand?
        switch event.chirality {
        case .left: hand = .left
        case .right: hand = .right
        default: hand = nil
        }
        let phase: BoundaryDotsPinchPhase
        switch event.phase {
        case .active: phase = .active
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        @unknown default: return false
        }
        guard let pinch = pinches.update(id: event.id, hand: hand, phase: phase,
                                        timestamp: event.timestamp,
                                        target: (event.targetedEntity ?? target).name) else { return false }
        if pinch.hand == .left {
            if let dot = session.step(outward: !pinch.held) {
                Diag.log("dots", session.markFields(dot, action: pinch.held ? "step_in" : "step_out", via: "step"))
            }
        } else if pinch.held {
            if let dot = session.confirm() {
                Diag.log("dots", session.markFields(dot, action: "confirm", via: "step"))
            }
        } else if let name = pinch.target {
            if name == "leave" { return true }
            if name.hasPrefix("eye_"), let eye = BoundaryDotsEye(rawValue: String(name.dropFirst(4))) {
                session.eye = eye
            } else if name.hasPrefix("dot_"), let index = Int(name.dropFirst(4)),
                      BoundaryDots.layout.indices.contains(index) {
                let dot = BoundaryDots.layout[index]
                let action = session.select(dot)
                Diag.log("dots", session.markFields(dot, action: action, via: "gaze"))
            }
        }
        refresh()
        return false
    }

    private func refresh() {
        for (index, dot) in BoundaryDots.layout.enumerated() { updateDot(index, dot) }
        for (eye, button) in eyeEntities { button.model?.materials = [eye == session.eye ? white : dim] }
        cursorEntity.isEnabled = session.cursor != nil
        var text = "\(session.eye.rawValue)  select a ray"
        if let dot = session.cursor {
            let direction = SIMD3<Float>(dot.direction)
            cursorEntity.position = direction * 9.95
            cursorEntity.orientation = simd_quatf(from: [0, 0, 1], to: -direction)
            text = String(format: "%@  ray %g  ecc %g", session.eye.rawValue, dot.rayDeg, dot.eccDeg)
        }
        text += "  [\(session.outermost(session.eye).count) rays done]"
        statusEntity.model = ModelComponent(mesh: .generateText(text, extrusionDepth: 0.001,
                                          font: .systemFont(ofSize: 0.065)),
                                          materials: [UnlitMaterial(color: UIColor(white: 0.3, alpha: 1))])
    }

    private func updateDot(_ index: Int, _ dot: BoundaryDot) {
        dotEntities[index].model?.materials = [session.isConfirmed(dot) ? white : dim]
    }

    func finish() {
        guard started, !finished else { return }
        finished = true
        subscription?.cancel()
        subscription = nil
        root.isEnabled = false
        for eye in BoundaryDotsEye.allCases { Diag.log("dots_summary", session.summaryFields(eye)) }
        Diag.flush()
    }
}

struct BoundaryDotsView: View {
    @Environment(ViewModel.self) private var model
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var scene = BoundaryDotsScene()

    private func dismiss() {
        Task { @MainActor in
            guard model.offlineDiagnostics.space == .boundaryDots,
                  model.offlineDiagnostics.requestDismissal() else { return }
            await dismissImmersiveSpace()
            model.offlineDiagnostics.dismissed()
        }
    }

    var body: some View {
        RealityView { content in
            if Diag.isOn, model.offlineDiagnostics.space == .boundaryDots {
                scene.install(in: content)
            }
        }
        .gesture(SpatialEventGesture(coordinateSpace: .local).targetedToAnyEntity()
            .onChanged { value in
                for event in value.gestureValue {
                    if scene.spatialEvent(event, target: value.entity) { dismiss() }
                }
            }
            .onEnded { value in
                for event in value.gestureValue {
                    if scene.spatialEvent(event, target: value.entity) { dismiss() }
                }
            })
        .onDisappear {
            scene.finish()
            // An ImmersiveSpace can retain SwiftUI state across presentations.
            // A later entry needs fresh marks, entities and an update subscription.
            scene = BoundaryDotsScene()
            // Keep ownership during a connection/Done dismissal until the await
            // returns; a system/manual leave clears it here.
            if model.offlineDiagnostics.space == .boundaryDots, model.offlineDiagnostics.phase == .offline {
                model.offlineDiagnostics.dismissed()
            }
        }
    }
}
