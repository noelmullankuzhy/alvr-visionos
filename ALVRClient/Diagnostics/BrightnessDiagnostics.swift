import SwiftUI
import AVKit
import RealityKit

@MainActor final class PQDiagnostic: ObservableObject {
    static let shared = PQDiagnostic()
    let player = AVPlayer()
    @Published var clips: [URL] = []
    @Published var selected: URL? {
        didSet {
            guard selected != oldValue else { return }
            if let selected { UserDefaults.standard.set(selected.lastPathComponent, forKey: PQClipSelection.defaultsKey) }
            switch PQControls.restartAfterSelectionChange(playing: playingPath, to: selected) {
            case .play(let path, let clip): play(clip: clip, immersive: path == .immersive)
            case .stop: stop()
            default: break
            }
        }
    }
    @Published var space: String?
    @Published private(set) var playbackContext: PQPlaybackContext?
    var playingPath: PQPlaybackPath? { playbackContext.flatMap { PQPlaybackPath(rawValue: $0.path) } }
    func adjacentClip(forward: Bool) {
        selected = PQClipSelection.adjacent(clips: clips, selected: selected, forward: forward)
    }
    private var observer: Any?
    private var status: NSKeyValueObservation?
    func refresh() {
        guard Diag.isOn else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag-clips")
        clips = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        selected = PQClipSelection.restore(clips: clips, current: selected,
                                           rememberedName: UserDefaults.standard.string(forKey: PQClipSelection.defaultsKey))
    }
    func stop() {
        playbackContext = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil; status = nil
        player.replaceCurrentItem(with: nil)
    }
    func play(clip: URL, immersive: Bool) {
        guard Diag.isOn else { return }
        stop()
        let context = PQPlaybackContext(clip: clip.lastPathComponent, path: immersive ? "realitykit" : "window")
        playbackContext = context
        let item = AVPlayerItem(url: clip)
        player.replaceCurrentItem(with: item)
        Diag.log("pq", ["path": context.path, "clip": context.clip, "eligibleForHDRPlayback": AVPlayer.eligibleForHDRPlayback,
                        "availableHDRModes": AVPlayer.availableHDRModes.rawValue])
        status = item.observe(\.status, options: [.initial, .new]) { item, _ in
            Diag.log("pq", context.statusFields(status: item.status.rawValue, error: item.error?.localizedDescription ?? "none"))
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                Diag.log("pq", ["path": context.path, "clip": context.clip, "current_s": time.seconds,
                                "step": PQSchedule.step(time: time.seconds, clip: context.clip),
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
                        Diag.log("pq", ["path": context.path, "clip": context.clip,
                                        "transfer": CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) ?? "unavailable" as CFString,
                                        "primaries": CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) ?? "unavailable" as CFString])
                    }
                }
            } catch { Diag.log("pq", context.metadataErrorFields(error.localizedDescription)) }
        }
        player.play()
    }
}

