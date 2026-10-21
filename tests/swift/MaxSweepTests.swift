// SOURCES: ALVRClient/Diagnostics/Diag.swift ALVRClient/Diagnostics/MaxSweep.swift
import Foundation

@main enum MaxSweepTests {
    static func main() {
        expect(RQSchedule.make(diagnostics: false, enabled: true) == nil, "off creates no sweep")
        expect(RQSchedule.make(diagnostics: true, enabled: false) == nil, "opt in only")
        var s = RQSchedule.make(diagnostics: true, enabled: true)!
        expectEqual(s.tick(now: 0, enabled: true, streaming: true, supported: true, previous: 0.9, maximum: 1), .none, "stream blocks start")
        expectEqual(s.tick(now: 1, enabled: true, streaming: false, supported: true, previous: 0.9, maximum: 1), .set(0.5), "first point")
        expect(!s.measuring(now: 3000), "settle excluded")
        expect(s.measuring(now: 3001), "3s settle")
        expectEqual(s.tick(now: 23000, enabled: true, streaming: false, supported: true, previous: 0.5, maximum: 1), .none, "20s measurement")
        expectEqual(s.tick(now: 23001, enabled: true, streaming: false, supported: true, previous: 0.5, maximum: 1), .finish(0.5, next: 0.75), "second point")
        expectEqual(s.tick(now: 46001, enabled: true, streaming: false, supported: true, previous: 0.75, maximum: 1), .finish(0.75, next: 1), "third point")
        expectEqual(s.tick(now: 69001, enabled: true, streaming: false, supported: true, previous: 1, maximum: 1), .finish(1, next: 0.9), "restore exact previous")
        expect(!s.active, "finished grid stops")
        expectEqual(s.tick(now: 99999, enabled: true, streaming: false, supported: true, previous: 0.9, maximum: 1), .none, "one run per opt in")
        s = RQSchedule.make(diagnostics: true, enabled: true)!
        _ = s.tick(now: 0, enabled: true, streaming: false, supported: true, previous: 0.8, maximum: 0.75)
        expectEqual(s.tick(now: 10, enabled: true, streaming: true, supported: true, previous: 0.5, maximum: 0.75), .restore(0.8), "stream cancels and restores")
        expect(!s.active && !s.measuring(now: 30000), "no stream samples")
        s = RQSchedule.make(diagnostics: true, enabled: true)!
        expectEqual(s.tick(now: 0, enabled: true, streaming: false, supported: false, previous: 0, maximum: 1), .unsupported, "old OS")
        expectEqual(s.tick(now: 1, enabled: true, streaming: false, supported: false, previous: 0, maximum: 1), .none, "unsupported once")
        s = RQSchedule.make(diagnostics: true, enabled: true)!
        _ = s.tick(now: 0, enabled: true, streaming: false, supported: true, previous: 0.9, maximum: 0.75)
        expectEqual(s.tick(now: 23000, enabled: true, streaming: false, supported: true, previous: 0.5, maximum: 0.75), .finish(0.5, next: 0.75), "within allocation ceiling")
        expectEqual(s.tick(now: 46000, enabled: true, streaming: false, supported: true, previous: 0.75, maximum: 0.75), .finish(0.75, next: 0.9), "never request above max")
        s = RQSchedule.make(diagnostics: true, enabled: true)!
        _ = s.tick(now: 0, enabled: true, streaming: false, supported: true, previous: 0.7, maximum: 1)
        expectEqual(s.tick(now: 1, enabled: false, streaming: false, supported: true, previous: 0.5, maximum: 1), .restore(0.7), "disable restores during settle")
        expectEqual(Diag.line(topic: "rq", tMs: 0, fields: ["unsupported": 1]), "DIAG rq t_ms=0 unsupported=1", "unsupported line")
        expectEqual(Diag.line(topic: "rq", tMs: 0, fields: RQReport.start(defaultQuality: 0.8, maximum: 1)), "DIAG rq t_ms=0 default=0.800 max=1.000", "start format")
        let fields = RQReport.step(step: 0.5, actual: 0.49, drawable: 0, view: 1, width: 100, height: 90,
                                   screen: "100x90", physical: "80x70", gpu: Array(1...100).map(Double.init), missed: 3, frames: 100, footprint: 64)
        expectEqual(Diag.line(topic: "rq", tMs: 1, fields: fields), "DIAG rq t_ms=1 step=0.500 actual=0.490 drawable=0 view=1 tex_w=100 tex_h=90 rrm_screen=100x90 rrm_physical=80x70 gpu_ms_p50=50.000 gpu_ms_p99=99.000 missed_deadlines=3 frames=100 footprint_mb=64.000", "per view result format")
        var calls: [String] = []
        let lines = CodecAudit.lines(hardware: { calls.append($0); return $0 == "hevc" }, session: { chroma in chroma == "420" ? .status(0) : chroma == "422" ? .status(-12906) : .refused })
        expectEqual(calls, ["hevc", "av1", "h264"], "all VT codec queries")
        expectEqual(lines.map { Diag.line(topic: "codec", tMs: 0, fields: $0) }, [
            "DIAG codec t_ms=0 type=hevc hw=true", "DIAG codec t_ms=0 type=av1 hw=false", "DIAG codec t_ms=0 type=h264 hw=false",
            "DIAG codec t_ms=0 type=hevc chroma=420 bit_depth=10 session=ok",
            "DIAG codec t_ms=0 type=hevc chroma=422 bit_depth=10 session=-12906",
            "DIAG codec t_ms=0 type=hevc chroma=444 bit_depth=10 session=unavailable refused_by_encoder=1"], "fake VT format")
        finishTests("MaxSweep")
    }
}
