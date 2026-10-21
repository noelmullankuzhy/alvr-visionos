//
//  ControllerInputGate.swift
//
//  The one choke point for controller and hand button sends.
//
//  The server builds its button mapping per connection from the declared
//  interaction profile and drops a declaration sent while disconnected. So each
//  stream's profile is chosen once at STREAMING_STARTED from the emulation mode
//  alone (PSVR2Sense -> PSVR2, any other mode -> Quest Touch; GM 61d), declared,
//  and only then is the gate opened, all under one lock. Sense controller
//  detection never selects the profile: PSVR2Sense without Sense controllers is
//  logged once per stream. The profile never changes during the stream. Each
//  stream has a generation number; STOPPED/disconnect closes it and nothing
//  goes out until the next STARTED.
//
//  A frame's input path takes the lock once: it reads the stream's profile, maps
//  the raw controller state with it (send(mapping:)), filters to that profile's
//  button_set and delivers, all in one critical section. A frame mapped under
//  one profile therefore can never be delivered under another.
//
//  Accepted residual (GM decisions 61c and 61d, not fixed here): the Rust core
//  installs the next connection's sender before this gate sees STOPPED/STARTED,
//  so for the milliseconds until those events are processed the previous
//  stream's profile can still map inputs onto the new connection. Both the
//  client profile and the server's default source set are the same pure
//  function of the emulation mode (61a, 61d), so for an unchanged mode the two
//  streams' profiles are identical and nothing crosses: attaching or detaching
//  Sense controllers between reconnects cannot change the profile. Only a mode
//  change across the reconnect can leak stale-profile inputs, and a mode change
//  restarts SteamVR: those inputs are inert. A Rust-core generation token is
//  not worth the core change.
//
//  Pure (Foundation only): the ALVR calls are injected, so tests/swift runs it.
//

import Foundation

/// One stream's immutable input declaration.
struct ControllerInputStream: Equatable {
    let profile: ControllerInputProfile
    let generation: UInt64
}

final class ControllerInputGate {
    /// Every controller input path ALVR knows (alvr/common/src/inputs.rs controller_inputs), for log names.
    static let knownPaths: [String] = ["left", "right"].flatMap { side in
        ["system/click", "system/touch", "menu/click", "menu/touch", "back/click",
         "a/click", "a/touch", "b/click", "b/touch", "x/click", "x/touch", "y/click", "y/touch",
         "squeeze/click", "squeeze/touch", "squeeze/value", "squeeze/force",
         "trigger/click", "trigger/value", "trigger/touch",
         "thumbstick/x", "thumbstick/y", "thumbstick/click", "thumbstick/touch",
         "trackpad/x", "trackpad/y", "trackpad/click", "trackpad/force", "trackpad/touch",
         "thumbrest/touch"].map { "/user/hand/\(side)/input/\($0)" }
    }

    private let lock = NSLock()
    private let pathId: (String) -> UInt64
    private let deliver: (UInt64, ButtonInputValue) -> Void
    private let announce: (ControllerInputProfile) -> Void
    private let log: (String) -> Void
    /// Test seam: called on the caller's thread with the entry point's name just before it takes the lock.
    private let beforeLock: ((String) -> Void)?
    /// Test seam: called with the entry point's name just after it takes the lock.
    private let inLock: ((String) -> Void)?
    private let idByPath: [String: UInt64]
    private let pathById: [UInt64: String]
    private let questIds: Set<UInt64>
    private let psvr2Ids: Set<UInt64>
    private var stream: ControllerInputStream?
    private var lastGeneration: UInt64 = 0
    private var changeLoggedGeneration: UInt64 = 0
    private var noSenseLoggedGeneration: UInt64 = 0
    private var reported: Set<String> = []

    init(pathId: @escaping (String) -> UInt64,
         deliver: @escaping (UInt64, ButtonInputValue) -> Void,
         announce: @escaping (ControllerInputProfile) -> Void,
         log: @escaping (String) -> Void,
         beforeLock: ((String) -> Void)? = nil,
         inLock: ((String) -> Void)? = nil) {
        self.pathId = pathId
        self.deliver = deliver
        self.announce = announce
        self.log = log
        self.beforeLock = beforeLock
        self.inLock = inLock
        var idByPath: [String: UInt64] = [:]
        var pathById: [UInt64: String] = [:]
        for path in ControllerInputGate.knownPaths {
            let id = pathId(path)
            idByPath[path] = id
            pathById[id] = path
        }
        self.idByPath = idByPath
        self.pathById = pathById
        questIds = Set(ControllerInputProfile.questTouch.buttonSet.map(pathId))
        psvr2Ids = Set(ControllerInputProfile.psvr2Sense.buttonSet.map(pathId))
    }

