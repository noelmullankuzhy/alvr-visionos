// SOURCES: ALVRClient/Input/PSVR2SenseInputs.swift ALVRClient/Input/ControllerInputGate.swift ALVRClient/Input/ControllerButtonSources.swift
// ControllerInputGate: the one choke point for controller/hand button sends. Nothing is delivered for a stream until
// that stream's interaction profile is declared, and only paths in the declared profile's button_set get through.
// Pinch emulation and generic gamepads are driven through their production mappers and the gate.
import Foundation

final class Recorder {
    var events: [String] = []
    var delivered: [(String, ButtonInputValue)] = []
    var logs: [String] = []
}

// Stand-in for alvr_path_string_to_id (FNV-1a 64).
func testPathId(_ path: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in path.utf8 {
        h ^= UInt64(b)
        h = h &* 0x100000001b3
    }
    return h
}

func makeGate(_ rec: Recorder) -> ControllerInputGate {
    var names: [UInt64: String] = [:]
    for path in ControllerInputGate.knownPaths {
        names[testPathId(path)] = path
    }
    return ControllerInputGate(
        pathId: testPathId,
        deliver: { id, value in
            let path = names[id] ?? "?\(id)"
            rec.delivered.append((path, value))
            rec.events.append("deliver \(path)")
        },
        announce: { profile in rec.events.append("announce \(profile)") },
        log: { rec.logs.append($0) })
}

func id(_ path: String) -> UInt64 { testPathId(path) }

func deliveredPaths(_ rec: Recorder) -> Set<String> { Set(rec.delivered.map { $0.0 }) }

func deliveredValue(_ rec: Recorder, _ path: String) -> ButtonInputValue? {
    rec.delivered.last { $0.0 == path }?.1
}

func hand(_ side: String, _ suffixes: [String]) -> Set<String> {
    Set(suffixes.map { "/user/hand/\(side)/input/\($0)" })
}

@main
enum ControllerInputGateTests {
    static func gateStateMachine() {
        // Startup: inputs before the declaration are not delivered.
        let rec = Recorder()
        let gate = makeGate(rec)
        expect(gate.declaredProfile == nil, "startup: undeclared")
        expect(!gate.send(id("/user/hand/right/input/a/click"), .binary(true)), "startup: send before declaration refused")
        expect(rec.events.isEmpty, "startup: nothing delivered or announced before the stream starts")

        // A profile change before any stream does not declare anything.
        gate.profileChanged(profile: .psvr2Sense)
        expect(gate.declaredProfile == nil, "profile change while not streaming keeps the gate shut")
        expect(rec.events.isEmpty, "no announce while not streaming")

        // Stream start: the declaration goes out first, then inputs flow.
        gate.streamStarted(profile: .psvr2Sense)
        expectEqual(gate.declaredProfile, .psvr2Sense, "declared after stream start")
        expect(gate.send(id("/user/hand/right/input/menu/click"), .binary(true)), "Options delivered after declaration")
        expectEqual(rec.events, ["announce psvr2Sense", "deliver /user/hand/right/input/menu/click"], "announce precedes the first input")

        // Disconnect: the gate shuts again.
        gate.streamStopped()
        expect(gate.declaredProfile == nil, "undeclared after disconnect")
        expect(!gate.send(id("/user/hand/right/input/menu/click"), .binary(false)), "send after disconnect refused")
        expectEqual(rec.events.count, 2, "nothing delivered between disconnect and reconnect")

        // Reconnect: declared again before any input of the new stream.
        gate.streamStarted(profile: .psvr2Sense)
        expect(gate.send(id("/user/hand/left/input/system/click"), .binary(true)), "left PS delivered after re-declaration")
        expectEqual(Array(rec.events.suffix(2)), ["announce psvr2Sense", "deliver /user/hand/left/input/system/click"], "reconnect: announce precedes input")

        // Reconnect under Quest Touch: Quest is declared explicitly too.
        gate.streamStopped()
        gate.streamStarted(profile: .questTouch)
        expectEqual(rec.events.last, "announce questTouch", "Quest declared on stream start")
        expect(!gate.send(id("/user/hand/right/input/menu/click"), .binary(true)), "Quest: right menu/click outside the set")
        expect(gate.send(id("/user/hand/right/input/system/click"), .binary(true)), "Quest: right system/click inside the set")

        // Mid-stream profile change re-declares and switches the set.
        gate.profileChanged(profile: .psvr2Sense)
        expectEqual(gate.declaredProfile, .psvr2Sense, "mid-stream change switches profile")
        expectEqual(rec.events.last, "announce psvr2Sense", "mid-stream change announced")
        expect(gate.send(id("/user/hand/right/input/menu/click"), .binary(true)), "PSVR2 after change: right menu/click delivered")

        // Out-of-set paths are logged once per profile, not per frame.
        let rec2 = Recorder()
        let g2 = makeGate(rec2)
        g2.streamStarted(profile: .questTouch)
        for _ in 0..<5 {
            g2.send(id("/user/hand/left/input/trigger/click"), .binary(true))
        }
        expectEqual(rec2.logs.count, 1, "one log line per dropped path")
        expect(rec2.logs.first?.contains("/user/hand/left/input/trigger/click") ?? false, "log names the path")
        expect(rec2.delivered.isEmpty, "dropped path never delivered")
    }

