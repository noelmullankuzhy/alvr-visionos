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
    private var drag = BoundaryDotsDrag<SpatialEventCollection.Event.ID>()
    private var slider = BoundaryDotsSlider<SpatialEventCollection.Event.ID>()
    private let cursorEntity = ModelEntity()
    private let statusEntity = ModelEntity()
    private let outlineEntity = ModelEntity()
    private let insetEntity = ModelEntity()
    private let limitsEntity = ModelEntity()
    private var outlineShown: (eye: BoundaryDotsEye, inset: Double, frustum: BoundaryDotsFrustum)?
    private var eyeEntities: [BoundaryDotsEye: ModelEntity] = [:]
    private var started = false
    private var finished = false
    private var poseAvailable = false

    private let dim = UnlitMaterial(color: UIColor(white: 0.18, alpha: 1))
    private let white = UnlitMaterial(color: .white)
    private let bright = UnlitMaterial(color: UIColor(red: 0.2, green: 1, blue: 0.4, alpha: 1))

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
        // Controls keep their 1 deg spheres; only the reference dots shrank.
        let buttonMesh = MeshResource.generateSphere(radius: Float(BoundaryDots.radius * sin(.pi / 360)))
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
        root.addChild(outlineEntity)
        statusEntity.position = [-0.65, -0.27, -9.9]
        root.addChild(statusEntity)
        for entity in [insetEntity, limitsEntity] { root.addChild(entity) }

        // A quick right pinch on the centre cross deselects the cursor (the left drag then sizes the outline).
        let centre = Entity()
        centre.name = "centre"
        centre.position = [0, 0, -10]
        makeInteractive(centre)
        for size in [SIMD3<Float>(0.09, 0.015, 0.01), SIMD3<Float>(0.015, 0.09, 0.01)] {
            centre.addChild(ModelEntity(mesh: .generateBox(size: size), materials: [white]))
        }
        root.addChild(centre)
        refresh()
        for (index, eye) in BoundaryDotsEye.allCases.enumerated() {
            let button = ModelEntity(mesh: buttonMesh, materials: [eye == session.eye ? white : dim])
            button.name = "eye_\(eye.rawValue)"
            button.position = [Float(index - 1) * 0.6, -0.5, -10]
            makeInteractive(button)
            addLabel(eye.rawValue, to: button)
            eyeEntities[eye] = button
            root.addChild(button)
        }
        let exit = ModelEntity(mesh: buttonMesh, materials: [dim])
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
    /// `handPosition` is the pinch point (inputDevicePose) in scene metres; the
    /// left hand drags the cursor along its ray, the right hand selects/confirms.
    func spatialEvent(_ event: SpatialEventCollection.Event, target: Entity, handPosition: SIMD3<Float>?) -> Bool {
        guard !finished, poseAvailable, root.isEnabled,
              EntryEnterPolicy.boundaryDotsVisible(diagnostics: Diag.isOn,
                  connected: EventHandler.shared.connectionState == .connected,
                  streaming: EventHandler.shared.streamingActive) else {
            pinches = BoundaryDotsPinches()
            drag = BoundaryDotsDrag()
            slider = BoundaryDotsSlider()
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
        if let handPosition {
            let rotation = simd_quatd(vector: SIMD4<Double>(root.orientation.vector))
            // Without a cursor the left drag is the outline slider; a started slide or cursor drag keeps its meaning.
            if slider.active || (!drag.active && session.cursor == nil) {
                switch slider.update(id: event.id, hand: hand, phase: phase, position: SIMD3<Double>(handPosition),
                                     headRotation: rotation, inset: session.inset,
                                     enabled: session.cursor == nil && session.eye != .both) {
                case .move(let inset)?, .release(_, let inset)?:
                    session.inset = inset
                    refresh()
                case nil:
                    break
                }
            } else {
                switch drag.update(id: event.id, hand: hand, phase: phase, position: SIMD3<Double>(handPosition),
                                   headRotation: rotation, cursor: session.cursor) {
                case .move(let dot)?:
                    if session.place(dot) { refresh() }
                case .release(let from, let to)?:
                    if session.place(to) {
                        Diag.log("dots", session.markFields(to, action: to.eccDeg > from.eccDeg ? "step_out" : "step_in", via: "step"))
                        refresh()
                    }
                case nil:
                    break
                }
            }
        }
        guard let pinch = pinches.update(id: event.id, hand: hand, phase: phase,
                                        timestamp: event.timestamp,
                                        target: (event.targetedEntity ?? target).name) else { return false }
        // Left pinches only drag (above); a quick left pinch is reserved.
        if pinch.hand == .left { return false }
        if pinch.held {
            if let dot = session.confirm() {
                Diag.log("dots", session.markFields(dot, action: "confirm", via: "step"))
            } else if let (frustum, source) = BoundaryDotsTangents.frustum(session.eye),
                      let fields = session.outlineFields(frustum: frustum, source: source) {
                Diag.log("dots_outline", fields)
            }
        } else if let name = pinch.target {
            if name == "leave" { return true }
            if name == "centre" { _ = session.deselect() }
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
        var text = "\(session.eye.rawValue)  select a ray" + (session.eye == .both ? "" : "  |  left drag: outline")
        if let dot = session.cursor {
            let direction = SIMD3<Float>(dot.direction)
            cursorEntity.position = direction * 9.95
            cursorEntity.orientation = simd_quatf(from: [0, 0, 1], to: -direction)
            text = String(format: "%@  ray %g  ecc %g  |  left drag: cursor, pinch cross for outline",
                          session.eye.rawValue, dot.rayDeg, dot.eccDeg)
        }
        text += "  [\(session.outermost(session.eye).count) rays done]"
        refreshOutline()
        statusEntity.model = ModelComponent(mesh: .generateText(text, extrusionDepth: 0.001,
                                          font: .systemFont(ofSize: 0.065)),
                                          materials: [UnlitMaterial(color: UIColor(white: 0.3, alpha: 1))])
    }

    /// The inset outline of the selected eye, its inset and four side limits under the centre cross.
    /// Both has no monocular frustum: the outline and its labels are hidden.
    private func refreshOutline() {
        guard let (frustum, _) = BoundaryDotsTangents.frustum(session.eye),
              let limits = frustum.limits(eye: session.eye, insetDeg: session.inset) else {
            outlineShown = nil
            for entity in [outlineEntity, insetEntity, limitsEntity] { entity.isEnabled = false }
            return
        }
        for entity in [outlineEntity, insetEntity, limitsEntity] { entity.isEnabled = true }
        if let shown = outlineShown, shown.eye == session.eye, shown.inset == session.inset, shown.frustum == frustum { return }
        outlineShown = (session.eye, session.inset, frustum)
        if let mesh = outlineMesh(frustum.outline(insetDeg: session.inset)) {
            outlineEntity.model = ModelComponent(mesh: mesh, materials: [bright])
        }
        setCentredText(insetEntity, String(format: "inset %.1f deg  area %.0f%%", session.inset,
                                           100 * frustum.areaFraction(insetDeg: session.inset)), y: -0.12)
        setCentredText(limitsEntity, String(format: "nasal %.1f  temporal %.1f  up %.1f  down %.1f",
                                            limits.nasal, limits.temporal, limits.up, limits.down), y: -0.2)
    }

    private func setCentredText(_ entity: ModelEntity, _ text: String, y: Float) {
        entity.model = ModelComponent(mesh: .generateText(text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.065)),
                                      materials: [bright])
        let bounds = entity.visualBounds(relativeTo: entity)
        entity.position = [-bounds.center.x, y, -9.9]
    }

    // A closed ribbon of constant angular width on the 9.9 m sphere, in front of the
    // dots (10 m) and behind the cursor (9.95 m). Both windings, so it shows from inside.
    private func outlineMesh(_ outline: [BoundaryDot]) -> MeshResource? {
        let radius: Float = 9.9
        let half = radius * Float(tan(BoundaryDotsOutline.lineWidthDeg * .pi / 360))
        let points = outline.map { SIMD3<Float>($0.direction) * radius }
        guard points.count >= 3 else { return nil }
        var positions: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        for (i, point) in points.enumerated() {
            let along = normalize(points[(i + 1) % points.count] - points[(i + points.count - 1) % points.count])
            let side = normalize(cross(normalize(point), along)) * half
            positions += [point + side, point - side]
            let a = UInt32(i * 2), b = UInt32(((i + 1) % points.count) * 2)
            triangles += [a, b, a + 1, a + 1, b, b + 1, a, a + 1, b, a + 1, b + 1, b]
        }
        var descriptor = MeshDescriptor(name: "boundary_outline")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(triangles)
        return try? MeshResource.generate(from: [descriptor])
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

    private func handPosition(_ event: SpatialEventCollection.Event,
                              _ value: EntityTargetValue<SpatialEventCollection>) -> SIMD3<Float>? {
        guard let pose = event.inputDevicePose else { return nil }
        return value.convert(pose.pose3D.position, from: .local, to: .scene)
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
                    if scene.spatialEvent(event, target: value.entity, handPosition: handPosition(event, value)) { dismiss() }
                }
            }
            .onEnded { value in
                for event in value.gestureValue {
                    if scene.spatialEvent(event, target: value.entity, handPosition: handPosition(event, value)) { dismiss() }
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
