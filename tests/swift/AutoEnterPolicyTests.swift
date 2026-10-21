// SOURCES: ALVRClient/AutoEnterPolicy.swift
// AutoEnterPolicy: one automatic "Enter" per connection, re-armed by a disconnect, never when disabled.
@main
enum AutoEnterPolicyTests {
    static func main() {
        // Fires once on connect.
        var p = AutoEnterPolicy(enabled: true)
        expect(!p.update(connected: false, showing: false), "no fire while disconnected")
        expect(p.update(connected: true, showing: false), "fires on connect")

        // Not again while still connected (the tap has not landed yet, or the user left).
        expect(!p.update(connected: true, showing: false), "no second fire while connected")
        expect(!p.update(connected: true, showing: true), "no fire once showing")
        expect(!p.update(connected: true, showing: false), "no fire after leaving while connected")

        // Re-arms after a disconnect (streamer restart).
        expect(!p.update(connected: false, showing: false), "no fire on disconnect")
        expect(p.update(connected: true, showing: false), "fires again after reconnect")

        // Not while already showing, even on the first connect.
        var q = AutoEnterPolicy(enabled: true)
        expect(!q.update(connected: true, showing: true), "no fire when already showing")
        expect(!q.update(connected: true, showing: false), "already-showing connection counts as entered")
        expect(!q.update(connected: false, showing: false), "disconnect")
        expect(q.update(connected: true, showing: false), "re-arms after disconnect")

        // Disconnect while showing still re-arms.
        var r = AutoEnterPolicy(enabled: true)
        expect(r.update(connected: true, showing: false), "r fires")
        expect(!r.update(connected: false, showing: true), "disconnect while showing")
        expect(r.update(connected: true, showing: false), "r fires after reconnect")

        // Disabled never fires.
        var d = AutoEnterPolicy(enabled: false)
        expect(!d.update(connected: true, showing: false), "disabled: no fire on connect")
        expect(!d.update(connected: false, showing: false), "disabled: no fire on disconnect")
        expect(!d.update(connected: true, showing: false), "disabled: no fire on reconnect")

        finishTests("AutoEnterPolicyTests")
    }
}
