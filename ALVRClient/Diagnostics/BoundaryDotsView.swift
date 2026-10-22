import ARKit
import QuartzCore
import RealityKit
import SwiftUI

/// What the projection overlay last drew; a refresh with the same inputs rebuilds nothing.
private struct ProjectionShown: Equatable {
    struct Eye: Equatable {
        let eye: BoundaryDotsEye
        let frustum: BoundaryDotsFrustum
        let outline: [BoundaryDot]
    }
    let eye: BoundaryDotsEye
    let shape: BoundaryDotsOutlineShape
    let value: Double
    let stream: ProjectionStream?
    let foveationPoint: String
    let eyes: [Eye]
}

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
    private var sliderLog = BoundaryDotsSliderLog()
    private let cursorEntity = ModelEntity()
    private let statusEntity = ModelEntity()
    private let insetEntity = ModelEntity()
    private let limitsEntity = ModelEntity()
    /// Per eye: frustum rectangle, lens/rect outline, its bbox, foveation rect, axis circle, three readout lines.
    private var layers: [BoundaryDotsEye: [ModelEntity]] = [:]
    private var readoutEntities: [BoundaryDotsEye: [ModelEntity]] = [:]
    private var crossEntities: [ModelEntity] = []
    private let fovButtonLabel = ModelEntity()
    private var fovButtonShown: String?
    private var projectionShown: ProjectionShown?
    private var hueMaterials: [BoundaryDotsEye: UnlitMaterial] = [:]
    private var dotStates = BoundaryDotsDotStates()
    private var statusShown: String?
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
        for eye in [BoundaryDotsEye.left, .right] {
            layers[eye] = (0..<5).map { _ in ModelEntity() }
            readoutEntities[eye] = (0..<3).map { _ in ModelEntity() }
            for entity in layers[eye]! + readoutEntities[eye]! { root.addChild(entity) }
        }
        statusEntity.position = [-0.65, -0.27, -9.9]
        root.addChild(statusEntity)
        for entity in [insetEntity, limitsEntity] { root.addChild(entity) }

        // A quick right pinch on the centre cross deselects the cursor (the left drag then sizes the outline);
        // with no cursor it toggles the outline style (lens <-> rect).
        let centre = Entity()
        centre.name = "centre"
        centre.position = [0, 0, -10]
        makeInteractive(centre)
        for size in [SIMD3<Float>(0.09, 0.015, 0.01), SIMD3<Float>(0.015, 0.09, 0.01)] {
            let bar = ModelEntity(mesh: .generateBox(size: size), materials: [white])
            crossEntities.append(bar)
            centre.addChild(bar)
        }
        root.addChild(centre)
        // A quick right pinch cycles the points row the foveation rect and px/deg use while no stream is up.
        let fovButton = ModelEntity(mesh: buttonMesh, materials: [dim])
        fovButton.name = "fov_row"
        fovButton.position = [1.2, -0.5, -10]
        makeInteractive(fovButton)
        fovButton.addChild(fovButtonLabel)
        root.addChild(fovButton)
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
                if !slider.active { sliderLog.reset() }
                let update = slider.update(id: event.id, hand: hand, phase: phase, position: SIMD3<Double>(handPosition),
                                           headRotation: rotation, inset: session.sliderValue,
                                           enabled: session.cursor == nil && session.eye != .both,
                                           range: session.sliderRange, sign: session.sliderSign)
                switch update {
                case .move(let value)?, .release(_, let value)?:
                    // A slider step changes only the outline and its labels: no dot materials.
                    session.sliderValue = value
                    refreshOutline()
                    refreshStatus()
                case nil:
                    break
                }
                // One dots_outline line per snapped step and one at release.
                if sliderLog.logs(update, session: session) { logOutline() }
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
            } else {
                logOutline()
            }
        } else if let name = pinch.target {
            if name == "leave" { return true }
            if name == "centre", !session.deselect(), session.eye != .both { session.toggleShape() }
            if name == "fov_row" {
                session.nextFoveationPoint()
                logOutline()
            }
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

    /// The selected eye's `dots_outline` line (none for Both).
    private func logOutline() {
        if let (frustum, source) = BoundaryDotsTangents.frustum(session.eye),
           let fields = session.outlineFields(frustum: frustum, source: source, stream: liveStream()) {
            Diag.log("dots_outline", fields)
        }
    }

    /// The streaming session's render size and foveation (read only, as EventHandler captured them at stream
    /// start); nil while no stream is up, which is always the case while Boundary dots is visible (offline only),
    /// so the selected points row is what shows in practice.
    private func liveStream() -> ProjectionStream? {
        guard EventHandler.shared.streamingActive, let event = EventHandler.shared.streamEvent else { return nil }
        let started = event.STREAMING_STARTED
        let ffr = started.enable_foveated_encoding ? Settings.getAlvrSettings()?.video.foveated_encoding : nil
        return .live(width: Int(started.view_width), height: Int(started.view_height),
                     centerSize: ffr.map { [Double($0.centerSizeX), Double($0.centerSizeY)] },
                     shift: ffr.map { [Double($0.centerShiftX), Double($0.centerShiftY)] },
                     edgeRatio: ffr.map { [Double($0.edgeRatioX), Double($0.edgeRatioY)] })
    }

    private func refresh() {
        for index in dotStates.changes(session) { updateDot(index, BoundaryDots.layout[index]) }
        for (eye, button) in eyeEntities { button.model?.materials = [eye == session.eye ? white : dim] }
        cursorEntity.isEnabled = session.cursor != nil
        if let dot = session.cursor {
            let direction = SIMD3<Float>(dot.direction)
            cursorEntity.position = direction * 9.95
            cursorEntity.orientation = simd_quatf(from: [0, 0, 1], to: -direction)
        }
        refreshOutline()
        refreshStatus()
    }

    /// Rebuilds the status text mesh only when its text changes.
    private func refreshStatus() {
        var text = "\(session.eye.rawValue)  select a ray"
            + (session.eye == .both ? "" : "  |  left drag: \(session.shape.rawValue) outline, pinch cross: style")
        if let dot = session.cursor {
            text = String(format: "%@  ray %g  ecc %g  |  left drag: cursor, pinch cross for outline",
                          session.eye.rawValue, dot.rayDeg, dot.eccDeg)
        }
        text += "  [\(session.outermost(session.eye).count) rays done]"
        guard text != statusShown else { return }
        statusShown = text
        statusEntity.model = ModelComponent(mesh: .generateText(text, extrusionDepth: 0.001,
                                          font: .systemFont(ofSize: 0.065)),
                                          materials: [UnlitMaterial(color: UIColor(white: 0.3, alpha: 1))])
    }

    /// The projection overlay of the selected eye, or of both in Both, in that eye's hue: the frustum rectangle
    /// (live tangents), the lens/rect outline at the eye's own slider value, its bbox (thinner), the foveation rect
    /// (white) and the 0.5 deg axis circle, with three readout lines per eye. A single eye also shows the outline
    /// value and four side limits under the centre cross. Rebuilt only when an input changes.
    private func refreshOutline() {
        let eye = session.eye, stream = liveStream()
        let eyes: [BoundaryDotsEye] = eye == .both ? [.left, .right] : [eye]
        let drawnEyes = eyes.compactMap { side -> ProjectionShown.Eye? in
            guard let (frustum, _) = BoundaryDotsTangents.frustum(side),
                  let outline = session.outline(side, frustum: frustum) else { return nil }
            return ProjectionShown.Eye(eye: side, frustum: frustum, outline: outline)
        }
        let shown = ProjectionShown(eye: eye, shape: session.shape, value: session.sliderValue, stream: stream,
                                    foveationPoint: session.foveationPoint, eyes: drawnEyes)
        let fovLabel = "fov \(stream?.source ?? session.foveationPoint)"
        if fovLabel != fovButtonShown {
            fovButtonShown = fovLabel
            fovButtonLabel.model = ModelComponent(mesh: .generateText(fovLabel, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.11)),
                                                  materials: [white])
            let bounds = fovButtonLabel.visualBounds(relativeTo: fovButtonLabel)
            fovButtonLabel.position = [-bounds.center.x, 0.16, 0]
        }
        guard shown != projectionShown else { return }
        projectionShown = shown
        for bar in crossEntities { bar.model?.materials = [hueMaterial(eye)] }
        for side in [BoundaryDotsEye.left, .right] {
            for entity in (layers[side] ?? []) + (readoutEntities[side] ?? []) { entity.isEnabled = eyes.contains(side) }
        }
        for (row, drawn) in shown.eyes.enumerated() {
            guard let layer = layers[drawn.eye],
                  let readout = session.projection(drawn.eye, frustum: drawn.frustum, stream: stream) else { continue }
            let hue = hueMaterial(drawn.eye), width = ProjectionOverlay.width
            // L in front of R by 1 cm so coincident edges (top and bottom) do not z-fight; both in front of the dots.
            let radius: Float = drawn.eye == .left ? 9.9 : 9.89
            let ribbons: [([SIMD3<Double>], Double, UnlitMaterial, Float)] = [
                (boxDirections(readout.frustum), width.frustum, hue, 0),
                (drawn.outline.map(\.direction), width.lens, hue, 0.02),
                (boxDirections(readout.bbox), width.bbox, hue, 0.04),
                (readout.fovRect.map(boxDirections) ?? [], width.foveation, white, 0.06),
                (ProjectionOverlay.axisCircle.map(\.direction), width.circle, hue, 0.08),
            ]
            for (entity, ribbon) in zip(layer, ribbons) {
                entity.model = ribbonMesh(ribbon.0, widthDeg: ribbon.1, radius: radius - ribbon.3).map {
                    ModelComponent(mesh: $0, materials: [ribbon.2])
                }
            }
            for (line, (entity, text)) in zip(readout.lines.indices, zip(readoutEntities[drawn.eye] ?? [], readout.lines)) {
                setCentredText(entity, text, y: -1.3 - 0.09 * Float(row * readout.lines.count + line), material: hue)
            }
        }
        let value = session.sliderValue
        guard let drawn = shown.eyes.first, eye != .both,
              let limits = session.shape == .lens ? BoundaryDotsLensReference.limits(eye, offsetDeg: value)
                                                  : drawn.frustum.limits(eye: eye, insetDeg: value) else {
            for entity in [insetEntity, limitsEntity] { entity.isEnabled = false }
            return
        }
        for entity in [insetEntity, limitsEntity] { entity.isEnabled = true }
        let label = session.shape == .lens ? String(format: "lens offset %+.1f deg", value) : String(format: "rect inset %.1f deg", value)
        setCentredText(insetEntity, String(format: "%@  area %.0f%%", label, 100 * drawn.frustum.areaFraction(of: drawn.outline)), y: -0.12,
                       material: hueMaterial(eye))
        setCentredText(limitsEntity, String(format: "nasal %.1f  temporal %.1f  up %.1f  down %.1f",
                                            limits.nasal, limits.temporal, limits.up, limits.down), y: -0.2, material: hueMaterial(eye))
    }

    private func hueMaterial(_ eye: BoundaryDotsEye) -> UnlitMaterial {
        if let material = hueMaterials[eye] { return material }
        let rgb = ProjectionOverlay.hue(eye)
        let material = UnlitMaterial(color: UIColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1))
        hueMaterials[eye] = material
        return material
    }

    /// A tangent-space box as head-frame directions (x right, y up, forward -z), edges split every 0.05 tan.
    private func boxDirections(_ box: ProjectionBox) -> [SIMD3<Double>] {
        box.path(step: 0.05).map { normalize(SIMD3($0.x, $0.y, -1)) }
    }

    private func setCentredText(_ entity: ModelEntity, _ text: String, y: Float, material: UnlitMaterial) {
        entity.model = ModelComponent(mesh: .generateText(text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.065)),
                                      materials: [material])
        let bounds = entity.visualBounds(relativeTo: entity)
        entity.position = [-bounds.center.x, y, -9.9]
    }

    // A closed ribbon of constant angular width on a sphere of `radius` (9.8-9.9 m), in front of the
    // dots (10 m) and the cursor (9.95 m). Both windings, so it shows from inside.
    private func ribbonMesh(_ directions: [SIMD3<Double>], widthDeg: Double, radius: Float) -> MeshResource? {
        let half = radius * Float(tan(widthDeg * .pi / 360))
        let points = directions.map { SIMD3<Float>($0) * radius }
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
