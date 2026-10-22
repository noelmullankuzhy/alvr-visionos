//
//  LaunchFlags.swift
//
// Effective value of an option that has both a launch argument and a persisted settings control: the launch argument
// when it is present in the argument domain (`-Key value` on the devicectl command line), else the UI setting.
//

import Foundation

enum LaunchFlags {
    static var currentArguments: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    static func isOverridden(_ key: String, arguments: [String: Any] = currentArguments) -> Bool {
        arguments[key] != nil
    }

    static func bool(_ key: String, setting: Bool, arguments: [String: Any] = currentArguments) -> Bool {
        switch arguments[key] {
        case let value as NSNumber: return value.boolValue
        case let value as String: return (value as NSString).boolValue
        default: return setting
        }
    }

    static func double(_ key: String, setting: Double, arguments: [String: Any] = currentArguments) -> Double {
        switch arguments[key] {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return (value as NSString).doubleValue
        default: return setting
        }
    }
}
