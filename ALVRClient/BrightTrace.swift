//
//  BrightTrace.swift
//
// Brightness trace ("brightness waves"): per presented frame and eye, the decoded Y plane and the drawn eye texture
// sampled on the same 16x16 grid of cell centres, both in relative linear light (SDR white = 1.0), with the frame's
// timing, path, colour state, CVPixelBuffer attachments and output format. Off by default (GlobalSettings.brightnessTrace,
// -ALVRBrightTrace YES). Pure Foundation/simd (tests/swift/BrightTraceTests.swift); BrightTraceSession.swift samples
// and writes. Analysis: tools/brighttrace.py.
//
// Transfer exponent: least-squares slope of log(output) on log(input) over the grid, pairing values by rank (both
// sorted), so warp, crop and reprojection between the decoded frame and the eye texture do not matter while the
// transfer curve is monotonic. A flat gain moves the intercept (log_gain), a curve change moves the slope.
//

import Foundation

enum BrightTrace {
    static let defaultsKey = "ALVRBrightTrace"
    static let gridSize = 16
    // Fixed sample points: four grid cells (column, row), so they cost no extra reads.
    static let fixedCells = [(4, 4), (11, 4), (4, 11), (11, 11)]
    // Jump, per eye between consecutive presented frames (repeats included) while the input mean moves by less than
    // jumpInputStableRatio (relative): the exponent moves by more than jumpExponentDelta, or the gain (output mean over
    // input mean) by more than jumpLogGainDelta in natural log (about 10%). Mirrored in tools/brighttrace.py.
    static let jumpExponentDelta = 0.08
    static let jumpLogGainDelta = 0.1
    static let jumpInputStableRatio = 0.03
    static let jumpsPerSecond = 5
    // Linear values at or below this are excluded from the fit (black borders, outside the video quad).
    static let lumaFloor = 1e-4
    // Exponents closer than this belong to one output level.
    static let levelGap = 0.05
    static let maxFileBytes = 50 * 1024 * 1024
    static let summaryIntervalMs = 1000

    static func gridCoordinates(origin: Double, length: Double, count: Int = gridSize) -> [Double] {
        (0..<count).map { origin + (Double($0) + 0.5) * length / Double(count) }
    }

    // Row-major grid points of one eye of a side-by-side plane, in plane pixels.
    static func planePoints(width: Int, height: Int, eye: Int, eyes: Int) -> [(x: Int, y: Int)] {
        let eyeWidth = Double(width) / Double(eyes)
        let xs = gridCoordinates(origin: Double(eye) * eyeWidth, length: eyeWidth).map { Int($0) }
        let ys = gridCoordinates(origin: 0, length: Double(height)).map { Int($0) }
        return ys.flatMap { y in xs.map { (x: $0, y: y) } }
    }

    static func fixed(_ grid: [Double]) -> [Double] {
        fixedCells.map { grid[$0.1 * gridSize + $0.0] }
    }

    // Y' code -> normalised signal in [0, 1].
    static func codeSignal(_ code: Double, bits: Int, fullRange: Bool) -> Double {
        let scale = Double(1 << (bits - 8))
        let (black, white) = fullRange ? (0.0, Double((1 << bits) - 1)) : (16 * scale, 235 * scale)
        return min(max((code - black) / (white - black), 0), 1)
    }

    // Signal -> relative linear light: PQ through ST 2084 over reference white; SDR through gamma 2.2.
    static func inputLinear(signal: Double, pq: Bool, referenceWhiteNits: Double) -> Double {
        pq ? HDRPipeline.pqEOTF(signal) / referenceWhiteNits : pow(signal, 2.2)
    }

