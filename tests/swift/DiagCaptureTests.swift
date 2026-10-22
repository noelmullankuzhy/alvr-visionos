// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/DiagFrameCapture.swift ALVRClient/Diagnostics/DiagCapturePose.swift
import Foundation
import Metal
import ImageIO

@main enum DiagCaptureTests {
    static func main() throws {
        let disabled = DiagCaptureRequests(acceptsMarks: false)
        disabled.mark(eye: "L", spoke: 0, pct: 100)
        disabled.setAcceptsMarks(true)
        expect(disabled.take(nowMs: 0, idle: true) == nil, "disabled marks do not queue for later capture")
        disabled.mark(eye: "L", spoke: 0, pct: 100)
        disabled.setAcceptsMarks(false)
        disabled.setAcceptsMarks(true)
        expect(disabled.take(nowMs: 1, idle: true) == nil, "leaving diagnostics drops pending marks")
        let state = DiagCaptureRequests()
        expect(state.take(nowMs: 10, idle: true) == nil, "first idle frame starts timer")
        expect(state.take(nowMs: 3009, idle: true) == nil, "not before three seconds")
        expect(state.take(nowMs: 3010, idle: false) == nil, "no capture while streaming")
        expect(state.take(nowMs: 3010, idle: true) != nil, "once after three seconds")
        expect(state.take(nowMs: 6000, idle: true) == nil, "timer is one-shot")
        state.mark(eye: "R", spoke: 4, pct: 85)
        let mark = state.take(nowMs: 6001, idle: true)
        expectEqual(mark?.eye, "R", "mark state preserved")
        expectEqual(mark?.pct, 85, "mark percent preserved")
        for _ in 0..<30 { state.mark(eye: "L", spoke: 0, pct: 90) }
        var captures = 2
        while state.take(nowMs: 7000, idle: true) != nil { captures += 1 }
        expectEqual(captures, 24, "session cap")
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("capture-roundtrip.png")
        let rgba: [UInt8] = [0, 255, 255, 255, 255, 0, 255, 255, 0, 0, 0, 0, 255, 128, 1, 255]
        try DiagFrameCapture.writePNG(url: url, width: 2, height: 2, rgba: rgba)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        expectEqual(image.width, 2, "PNG width")
        expectEqual(Array((image.dataProvider!.data! as Data).prefix(16)), rgba, "PNG byte round trip without tone conversion")
        let table = DiagFrameCapture.rateTables(map: nil, layer: 0, width: 12, height: 9)
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: table)) as! [String: Any]
        expectEqual((json["physical_x"] as! [Double]).count, 13, "inclusive x table")
        expectEqual((json["physical_y"] as! [Double]).count, 10, "inclusive y table")
        try FileManager.default.removeItem(at: url)
        finishTests("DiagCapture")
    }
}