    private func locked<T>(_ entry: String, _ body: () -> T) -> T {
        beforeLock?(entry)
        lock.lock(); defer { lock.unlock() }
        inLock?(entry)
        return body()
    }

    /// The current stream's profile and generation, nil while no stream is open.
    var currentStream: ControllerInputStream? {
        locked("currentStream") { stream }
    }

    /// The profile declared for the current stream, nil while no stream is open.
    var declaredProfile: ControllerInputProfile? {
        currentStream?.profile
    }

    /// STREAMING_STARTED: open a new generation with this profile, declared before the gate opens.
    /// A STARTED over a still-open stream (its STOPPED not seen) replaces it the same way.
    @discardableResult
    func streamStarted(profile: ControllerInputProfile) -> ControllerInputStream {
        locked("streamStarted") { openLocked(profile) }
    }

    /// STREAMING_STARTED from the app: the profile comes from the emulation mode alone (GM 61d);
    /// Sense detection is only logged.
    @discardableResult
    func streamStarted(emulationMode: String, senseDetected: Bool) -> ControllerInputStream {
        locked("streamStarted") {
            let opened = openLocked(ControllerInputProfile.active(emulationMode: emulationMode))
            noteSenseLocked(emulationMode: emulationMode, senseDetected: senseDetected)
            return opened
        }
    }

    /// Controllers changed. The stream's profile is immutable: a mismatch is logged once per stream
    /// and takes effect at the next STREAMING_STARTED.
    func controllersChanged(profile: ControllerInputProfile) {
        locked("controllersChanged") { changedLocked(profile) }
    }

    /// Controllers were (re)detected mid-stream. Detection never selects the profile; under PSVR2Sense
    /// a missing Sense controller is logged once per stream.
    func controllersDetected(emulationMode: String, senseDetected: Bool) {
        locked("controllersChanged") {
            changedLocked(ControllerInputProfile.active(emulationMode: emulationMode))
            noteSenseLocked(emulationMode: emulationMode, senseDetected: senseDetected)
        }
    }

    private func openLocked(_ profile: ControllerInputProfile) -> ControllerInputStream {
        stream = nil
        announce(profile)
        lastGeneration += 1
        let opened = ControllerInputStream(profile: profile, generation: lastGeneration)
        stream = opened
        return opened
    }

    private func changedLocked(_ profile: ControllerInputProfile) {
        guard let current = stream, current.profile != profile,
              changeLoggedGeneration != current.generation else { return }
        changeLoggedGeneration = current.generation
        log("Controllers changed mid-stream (now \(profile)); stream \(current.generation) keeps \(current.profile) until the next stream")
    }

    private func noteSenseLocked(emulationMode: String, senseDetected: Bool) {
        guard let current = stream, emulationMode == "PSVR2Sense", !senseDetected,
              noSenseLoggedGeneration != current.generation else { return }
        noSenseLoggedGeneration = current.generation
        log("PSVR2Sense mode without Sense controllers detected; stream \(current.generation) keeps \(current.profile)")
    }

    /// STREAMING_STOPPED or disconnect: close the generation; nothing goes out until the next stream.
    func streamStopped() {
        locked("streamStopped") { stream = nil }
    }

    /// One frame: map the raw controller state with the open stream's profile and deliver it,
    /// in one critical section. Returns false (map not called) while no stream is open.
    @discardableResult
    func send(mapping: (ControllerInputProfile) -> [ButtonInput]) -> Bool {
        locked("send") {
            guard let current = stream else { return false }
            for input in mapping(current.profile) {
                sendLocked(current.profile, idByPath[input.path] ?? pathId(input.path), input.value)
            }
            return true
        }
    }

    /// Inputs whose paths do not depend on the profile; filtered by the open stream's button_set.
    func send(_ inputs: [ButtonInput]) {
        send(mapping: { _ in inputs })
    }

    @discardableResult
    func send(_ id: UInt64, _ value: ButtonInputValue) -> Bool {
        locked("send") {
            guard let current = stream else { return false }
            return sendLocked(current.profile, id, value)
        }
    }

    @discardableResult
    private func sendLocked(_ profile: ControllerInputProfile, _ id: UInt64, _ value: ButtonInputValue) -> Bool {
        guard (profile == .psvr2Sense ? psvr2Ids : questIds).contains(id) else {
            let name = pathById[id] ?? String(format: "path id 0x%016llx", id)
            if reported.insert("\(profile):\(name)").inserted {
                log("Controller input not in the \(profile) button set, not sent: \(name)")
            }
            return false
        }
        deliver(id, value)
        return true
    }
}
