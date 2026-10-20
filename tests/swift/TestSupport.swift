import Foundation

// Minimal assertion support for tests/swift (no XCTest on this path).
var testChecks = 0
var testFailures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    testChecks += 1
    if !condition() {
        testFailures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    expect(actual == expected, "\(message) expected \(expected), got \(actual)", file: file, line: line)
}

func finishTests(_ name: String) -> Never {
    print("\(name): \(testChecks) checks, \(testFailures) failures")
    exit(testFailures == 0 ? 0 : 1)
}
