enum ClientLogging {
    static func defaultFilter(environment: [String: String]) -> String? {
        // Apple's client_core uses env_logger::builder() (from_default_env): without RUST_LOG,
        // env_logger defaults to Error, filtering Info before it can be mirrored to the streamer.
        // Preserve every explicit filter, including an empty string.
        environment["RUST_LOG"] == nil ? "info" : nil
    }
}
