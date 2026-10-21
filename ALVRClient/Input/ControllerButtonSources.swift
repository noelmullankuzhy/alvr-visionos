//
//  ControllerButtonSources.swift
//
//  Button paths for emulated pinch interactions and generic (extended)
//  gamepads, as pure mappers so tests/swift can drive them through
//  ControllerInputGate exactly as WorldTracker does.
//

import Foundation

private func input(_ side: String, _ suffix: String, _ value: Bool) -> ButtonInput {
    ButtonInput(path: "/user/hand/\(side)/input/\(suffix)", value: .binary(value))
}

private func input(_ side: String, _ suffix: String, _ value: Float) -> ButtonInput {
    ButtonInput(path: "/user/hand/\(side)/input/\(suffix)", value: .scalar(value))
}

enum PinchButtons {
    /// The two-pinch menu press lands on the right PS button under PSVR2Sense,
    /// on the left menu button otherwise.
    static func systemIsRight(emulationMode: String) -> Bool {
        emulationMode == "PSVR2Sense"
    }

    static func system(emulationMode: String, pressed: Bool) -> [ButtonInput] {
        systemIsRight(emulationMode: emulationMode) ? [input("right", "system/click", pressed)] : [input("left", "menu/click", pressed)]
    }

    /// The emulated trigger for one hand: click past 0.7, then the value.
    static func trigger(isLeft: Bool, value: Float) -> [ButtonInput] {
        let side = isLeft ? "left" : "right"
        return [input(side, "trigger/click", value > 0.7), input(side, "trigger/value", value)]
    }
}

/// An extended gamepad's elements (GCExtendedGamepad plus the named system buttons).
struct GamepadElements {
    var buttonA = false, buttonB = false, buttonX = false, buttonY = false
    var dpadUp = false, dpadDown = false, dpadLeft = false, dpadRight = false
    var leftTrigger: Float = 0, leftTriggerPressed = false
    var rightTrigger: Float = 0, rightTriggerPressed = false
    var leftShoulder: Float = 0, leftShoulderPressed = false
    var rightShoulder: Float = 0, rightShoulderPressed = false
    var leftStickX: Float = 0, leftStickY: Float = 0, rightStickX: Float = 0, rightStickY: Float = 0
    var leftStickClick = false, rightStickClick = false
    var home = false, menu = false, share = false, options = false
}

enum GamepadButtons {
    /// One gamepad driving both virtual hands with Quest Touch vocabulary (no real input profile exists).
    static func inputs(_ e: GamepadElements, includeLeftTrigger: Bool, includeRightTrigger: Bool) -> [ButtonInput] {
        var out: [ButtonInput] = []
        out.append(input("right", "a/click", e.buttonA))
        out.append(input("right", "b/click", e.buttonB))
        out.append(input("right", "y/click", e.buttonY))

        // Kinda weird here, we're emulating Quest controllers bc we don't have a real input profile.
        out.append(input("left", "y/click", e.dpadRight))
        out.append(input("left", "x/click", e.dpadDown || e.dpadLeft))

        // ZL/ZR -> Trigger
        if includeLeftTrigger {
            out.append(input("left", "trigger/click", e.leftTriggerPressed))
            out.append(input("left", "trigger/value", e.leftTrigger))
        }
        if includeRightTrigger {
            out.append(input("right", "trigger/click", e.rightTriggerPressed))
            out.append(input("right", "trigger/value", e.rightTrigger))
        }

        // L/R -> Squeeze
        let leftSqueeze = max(e.leftShoulder, e.dpadUp ? 1.0 : 0.0)
        out.append(input("left", "squeeze/click", e.leftShoulderPressed || e.dpadUp))
        out.append(input("left", "squeeze/value", leftSqueeze))
        out.append(input("left", "squeeze/force", leftSqueeze))
        let rightSqueeze = max(e.rightShoulder, e.buttonX ? 1.0 : 0.0)
        out.append(input("right", "squeeze/click", e.rightShoulderPressed || e.buttonX))
        out.append(input("right", "squeeze/value", rightSqueeze))
        out.append(input("right", "squeeze/force", rightSqueeze))

        // Thumbsticks
        out.append(input("left", "thumbstick/x", e.leftStickX))
        out.append(input("left", "thumbstick/y", e.leftStickY))
        out.append(input("right", "thumbstick/x", e.rightStickX))
        out.append(input("right", "thumbstick/y", e.rightStickY))
        out.append(input("left", "thumbstick/click", e.leftStickClick))
        out.append(input("right", "thumbstick/click", e.rightStickClick))

        // System buttons of various varieties (whichever one actually hits)
        let leftSystem = e.home || e.menu
        let rightSystem = e.share || e.options
        out.append(input("left", "system/click", leftSystem))
        out.append(input("right", "system/click", rightSystem))
        out.append(input("left", "menu/click", leftSystem))
        out.append(input("right", "menu/click", rightSystem))
        return out
    }
}