    // Linear RGB of the eye texture -> luminance (BT.709 weights).
    static func outputLuma(r: Double, g: Double, b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func exponent(input: [Double], output: [Double]) -> (slope: Double, logGain: Double)? {
        guard input.count == output.count else { return nil }
        let pairs = zip(input.sorted(), output.sorted()).filter { $0.0 > lumaFloor && $0.1 > lumaFloor }
        guard pairs.count >= 2 else { return nil }
        let xs = pairs.map { log($0.0) }, ys = pairs.map { log($0.1) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 1e-12 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        return (slope, my - slope * mx)
    }

    // Cluster centres (means) of 1-D values split at gaps wider than `gap`.
    static func levels(_ values: [Double], gap: Double = levelGap) -> [Double] {
        var clusters: [[Double]] = []
        for v in values.sorted() {
            if let last = clusters.last?.last, v - last <= gap { clusters[clusters.count - 1].append(v) } else { clusters.append([v]) }
        }
        return clusters.map { $0.reduce(0, +) / Double($0.count) }
    }

    // Whether one eye's gain or exponent stepped from `a` to `b` with a stable input.
    static func stepped(_ a: BrightTraceEye, _ b: BrightTraceEye) -> Bool {
        guard let ia = a.inputMean, let ib = b.inputMean, let ga = a.gain, let gb = b.gain,
              abs(ia - ib) / max(ia, ib) < jumpInputStableRatio else { return false }
        if abs(log(gb / ga)) > jumpLogGainDelta { return true }
        guard let ea = a.fit?.slope, let eb = b.fit?.slope else { return false }
        return abs(eb - ea) > jumpExponentDelta
    }

    // 4 significant digits, for the record grids.
    static func rounded(_ v: Double) -> Double {
        guard v != 0, v.isFinite else { return v }
        let m = pow(10, 3 - floor(log10(abs(v))))
        return (v * m).rounded() / m
    }

    static func format(_ v: Double?) -> String {
        v.map { String(format: "%.4g", $0) } ?? "na"
    }

    // The eye of each drawable view (view order: left, right) and where it is read back: its colour texture and slice,
    // and the rate map and layer mapping its screen coordinates. Layered: one texture, a slice and rate map layer per eye.
    // Dedicated: a texture and a rate map per eye. Shared: one slice, a rate map layer per view.
    static func targets(views: [(texture: Int, slice: Int)], rateMaps: Int) -> [BrightTraceTarget] {
        views.enumerated().map { i, v in
            let layer = views.prefix(i).filter { $0.texture == v.texture }.count
            return BrightTraceTarget(eye: i < 2 ? ["L", "R"][i] : "\(i)", texture: v.texture, slice: v.slice,
                                     rateMap: rateMaps == 0 ? nil : min(v.texture, rateMaps - 1), layer: layer)
        }
    }

    // Recorded fields that make up the colour state (generation) and the CVPixelBuffer attachments.
    static let colourKeys: Set = ["path", "pipeline", "binding", "hdr_pq", "headroom", "transfer", "matrix", "range", "encoding_gamma", "gamut_hash"]
    static let attachmentKeys: Set = ["cv_fourcc", "cv_transfer", "cv_matrix", "cv_primaries", "cv_mastering", "cv_cll"]
}

struct BrightTraceTarget: Equatable {
    let eye: String
    let texture: Int
    let slice: Int
    let rateMap: Int?
    let layer: Int
}

struct BrightTraceEye {
    let eye: String
    let input: [Double]?    // 16x16 row-major, relative linear
    let output: [Double]?
    let inputMean: Double?
    let outputMean: Double?
    let fit: (slope: Double, logGain: Double)?

    init(eye: String, input: [Double]?, output: [Double]?) {
        self.eye = eye
        self.input = input
        self.output = output
        func mean(_ v: [Double]?) -> Double? { v.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) } }
        inputMean = mean(input)
        outputMean = mean(output)
        fit = input.flatMap { i in output.flatMap { BrightTrace.exponent(input: i, output: $0) } }
    }

    // Output mean over input mean; nil when either is at or below the floor.
    var gain: Double? {
        guard let i = inputMean, let o = outputMean, i > BrightTrace.lumaFloor, o > BrightTrace.lumaFloor else { return nil }
        return o / i
    }

    func json() -> [String: Any?] {
        ["eye": eye, "in": input?.map(BrightTrace.rounded), "out": output?.map(BrightTrace.rounded),
         "in_fixed": input.map(BrightTrace.fixed), "out_fixed": output.map(BrightTrace.fixed),
         "in_mean": inputMean, "out_mean": outputMean, "exp": fit?.slope, "log_gain": fit?.logGain]
    }
}

struct BrightTraceRecord {
    var seq: Int
    var tMs: Int              // wall-clock Unix ms at render
    var renderStartS: Double  // host time (CACurrentMediaTime) at render start
    var presentS: Double      // predicted present time
    var timestampNs: UInt64   // video frame timestamp
    var fields: [String: String]
    var overlayAlpha: Double
    var eyes: [BrightTraceEye]
    var isNew = true
    var generation = 0
    var changed: [String] = []
    var attachmentsChanged = false

    func json() -> [String: Any?] {
        ["seq": seq, "t_ms": tMs, "render_start_s": renderStartS, "present_s": presentS, "ts_ns": timestampNs, "new": isNew,
         "gen": generation, "changed": changed, "attach_changed": attachmentsChanged, "fields": fields,
         "overlay_alpha": overlayAlpha, "eyes": eyes.map { $0.json() }]
    }

    func line() -> String { BrightTraceJSON.encode(json()) }
}

