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
        // Inward-facing, unlit black sphere behind every dot; no collision/input.
        let backdrop = ModelEntity(mesh: .generateSphere(radius: 11), materials: [UnlitMaterial(color: .black)])
        backdrop.scale = [-1, 1, 1]
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

    /// Only the system's selected entity is delivered here, never a gaze ray.
    func tap(_ entity: Entity) -> Bool {
        guard !finished, poseAvailable, root.isEnabled,
              EntryEnterPolicy.boundaryDotsVisible(diagnostics: Diag.isOn,
                  connected: EventHandler.shared.connectionState == .connected,
                  streaming: EventHandler.shared.streamingActive) else { return false }
        if entity.name == "leave" { return true }
        if entity.name.hasPrefix("eye_"), let eye = BoundaryDotsEye(rawValue: String(entity.name.dropFirst(4))) {
            session.eye = eye
            for (index, dot) in BoundaryDots.layout.enumerated() { updateDot(index, dot) }
            for (label, button) in eyeEntities { button.model?.materials = [label == eye ? white : dim] }
        } else if entity.name.hasPrefix("dot_"), let index = Int(entity.name.dropFirst(4)),
                  BoundaryDots.layout.indices.contains(index) {
            let dot = BoundaryDots.layout[index]
            let action = session.toggle(dot)
            Diag.log("dots", session.markFields(dot, action: action))
            updateDot(index, dot)
        }
        return false
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

    var body: some View {
        RealityView { content in
            if Diag.isOn, model.offlineDiagnostics.space == .boundaryDots {
                scene.install(in: content)
            }
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            if scene.tap(value.entity) {
                Task { @MainActor in
                    guard model.offlineDiagnostics.space == .boundaryDots,
                          model.offlineDiagnostics.requestDismissal() else { return }
                    await dismissImmersiveSpace()
                    model.offlineDiagnostics.dismissed()
                }
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
