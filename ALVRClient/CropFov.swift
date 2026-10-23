import Foundation
import simd

/// "Crop FOV to outline" (Diagnostics setting, on by default; the user can turn it off): the client reports, per eye, the model lens's inset
/// rectangle (BoundaryDotsLensModel.insetRect at the Boundary dots lens inset: each device frustum edge moved in by the
/// inset) widened by a margin and clamped to the device frustum, instead of the whole device frustum. The server renders
/// that box at the configured render size, so the centre density rises by the tangent-span ratio; the display draws the
/// frame on the sent box (Renderer uniforms.tangents) and the rest of the drawable stays black. docs/lumen/crop-fov.md.
/// Tangents are gimmeTangents magnitudes, slots (left, right, bottom, top).
enum CropFov {
    static let defaultMarginDeg = 2.5
    /// GlobalSettings.cropFovToOutline default: on, so the lens style streams the cropped box; off sends the device frustum.
    static let defaultEnabled = true
    /// No sent edge reaches 90 deg (tan blows up) or goes below the eye axis.
    static let maxEdgeDeg = 89.0

    /// One eye's sent tangents: the inset rectangle of `device`, each side widened by `marginDeg` (in degrees; negative
    /// or non-finite is 0), then no wider than `device` on any side, every side within 0...tan(maxEdgeDeg). Nil for Both.
    static func tangents(eye: BoundaryDotsEye, device: simd_float4, insetDeg: Double, marginDeg: Double) -> simd_float4? {
        let frustum = BoundaryDotsFrustum(left: Double(device.x), right: Double(device.y), bottom: Double(device.z), top: Double(device.w))
        guard let box = BoundaryDotsLensModel.insetRect(eye, frustum: frustum, insetDeg: insetDeg)?.box(eye) else { return nil }
        let margin = marginDeg.isFinite ? max(0, marginDeg) : 0
        func widened(_ t: Double, _ limit: Float) -> Float {
            // The angle is held below maxEdgeDeg before the tan, which turns negative past 90 deg; a negative device side sends 0.
            let angle = min(atan(t) * 180 / .pi + margin, maxEdgeDeg)
            return max(0, min(Float(tan(angle * .pi / 180)), limit))
        }
        return simd_float4(widened(box.left, device.x), widened(box.right, device.y),
                           widened(box.down, device.z), widened(box.up, device.w))
    }

    /// The Vision Pro's logical grid at render quality 1.0 (rate map screen size, 22 Oct device log) and its per-eye device
    /// frustum (left, right, bottom, top |tan|): 6261x5023 over 2.7321 x 2.1918 tangent units is 2291.7 px per unit. The
    /// grid until the layer has been measured (`recordGrid`) and the test fixture.
    static let referenceScreen = (width: 6261, height: 5023)
    static let referenceDevice = [simd_float4(1.7321, 1.0, 1.1918, 1.0), simd_float4(1.0, 1.7321, 1.1918, 1.0)]

    /// Pixels per tangent unit of the logical grid, per axis: the grid's width and height over the device frustum's
    /// tangent width (left + right) and height (bottom + top). Zero on a degenerate frustum.
    static func gridDensity(screenWidth: Int, screenHeight: Int, device: simd_float4) -> SIMD2<Double> {
        let w = Double(device.x) + Double(device.y), h = Double(device.z) + Double(device.w)
        guard w > 0, h > 0 else { return [0, 0] }
        return [Double(screenWidth) / w, Double(screenHeight) / h]
    }

    /// Up to the next multiple of 32 (a value already on one stays).
    static func roundUp32(_ value: Double) -> Int {
        Int((value / 32 - 1e-9).rounded(.up)) * 32
    }

    /// The render size at which one render pixel is one logical grid pixel on the sent frame: its tangent spans times the
    /// grid density, each side rounded up to a multiple of 32. docs/lumen/crop-fov.md.
    static func oneToOne(density: SIMD2<Double>, sent: simd_float4) -> (width: Int, height: Int) {
        (roundUp32(density.x * (Double(sent.x) + Double(sent.y))), roundUp32(density.y * (Double(sent.z) + Double(sent.w))))
    }

    /// The per-eye view size the client recommends at connect (AlvrClientCapabilities.default_view_width/height): with
    /// crop on, the larger 1:1 size of the two sent eyes per side; with crop off, `fallback` (the unchanged default).
    static func recommendedViewResolution(crop: Bool, device: [simd_float4], density: SIMD2<Double>, insetDeg: Double,
                                          marginDeg: Double, fallback: (width: Int, height: Int)) -> (width: Int, height: Int) {
        guard crop else { return fallback }
        let sent = choose(device: device, debug: nil, crop: true, insetDeg: insetDeg, marginDeg: marginDeg).tangents
        let sizes = sent.map { oneToOne(density: density, sent: $0) }
        let width = sizes.map(\.width).max() ?? 0, height = sizes.map(\.height).max() ?? 0
        return width > 0 && height > 0 ? (width, height) : fallback
    }