// Newness, generation and changed fields against the previous traced frame. Trace queue only.
struct BrightTraceState {
    private var previous: (timestampNs: UInt64, fields: [String: String])?
    private var generation = 0

    mutating func annotate(_ record: inout BrightTraceRecord) {
        if let previous {
            record.isNew = previous.timestampNs != record.timestampNs
            let keys = Set(previous.fields.keys).union(record.fields.keys)
            record.changed = keys.filter { previous.fields[$0] != record.fields[$0] }.sorted()
            if record.changed.contains(where: BrightTrace.colourKeys.contains) { generation += 1 }
            record.attachmentsChanged = record.changed.contains(where: BrightTrace.attachmentKeys.contains)
        }
        record.generation = generation
        previous = (record.timestampNs, record.fields)
    }
}

// Gain or exponent step per eye (matched by name) between consecutive presented frames, repeats included
// (BrightTrace.stepped); at most jumpsPerSecond reported.
struct BrightTraceJumpDetector {
    struct Jump {
        let before: BrightTraceRecord
        let after: BrightTraceRecord
        let eyes: [String]   // the eyes that stepped

        // Compact for log forwarding: the changed fields and, per eye, the means, gain and exponent before>after.
        func line(tMs: Int) -> String {
            let f = BrightTrace.format
            let perEye = after.eyes.map { b -> String in
                let a = before.eyes.first { $0.eye == b.eye }
                return "\(b.eye)=in:\(f(a?.inputMean))>\(f(b.inputMean)),out:\(f(a?.outputMean))>\(f(b.outputMean))"
                    + ",gain:\(f(a?.gain))>\(f(b.gain)),exp:\(f(a?.fit?.slope))>\(f(b.fit?.slope))"
            }
            return "BRIGHTTRACE JUMP t_ms=\(tMs) seq=\(before.seq)>\(after.seq) ts_ns=\(before.timestampNs)>\(after.timestampNs)"
                + " eyes=\(eyes.joined(separator: ",")) changed=\(after.changed.isEmpty ? "none" : after.changed.joined(separator: ","))"
                + " " + perEye.joined(separator: " ")
        }
    }
    private var previous: BrightTraceRecord?
    private var emittedMs: [Int] = []
    private(set) var suppressed = 0

    mutating func check(_ record: BrightTraceRecord, nowMs: Int) -> Jump? {
        defer { previous = record }
        guard let before = previous else { return nil }
        let eyes = record.eyes.filter { b in before.eyes.first { $0.eye == b.eye }.map { BrightTrace.stepped($0, b) } ?? false }.map(\.eye)
        guard !eyes.isEmpty else { return nil }
        emittedMs.removeAll { nowMs - $0 >= 1000 || nowMs < $0 }
        guard emittedMs.count < BrightTrace.jumpsPerSecond else { suppressed += 1; return nil }
        emittedMs.append(nowMs)
        return Jump(before: before, after: record, eyes: eyes)
    }
}

// The 1 Hz BRIGHTTRACE line. Trace queue only.
struct BrightTraceSummary {
    private var startMs: Int?
    private var frames = 0, new = 0, generations = 0, attachments = 0, jumps = 0
    private var inputs: [Double] = [], outputs: [Double] = [], exponents: [Double] = []
    // Per eye: exponents, log gains (fit intercepts) and jumps.
    private var eyeExponents: [String: [Double]] = [:], eyeLogGains: [String: [Double]] = [:], eyeJumps: [String: Int] = [:]
    private var variants = Set<String>()

    mutating func add(_ r: BrightTraceRecord) {
        frames += 1
        if r.isNew { new += 1 }
        if r.changed.contains(where: BrightTrace.colourKeys.contains) { generations += 1 }
        if r.attachmentsChanged { attachments += 1 }
        variants.insert("\(r.fields["pipeline"] ?? "na")/\(r.fields["binding"] ?? "na")")
        for eye in r.eyes {
            if let v = eye.inputMean { inputs.append(v) }
            if let v = eye.outputMean { outputs.append(v) }
            if let v = eye.fit?.slope { exponents.append(v); eyeExponents[eye.eye, default: []].append(v) }
            if let v = eye.fit?.logGain { eyeLogGains[eye.eye, default: []].append(v) }
            if eyeJumps[eye.eye] == nil { eyeJumps[eye.eye] = 0 }
        }
    }

    mutating func addJump(eyes: [String]) {
        jumps += 1
        for eye in eyes { eyeJumps[eye, default: 0] += 1 }
    }

