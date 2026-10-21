#!/usr/bin/env swift
import Foundation
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("clip-engine.swift")
let cache = ProcessInfo.processInfo.environment["CLANG_MODULE_CACHE_PATH"] ?? NSTemporaryDirectory() + "alvr-diag-module-cache"
let arguments = ["-O", "-module-cache-path", cache, engine.path, "--kind", "stress"] + Array(CommandLine.arguments.dropFirst())
// Assemble the shared policy and CLI into one interpreter input; tests compile the
// same policy directly, with no encoder or filesystem work in the test cases.
func runEngine() throws -> Int32 {
    let policy = engine.deletingLastPathComponent().appendingPathComponent("clip-policy.swift")
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("diag-clip-\(UUID().uuidString).swift")
    defer { try? FileManager.default.removeItem(at: script) }
    try (String(contentsOf: policy) + "\n" + String(contentsOf: engine)).write(to: script, atomically: true, encoding: .utf8)
    process.arguments = arguments.map { $0 == engine.path ? script.path : $0 }
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
do { exit(try runEngine()) }
catch {
    fputs("Unable to run Swift encoder: \(error)\n", stderr)
    exit(1)
}
