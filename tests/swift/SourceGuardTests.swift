// SOURCES:
// Fails if Settings.swift, EventHandler.swift or Renderer.swift name a raw property removed by the render-thread race
// fix (22 Oct crashes). Their values now live only inside the lock types in ALVRClient/LockedBox.swift: the settings
// cache (SettingsCache), lastQueuedFrame/lastQueuedFramePose (EventHandler.lastQueued), vtDecompressionSession/
// videoFormat/currentCodec (EventHandler.decoder) and viewFovs (EventHandler.viewFovsBox). Reads the sources next to
// this file, so a scratch copy of the tree checks the scratch sources.
import Foundation

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

// (files, pattern, what it catches)
private let rules: [([String], String, String)] = [
    (["Settings.swift"], #"\b_cached\b"#, "the old unlocked settings cache"),
    (["Settings.swift"], #"static\s+var\s+\w+\s*:\s*SettingsCodables"#, "a settings value stored outside SettingsCache"),
    (["EventHandler.swift", "Renderer.swift"], #"\blastQueuedFrame(Pose)?\b"#, "lastQueuedFrame/Pose outside lastQueued"),
    (["EventHandler.swift", "Renderer.swift"], #"\bvtDecompressionSession\b"#, "the decoder session outside decoder"),
    (["EventHandler.swift", "Renderer.swift"], #"\bcurrentCodec\b"#, "the codec outside decoder"),
    (["EventHandler.swift", "Renderer.swift"], #"(\bshared|\bself)\.videoFormat\b"#, "the decoder format outside decoder"),
    (["EventHandler.swift", "Renderer.swift"], #"(\bshared|\bself)\.viewFovs\b"#, "viewFovs outside viewFovsBox"),
    (["EventHandler.swift"], #"^\s*(private\s+)?var\s+(videoFormat|viewFovs)\b"#, "a raw videoFormat/viewFovs property"),
    (["EventHandler.swift"], #"\bviewFovs\b(?!\s*:)"#, "viewFovs read outside viewFovsBox"),
]

private func check() {
    for (files, pattern, what) in rules {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        for file in files {
            let url = root.appendingPathComponent("ALVRClient").appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                expect(false, "read \(url.path)")
                continue
            }
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                let hit = regex.firstMatch(in: line, range: range) != nil
                expect(!hit, "\(file):\(number + 1) names \(what): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
}

@main
enum SourceGuardTests {
    static func main() {
        check()
        finishTests("SourceGuard")
    }
}
