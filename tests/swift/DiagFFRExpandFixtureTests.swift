// SOURCES:
// METAL: tests/swift/DiagFFRExpandKernel.metal
// Shared fixture for tools/golden (review r1 item 2): the client's foveation expansion, decompressAxisAlignedCoord
// (ALVRClient/Shaders.metal:148-189), runs on the Mac GPU for the a100-axis-C point (render 1.1447 x 3648x2912 =
// 4176x3333, foveation 0.5,0.45,3,3,0.536,-0.159) on a 9x9 grid of pixel-centre eye UVs per eye, and writes
// tools/golden/fixtures/ffr-expand-a100-axis-C.tsv. uv_in is the side-by-side texCoord the vertex shader gives that eye
// (Shaders.metal:217-221: x * 0.5, + 0.5 for R); uv_out is the shader's result, the side-by-side UV of the coded frame.
// test_golden_frame.py MetalFixture compares golden-frame.py client_texture_uv with it within 1e-4.
// FFR.swift needs the ALVR core types, so its aligned-value maths (FFR.swift:73-102) is repeated below in Float.
import Foundation
import Metal

struct Aligned { var c: Float; var s: Float; var r: Float; var ratio: Float; var opt: Float; var coded: UInt32 }

// FFR.swift:73-102 for one axis, Float as in the client.
func aligned(target n: Float, centerSize: Float, centerShift: Float, edgeRatio r: Float) -> Aligned {
    let edge = n - centerSize * n
    let c = 1 - ceil(edge / (r * 2)) * (r * 2) / n
    let edgeAligned = n - c * n
    let s = ceil(centerShift * edgeAligned / (r * 2)) * (r * 2) / edgeAligned
    let scale = c + (1 - c) / r
    let opt = scale * n
    let coded = UInt32(ceil(opt / 32) * 32)
    return Aligned(c: c, s: s, r: r, ratio: opt / Float(coded), opt: opt, coded: coded)
}

@main enum DiagFFRExpandFixtureTests {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            expect(false, "metallib path argument (run through tests/swift/run-tests.sh)")
            finishTests("DiagFFRExpandFixture")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            expect(false, "Metal device unavailable; GM must run DiagFFRExpandFixture outside sandbox")
            finishTests("DiagFFRExpandFixture")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let x = aligned(target: 4176, centerSize: 0.5, centerShift: 0.536, edgeRatio: 3)
        let y = aligned(target: 3333, centerSize: 0.45, centerShift: -0.159, edgeRatio: 3)
        // FFR.makeFunctionConstants (FFR.swift:122-140); indices from ShaderTypes.h ALVRFunctionConstant.
        let constants = MTLFunctionConstantValues()
        var enabled = true
        constants.setConstantValue(&enabled, type: .bool, index: 100)
        for (index, value) in [(103, [x.ratio, y.ratio]), (104, [x.c, y.c]), (105, [x.s, y.s]), (106, [x.r, y.r])] {
            var v: [Float32] = value
            constants.setConstantValue(&v, type: .float2, index: index)
        }
        let function = try library.makeFunction(name: "ffrExpandFixtureKernel", constantValues: constants)
        let pipeline = try device.makeComputePipelineState(function: function)

        var inputs: [SIMD2<Float>] = []
        var eyes: [String] = []
        for eye in ["L", "R"] { for j in 0..<9 { for i in 0..<9 {
            let u = (Float(i) + 0.5) / 9, v = (Float(j) + 0.5) / 9
            inputs.append(SIMD2(u * 0.5 + (eye == "R" ? 0.5 : 0), v))
            eyes.append(eye)
        } } }
        let n = inputs.count
        let inBuffer = device.makeBuffer(bytes: inputs, length: n * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
        let outBuffer = device.makeBuffer(length: n * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
        let commands = device.makeCommandQueue()!.makeCommandBuffer()!
        let encoder = commands.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let out = outBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: n)

        // Sanity: every sample lands in its own eye's coded content (L x in [0, ratio / 2], R x in [1 - ratio / 2, 1]).
        for k in 0..<n {
            let o = out[k]
            let inHalf = eyes[k] == "L" ? o.x >= 0 && o.x <= x.ratio * 0.5 + 1e-6 : o.x >= 1 - x.ratio * 0.5 - 1e-6 && o.x <= 1
            expect(inHalf && o.y >= 0 && o.y <= y.ratio + 1e-6, "\(eyes[k]) \(inputs[k]) -> \(o) inside the eye's coded content")
        }
        // FFR.swift by hand: x opt 4176 * (0.5 + 0.5 / 3) = 2784 (no padding); y as golden-frame.py fov_axes.
        expect(x.coded == 2784 && y.coded == 2112, "a100-axis-C coded size 2784x2112 per eye, got \(x.coded)x\(y.coded)")

        var text = "# decompressAxisAlignedCoord (ALVRClient/Shaders.metal:148-189) on the Mac GPU, tests/swift/DiagFFRExpandFixtureTests.swift\n"
        text += "# a100-axis-C: target 4176x3333, foveation 0.5,0.45,3,3,0.536,-0.159 (tools/fov-matrix/points-chart-avp.tsv)\n"
        text += String(format: "# aligned x: c %.9g s %.9g r %.9g opt %.9g coded %u ratio %.9g\n", x.c, x.s, x.r, x.opt, x.coded, x.ratio)
        text += String(format: "# aligned y: c %.9g s %.9g r %.9g opt %.9g coded %u ratio %.9g\n", y.c, y.s, y.r, y.opt, y.coded, y.ratio)
        text += "# device: \(device.name)\n"
        text += "uv_in_x\tuv_in_y\teye\tuv_out_x\tuv_out_y\n"
        for k in 0..<n {
            text += String(format: "%.9g\t%.9g\t%@\t%.9g\t%.9g\n", inputs[k].x, inputs[k].y, eyes[k], out[k].x, out[k].y)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("tools/golden/fixtures")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("ffr-expand-a100-axis-C.tsv")
        try text.write(to: path, atomically: true, encoding: .utf8)
        print("wrote \(path.path) (\(n) points on \(device.name))")
        finishTests("DiagFFRExpandFixture")
    }
}
