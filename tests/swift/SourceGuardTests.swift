// SOURCES:
// Fails if a file that used the raw properties removed by the render-thread race fix (22 Oct crashes) names one of them
// again, as a whole word anywhere: implicit-self access, declaration with any modifiers, key path. Their values now
// live only inside the lock types in ALVRClient/LockedBox.swift (not scanned): the settings cache (SettingsCache),
// lastQueuedFrame/lastQueuedFramePose (EventHandler.lastQueued), vtDecompressionSession/videoFormat/currentCodec
// (EventHandler.decoder) and viewFovs (EventHandler.viewFovsBox). Reads the sources next to this file.
import Foundation

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

private let removed = ["_cached", "lastQueuedFrame", "lastQueuedFramePose", "vtDecompressionSession", "videoFormat",
                       "currentCodec", "viewFovs"]
private let removedRegex = try! NSRegularExpression(pattern: #"\b("# + removed.joined(separator: "|") + #")\b"#)

private let scanned = ["Settings.swift", "EventHandler.swift", "Renderer.swift", "RealityKitClientSystem.swift",
                       "DummyMetalRenderer.swift"]

// Allowlist 1: same-name tokens that are not the removed properties, cut from every line before the check.
private let allowedTokens = [
    // Argument labels of WorldTracker.sendTracking/sendFakeTracking/sendViewParams, QueuedFrame(...),
    // VideoHandler.feedVideoIntoDecoder and VideoHandler.applyRefreshRate. Labels only: the value after them is checked.
    #"[(,]\s*(viewFovs|videoFormat):"#,
    // QueuedFrame's own immutable field, read from a frame the render loop already holds.
    #"\bqueuedFrame!?\.videoFormat\b"#,
].map { try! NSRegularExpression(pattern: $0) }

// Allowlist 2: whole lines (trimmed) that use a same-name local or field, with the exact number of times each file has
// them, so a copy elsewhere still fails and a stale entry is reported.
private let allowedLines: [String: [String: Int]] = [
    "EventHandler.swift": [
        // Comment in handleNals.
        "// The stream this frame was decoded for: its colour state is derived from it, not from a later videoFormat.": 1,
        // DECODER_CONFIG: the new decoder's format is a local, installed into DecoderSlot in one step.
        "let (session, videoFormat) = VideoHandler.createVideoDecoder(initialNals: nalBuffer!, codec: codec)": 1,
        "decoder.replace(session: session, format: videoFormat, codec: codec)": 1,
        "if let videoFormat {": 1,
        "VideoHandler.reportVideoFormat(videoFormat)": 1,
        // struct QueuedFrame's immutable field (a per-frame value, not the decoder's shared format).
        "let videoFormat: CMFormatDescription?": 1,
    ],
    "Renderer.swift": [
        // Render-loop locals: one locked snapshot of viewFovsBox per frame, then passed to sendTracking.
        "let viewFovs = EventHandler.shared.viewFovsBox.get()": 2,
        "WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)": 2,
    ],
    "RealityKitClientSystem.swift": [
        "let viewFovs = EventHandler.shared.viewFovsBox.get()": 1,
        "let sentAnchor = WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)": 1,
    ],
]

// Lines of `text` (as file `file`) that name a removed property, and how often each allowlisted line was used.
private func scan(_ file: String, _ text: String) -> (hits: [String], used: [String: Int]) {
    var hits: [String] = []
    var used: [String: Int] = [:]
    let allowed = allowedLines[file] ?? [:]
    for (number, line) in text.components(separatedBy: "\n").enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if allowed[trimmed] != nil {
            used[trimmed, default: 0] += 1
            continue
        }
        var rest = line
        for token in allowedTokens {
            rest = token.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: "(")
        }
        if removedRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil {
            hits.append("\(file):\(number + 1): \(trimmed)")
        }
    }
    return (hits, used)
}

private func testRealTree() {
    let client = root.appendingPathComponent("ALVRClient")
    let entry = client.appendingPathComponent("Entry")
    let entryFiles = ((try? FileManager.default.contentsOfDirectory(atPath: entry.path)) ?? [])
        .filter { $0.hasSuffix(".swift") }.sorted().map { "Entry/" + $0 }
    expect(!entryFiles.isEmpty, "Entry/*.swift found")
    for file in scanned + entryFiles {
        guard let text = try? String(contentsOf: client.appendingPathComponent(file), encoding: .utf8) else {
            expect(false, "read ALVRClient/\(file)")
            continue
        }
        let (hits, used) = scan(file, text)
        for hit in hits { expect(false, "names a removed raw property: \(hit)") }
        for (line, count) in allowedLines[file] ?? [:] {
            expect(used[line] == count, "\(file): allowlisted line seen \(used[line] ?? 0)x, expected \(count)x: \(line)")
        }
    }
}

// Old accesses (from the review and the original code) must each fail the guard, read as in-memory fixtures.
private func testOldAccessesFail() {
    let fixtures: [(String, String)] = [
        ("EventHandler.swift", "        videoFormat = nil"),
        ("EventHandler.swift", "            let frameVideoFormat = videoFormat!"),
        ("EventHandler.swift", "    private(set) var videoFormat: CMFormatDescription?"),
        ("EventHandler.swift", "        self.lastQueuedFrame = f"),
        ("Renderer.swift", "            EventHandler.shared.lastQueuedFrame = queuedFrame"),
        ("EventHandler.swift", "    var lastQueuedFramePose: simd_float4x4? = nil"),
        ("EventHandler.swift", "    nonisolated(unsafe) var vtDecompressionSession: VTDecompressionSession? = nil"),
        ("EventHandler.swift", "        feedVideoIntoDecoder(codec: currentCodec)"),
        ("EventHandler.swift", "        WorldTracker.shared.sendViewParams(viewTransforms: viewTransforms, viewFovs: viewFovs)"),
        ("RealityKitClientSystem.swift", "            EventHandler.shared.viewFovs = [leftFov, rightFov]"),
        ("Entry/Entry.swift", "        VideoHandler.applyRefreshRate(videoFormat: EventHandler.shared.videoFormat)"),
        ("DummyMetalRenderer.swift", "        let path = \\EventHandler.lastQueuedFrame"),
        ("Settings.swift", "    static var _cached: SettingsCodables.Settings? = nil"),
        // An allowlisted line is only allowed in its own file.
        ("Renderer.swift", "                    if let videoFormat {"),
    ]
    for (file, line) in fixtures {
        expect(scan(file, line).hits.count == 1, "guard fails on \(file): \(line.trimmingCharacters(in: .whitespaces))")
    }
    // The allowed tokens and lines pass as written.
    expect(scan("EventHandler.swift", "    WorldTracker.shared.sendFakeTracking(viewFovs: viewFovsBox.get(), targetTimestamp: 0)").hits.isEmpty,
           "argument label passes")
    expect(scan("EventHandler.swift", "                    if let videoFormat {").hits.isEmpty, "allowlisted line passes")
}

@main
enum SourceGuardTests {
    static func main() {
        testOldAccessesFail()
        testRealTree()
        finishTests("SourceGuard")
    }
}
