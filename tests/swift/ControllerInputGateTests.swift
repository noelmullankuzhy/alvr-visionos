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

func makeGate(_ rec: Recorder, onAnnounce: ((ControllerInputProfile) -> Void)? = nil,
              beforeLock: ((String) -> Void)? = nil, inLock: ((String) -> Void)? = nil) -> ControllerInputGate {
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
        announce: { profile in
            rec.events.append("announce \(profile)")
            onAnnounce?(profile)
        },
        log: { rec.logs.append($0) },
        beforeLock: beforeLock,
        inLock: inLock)
}

/// Forces one lock order between two gate calls on two threads, with the gate's test seams and semaphores (no sleeps):
/// the holder takes the gate lock at `holderEntry` and stays in the critical section until the waiter has reached
/// the lock at `waiterEntry`, so the waiter's call runs strictly after the holder's.
final class LockOrder {
    private let mutex = NSLock()
    private var holderEntry: String?
    private var waiterEntry: String?
    private let holderIn = DispatchSemaphore(value: 0)
    private let waiterEntered = DispatchSemaphore(value: 0)
    private var waiterWasWaiting = false

    func beforeLock(_ entry: String) {
        mutex.lock()
        let hit = entry == waiterEntry
        if hit { waiterEntry = nil }
        mutex.unlock()
        if hit { waiterEntered.signal() }
    }

    func inLock(_ entry: String) {
        mutex.lock()
        let hit = entry == holderEntry
        if hit { holderEntry = nil }
        mutex.unlock()
        guard hit else { return }
        holderIn.signal()
        waiterWasWaiting = waiterEntered.wait(timeout: .now() + 10) == .success
    }

    /// True when both calls finished and the waiter reached the lock while the holder held it.
    func run(holderEntry: String, _ holder: @escaping () -> Void, waiterEntry: String, _ waiter: @escaping () -> Void) -> Bool {
        mutex.lock()
        self.holderEntry = holderEntry
        self.waiterEntry = waiterEntry
        waiterWasWaiting = false
        mutex.unlock()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { holder(); done.signal() }
        guard holderIn.wait(timeout: .now() + 10) == .success else { return false }
        Thread.detachNewThread { waiter(); done.signal() }
        let finished = done.wait(timeout: .now() + 10) == .success && done.wait(timeout: .now() + 10) == .success
        return finished && waiterWasWaiting
    }
}

/// Options-held frames from the right Sense controller, sent through the production mapper; records each frame's profile.
final class Frames {
    var mappedWith: [ControllerInputProfile] = []
    var sent: [Bool] = []
}

func optionsFrame(_ gate: ControllerInputGate, _ frames: Frames) -> () -> Void {
    {
        let ok = gate.send { profile in
            frames.mappedWith.append(profile)
            return PSVR2SenseInputs.inputs(isLeft: false, elements: optionsHeld(), profile: profile,
                                           homeButtonReachesApp: false, includeTrigger: true)
        }
        frames.sent.append(ok)
    }
}

func racingGate() -> (Recorder, LockOrder, ControllerInputGate) {
    let rec = Recorder()
    let order = LockOrder()
    let gate = makeGate(rec, beforeLock: { order.beforeLock($0) }, inLock: { order.inLock($0) })
    return (rec, order, gate)
}

func indexOf(_ rec: Recorder, _ event: String, from: Int = 0) -> Int? {
    rec.events.indices.first { $0 >= from && rec.events[$0] == event }
}

func deliveriesFrom(_ rec: Recorder, _ from: Int) -> [Int] {
    rec.events.indices.filter { $0 >= from && rec.events[$0].hasPrefix("deliver") }
}

let noSenseLog = "PSVR2Sense mode without Sense controllers detected"

