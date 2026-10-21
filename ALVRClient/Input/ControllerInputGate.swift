//
//  ControllerInputGate.swift
//
//  The one choke point for controller and hand button sends.
//
//  The server builds its button mapping per connection from the declared
//  interaction profile (Quest Touch until told otherwise) and drops a
//  declaration sent while disconnected. So for each stream the profile is
//  declared first, under the same lock the sends take, and until then no input
//  goes out. After that only paths in the declared profile's button_set are
//  delivered; anything else would arrive at the server unmapped.
//
//  Pure (Foundation only): the ALVR calls are injected, so tests/swift runs it.
//

import Foundation

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
    private let idByPath: [String: UInt64]
    private let pathById: [UInt64: String]
    private let questIds: Set<UInt64>
    private let psvr2Ids: Set<UInt64>
    private var declared: ControllerInputProfile?
    private var reported: Set<String> = []

    init(pathId: @escaping (String) -> UInt64,
         deliver: @escaping (UInt64, ButtonInputValue) -> Void,
         announce: @escaping (ControllerInputProfile) -> Void,
         log: @escaping (String) -> Void) {
        self.pathId = pathId
        self.deliver = deliver
        self.announce = announce
        self.log = log
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

    /// The profile declared for the current stream, nil while no stream has declared one.
    var declaredProfile: ControllerInputProfile? {
        lock.lock(); defer { lock.unlock() }
        return declared
    }

    /// A stream started: declare its profile, then open the gate.
    func streamStarted(profile: ControllerInputProfile) {
        lock.lock(); defer { lock.unlock() }
        announce(profile)
        declared = profile
    }

    /// Controllers changed: re-declare for the current stream. Before a stream
    /// starts there is nothing to declare to; streamStarted does it.
    func profileChanged(profile: ControllerInputProfile) {
        lock.lock(); defer { lock.unlock() }
        guard declared != nil else { return }
        announce(profile)
        declared = profile
    }

    /// The stream ended: shut the gate until the next stream declares.
    func streamStopped() {
        lock.lock(); defer { lock.unlock() }
        declared = nil
    }

    @discardableResult
    func send(_ id: UInt64, _ value: ButtonInputValue) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sendLocked(id, value)
    }

    func send(_ inputs: [ButtonInput]) {
        lock.lock(); defer { lock.unlock() }
        for input in inputs {
            sendLocked(idByPath[input.path] ?? pathId(input.path), input.value)
        }
    }

    @discardableResult
    private func sendLocked(_ id: UInt64, _ value: ButtonInputValue) -> Bool {
        guard let profile = declared else { return false }
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
