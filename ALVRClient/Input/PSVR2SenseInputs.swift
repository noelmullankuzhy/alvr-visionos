//
//  PSVR2SenseInputs.swift
//
//  PS VR2 Sense controller elements -> ALVR button paths, limited to the
//  button_set of the profile the server maps from (ALVR
//  alvr/common/src/inputs.rs). A path outside that set has no binding on the
//  server: it is logged there as "Received button not mapped" (scalars on every
//  packet) and never reaches SteamVR.
//
//  Pure (Foundation only) so tests/swift can run it on macOS; WorldTracker
//  turns the paths into IDs with alvr_path_string_to_id.
//

import Foundation

/// The interaction profile whose button_set the server matches our paths against.
enum ControllerInputProfile: Equatable {
    /// The server's default source set until the client declares a profile.
    case questTouch
    /// Declared with alvr_send_active_interaction_profile(PSVR2 profile).
    case psvr2Sense

    static let psvr2ProfilePath = "/interaction_profiles/sony/playstation_vr2_sense_controller"

    static func active(emulationMode: String, psvr2Connected: Bool) -> ControllerInputProfile {
        emulationMode == "PSVR2Sense" && psvr2Connected ? .psvr2Sense : .questTouch
    }

    var buttonSet: Set<String> {
        switch self {
        case .questTouch: return ControllerInputProfile.questSet
        case .psvr2Sense: return ControllerInputProfile.psvr2Set
        }
    }

    private static func hand(_ side: String, _ inputs: [String]) -> [String] {
        inputs.map { "/user/hand/\(side)/input/\($0)" }
    }

    // QUEST_CONTROLLER_PROFILE button_set
    private static let questSet = Set(
        hand("left", ["x/click", "x/touch", "y/click", "y/touch", "menu/click",
                      "squeeze/value", "trigger/value", "trigger/touch",
                      "thumbstick/x", "thumbstick/y", "thumbstick/click", "thumbstick/touch", "thumbrest/touch"])
        + hand("right", ["a/click", "a/touch", "b/click", "b/touch", "system/click",
                         "squeeze/value", "trigger/value", "trigger/touch",
                         "thumbstick/x", "thumbstick/y", "thumbstick/click", "thumbstick/touch", "thumbrest/touch"]))

    // PSVR2_CONTROLLER_PROFILE button_set
    private static let psvr2Common = ["system/click", "system/touch", "menu/click", "menu/touch",
                                      "trigger/click", "trigger/value", "trigger/touch",
                                      "thumbstick/x", "thumbstick/y", "thumbstick/click", "thumbstick/touch",
                                      "squeeze/click", "squeeze/value", "squeeze/touch"]
    private static let psvr2Set = Set(
        hand("left", psvr2Common + ["x/click", "x/touch", "y/click", "y/touch"])
        + hand("right", psvr2Common + ["a/click", "a/touch", "b/click", "b/touch"]))
}

enum ButtonInputValue: Equatable {
    case binary(Bool)
    case scalar(Float)
}

struct ButtonInput: Equatable {
    let path: String
    let value: ButtonInputValue
}

/// One Sense controller as visionOS reports it (GCController input elements).
struct PSVR2SenseElements {
    var buttonA = false, buttonATouched = false     // "Button A": square (left), cross (right)
    var buttonB = false, buttonBTouched = false     // "Button B": triangle (left), circle (right)
    var menu = false, menuTouched = false           // "Button Menu": Create (left), Options (right)
    var home = false, homeTouched = false           // "Button Home": PS
    var grip = false, gripTouched = false           // "Grip": L1/R1
    var trigger: Float = 0                          // "Trigger": L2/R2
    var triggerPressed = false, triggerTouched = false
    var stickX: Float = 0, stickY: Float = 0        // "Thumbstick" dpad
    var stickClick = false, stickTouched = false    // "Thumbstick Button"
}

enum PSVR2SenseInputs {
    /// Every path for one hand. Under PSVR2 the result is exactly that hand's
    /// half of the PSVR2 button_set; under Quest Touch run it through
    /// ButtonPathFilter. `includeTrigger` is false while pinch emulation owns
    /// the trigger click/value.
    static func inputs(isLeft: Bool, elements e: PSVR2SenseElements, profile: ControllerInputProfile,
                       homeButtonReachesApp: Bool, includeTrigger: Bool) -> [ButtonInput] {
        let side = isLeft ? "left" : "right"
        var out: [ButtonInput] = []
        func send(_ input: String, _ value: Bool) {
            out.append(ButtonInput(path: "/user/hand/\(side)/input/\(input)", value: .binary(value)))
        }
        func send(_ input: String, _ value: Float) {
            out.append(ButtonInput(path: "/user/hand/\(side)/input/\(input)", value: .scalar(value)))
        }

        let primary = isLeft ? "x" : "a"
        let secondary = isLeft ? "y" : "b"
        send("\(primary)/click", e.buttonA)
        send("\(secondary)/click", e.buttonB)
        send("thumbstick/click", e.stickClick)
        send("thumbstick/x", e.stickX)
        send("thumbstick/y", e.stickY)
        if includeTrigger {
            send("trigger/click", e.triggerPressed)
            send("trigger/value", e.trigger)
        }

        send("squeeze/click", e.grip)
        send("squeeze/value", e.grip ? Float(1.0) : Float(0.0))
        send("squeeze/touch", e.gripTouched)

        send("\(primary)/touch", e.buttonATouched)
        send("\(secondary)/touch", e.buttonBTouched)
        send("thumbstick/touch", e.stickTouched)
        send("trigger/touch", e.triggerTouched)

        // PSVR2 has its own system (PS) and menu (Create/Options) inputs. Under
        // Quest Touch the menu button also drives system while Home does not
        // reach the app, as before.
        let menuIsSystem = profile == .questTouch && !homeButtonReachesApp
        send("menu/touch", e.menuTouched)
        send("system/touch", e.homeTouched || (menuIsSystem && e.menuTouched))
        send("menu/click", e.menu)
        send("system/click", e.home || (menuIsSystem && e.menu))
        return out
    }
}

/// Keeps only the paths in the active profile's button_set and reports each
/// dropped path once per profile, not every frame.
struct ButtonPathFilter {
    private var reported: Set<String> = []

    mutating func admit(_ inputs: [ButtonInput], profile: ControllerInputProfile) -> (send: [ButtonInput], newlyDropped: [String]) {
        let set = profile.buttonSet
        var send: [ButtonInput] = []
        var newlyDropped: [String] = []
        for input in inputs {
            if set.contains(input.path) {
                send.append(input)
            } else if reported.insert("\(profile):\(input.path)").inserted {
                newlyDropped.append(input.path)
            }
        }
        return (send, newlyDropped)
    }
}