    static func pinch() {
        // Quest Touch: pinch trigger value only (trigger/click is not in the Quest set); system via left menu/click.
        let rec = Recorder()
        let gate = makeGate(rec)
        gate.streamStarted(profile: .questTouch)
        gate.send(PinchButtons.trigger(isLeft: true, value: 0.8))
        gate.send(PinchButtons.trigger(isLeft: false, value: 0.3))
        gate.send(PinchButtons.system(emulationMode: "Quest2Touch", pressed: true))
        expectEqual(deliveredPaths(rec), ["/user/hand/left/input/trigger/value", "/user/hand/right/input/trigger/value",
                                          "/user/hand/left/input/menu/click"], "Quest pinch deliveries")
        expect(deliveredPaths(rec).isSubset(of: ControllerInputProfile.questTouch.buttonSet), "Quest pinch within button_set")
        expectEqual(deliveredValue(rec, "/user/hand/left/input/trigger/value"), .scalar(0.8), "pinch trigger value")

        // PSVR2: click and value; the two-pinch system press is the right PS button.
        let rec2 = Recorder()
        let g2 = makeGate(rec2)
        g2.streamStarted(profile: .psvr2Sense)
        g2.send(PinchButtons.trigger(isLeft: false, value: 0.8))
        g2.send(PinchButtons.trigger(isLeft: true, value: 0.5))
        g2.send(PinchButtons.system(emulationMode: "PSVR2Sense", pressed: true))
        expectEqual(deliveredValue(rec2, "/user/hand/right/input/trigger/click"), .binary(true), "click past 0.7")
        expectEqual(deliveredValue(rec2, "/user/hand/left/input/trigger/click"), .binary(false), "no click at 0.5")
        expectEqual(deliveredValue(rec2, "/user/hand/right/input/system/click"), .binary(true), "PSVR2 pinch system -> right system/click")
        expect(deliveredPaths(rec2).isSubset(of: ControllerInputProfile.psvr2Sense.buttonSet), "PSVR2 pinch within button_set")
        expect(PinchButtons.systemIsRight(emulationMode: "PSVR2Sense"), "PSVR2Sense: system on the right")
        expect(!PinchButtons.systemIsRight(emulationMode: "Quest2Touch"), "Quest2Touch: system on the left")

        // Before the stream's declaration, pinch sends nothing.
        let rec3 = Recorder()
        let g3 = makeGate(rec3)
        g3.send(PinchButtons.trigger(isLeft: true, value: 1.0))
        expect(rec3.delivered.isEmpty, "pinch before declaration not delivered")
    }

