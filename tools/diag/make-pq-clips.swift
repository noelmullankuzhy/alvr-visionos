#!/usr/bin/env swift
import Foundation
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("clip-engine.swift")
let cache = ProcessInfo.processInfo.environment["CLANG_MODULE_CACHE_PATH"] ?? NSTemporaryDirectory() + "alvr-diag-module-cache"
process.arguments = ["-module-cache-path", cache, engine.path, "--kind", "pq"] + Array(CommandLine.arguments.dropFirst())
do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("Unable to run Swift encoder: \(error)\n", stderr)
    exit(1)
}
