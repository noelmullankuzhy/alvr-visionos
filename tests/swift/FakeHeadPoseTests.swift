// SOURCES: ALVRClient/FakeHeadPose.swift
// FakeHeadPose: the fixed head pose sent without device anchors (visionOS simulator, bootstrap) must still be
// unique per tracking sample, because the server tags each frame with the timestamp of the pose whose rotation
// matrix is closest to the frame's pose (PoseHistory::GetBestPoseMatch, 360-pose buffer, first minimum wins).
import simd

@main
enum FakeHeadPoseTests {
    // Server PoseHistory::GetBestPoseMatch: squared distance over the 3x3 rotation, first strict minimum wins.
    static func bestMatchIndex(_ buffer: [simd_float3x3], _ pose: simd_float3x3) -> Int {
        var minDiff: Float = 100000
        var minIndex = 0
        for (index, rotation) in buffer.enumerated() {
            var distance: Float = 0
            for i in 0..<3 {
                for j in 0..<3 {
                    let d = rotation[i][j] - pose[i][j]
                    distance += d * d
                }
            }
            if minDiff > distance {
                minIndex = index
                minDiff = distance
            }
        }
        return minIndex
    }

    static func rotation(_ sequence: UInt64) -> simd_float3x3 {
        return simd_float3x3(FakeHeadPose.orientation(sequence: sequence))
    }

    static func main() {
        // Sequence 0 is the plain fixed pose (identity orientation).
        expectEqual(FakeHeadPose.yaw(sequence: 0), 0, "sequence 0 has no yaw")
        expect(simd_length(FakeHeadPose.orientation(sequence: 0).vector - simd_float4(0, 0, 0, 1)) < 1e-7, "sequence 0 is identity")

        // The dither stays well under a degree.
        var maxYaw: Float = 0
        for s in 0..<UInt64(FakeHeadPose.period * 2) {
            maxYaw = max(maxYaw, abs(FakeHeadPose.yaw(sequence: s)))
        }
        expect(maxYaw < 0.6 * Float.pi / 180, "yaw dither under 0.6 degrees, got \(maxYaw)")

        // The period is longer than the server's pose buffer (120 * 3 poses), so no repeats inside it.
        expect(FakeHeadPose.period > serverPoseBufferSize, "period exceeds the server pose buffer")

        // Every pose in a full server buffer matches itself, including across the sawtooth wrap.
        // The old fixed pose (all identical) matched the OLDEST entry for every frame.
        for start in [UInt64(0), UInt64(FakeHeadPose.period - 100), UInt64(5 * FakeHeadPose.period + 17)] {
            let sequences = (0..<UInt64(serverPoseBufferSize)).map { start + $0 }
            let buffer = sequences.map { rotation($0) }
            var mismatches = 0
            for (index, s) in sequences.enumerated() {
                if bestMatchIndex(buffer, rotation(s)) != index {
                    mismatches += 1
                }
            }
            expectEqual(mismatches, 0, "every buffered pose matches its own sample (start \(start))")
        }

        // Real tracking path (simulator): a static, non-identity head orientation gets the same head-local yaw,
        // so samples are unique there too.
        let staticHead = simd_quatf(angle: 0.7, axis: simd_normalize(simd_float3(0.2, 1, -0.3)))
        expect(simd_length(FakeHeadPose.dithered(staticHead, sequence: 0).vector - staticHead.vector) < 1e-7, "sequence 0 leaves the orientation unchanged")
        expect(simd_length(FakeHeadPose.dithered(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), sequence: 77).vector - FakeHeadPose.orientation(sequence: 77).vector) < 1e-7, "identity head -> fake orientation")
        let staticBuffer = (0..<UInt64(serverPoseBufferSize)).map { simd_float3x3(FakeHeadPose.dithered(staticHead, sequence: 900 + $0)) }
        var staticMismatches = 0
        for (index, rotation) in staticBuffer.enumerated() where bestMatchIndex(staticBuffer, rotation) != index {
            staticMismatches += 1
        }
        expectEqual(staticMismatches, 0, "static real head: every buffered pose matches its own sample")
        let angle = 2 * acos(min(1, abs(simd_dot(FakeHeadPose.dithered(staticHead, sequence: 1023).vector, staticHead.vector))))
        expect(angle < 0.6 * Float.pi / 180, "real-path dither under 0.6 degrees, got \(angle)")

        // Regression: identical poses all resolve to the oldest buffer entry (what the server saw before).
        let fixed = [simd_float3x3](repeating: matrix_identity_float3x3, count: serverPoseBufferSize)
        expectEqual(bestMatchIndex(fixed, matrix_identity_float3x3), 0, "fixed pose matches the oldest entry")

        finishTests("FakeHeadPose")
    }

    static let serverPoseBufferSize = 120 * 3
}
