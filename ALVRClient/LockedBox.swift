//
//  LockedBox.swift
//
// One value shared between the render, event and decode threads; every read and write takes the lock, so a copy
// (retain) on one thread never meets an assign (release) on another.
//
import Foundation

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
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
