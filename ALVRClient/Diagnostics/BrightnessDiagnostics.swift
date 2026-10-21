import SwiftUI
import AVKit
import RealityKit

@MainActor final class PQDiagnostic: ObservableObject {
    static let shared = PQDiagnostic()
    let player = AVPlayer()
    @Published var clips: [URL] = []
    @Published var selected: URL?
    @Published var space: String?
    private var observer: Any?
    private var status: NSKeyValueObservation?
    private var path = "window"
    func refresh() {
        guard Diag.isOn else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag-clips")
        clips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        selected = clips.first
    }
    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil; status = nil
        player.replaceCurrentItem(with: nil)
    }
    func play(immersive: Bool) {
        guard Diag.isOn, let selected else { return }
        stop(); path = immersive ? "realitykit" : "window"
        let item = AVPlayerItem(url: selected)
        player.replaceCurrentItem(with: item)
        Diag.log("pq", ["path": path, "clip": selected.lastPathComponent, "eligibleForHDRPlayback": AVPlayer.eligibleForHDRPlayback,
                        "availableHDRModes": AVPlayer.availableHDRModes.rawValue])
        status = item.observe(\.status, options: [.initial, .new]) { item, _ in
            Diag.log("pq", ["status": item.status.rawValue, "error": item.error?.localizedDescription ?? "none"])
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                Diag.log("pq", ["path": self.path, "clip": selected.lastPathComponent, "current_s": time.seconds,
                                "step": PQSchedule.step(time: time.seconds, isSteps: selected.lastPathComponent.contains("steps")),
                                "rate": self.player.rate, "waiting": self.player.reasonForWaitingToPlay?.rawValue ?? "none"])
            }
        }
        Task {
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                for track in tracks {
                    let formats = try await track.load(.formatDescriptions)
                    guard player.currentItem === item else { return }
                    for format in formats {
                        Diag.log("pq", ["path": path, "clip": selected.lastPathComponent,
                                        "transfer": CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) ?? "unavailable" as CFString,
                                        "primaries": CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) ?? "unavailable" as CFString])
                    }
                }
            } catch { Diag.log("pq", ["metadata_error": error.localizedDescription]) }
        }
        player.play()
    }
}

struct PQImmersiveView: View {
    var body: some View {
        if Diag.isOn {
            RealityView { content in
                let screen = Entity()
                screen.components.set(VideoPlayerComponent(avPlayer: PQDiagnostic.shared.player))
                screen.position = [0, 1.4, -2]
                content.add(screen)
            }
            .onDisappear {
                if PQDiagnostic.shared.space == "PQDiagnostic" { PQDiagnostic.shared.stop(); PQDiagnostic.shared.space = nil }
            }
        }
    }
}

struct BrightnessDiagnostics: View {
    var body: some View {
        if Diag.isOn { BrightnessControls() }
    }
}

private struct BrightnessControls: View {
    @StateObject private var pq = PQDiagnostic.shared
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var layout = EDRLayout.onePercent
    @State private var automatic = false
    @State private var sustained = false
    @State private var busy = false
    @State private var error = ""
    private func configure() { EDRSession.shared.configure(layout: layout, automatic: automatic, sustained: sustained) }
    private func enter(_ id: String) {
        busy = true
        Task {
            EDRSession.shared.beginRun()
            pq.stop()
            if pq.space != nil { await dismissSpace(); pq.space = nil }
            configure()
            switch await openSpace(id: id) {
            case .opened:
                pq.space = id
                if id == "PQDiagnostic" { pq.play(immersive: true) }
            case .error: error = "Could not open immersive space. Close any active stream first."
            case .userCancelled: break
            @unknown default: break
            }
            busy = false
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            Text("EDR ramp").font(.title2)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(EDRSession.shared.currentValue.map { "Submitted EDR value: \($0)" } ?? "Start the ramp to begin")
            }
            Picker("Layout", selection: $layout) { ForEach(EDRLayout.allCases, id: \.self) { Text($0.rawValue) } }
            Toggle("Automatic steps every 4 seconds", isOn: $automatic)
            Toggle("Sustained: hold each automatic step for 60 seconds", isOn: $sustained)
            HStack {
                Button("EDR ramp") { enter("EDRDiagnostic") }
                Button("Next (or pinch the ramp)") { EDRSession.shared.next() }.disabled(pq.space != "EDRDiagnostic")
            }
            Button("Brightness stopped increasing here") { EDRSession.shared.mark() }.disabled(pq.space != "EDRDiagnostic")
            Divider()
            Text("PQ player").font(.title2)
            Picker("Clip", selection: $pq.selected) {
                ForEach(pq.clips, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
            }.disabled(pq.space != nil)
            if pq.clips.isEmpty { Text("Copy PQ clips to Documents/diag-clips, then Reload clips.") }
            HStack {
                Button("Reload clips") { pq.refresh() }.disabled(pq.space != nil)
                Button("Play in window") { pq.play(immersive: false) }.disabled(pq.space != nil || pq.selected == nil)
                Button("Play immersive") { enter("PQDiagnostic") }.disabled(pq.selected == nil)
            }
            if pq.space == nil { VideoPlayer(player: pq.player).frame(width: 640, height: 360) }
            Button("Stop / exit diagnostic") {
                pq.stop()
                Task { if pq.space != nil { await dismissSpace(); pq.space = nil } }
            }
            Text(error).font(.caption)
        }
        .padding().disabled(busy)
        .onAppear { pq.refresh(); configure() }
        .onChange(of: layout) { configure() }
        .onChange(of: automatic) { configure() }
        .onChange(of: sustained) { configure() }
        .onDisappear { pq.stop(); Task { if pq.space != nil { await dismissSpace(); pq.space = nil } } }
    }
}
