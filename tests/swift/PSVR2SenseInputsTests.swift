// SOURCES: ALVRClient/Input/PSVR2SenseInputs.swift ALVRClient/Input/ControllerInputGate.swift
// PSVR2SenseInputs: Sense controller elements -> ALVR button paths, limited to the server's active profile button_set
// (ALVR alvr/common/src/inputs.rs: QUEST_CONTROLLER_PROFILE / PSVR2_CONTROLLER_PROFILE).

// A declared ControllerInputGate that records what it delivers and logs, per send call.
final class GateHarness {
    private var names: [UInt64: String] = [:]
    private var sent: [ButtonInput] = []
    private var logs: [String] = []
    private var gate: ControllerInputGate!

    init(profile: ControllerInputProfile) {
        for path in ControllerInputGate.knownPaths {
            names[UInt64(truncatingIfNeeded: path.hashValue)] = path
        }
        gate = ControllerInputGate(
            pathId: { UInt64(truncatingIfNeeded: $0.hashValue) },
            deliver: { [unowned self] id, value in self.sent.append(ButtonInput(path: self.names[id] ?? "?", value: value)) },
            announce: { _ in },
            log: { [unowned self] in self.logs.append($0) })
        gate.streamStarted(profile: profile)
    }

    func send(_ inputs: [ButtonInput]) -> (sent: [ButtonInput], logs: [String]) {
        sent = []
        logs = []
        gate.send(inputs)
        return (sent, logs)
    }
}

@main
enum PSVR2SenseInputsTests {
    static func paths(_ inputs: [ButtonInput]) -> Set<String> {
        Set(inputs.map { $0.path })
    }

    static func value(_ inputs: [ButtonInput], _ path: String) -> ButtonInputValue? {
        inputs.first { $0.path == path }?.value
    }

    static func hand(_ side: String, _ suffixes: [String]) -> Set<String> {
        Set(suffixes.map { "/user/hand/\(side)/input/\($0)" })
    }

