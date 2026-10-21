/*
Abstract:
Decides when the client enters the stream by itself (launch argument -ALVRAutoEnter YES), once per connection.
*/

import Foundation

/// Answers "enter now?" once per connection and re-arms after a disconnect. Foundation only, so it is unit-tested on macOS.
struct AutoEnterPolicy {
    let enabled: Bool
    private var armed = true

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Feed the current state; returns true exactly when the client should enter now.
    mutating func update(connected: Bool, showing: Bool) -> Bool {
        guard enabled else { return false }
        if !connected {
            armed = true
            return false
        }
        if showing {
            // Already in (entered by tap or by us): this connection is spent.
            armed = false
            return false
        }
        if armed {
            armed = false
            return true
        }
        return false
    }
}