    mutating func take(nowMs: Int, tMs: Int) -> String? {
        guard let start = startMs else { startMs = nowMs; return nil }
        guard nowMs - start >= BrightTrace.summaryIntervalMs || nowMs < start else { return nil }
        let f = BrightTrace.format
        // Output levels of an eye: exponent clusters or gain clusters, whichever is more.
        let eyes = eyeJumps.keys.sorted()
        let levels = eyes.map { max(BrightTrace.levels(eyeExponents[$0] ?? []).count, BrightTrace.levels(eyeLogGains[$0] ?? []).count) }
        let line = "BRIGHTTRACE t_ms=\(tMs) frames=\(frames) new=\(new) repeat=\(frames - new)"
            + " in_min=\(f(inputs.min())) in_max=\(f(inputs.max())) out_min=\(f(outputs.min())) out_max=\(f(outputs.max()))"
            + " exp_min=\(f(exponents.min())) exp_max=\(f(exponents.max())) levels=\(levels.max() ?? 0)"
            + zip(eyes, levels).map { " levels_\($0)=\($1)" }.joined()
            + " gen_changes=\(generations) variants=\(variants.sorted().joined(separator: ",")) attach_changes=\(attachments) jumps=\(jumps)"
            + eyes.map { " jumps_\($0)=\(eyeJumps[$0] ?? 0)" }.joined()
        self = BrightTraceSummary()
        startMs = nowMs
        return line
    }
}

// Output grid of one eye in its texture slice: the screen-space cell centres of the viewport mapped through the
// rasterization rate map (separable: physical x depends on screen x only, y on y), one blit per grid row from xMin
// over span pixels. luma decodes that readback (rows rowBytes apart) in row-major grid order.
struct BrightTraceRows {
    enum Format { case half, rgba8, bgra8, rgba8srgb, bgra8srgb }
    let rows: [Int], cols: [Int], xMin: Int, span: Int

    init(x: Double, y: Double, width: Double, height: Double, textureWidth: Int, textureHeight: Int,
         physical: (Double, Double) -> (x: Double, y: Double)) {
        let cx = x + width / 2, cy = y + height / 2
        cols = BrightTrace.gridCoordinates(origin: x, length: width).map { min(max(Int(physical($0, cy).x), 0), textureWidth - 1) }
        rows = BrightTrace.gridCoordinates(origin: y, length: height).map { min(max(Int(physical(cx, $0).y), 0), textureHeight - 1) }
        xMin = cols.min() ?? 0
        span = (cols.max() ?? 0) - xMin + 1
    }

    func luma(_ base: UnsafeRawPointer, rowBytes: Int, format: Format) -> [Double] {
        rows.indices.flatMap { r in
            cols.map { c -> Double in
                let p = base.advanced(by: r * rowBytes + (c - xMin) * (format == .half ? 8 : 4))
                if format == .half {
                    let h = p.assumingMemoryBound(to: UInt16.self)
                    return BrightTrace.outputLuma(r: Double(Float16(bitPattern: h[0])), g: Double(Float16(bitPattern: h[1])), b: Double(Float16(bitPattern: h[2])))
                }
                let b = p.assumingMemoryBound(to: UInt8.self)
                let swap = format == .bgra8 || format == .bgra8srgb
                let srgb = format == .rgba8srgb || format == .bgra8srgb
                let rgb = [b[swap ? 2 : 0], b[1], b[swap ? 0 : 2]].map { srgb ? BrightTrace.srgbToLinear(Double($0) / 255) : Double($0) / 255 }
                return BrightTrace.outputLuma(r: rgb[0], g: rgb[1], b: rgb[2])
            }
        }
    }
}

// Compact JSON with sorted keys and shortest round-trip numbers (JSONSerialization prints 0.7 as 0.69999999999999996).
enum BrightTraceJSON {
    static func encode(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case let v as Bool: return v ? "true" : "false"
        case let v as Int: return String(v)
        case let v as UInt64: return String(v)
        case let v as Double: return v.isFinite ? "\(v)" : "null"
        case let v as Float: return encode(Double(v))
        case let v as String: return string(v)
        case let v as [Any?]: return "[" + v.map(encode).joined(separator: ",") + "]"
        case let v as [String: Any?]: return "{" + v.keys.sorted().map { string($0) + ":" + encode(v[$0] ?? nil) }.joined(separator: ",") + "}"
        case let v as [String: String]: return encode(v.mapValues { $0 as Any? })
        case let v as [String]: return encode(v.map { $0 as Any? })
        case let v as [Double]: return encode(v.map { $0 as Any? })
        case let v as [Any]: return encode(v.map { $0 as Any? })
        default: return string(String(describing: value!))
        }
    }

    private static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
