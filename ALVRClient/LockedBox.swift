//
//  LockedBox.swift
//
// Values shared between the render, event and decode threads; every read and write takes the lock, so a copy
// (retain) on one thread never meets an assign (release) on another. The locks are leaves: nothing is called under
// them, and replaced values are handed back so they are released after the unlock.
//
import Foundation
import simd

final class LockedBox<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        _ = exchange(newValue)
    }

    // Returns the old value, released by the caller after the unlock.
    @discardableResult
    func exchange(_ newValue: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }

    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// Settings.getAlvrSettings(): filled on a miss, cleared by the event thread on every DecoderConfig. The fill (a parse)
// runs outside the lock; one that spans a clear is returned to its caller but not stored, so stale settings never
// outlive the clear.
final class SettingsCache<Value> {
    private let box = LockedBox<(value: Value?, generation: UInt64)>((nil, 0))

    func get(fill: () -> Value?) -> Value? {
        let start = box.get()
        if let value = start.value {
            return value
        }
        let fresh = fill()
        box.update { cache in
            if cache.generation == start.generation && cache.value == nil {
                cache.value = fresh
            }
        }
        return fresh
    }

    func clear() {
        _ = box.update { cache -> Value? in
            let old = cache.value
            cache = (nil, cache.generation &+ 1)
            return old
        }
    }
}

// EventHandler.lastQueuedFrame/lastQueuedFramePose: render threads set them, stop() clears them on the event thread.
final class LastQueuedFrameSlot<Frame> {
    private let box = LockedBox<(frame: Frame?, pose: simd_float4x4?)>((nil, nil))

    var frame: Frame? {
        get { box.get().frame }
        set {
            _ = box.update { pair -> Frame? in
                let old = pair.frame
                pair.frame = newValue
                return old
            }
        }
    }

    func get() -> (frame: Frame?, pose: simd_float4x4?) {
        box.get()
    }

    func set(_ frame: Frame?, pose: simd_float4x4?) {
        box.set((frame, pose))
    }

    func clear() {
        box.set((nil, nil))
    }
}

// EventHandler's decoder session and its format: stop() tears them down while the decode thread copies them.
final class DecoderSlot<Session: AnyObject, Format: AnyObject> {
    private let box = LockedBox<(session: Session?, format: Format?, codec: Int)>((nil, nil, -1))

    var session: Session? { box.get().session }
    var format: Format? { box.get().format }
    var codec: Int { box.get().codec }

    // Session, format and codec of one decoder, or nil.
    func snapshot() -> (session: Session, format: Format, codec: Int)? {
        let current = box.get()
        guard let session = current.session, let format = current.format else { return nil }
        return (session, format, current.codec)
    }

    // Installs a decoder with its codec (nil, nil, -1 tears down) and returns the old session to finish outside the lock.
    @discardableResult
    func replace(session: Session?, format: Format?, codec: Int) -> Session? {
        box.exchange((session, format, codec)).session
    }

    // A codec for the current session (DecoderConfig with a decoder already up, or a reset to -1).
    func setCodec(_ codec: Int) {
        box.update { $0.codec = codec }
    }
}
