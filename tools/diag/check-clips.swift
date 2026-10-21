#!/usr/bin/env swift
import Foundation

// Assemble the checker with the same pure sampling policy used by unit tests.
func runChecker() throws -> Int32 {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let cache = ProcessInfo.processInfo.environment["CLANG_MODULE_CACHE_PATH"] ?? NSTemporaryDirectory() + "alvr-diag-module-cache"
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("diag-check-\(UUID().uuidString).swift")
    defer { try? FileManager.default.removeItem(at: script) }
    let policy = try String(contentsOf: directory.appendingPathComponent("clip-inspection.swift"), encoding: .utf8)
    let engine = try String(contentsOf: directory.appendingPathComponent("check-clip-engine.swift"), encoding: .utf8)
    try (policy + "\n" + engine.replacingOccurrences(of: "#!/usr/bin/env swift\n", with: "")).write(to: script, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = ["-module-cache-path", cache, script.path] + Array(CommandLine.arguments.dropFirst())
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
do { exit(try runChecker()) } catch {
    fputs("FAIL: unable to run clip checker: \(error)\n", stderr)
    exit(1)
}
