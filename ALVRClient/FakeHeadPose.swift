//
//  FakeHeadPose.swift
//
// Orientation for the fixed head pose sent when there is no device anchor (visionOS simulator fallback,
// bootstrap tracking before the immersive space is up).
//
// The server tags every frame with the target timestamp of the tracking sample whose rotation is closest to
// the frame's pose (server_openvr PoseHistory::GetBestPoseMatch over the last 360 poses, first minimum wins).
// With an identical orientation in every sample all distances tie, so every frame got the timestamp of the
// OLDEST buffered pose (~360 samples old). That timestamp has already left both statistics histories
// (statistics_history_size 256), so the client sends no ClientStatistics and the server emits no
// GraphStatistics/StatisticsSummary and gets no latency feedback for adaptive bitrate.
//
// Fix: a tiny yaw sawtooth (1e-5 rad per sample, period 1024 > 360, max ~0.59 degrees) makes each sample's
// rotation unique inside the server's buffer, so each frame matches its own sample.
//
// Pure logic (simd only) so it is unit tested on macOS: tests/swift/FakeHeadPoseTests.swift.
//
import simd

enum FakeHeadPose {
    static let yawStepRadians: Float = 1e-5
    static let period = 1024

    static func yaw(sequence: UInt64) -> Float {
        return Float(sequence % UInt64(period)) * yawStepRadians
    }

    static func orientation(sequence: UInt64) -> simd_quatf {
        return simd_quatf(angle: yaw(sequence: sequence), axis: simd_float3(0, 1, 0))
    }
}
