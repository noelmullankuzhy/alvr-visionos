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

        // Regression: identical poses all resolve to the oldest buffer entry (what the server saw before).
        let fixed = [simd_float3x3](repeating: matrix_identity_float3x3, count: serverPoseBufferSize)
        expectEqual(bestMatchIndex(fixed, matrix_identity_float3x3), 0, "fixed pose matches the oldest entry")

        finishTests("FakeHeadPose")
    }

    static let serverPoseBufferSize = 120 * 3
}