    static func genericGamepad() {
        var e = GamepadElements()
        e.buttonA = true; e.buttonB = true; e.buttonX = true; e.buttonY = true
        e.dpadUp = true; e.dpadDown = true; e.dpadRight = true
        e.leftTrigger = 0.4; e.leftTriggerPressed = true
        e.rightTrigger = 0.9; e.rightTriggerPressed = true
        e.leftShoulder = 0.2; e.leftShoulderPressed = false
        e.rightShoulder = 0.0; e.rightShoulderPressed = false
        e.leftStickX = 0.5; e.leftStickY = -0.5; e.rightStickX = 0.25; e.rightStickY = 0.75
        e.leftStickClick = true; e.rightStickClick = true
        e.home = true; e.options = true

        let all = GamepadButtons.inputs(e, includeLeftTrigger: true, includeRightTrigger: true)
        expectEqual(all.first { $0.path == "/user/hand/left/input/squeeze/value" }?.value, .scalar(1.0), "d-pad up forces squeeze value")
        expectEqual(all.first { $0.path == "/user/hand/right/input/squeeze/click" }?.value, .binary(true), "X drives right squeeze click")

        // Quest Touch: only Quest-set paths reach the server.
        let rec = Recorder()
        let gate = makeGate(rec)
        gate.streamStarted(profile: .questTouch)
        gate.send(all)
        expect(deliveredPaths(rec).isSubset(of: ControllerInputProfile.questTouch.buttonSet), "generic gamepad within Quest button_set")
        expectEqual(deliveredPaths(rec), hand("left", ["x/click", "y/click", "trigger/value", "squeeze/value",
                                                       "thumbstick/x", "thumbstick/y", "thumbstick/click", "menu/click"])
                    .union(hand("right", ["a/click", "b/click", "trigger/value", "squeeze/value",
                                          "thumbstick/x", "thumbstick/y", "thumbstick/click", "system/click"])), "Quest generic deliveries")
        expectEqual(deliveredValue(rec, "/user/hand/left/input/menu/click"), .binary(true), "Home -> left menu/click")
        expectEqual(deliveredValue(rec, "/user/hand/right/input/system/click"), .binary(true), "Options -> right system/click")
        for dropped in ["/user/hand/right/input/y/click", "/user/hand/left/input/squeeze/force", "/user/hand/left/input/trigger/click",
                        "/user/hand/left/input/system/click", "/user/hand/right/input/menu/click", "/user/hand/right/input/squeeze/click"] {
            expect(!deliveredPaths(rec).contains(dropped), "Quest drops \(dropped)")
        }

        // PSVR2 declared with a generic gamepad: still only PSVR2-set paths.
        let rec2 = Recorder()
        let g2 = makeGate(rec2)
        g2.streamStarted(profile: .psvr2Sense)
        g2.send(all)
        expect(deliveredPaths(rec2).isSubset(of: ControllerInputProfile.psvr2Sense.buttonSet), "generic gamepad within PSVR2 button_set")

        // Pinch owns the triggers.
        let noTriggers = GamepadButtons.inputs(e, includeLeftTrigger: false, includeRightTrigger: false)
        expect(!noTriggers.contains { $0.path.contains("/trigger/") }, "pinch suppresses gamepad triggers")
    }

    // Every alvr_send_button call in the app goes through the gate's delivery (one choke point).
    static func singleChokePoint() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appDir = root.appendingPathComponent("ALVRClient")
        var hits: [String] = []
        let files = FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if !code.hasPrefix("//") && code.contains("alvr_send_button(") {
                    hits.append(url.lastPathComponent)
                }
            }
        }
        expectEqual(hits, ["InputSink.swift"], "alvr_send_button called only from the gate delivery")
    }

    static func main() {
        gateStateMachine()
        pinch()
        genericGamepad()
        singleChokePoint()
        finishTests("ControllerInputGateTests")
    }
}