    /// ALVR center_shift_x/y that puts the 1:1 band's centre on the eye axis (tan 0) of the sent boxes. The band spans
    /// eye UV [c0 (1 + s), 1 - c0 (1 - s)], c0 = (1 - c) / 2, so its centre is 0.5 + s c0 (Shaders.metal:152-157;
    /// FFR.swift:88-89 only rounds s to 2r px). Eye UV x runs from the temporal edge (R mirrored, Shaders.metal:136-140)
    /// and y from the top row, so the axis sits at temporal / (temporal + nasal) and up / (up + down), and
    /// s = (that fraction - 0.5) / c0. ALVR has one shift for both eyes: the mean of the two (equal for mirrored eyes).
    static func centerShift(left: simd_float4, right: simd_float4, centerSize: SIMD2<Double>) -> SIMD2<Double> {
        func shift(_ lo: Float, _ hi: Float, _ c: Double) -> Double {
            let c0 = (1 - c) / 2
            guard c0 > 0, lo + hi > 0 else { return 0 }
            return (Double(lo / (lo + hi)) - 0.5) / c0
        }
        let x = (shift(left.x, left.y, centerSize.x) + shift(right.y, right.x, centerSize.x)) / 2
        let y = (shift(left.w, left.z, centerSize.y) + shift(right.w, right.z, centerSize.y)) / 2
        return [x, y]
    }

    /// The per-eye tangents to report and their source: -ALVRDebugEyeTangents first, then the crop, then the device.
    static func choose(device: [simd_float4], debug: [simd_float4]?, crop: Bool, insetDeg: Double,
                       marginDeg: Double) -> (tangents: [simd_float4], source: String) {
        if let debug { return (debug, "debug") }
        guard crop else { return (device, "frustum") }
        let eyes: [BoundaryDotsEye] = [.left, .right]
        let cropped = device.indices.map { i in
            CropFov.tangents(eye: eyes[min(i, 1)], device: device[i],
                             insetDeg: insetDeg, marginDeg: marginDeg) ?? device[i]
        }
        return (cropped, "crop")
    }

    static let insetRange = 0.0...30.0
    static let marginRange = 0.0...10.0

    /// Launch value over setting (LaunchFlags), clamped to `range`; a non-finite argument falls back to the setting.
    private static func resolved(_ key: String, setting: Double, range: ClosedRange<Double>, arguments: [String: Any]) -> Double {
        let fallback = setting.isFinite ? setting : 0
        let value = LaunchFlags.double(key, setting: fallback, arguments: arguments)
        return min(max(value.isFinite ? value : fallback, range.lowerBound), range.upperBound)
    }

    /// `-ALVRCropInsetDeg` over `GlobalSettings.cropInsetDeg`, clamped to 0...30.
    static func effectiveInset(setting: Double, arguments: [String: Any] = LaunchFlags.currentArguments) -> Double {
        resolved("ALVRCropInsetDeg", setting: setting, range: insetRange, arguments: arguments)
    }

    /// `-ALVRCropMarginDeg` over `GlobalSettings.cropMarginDeg`, clamped to 0...10.
    static func effectiveMargin(setting: Double, arguments: [String: Any] = LaunchFlags.currentArguments) -> Double {
        resolved("ALVRCropMarginDeg", setting: setting, range: marginRange, arguments: arguments)
    }

    /// Model lens inset last set on the Boundary dots lens slider in this app session, one value for both eyes; nil until then.
    private static let lock = NSLock()
    private static var stored: Double?
    /// The inset at launch (`applyLaunch`, each stream): the argument or the setting, 15 until then. `inset` without a slider value.
    private static var launch = BoundaryDotsOutline.defaultInsetDeg

    static var inset: Double {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? launch
    }

    /// The margin for the current stream (`applyLaunch`), read per frame without touching the launch arguments.
    private static var launchMargin = defaultMarginDeg

    static var margin: Double {
        lock.lock()
        defer { lock.unlock() }
        return launchMargin
    }

    /// Resolve the launch/setting inset and margin once per stream (init, every connect and reconnect); a slider value
    /// (`recordInset`) still wins for the inset.
    static func applyLaunch(insetSetting: Double, marginSetting: Double = defaultMarginDeg,
                            arguments: [String: Any] = LaunchFlags.currentArguments) {
        let inset = effectiveInset(setting: insetSetting, arguments: arguments)
        let margin = effectiveMargin(setting: marginSetting, arguments: arguments)
        lock.lock()
        launch = inset
        launchMargin = margin
        lock.unlock()
    }

    static func recordInset(_ deg: Double) {
        guard deg.isFinite else { return }
        lock.lock()
        stored = deg
        lock.unlock()
    }

    /// The logical grid density measured from the layer's drawable (`recordGrid`); `measured` is false until then, and the
    /// density is the reference device's.
    private static var storedGrid: (density: SIMD2<Double>, measured: Bool)?

    static var grid: (density: SIMD2<Double>, measured: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return storedGrid ?? (gridDensity(screenWidth: referenceScreen.width, screenHeight: referenceScreen.height,
                                          device: referenceDevice[0]), false)
    }

    /// Record the drawable's logical grid (rate map screen size, else the view viewport) and the device frustum it was
    /// measured on; a zero size or a degenerate frustum is ignored.
    static func recordGrid(screenWidth: Int, screenHeight: Int, device: simd_float4) {
        guard screenWidth > 0, screenHeight > 0 else { return }
        let density = gridDensity(screenWidth: screenWidth, screenHeight: screenHeight, device: device)
        guard density.x > 0, density.y > 0 else { return }
        lock.lock()
        storedGrid = (density, true)
        lock.unlock()
    }

    static func resetGrid() {
        lock.lock()
        storedGrid = nil
        lock.unlock()
    }

    static func resetInset() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}
