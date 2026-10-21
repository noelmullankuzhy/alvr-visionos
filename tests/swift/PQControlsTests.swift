// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/EDRDiagnostic.swift
import Foundation

@main enum PQControlsTests {
    static func main() {
        let a = URL(fileURLWithPath: "/clips/gradient.mov")
        let b = URL(fileURLWithPath: "/clips/level-100-pq.mov")
        let c = URL(fileURLWithPath: "/clips/level-1000-pq.mov")
        let clips = [a, b, c]
        expectEqual(PQClipSelection.restore(clips: clips, current: nil, rememberedName: nil), a, "first run")
        expectEqual(PQClipSelection.restore(clips: clips, current: b, rememberedName: a.lastPathComponent), b, "reload/onAppear keeps current")
        expectEqual(PQClipSelection.restore(clips: clips, current: nil, rememberedName: b.lastPathComponent), b, "next launch restores name")
        expectEqual(PQClipSelection.restore(clips: clips, current: URL(fileURLWithPath: "/old/level-100-pq.mov"), rememberedName: nil), b, "name survives document directory relocation")
        expectEqual(PQClipSelection.restore(clips: [a, c], current: b, rememberedName: b.lastPathComponent), a, "missing clip falls back")
        expectEqual(PQClipSelection.restore(clips: [], current: b, rememberedName: b.lastPathComponent), nil, "empty directory")
        expectEqual(PQClipSelection.adjacent(clips: clips, selected: a, forward: false), c, "previous wraps")
        expectEqual(PQClipSelection.adjacent(clips: clips, selected: c, forward: true), a, "next wraps")
        expectEqual(PQClipSelection.adjacent(clips: clips, selected: b, forward: true), c, "next")
        expectEqual(PQClipSelection.adjacent(clips: clips, selected: b, forward: false), a, "previous")
        expectEqual(PQClipSelection.adjacent(clips: [b], selected: b, forward: true), b, "single clip")
        expectEqual(PQClipSelection.adjacent(clips: [], selected: nil, forward: true), nil, "empty navigation")
        expectEqual(PQClipSelection.adjacent(clips: clips, selected: nil, forward: false), a, "navigation recovers selection")
        for space in [nil, "PQDiagnostic", "EDRDiagnostic", "Other"] as [String?] {
            for layout in EDRLayout.allCases {
                for selection in [nil, b] as [URL?] {
                    for playing in [nil, .window, .immersive] as [PQPlaybackPath?] {
                        let controls = PQControls(space: space, layout: layout, selection: selection, playing: playing)
                        let active: PQPlaybackPath? = space == "PQDiagnostic" ? .immersive : playing
                        expect(controls.reloadEnabled, "reload always enabled")
                        for path in PQPlaybackPath.allCases {
                            expectEqual(controls.isOn(path), active == path, "toggles reflect one path")
                            let allowed = path == .immersive || space == "PQDiagnostic" || pqWindowPlaybackAllowed(space: space, layout: layout)
                            expectEqual(controls.canToggle(path), active == path || (selection != nil && allowed), "active toggle can always stop; starts need selection and allowed space")
                            let off: [PQControlAction] = active == path ? [.stop] + (path == .immersive && space == "PQDiagnostic" ? [.dismissSpace] : []) : []
                            expectEqual(controls.actions(path, on: false), off, "off stops only its active path, dismissing only PQ")
                            var on: [PQControlAction] = []
                            if selection != nil && allowed {
                                if path == .window {
                                    on = (space == "PQDiagnostic" ? [.stop, .dismissSpace] : []) + [.play(.window, b)]
                                } else if space == "PQDiagnostic" {
                                    on = [.play(.immersive, b)]
                                } else {
                                    on = [.stop] + (space != nil ? [.dismissSpace] : []) + [.openImmersive(b)]
                                }
                            }
                            expectEqual(controls.actions(path, on: true), on, "switch paths in order; window never dismisses EDR")
                        }
                        expectEqual(PQControls.restartAfterSelectionChange(playing: playing, to: c), playing.map { .play($0, c) }, "changing clip replays same path")
                        expectEqual(PQControls.restartAfterSelectionChange(playing: playing, to: nil), playing == nil ? nil : .stop, "removing selection stops playback")
                    }
                }
            }
        }
        let pressed = PQControls(space: nil, layout: .match, selection: b, playing: nil)
        let immersivePress = pressed.actions(.immersive, on: true)
        let windowPress = pressed.actions(.window, on: true)
        let refreshed = PQClipSelection.restore(clips: clips, current: c, rememberedName: a.lastPathComponent)
        expectEqual(refreshed, c, "refresh during entry keeps latest selection")
        expectEqual(immersivePress, [.stop, .openImmersive(b)], "entry retains URL selected at press despite subsequent refresh/selection")
        expectEqual(windowPress, [.play(.window, b)], "window press captures URL")
        expectEqual(PQControls.restartAfterSelectionChange(playing: .immersive, to: c), .play(.immersive, c), "next/prev captures new clip before asynchronous effects")
        finishTests("PQControls")
    }
}
