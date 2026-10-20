// SOURCES:
// Proves the harness itself compiles, runs and reports.
@main
enum HarnessTests {
    static func main() {
        expect(true, "harness runs")
        expectEqual(1 + 1, 2, "arithmetic")
        finishTests("HarnessTests")
    }
}