    static func main() {
        // Profile sets mirror the server's button_set sizes.
        expectEqual(ControllerInputProfile.psvr2Sense.buttonSet.count, 36, "PSVR2 button_set size")
        expectEqual(ControllerInputProfile.questTouch.buttonSet.count, 26, "Quest Touch button_set size")

        // Active profile (GM 61d): a pure function of the emulation mode, the same as the server's default source set.
        // Controller detection never selects it.
        expectEqual(ControllerInputProfile.active(emulationMode: "PSVR2Sense"), .psvr2Sense, "PSVR2Sense -> PSVR2, with or without Sense")
        expectEqual(ControllerInputProfile.active(emulationMode: "Quest2Touch"), .questTouch, "Quest2Touch -> Quest")
        expectEqual(ControllerInputProfile.active(emulationMode: "ValveIndex"), .questTouch, "other modes: server default source")
        expectEqual(ControllerInputProfile.active(emulationMode: ""), .questTouch, "no settings: Quest")

        let idle = PSVR2SenseElements()
        let psvr = ControllerInputProfile.psvr2Sense
        let quest = ControllerInputProfile.questTouch

        // PSVR2: every Sense input is sent natively, exactly the PSVR2 button_set for that hand, nothing else.
        let perHand = ["system/click", "system/touch", "menu/click", "menu/touch",
                       "trigger/click", "trigger/value", "trigger/touch",
                       "thumbstick/x", "thumbstick/y", "thumbstick/click", "thumbstick/touch",
                       "squeeze/click", "squeeze/value", "squeeze/touch"]
        let left = PSVR2SenseInputs.inputs(isLeft: true, elements: idle, profile: psvr, homeButtonReachesApp: false, includeTrigger: true)
        let right = PSVR2SenseInputs.inputs(isLeft: false, elements: idle, profile: psvr, homeButtonReachesApp: false, includeTrigger: true)
        expectEqual(paths(left), hand("left", perHand + ["x/click", "x/touch", "y/click", "y/touch"]), "PSVR2 left paths")
        expectEqual(paths(right), hand("right", perHand + ["a/click", "a/touch", "b/click", "b/touch"]), "PSVR2 right paths")
        expect(paths(left).isSubset(of: psvr.buttonSet), "PSVR2 left within button_set")
        expect(paths(right).isSubset(of: psvr.buttonSet), "PSVR2 right within button_set")
        expectEqual(left.count, paths(left).count, "no duplicate left sends")
        expectEqual(right.count, paths(right).count, "no duplicate right sends")

        // Options (right Button Menu) -> right menu/click only; it no longer doubles as the PS button.
        var options = PSVR2SenseElements()
        options.menu = true
        options.menuTouched = true
        let r = PSVR2SenseInputs.inputs(isLeft: false, elements: options, profile: psvr, homeButtonReachesApp: false, includeTrigger: true)
        expectEqual(value(r, "/user/hand/right/input/menu/click"), .binary(true), "Options -> right menu/click")
        expectEqual(value(r, "/user/hand/right/input/menu/touch"), .binary(true), "Options touch -> right menu/touch")
        expectEqual(value(r, "/user/hand/right/input/system/click"), .binary(false), "Options is not PS")
        expectEqual(value(r, "/user/hand/right/input/system/touch"), .binary(false), "Options touch is not PS touch")

        // Create (left Button Menu) -> left menu/click.
        let l = PSVR2SenseInputs.inputs(isLeft: true, elements: options, profile: psvr, homeButtonReachesApp: false, includeTrigger: true)
        expectEqual(value(l, "/user/hand/left/input/menu/click"), .binary(true), "Create -> left menu/click")
        expectEqual(value(l, "/user/hand/left/input/system/click"), .binary(false), "Create is not PS")

        // PS (Button Home) -> system/click on its own hand.
        var ps = PSVR2SenseElements()
        ps.home = true
        ps.homeTouched = true
        for isLeft in [true, false] {
            let side = isLeft ? "left" : "right"
            let out = PSVR2SenseInputs.inputs(isLeft: isLeft, elements: ps, profile: psvr, homeButtonReachesApp: true, includeTrigger: true)
            expectEqual(value(out, "/user/hand/\(side)/input/system/click"), .binary(true), "PS -> \(side) system/click")
            expectEqual(value(out, "/user/hand/\(side)/input/system/touch"), .binary(true), "PS touch -> \(side) system/touch")
            expectEqual(value(out, "/user/hand/\(side)/input/menu/click"), .binary(false), "PS is not \(side) menu")
        }

        // Face buttons, L1/L2, sticks.
        var all = PSVR2SenseElements()
        all.buttonA = true; all.buttonATouched = true
        all.buttonB = true; all.buttonBTouched = true
        all.grip = true; all.gripTouched = true
        all.trigger = 0.6; all.triggerPressed = true; all.triggerTouched = true
        all.stickX = -0.5; all.stickY = 0.25; all.stickClick = true; all.stickTouched = true
        let la = PSVR2SenseInputs.inputs(isLeft: true, elements: all, profile: psvr, homeButtonReachesApp: false, includeTrigger: true)
        let ra = PSVR2SenseInputs.inputs(isLeft: false, elements: all, profile: psvr, homeButtonReachesApp: false, includeTrigger: true)
        expectEqual(value(la, "/user/hand/left/input/x/click"), .binary(true), "square -> left x/click")
        expectEqual(value(la, "/user/hand/left/input/y/click"), .binary(true), "triangle -> left y/click")
        expectEqual(value(la, "/user/hand/left/input/x/touch"), .binary(true), "square touch -> left x/touch")
        expectEqual(value(ra, "/user/hand/right/input/a/click"), .binary(true), "cross -> right a/click")
        expectEqual(value(ra, "/user/hand/right/input/b/click"), .binary(true), "circle -> right b/click")
        expectEqual(value(ra, "/user/hand/right/input/b/touch"), .binary(true), "circle touch -> right b/touch")
        expectEqual(value(la, "/user/hand/left/input/squeeze/click"), .binary(true), "L1 -> squeeze/click")
        expectEqual(value(la, "/user/hand/left/input/squeeze/value"), .scalar(1.0), "L1 -> squeeze/value")
        expectEqual(value(la, "/user/hand/left/input/squeeze/touch"), .binary(true), "L1 touch -> squeeze/touch")
        expectEqual(value(ra, "/user/hand/right/input/trigger/value"), .scalar(0.6), "R2 value")
        expectEqual(value(ra, "/user/hand/right/input/trigger/click"), .binary(true), "R2 click")
        expectEqual(value(ra, "/user/hand/right/input/trigger/touch"), .binary(true), "R2 touch")
        expectEqual(value(la, "/user/hand/left/input/thumbstick/x"), .scalar(-0.5), "left stick x")
        expectEqual(value(la, "/user/hand/left/input/thumbstick/y"), .scalar(0.25), "left stick y")
        expectEqual(value(la, "/user/hand/left/input/thumbstick/click"), .binary(true), "L3")
        expectEqual(value(la, "/user/hand/left/input/thumbstick/touch"), .binary(true), "left stick touch")

        // Pinch emulation owns the trigger click/value; the touch still goes out.
        let pinch = PSVR2SenseInputs.inputs(isLeft: true, elements: all, profile: psvr, homeButtonReachesApp: false, includeTrigger: false)
        expect(!paths(pinch).contains("/user/hand/left/input/trigger/value"), "pinch: no trigger value")
        expect(!paths(pinch).contains("/user/hand/left/input/trigger/click"), "pinch: no trigger click")
        expect(paths(pinch).contains("/user/hand/left/input/trigger/touch"), "pinch: trigger touch kept")

        // Never the sensor/value paths (in no server profile: the "Unknown" per-frame stream).
        for profile in [psvr, quest] {
            for isLeft in [true, false] {
                let out = PSVR2SenseInputs.inputs(isLeft: isLeft, elements: all, profile: profile, homeButtonReachesApp: false, includeTrigger: true)
                expect(!out.contains { $0.path.contains("/sensor/") }, "no sensor/value path (\(profile), left=\(isLeft))")
            }
        }

        // Quest Touch: unchanged behaviour (menu doubles as system while Home does not reach the app),
        // minus the paths outside the Quest button_set.
        let qg = GateHarness(profile: quest)
        let qr = qg.send(PSVR2SenseInputs.inputs(isLeft: false, elements: options, profile: quest, homeButtonReachesApp: false, includeTrigger: true))
        expectEqual(value(qr.sent, "/user/hand/right/input/system/click"), .binary(true), "Quest: Options still drives right system/click")
        expect(!paths(qr.sent).contains("/user/hand/right/input/menu/click"), "Quest: right menu/click not in button_set")
        expect(paths(qr.sent).isSubset(of: quest.buttonSet), "Quest right sends within button_set")
        expectEqual(paths(qr.sent), hand("right", ["a/click", "a/touch", "b/click", "b/touch", "system/click",
                                                   "squeeze/value", "trigger/value", "trigger/touch",
                                                   "thumbstick/x", "thumbstick/y", "thumbstick/click", "thumbstick/touch"]), "Quest right paths")
        expectEqual(qr.logs.count, 6, "Quest right drops: menu click/touch, system touch, squeeze click/touch, trigger click")

        let ql = qg.send(PSVR2SenseInputs.inputs(isLeft: true, elements: options, profile: quest, homeButtonReachesApp: false, includeTrigger: true))
        expectEqual(value(ql.sent, "/user/hand/left/input/menu/click"), .binary(true), "Quest: Create -> left menu/click")
        expectEqual(paths(ql.sent), hand("left", ["x/click", "x/touch", "y/click", "y/touch", "menu/click",
                                                  "squeeze/value", "trigger/value", "trigger/touch",
                                                  "thumbstick/x", "thumbstick/y", "thumbstick/click", "thumbstick/touch"]), "Quest left paths")

        // Each dropped path is reported once, not every frame.
        let again = qg.send(PSVR2SenseInputs.inputs(isLeft: false, elements: idle, profile: quest, homeButtonReachesApp: false, includeTrigger: true))
        expect(again.logs.isEmpty, "drops reported once")
        expect(!again.sent.isEmpty, "sends continue after the drop report")

        // PSVR2 through the gate: nothing dropped.
        let pr = GateHarness(profile: psvr).send(right)
        expect(pr.logs.isEmpty, "PSVR2: nothing dropped")
        expectEqual(pr.sent, right, "PSVR2: everything sent, in order")

        finishTests("PSVR2SenseInputsTests")
    }
}