struct PQImmersiveView: View {
    var body: some View {
        if Diag.isOn {
            RealityView { content in
                DiagEye.unsupported()
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

// Shared by the controls and the EDR scene so the selected style and log attribution agree.
@MainActor final class EDRPresentation: ObservableObject {
    static let shared = EDRPresentation()
    @Published var immersion = EDRImmersion.defaultStyle
    var style: ImmersionStyle { immersion == .full ? .full : .mixed }
}

struct BrightnessDiagnostics: View {
    var body: some View {
        if Diag.isOn { BrightnessControls() }
    }
}

private struct BrightnessControls: View {
    @StateObject private var pq = PQDiagnostic.shared
    @StateObject private var edr = EDRPresentation.shared
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @State private var layout = EDRLayout.onePercent
    @State private var coarse = false
    @State private var fine = false
    @State private var gridRange = EDRGridRange.fine
    @State private var surround = EDRSurround.black
    @State private var mirror = false
    @State private var borders = false
    @State private var automatic = false
    @State private var sustained = false
    @State private var busy = false
    @State private var error = ""
    private func configure() {
        EDRSession.shared.setImmersion(edr.immersion.rawValue)
        EDRSession.shared.configure(layout: layout, automatic: automatic, sustained: sustained,
                                    fine: fine, gridRange: gridRange, mirror: mirror, borders: borders, coarse: coarse, surround: surround)
    }
    private func enter(_ id: String, clip: URL? = nil) async {
        busy = true
        defer { busy = false }
        EDRSession.shared.beginRun()
        pq.stop()
        if pq.space != nil { await dismissSpace(); pq.space = nil }
        configure()
        switch await openSpace(id: id) {
        case .opened:
            pq.space = id
            if id == "PQDiagnostic", let clip { pq.play(clip: clip, immersive: true) }
        case .error: error = "Could not open immersive space. Close any active stream first."
        case .userCancelled: break
        @unknown default: break
        }
    }
    private var pqControls: PQControls {
        PQControls(space: pq.space, layout: layout, selection: pq.selected, playing: pq.playingPath)
    }
    private func playbackBinding(_ path: PQPlaybackPath) -> Binding<Bool> {
        Binding(get: { pqControls.isOn(path) }, set: { setPlayback(path, on: $0) })
    }
    private func setPlayback(_ path: PQPlaybackPath, on: Bool) {
        guard !busy else { return }
        let actions = pqControls.actions(path, on: on)
        guard !actions.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            for action in actions {
                switch action {
                case .stop: pq.stop()
                case .dismissSpace:
                    await dismissSpace()
                    pq.space = nil
                case .play(let path, let clip): pq.play(clip: clip, immersive: path == .immersive)
                case .openImmersive(let clip): await enter("PQDiagnostic", clip: clip)
                }
            }
        }
    }
    private var running: Bool { pq.space == "EDRDiagnostic" }
    private var windowAllowed: Bool { pqWindowPlaybackAllowed(space: pq.space, layout: layout) }
    private var matchClip: String? {
        guard running, layout == .match, let context = pq.playbackContext,
              context.path == "window", EDRMatch.clipNits(context.clip) != nil else { return nil }
        return context.clip
    }
    private func recordMatch(_ result: EDRMatchResult) {
        if let clip = matchClip { EDRSession.shared.recordMatch(result, clip: clip) }
    }
    private var visible: Set<EDRControl> { edrVisibleControls(layout: layout, running: running) }
    private func stop() {
        pq.stop()
        Task { if pq.space != nil { await dismissSpace(); pq.space = nil } }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EDR ramp").font(.title2)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let value = layout.gridArea != nil ? gridRange.rawValue :
                    EDRSession.shared.currentValue.map { String(format: "Value: %.2f × SDR white", $0) } ?? "Awaiting first frame"
                Text("\(running ? "Running" : "Idle") · \(edr.immersion.rawValue.capitalized) · \(layout.rawValue) · \(value)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private var displaySection: some View {
        Section {
            Picker("Immersion", selection: $edr.immersion) {
                Text("Full").tag(EDRImmersion.full)
                Text("Mixed").tag(EDRImmersion.mixed)
            }.pickerStyle(.segmented).disabled(pq.space != nil)
        } header: {
            Text("Display")
        } footer: {
            Text("Choose the surroundings before starting the diagnostic.")
        }
    }
    private var patternSection: some View {
        Section {
            Picker("Layout", selection: $layout) {
                Section("Ramp") {
                    ForEach([EDRLayout.onePercent, .tenPercent, .full, .checkerboard], id: \.self) { Text($0.rawValue).tag($0) }
                }
                Section("Compare") {
                    ForEach([EDRLayout.split, .pairOne, .pairFive, .pairTwenty, .match], id: \.self) { Text($0.rawValue).tag($0) }
                }
                Section("Grid") {
                    ForEach([EDRLayout.gridOne, .gridTen, .gridFifty], id: \.self) { Text($0.rawValue).tag($0) }
                }
            }.pickerStyle(.menu)
            if visible.contains(.gridOptions) {
                Picker("Range", selection: $gridRange) {
                    ForEach([EDRGridRange.coarse, .fine, .knee, .wide], id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Surround", selection: $surround) {
                    Text("Black").tag(EDRSurround.black)
                    Text("SDR white").tag(EDRSurround.sdrWhite)
                }.pickerStyle(.segmented)
                Toggle("Mirror", isOn: $mirror)
                Toggle("Borders", isOn: $borders)
            }
            if visible.contains(.matchOptions) { Toggle("Coarse (0.10 steps)", isOn: $coarse) }
            if visible.contains(.steps) {
                Picker("Steps", selection: $fine) {
                    Text("Standard").tag(false)
                    Text("Fine").tag(true)
                }.pickerStyle(.segmented)
                Toggle("Automatic", isOn: $automatic)
                if automatic { Toggle("Sustained", isOn: $sustained) }
            }
        } header: {
            Text("Pattern")
        } footer: {
            Text(layout == .match ? "Match uses 0.02 steps, or 0.10 with Coarse." : layout.gridArea != nil ? "Borders off joins cells; knee focuses on 1.30–1.70. Wide: 1x–49x, ×1.18 steps, surround selectable." :
                    "Automatic advances every 4 seconds, or 60 seconds with Sustained.")
        }
    }
    private var primarySection: some View {
        Section {
            HStack {
                Button("Start") { Task { await enter("EDRDiagnostic") } }.buttonStyle(.borderedProminent)
                Button("Stop") { stop() }
            }
        }
    }
    private var runningSection: some View {
        Section {
            if visible.contains(.matchActions) {
                HStack {
                    Button("−") { EDRSession.shared.back() }.accessibilityLabel("Decrease Metal value")
                    Button("+") { EDRSession.shared.next() }.accessibilityLabel("Increase Metal value")
                }
                Group {
                    Button("Matched") { recordMatch(.equal) }
                    Button("Video brighter than max") { recordMatch(.above) }
                    Button("Video darker than min") { recordMatch(.below) }
                }.disabled(matchClip == nil)
            }
            if visible.contains(.navigation) {
                HStack {
                    Button("Back") { EDRSession.shared.back() }
                    Button("Next") { EDRSession.shared.next() }
                }
            }
            if visible.contains(.mark) {
                Button("Brightness stopped increasing here") { EDRSession.shared.mark() }
            }
            if visible.contains(.answers) {
                HStack {
                    Button("Right brighter") { EDRSession.shared.answer(.brighter) }
                    Button("Same") { EDRSession.shared.answer(.same) }
                    Button("Right darker") { EDRSession.shared.answer(.darker) }
                }
            }
            if visible.contains(.gridHint) {
                Text("Tell the GM the first cell that stops getting brighter").font(.caption)
            }
        } header: {
            Text("While running")
        } footer: {
            Text(layout == .match ? "Quick right pinch increases; quick left pinch decreases. Match the window to the patch." : layout.gridArea != nil ? "Close one eye and compare neighbouring cells, A–E and 1–5." :
                    layout.isComparison ? "Close one eye and compare right with the fixed 1.0 reference on the left." :
                    "Pinch the ramp or tap Next to advance; mark where brightness stops increasing.")
        }
    }
    private var pqSection: some View {
        Section {
            HStack {
                Button("Prev clip") { pq.adjacentClip(forward: false) }.disabled(pq.clips.isEmpty)
                Picker("Clip", selection: $pq.selected) {
                    ForEach(pq.clips, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                }
                Button("Next clip") { pq.adjacentClip(forward: true) }.disabled(pq.clips.isEmpty)
            }
            if pq.clips.isEmpty { Text("Copy PQ clips to Documents/diag-clips, then Reload.").font(.caption) }
            HStack {
                Button("Reload") { pq.refresh() }
                Toggle("Play in window", isOn: playbackBinding(.window))
                    .disabled(busy || !pqControls.canToggle(.window))
                Toggle("Play immersive", isOn: playbackBinding(.immersive))
                    .disabled(busy || !pqControls.canToggle(.immersive))
            }.toggleStyle(.button)
            if windowAllowed { VideoPlayer(player: pq.player).frame(height: 240) }
        } header: {
            Text("HDR video (PQ)")
        } footer: {
            Text("The split clip shows two halves for a side-by-side brightness comparison.")
        }
    }
    var body: some View {
        Form {
            header
            displaySection.disabled(busy)
            patternSection.disabled(busy)
            primarySection.disabled(busy)
            if running { runningSection.disabled(busy) }
            pqSection
            if !error.isEmpty { Text(error).font(.caption) }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { pq.refresh(); configure() }
        .onChange(of: edr.immersion) { configure() }
        .onChange(of: layout) {
            configure()
            if !windowAllowed, pq.playingPath == .window { pq.stop() }
        }
        .onChange(of: coarse) { configure() }
        .onChange(of: fine) { configure() }
        .onChange(of: gridRange) { configure() }
        .onChange(of: mirror) { configure() }
        .onChange(of: borders) { configure() }
        .onChange(of: automatic) { configure() }
        .onChange(of: sustained) { configure() }
        .onDisappear { pq.stop(); Task { if pq.space != nil { await dismissSpace(); pq.space = nil } } }
    }
}