// Options (right Button Menu) held: PSVR2 maps it to menu only, Quest Touch also to system.
func optionsHeld() -> PSVR2SenseElements {
    var e = PSVR2SenseElements()
    e.menu = true
    e.menuTouched = true
    return e
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

        // A controller change before any stream does not declare anything.
        gate.controllersChanged(profile: .psvr2Sense)
        expect(gate.declaredProfile == nil, "controller change while not streaming keeps the gate shut")
        expect(rec.events.isEmpty, "no announce while not streaming")
        expect(rec.logs.isEmpty, "no log while not streaming")

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

        // A mid-stream controller change never switches the stream's profile; it is logged once.
        let questStream = gate.currentStream
        let announcesBefore = rec.events.filter { $0.hasPrefix("announce") }.count
        let logsBefore = rec.logs.count
        gate.controllersChanged(profile: .psvr2Sense)
        gate.controllersChanged(profile: .psvr2Sense)
        expectEqual(gate.currentStream, questStream, "mid-stream change keeps the stream's profile and generation")
        expectEqual(rec.events.filter { $0.hasPrefix("announce") }.count, announcesBefore, "mid-stream change not announced")
        expectEqual(rec.logs.count, logsBefore + 1, "mid-stream change logged once")
        expect(!gate.send(id("/user/hand/right/input/menu/click"), .binary(true)), "still Quest after change: right menu/click dropped")
        gate.controllersChanged(profile: .questTouch)
        expectEqual(rec.logs.count, logsBefore + 1, "a change back to the stream's profile is not logged")

        // Each stream gets a new generation; the next stream picks the profile afresh.
        gate.streamStopped()
        let next = gate.streamStarted(profile: .psvr2Sense)
        expectEqual(next.generation, (questStream?.generation ?? 0) + 1, "next stream, next generation")
        expectEqual(gate.declaredProfile, .psvr2Sense, "next stream declares the new controllers")
        gate.controllersChanged(profile: .questTouch)
        expectEqual(rec.logs.count, logsBefore + 2, "the new stream logs its own mid-stream change once")

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

    // Race (a), reconnect: frames between STOPPED and the next STARTED are dropped unmapped; frames after STARTED are
    // mapped with the new stream's profile, under its generation, after its declaration.
    static func reconnectInterleaving() {
        let rec = Recorder()
        let gate = makeGate(rec)
        var mappedWith: [ControllerInputProfile] = []
        func frame() -> Bool {
            gate.send { profile in
                mappedWith.append(profile)
                return PSVR2SenseInputs.inputs(isLeft: false, elements: optionsHeld(), profile: profile,
                                               homeButtonReachesApp: false, includeTrigger: true)
            }
        }

        expect(!frame(), "startup: frame dropped")
        let first = gate.streamStarted(profile: .questTouch)
        expect(frame(), "stream 1: frame delivered")
        expectEqual(deliveredValue(rec, "/user/hand/right/input/system/click"), .binary(true), "stream 1 (Quest): Options drives system")

        gate.streamStopped()
        expect(gate.currentStream == nil, "STOPPED closes the generation")
        let delivered = rec.delivered.count
        let mapped = mappedWith.count
        for _ in 0..<3 {
            expect(!frame(), "between STOPPED and STARTED: frame dropped")
        }
        expectEqual(rec.delivered.count, delivered, "nothing delivered between STOPPED and STARTED")
        expectEqual(mappedWith.count, mapped, "nothing even mapped between STOPPED and STARTED")

        let second = gate.streamStarted(profile: .psvr2Sense)
        expectEqual(second.generation, first.generation + 1, "reconnect opens a new generation")
        let eventsBefore = rec.events.count
        expect(frame(), "stream 2: frame delivered")
        expectEqual(mappedWith.last, .psvr2Sense, "stream 2 frame mapped with the new profile")
        let stream2 = Array(rec.delivered.suffix(rec.delivered.count - delivered))
        expectEqual(stream2.first { $0.0 == "/user/hand/right/input/system/click" }?.1, .binary(false), "stream 2 (PSVR2): Options is not PS")
        expectEqual(stream2.first { $0.0 == "/user/hand/right/input/menu/click" }?.1, .binary(true), "stream 2 (PSVR2): Options -> menu")
        expectEqual(Array(rec.events.prefix(eventsBefore).suffix(1)), ["announce psvr2Sense"], "stream 2 declared before its first frame")

        // A STARTED with no STOPPED before it (stalled STOPPED) still opens a new generation and re-declares.
        let third = gate.streamStarted(profile: .questTouch)
        expectEqual(third.generation, second.generation + 1, "STARTED over an open stream: new generation")
        expectEqual(rec.events.last, "announce questTouch", "STARTED over an open stream re-declares")
        expect(frame(), "stream 3: frame delivered")
        expectEqual(mappedWith.last, .questTouch, "stream 3 frame mapped with its own profile")
    }

    // Race (b): a frame mapped under one profile is never delivered under another. Driven with the gate's beforeLock
    // hook and semaphores (no sleeps): each side holds the critical section until the other side has entered the gate.
    static func frameNeverCrossesProfiles() {
        // 1. A Quest frame is mid-map when a reconnect to PSVR2 begins: the whole frame is delivered first.
        let reconnectEntered = DispatchSemaphore(value: 0)
        let reconnectDone = DispatchSemaphore(value: 0)
        let rec = Recorder()
        let gate = makeGate(rec, beforeLock: { entry in
            if entry == "streamStopped" { reconnectEntered.signal() }
        })
        gate.streamStarted(profile: .questTouch)
        var mappedWith: ControllerInputProfile?
        var reconnectWasWaiting = false
        let sent = gate.send { profile in
            mappedWith = profile
            Thread.detachNewThread {
                gate.streamStopped()
                gate.streamStarted(profile: .psvr2Sense)
                reconnectDone.signal()
            }
            reconnectWasWaiting = reconnectEntered.wait(timeout: .now() + 10) == .success
            return PSVR2SenseInputs.inputs(isLeft: false, elements: optionsHeld(), profile: profile,
                                           homeButtonReachesApp: false, includeTrigger: true)
        }
        expect(reconnectDone.wait(timeout: .now() + 10) == .success, "reconnect completed")
        expect(reconnectWasWaiting, "the reconnect entered the gate while the frame was being mapped")
        expect(sent, "the frame in flight is delivered")
        expectEqual(mappedWith, .questTouch, "the frame was mapped with the Quest stream's profile")
        let announcePsvr2 = rec.events.firstIndex(of: "announce psvr2Sense") ?? -1
        let lastDelivery = rec.events.lastIndex { $0.hasPrefix("deliver") } ?? Int.max
        expect(announcePsvr2 > lastDelivery, "every delivery of the Quest frame precedes the PSVR2 declaration")
        expectEqual(deliveredValue(rec, "/user/hand/right/input/system/click"), .binary(true), "Quest frame: Options -> system (Quest stream)")
        expect(rec.delivered.allSatisfy { ControllerInputProfile.questTouch.buttonSet.contains($0.0) }, "Quest frame filtered by the Quest set")
        expectEqual(gate.declaredProfile, .psvr2Sense, "PSVR2 declared afterwards")

        // 2. A frame arrives while the PSVR2 declaration is in progress: it waits and is mapped with PSVR2.
        let frameEntered = DispatchSemaphore(value: 0)
        let frameDone = DispatchSemaphore(value: 0)
        let rec2 = Recorder()
        var frameWasWaiting = false
        final class Mapped { var profile: ControllerInputProfile? }
        let mapped2 = Mapped()
        var gate2: ControllerInputGate!
        gate2 = makeGate(rec2, onAnnounce: { profile in
            guard profile == .psvr2Sense else { return }
            let g = gate2!
            Thread.detachNewThread {
                g.send { profile in
                    mapped2.profile = profile
                    return PSVR2SenseInputs.inputs(isLeft: false, elements: optionsHeld(), profile: profile,
                                                   homeButtonReachesApp: false, includeTrigger: true)
                }
                frameDone.signal()
            }
            frameWasWaiting = frameEntered.wait(timeout: .now() + 10) == .success
        }, beforeLock: { entry in
            if entry == "send" { frameEntered.signal() }
        })
        gate2.streamStarted(profile: .questTouch)
        gate2.streamStopped()
        gate2.streamStarted(profile: .psvr2Sense)
        expect(frameDone.wait(timeout: .now() + 10) == .success, "frame completed")
        expect(frameWasWaiting, "the frame entered the gate during the PSVR2 declaration")
        expectEqual(mapped2.profile, .psvr2Sense, "the frame was mapped with the new stream's profile")
        expectEqual(rec2.events.first { $0.hasPrefix("deliver") || $0 == "announce psvr2Sense" }, "announce psvr2Sense",
                    "the declaration precedes the frame's deliveries")
        expectEqual(deliveredValue(rec2, "/user/hand/right/input/system/click"), .binary(false), "PSVR2 frame: Options is not PS")
        expectEqual(deliveredValue(rec2, "/user/hand/right/input/menu/click"), .binary(true), "PSVR2 frame: Options -> menu")
    }

    // GM 61(d): the stream's profile is a pure function of the emulation mode; Sense detection only logs, once per stream.
    static func profileFromEmulationMode() {
        let rec = Recorder()
        let gate = makeGate(rec)
        let s1 = gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: false)
        expectEqual(s1.profile, .psvr2Sense, "PSVR2Sense without Sense controllers: still PSVR2")
        expectEqual(rec.events, ["announce psvr2Sense"], "PSVR2 declared without Sense controllers")
        expectEqual(rec.logs.filter { $0.contains(noSenseLog) }.count, 1, "no-Sense start logged")
        gate.controllersDetected(emulationMode: "PSVR2Sense", senseDetected: false)
        expectEqual(rec.logs.filter { $0.contains(noSenseLog) }.count, 1, "no-Sense logged once per stream")
        gate.controllersDetected(emulationMode: "PSVR2Sense", senseDetected: true)
        expectEqual(gate.currentStream, s1, "Sense attach keeps the stream's profile and generation")
        expectEqual(rec.events, ["announce psvr2Sense"], "Sense attach declares nothing")

        let s2 = gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: true)
        expectEqual(s2.profile, .psvr2Sense, "PSVR2Sense with Sense: PSVR2")
        gate.controllersDetected(emulationMode: "PSVR2Sense", senseDetected: false)
        expectEqual(rec.logs.filter { $0.contains(noSenseLog) }.count, 2, "Sense detached mid-stream: logged once for that stream")
        gate.controllersDetected(emulationMode: "PSVR2Sense", senseDetected: false)
        expectEqual(rec.logs.filter { $0.contains(noSenseLog) }.count, 2, "and only once")
        expectEqual(gate.currentStream, s2, "Sense detach keeps the stream's profile")

        expectEqual(gate.streamStarted(emulationMode: "Quest2Touch", senseDetected: true).profile, .questTouch, "Quest2Touch with Sense: Quest")
        expectEqual(gate.streamStarted(emulationMode: "ValveIndex", senseDetected: false).profile, .questTouch, "other modes: Quest")
        expectEqual(rec.logs.filter { $0.contains(noSenseLog) }.count, 2, "no-Sense is only logged under PSVR2Sense")
    }

    // Concurrent STOPPED vs a frame, both lock orders.
    static func concurrentStoppedVsSend() {
        // STOPPED holds the lock, the frame waits: the frame is dropped unmapped.
        do {
            let (rec, order, gate) = racingGate()
            let frames = Frames()
            gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: true)
            expect(order.run(holderEntry: "streamStopped", { gate.streamStopped() }, waiterEntry: "send", optionsFrame(gate, frames)),
                   "STOPPED then send: forced order")
            expectEqual(frames.sent, [false], "STOPPED then send: frame refused")
            expect(frames.mappedWith.isEmpty, "STOPPED then send: frame not even mapped")
            expect(rec.delivered.isEmpty, "STOPPED then send: nothing delivered")
        }
        // The frame holds the lock, STOPPED waits: the whole frame goes out under the open stream, then the gate shuts.
        do {
            let (rec, order, gate) = racingGate()
            let frames = Frames()
            gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: true)
            expect(order.run(holderEntry: "send", optionsFrame(gate, frames), waiterEntry: "streamStopped", { gate.streamStopped() }),
                   "send then STOPPED: forced order")
            expectEqual(frames.sent, [true], "send then STOPPED: frame delivered")
            expectEqual(frames.mappedWith, [.psvr2Sense], "send then STOPPED: mapped with the open stream's profile")
            expectEqual(deliveredValue(rec, "/user/hand/right/input/menu/click"), .binary(true), "send then STOPPED: Options -> menu")
            expectEqual(deliveredValue(rec, "/user/hand/right/input/system/click"), .binary(false), "send then STOPPED: Options is not PS")
            expect(gate.currentStream == nil, "send then STOPPED: gate shut afterwards")
        }
    }

    // Concurrent STARTED vs a frame after STOPPED, both lock orders.
    static func concurrentStartedVsSend() {
        // STARTED holds the lock, the frame waits: the frame is mapped with the new stream's profile, after its declaration.
        do {
            let (rec, order, gate) = racingGate()
            let frames = Frames()
            gate.streamStarted(emulationMode: "Quest2Touch", senseDetected: true)
            gate.streamStopped()
            let mark = rec.events.count
            expect(order.run(holderEntry: "streamStarted", { gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: true) },
                             waiterEntry: "send", optionsFrame(gate, frames)), "STARTED then send: forced order")
            expectEqual(frames.sent, [true], "STARTED then send: frame delivered")
            expectEqual(frames.mappedWith, [.psvr2Sense], "STARTED then send: mapped with the new profile")
            let announce = indexOf(rec, "announce psvr2Sense", from: mark) ?? Int.max
            expect(deliveriesFrom(rec, mark).allSatisfy { $0 > announce }, "STARTED then send: declaration precedes every delivery")
            expectEqual(deliveredValue(rec, "/user/hand/right/input/system/click"), .binary(false), "STARTED then send: Options is not PS")
        }
        // The frame holds the lock, STARTED waits: the gate is still shut, the frame is dropped unmapped.
        do {
            let (rec, order, gate) = racingGate()
            let frames = Frames()
            gate.streamStarted(emulationMode: "Quest2Touch", senseDetected: true)
            gate.streamStopped()
            let mark = rec.events.count
            expect(order.run(holderEntry: "send", optionsFrame(gate, frames),
                             waiterEntry: "streamStarted", { gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: true) }),
                   "send then STARTED: forced order")
            expectEqual(frames.sent, [false], "send then STARTED: frame refused")
            expect(frames.mappedWith.isEmpty, "send then STARTED: frame not mapped")
            expect(deliveriesFrom(rec, mark).isEmpty, "send then STARTED: nothing delivered")
            expectEqual(gate.declaredProfile, .psvr2Sense, "send then STARTED: PSVR2 declared afterwards")
        }
    }

    // Concurrent STARTED with no preceding STOPPED (STOPPED stalled) vs a frame, both lock orders.
    static func concurrentStartedWithoutStoppedVsSend() {
        // STARTED holds the lock, the frame waits: mapped with the new stream's profile, after its declaration.
        do {
            let (rec, order, gate) = racingGate()
            let frames = Frames()
            let old = gate.streamStarted(emulationMode: "Quest2Touch", senseDetected: true)
            let mark = rec.events.count
            expect(order.run(holderEntry: "streamStarted", { gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: true) },
                             waiterEntry: "send", optionsFrame(gate, frames)), "STARTED (no STOPPED) then send: forced order")
            expectEqual(gate.currentStream?.generation, old.generation + 1, "STARTED over an open stream: new generation")
            expectEqual(frames.mappedWith, [.psvr2Sense], "STARTED (no STOPPED) then send: mapped with the new profile")
            let announce = indexOf(rec, "announce psvr2Sense", from: mark) ?? Int.max
            expect(!deliveriesFrom(rec, mark).isEmpty && deliveriesFrom(rec, mark).allSatisfy { $0 > announce },
                   "STARTED (no STOPPED) then send: declaration precedes every delivery")
            expectEqual(deliveredValue(rec, "/user/hand/right/input/system/click"), .binary(false), "STARTED (no STOPPED) then send: Options is not PS")
        }
        // The frame holds the lock, STARTED waits: the whole frame goes out under the old stream, before the new declaration.
        do {
            let (rec, order, gate) = racingGate()
            let frames = Frames()
            gate.streamStarted(emulationMode: "Quest2Touch", senseDetected: true)
            let mark = rec.events.count
            expect(order.run(holderEntry: "send", optionsFrame(gate, frames),
                             waiterEntry: "streamStarted", { gate.streamStarted(emulationMode: "PSVR2Sense", senseDetected: true) }),
                   "send then STARTED (no STOPPED): forced order")
            expectEqual(frames.mappedWith, [.questTouch], "send then STARTED (no STOPPED): mapped with the old stream's profile")
            let announce = indexOf(rec, "announce psvr2Sense", from: mark) ?? -1
            expect(!deliveriesFrom(rec, mark).isEmpty && deliveriesFrom(rec, mark).allSatisfy { $0 < announce },
                   "send then STARTED (no STOPPED): every delivery precedes the new declaration")
            expect(rec.delivered.allSatisfy { ControllerInputProfile.questTouch.buttonSet.contains($0.0) },
                   "send then STARTED (no STOPPED): the old frame stays in the old set")
            expectEqual(gate.declaredProfile, .psvr2Sense, "send then STARTED (no STOPPED): PSVR2 declared afterwards")
        }
    }

    // Review 3 blocker, same mode throughout: PSVR2Sense, the stream starts with no Sense detected, Sense is attached,
    // then the stream reconnects while Options is held, every reconnect step racing a frame in both lock orders.
    // No input is ever mapped with the Quest profile and Options never produces system.
    static func sameModeSenseAttachReconnect() {
        let (rec, order, gate) = racingGate()
        let frames = Frames()
        let frame = optionsFrame(gate, frames)
        let mode = "PSVR2Sense"
        func start() { gate.streamStarted(emulationMode: mode, senseDetected: true) }

        gate.streamStarted(emulationMode: mode, senseDetected: false)
        frame()
        gate.controllersDetected(emulationMode: mode, senseDetected: true)
        frame()
        expect(order.run(holderEntry: "streamStopped", { gate.streamStopped() }, waiterEntry: "send", frame), "attach: STOPPED then send")
        expect(order.run(holderEntry: "streamStarted", start, waiterEntry: "send", frame), "attach: STARTED then send")
        expect(order.run(holderEntry: "send", frame, waiterEntry: "streamStopped", { gate.streamStopped() }), "attach: send then STOPPED")
        expect(order.run(holderEntry: "send", frame, waiterEntry: "streamStarted", start), "attach: send then STARTED")
        expect(order.run(holderEntry: "streamStarted", start, waiterEntry: "send", frame), "attach: STARTED (no STOPPED) then send")
        expect(order.run(holderEntry: "send", frame, waiterEntry: "streamStarted", start), "attach: send then STARTED (no STOPPED)")
        frame()

        expectEqual(frames.sent, [true, true, false, true, true, false, true, true, true], "attach: frames refused only while shut")
        expect(!frames.mappedWith.isEmpty && frames.mappedWith.allSatisfy { $0 == .psvr2Sense }, "attach: no frame ever mapped with Quest")
        expect(rec.events.filter { $0.hasPrefix("announce") }.allSatisfy { $0 == "announce psvr2Sense" }, "attach: only PSVR2 ever declared")
        expect(!rec.delivered.contains { $0.0.hasSuffix("/system/click") && $0.1 == .binary(true) }, "attach: Options never produces system/click")
        expect(!rec.delivered.contains { $0.0.hasSuffix("/system/touch") && $0.1 == .binary(true) }, "attach: Options never produces system/touch")
        expect(rec.delivered.contains { $0.0 == "/user/hand/right/input/menu/click" && $0.1 == .binary(true) }, "attach: Options -> menu")
        expectEqual(rec.logs.filter { $0.contains(noSenseLog) }.count, 1, "attach: the no-Sense start logged once")
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
        reconnectInterleaving()
        frameNeverCrossesProfiles()
        profileFromEmulationMode()
        concurrentStoppedVsSend()
        concurrentStartedVsSend()
        concurrentStartedWithoutStoppedVsSend()
        sameModeSenseAttachReconnect()
        singleChokePoint()
        finishTests("ControllerInputGateTests")
    }
}
