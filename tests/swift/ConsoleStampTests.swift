// SOURCES: ALVRClient/ClientLogging.swift
import Foundation

@main
enum ConsoleStampTests {
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    static func main() {
        expectEqual(ClientLogging.consoleStampKey, "ALVRConsoleStamp", "flag key")
        expectEqual(ClientLogging.stampPrefix(wall: 1792766090.277, mono: 12345.678901), "[TS 1792766090.277 12345.678901] ", "prefix format")
        expectEqual(ClientLogging.stampPrefix(wall: 1.0006, mono: 2.0000004), "[TS 1.001 2.000000] ", "prefix rounding")

        let suite = "ConsoleStampTests.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        expectEqual(ClientLogging.consoleStampEnabled(defaults), false, "flag absent")
        defaults.set("NO", forKey: ClientLogging.consoleStampKey)
        expectEqual(ClientLogging.consoleStampEnabled(defaults), false, "flag NO")
        defaults.set("YES", forKey: ClientLogging.consoleStampKey)
        expectEqual(ClientLogging.consoleStampEnabled(defaults), true, "flag YES")
        defaults.removePersistentDomain(forName: suite)

        var calls = 0
        let p: () -> String = { calls += 1; return "<P\(calls)>" }
        var s = ConsoleLineStamper()
        expectEqual(text(s.feed(bytes("hello\n"), prefix: p)), "<P1>hello\n", "single line")
        expectEqual(text(s.feed(bytes("a\nb\n"), prefix: p)), "<P2>a\n<P3>b\n", "two lines in one chunk")
        calls = 0; s = ConsoleLineStamper()
        expectEqual(text(s.feed(bytes("par"), prefix: p)), "<P1>par", "split line, first half")
        expectEqual(text(s.feed(bytes("tial\n"), prefix: p)), "tial\n", "split line, second half unstamped")
        expectEqual(calls, 1, "prefix closure called once for a split line")
        expectEqual(s.feed([], prefix: p), [], "empty chunk")
        expectEqual(calls, 1, "empty chunk takes no prefix")
        expectEqual(text(s.feed(bytes("next\n"), prefix: p)), "<P2>next\n", "chunk right after newline gets a prefix")
        expectEqual(text(s.feed(bytes("x"), prefix: p)), "<P3>x", "trailing partial line")
        expectEqual(text(s.feed(bytes("y\n\n"), prefix: p)), "y\n<P4>\n", "its end, then an empty line")
        // Multibyte sequence split across chunks passes through unchanged.
        s = ConsoleLineStamper(); calls = 0
        let euro = bytes("€")
        let out = s.feed([euro[0], euro[1]], prefix: p) + s.feed([euro[2], 10], prefix: p)
        expectEqual(out, bytes("<P1>€\n"), "split multibyte")

        // Redirect with a recording fake dup2: no real fds are touched.
        func redirect(failing: Int32?) -> (Bool, [[Int32]]) {
            var calls = [[Int32]]()
            let ok = ClientLogging.redirectConsole(to: 50, savedOut: 60, savedErr: 61) { from, to in
                calls.append([from, to])
                return to == failing ? -1 : to
            }
            return (ok, calls)
        }
        let okRun = redirect(failing: nil)
        expectEqual(okRun.0, true, "redirect success")
        expectEqual(okRun.1, [[50, 1], [50, 2]], "redirect success calls")
        let err2 = redirect(failing: 2)
        expectEqual(err2.0, false, "fd 2 failure")
        expectEqual(err2.1, [[50, 1], [50, 2], [60, 1], [61, 2]], "fd 2 failure restores both")
        let err1 = redirect(failing: 1)
        expectEqual(err1.0, false, "fd 1 failure")
        expectEqual(err1.1, [[50, 1], [60, 1], [61, 2]], "fd 1 failure restores both")

        // End to end on a pipe pair we own.
        var inFD: [Int32] = [0, 0], outFD: [Int32] = [0, 0]
        expect(pipe(&inFD) == 0 && pipe(&outFD) == 0, "pipes")
        let readIn = inFD[0], writeIn = inFD[1], readOut = outFD[0], writeOut = outFD[1]
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            ClientLogging.pumpStamped(readFD: readIn, writeFD: writeOut) {
                ClientLogging.stampPrefix(wall: Date().timeIntervalSince1970,
                                          mono: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9)
            }
            close(writeOut); done.signal()
        }
        for l in ["one\n", "two\n", "three\n"] { _ = l.withCString { write(writeIn, $0, strlen($0)) } }
        close(writeIn)
        expect(done.wait(timeout: .now() + 10) == .success, "pump finished at EOF")
        var all = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(readOut, &buf, buf.count); if n <= 0 { break }; all += buf[0..<n] }
        close(readIn); close(readOut)
        let lines = text(all).split(separator: "\n").map(String.init)
        expectEqual(lines.count, 3, "three lines out")
        var last = -1.0
        for (l, want) in zip(lines, ["one", "two", "three"]) {
            expect(l.hasPrefix("[TS ") && l.hasSuffix("] " + want), "stamped line \(l)")
            let f = l.split(separator: " ")
            let mono = f.count > 2 ? Double(f[2].dropLast()) ?? -2 : -2
            expect(mono >= last && mono > 0, "mono non-decreasing in \(l)")
            last = mono
        }
        finishTests("ConsoleStampTests")
    }
}
