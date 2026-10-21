// SOURCES: ALVRClient/ClientLogging.swift

@main
enum ClientLoggingTests {
    static func main() {
        expectEqual(ClientLogging.defaultFilter(environment: [:]), "info", "unset RUST_LOG enables Info forwarding")
        expectEqual(ClientLogging.defaultFilter(environment: ["RUST_LOG": "error"]), nil, "explicit error wins")
        expectEqual(ClientLogging.defaultFilter(environment: ["RUST_LOG": ""]), nil, "explicit empty filter wins")
        finishTests("ClientLoggingTests")
    }
}
