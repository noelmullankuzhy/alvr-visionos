//
//  ColourPipeline.swift
//
//  Colour maths for decoded video -> CompositorServices' extended-linear Display P3 (pure Foundation/simd so it is
//  unit-tested on macOS, tests/swift/ColourPipelineTests.swift).
//
//  Explicit planar shader path: texture samples -> yuvToRGB (H.273 matrix + range) -> sRGB EOTF -> encoding gamma
//  (linear light, source primaries) -> sourceToDisplayP3 -> half output.
//

import Foundation
import simd

enum ColourPrimaries: String {
    case bt709, bt2020, displayP3
}

enum ColourTransfer: String {
    case sRGB, bt709, linear, pq, hlg, unknown
}

enum YCbCrMatrix: String {
    case bt601, bt709, bt2020
}

struct ColourSelection: Equatable {
    var primaries: ColourPrimaries
    var transfer: ColourTransfer
    var matrix: YCbCrMatrix
    var fullRange: Bool
    var bitDepth: Int
    // Code depth of the decoded planes actually bound (r8Unorm = 8, MSB-aligned r16Unorm = 10); sets yuvToRGB.
    var planeBitDepth: Int
    var primariesAssumed: Bool
    var matrixAssumed: Bool
    var rangeAssumed: Bool
    // Applied to float4(Y, Cb, Cr, 1) texture samples; columns are Y, Cb, Cr gains and offsets.
    var yuvToRGB: simd_float4x4
    // Linear source RGB -> linear Display P3. Identity for PQ/HLG, whose shader path is not implemented yet.
    var sourceToDisplayP3: simd_float3x3

    var convertsGamut: Bool { sourceToDisplayP3 != matrix_identity_float3x3 }

    func logLine(path: String) -> String {
        func tag(_ value: String, _ assumed: Bool) -> String { assumed ? value + "(assumed)" : value }
        return "ALVRCOLOUR primaries=\(tag(primaries.rawValue, primariesAssumed)) transfer=\(transfer.rawValue)"
            + " matrix=\(tag(matrix.rawValue, matrixAssumed)) range=\(tag(fullRange ? "full" : "limited", rangeAssumed))"
            + " bits=\(bitDepth) path=\(path)"
    }
}

enum ColourPipeline {
    // CIE 1931 xy chromaticities (ITU-R BT.709, BT.2020; SMPTE EG 432-1 Display P3), D65 white.
    static let d65 = simd_double2(0.3127, 0.3290)

    static func chromaticities(_ primaries: ColourPrimaries) -> (r: simd_double2, g: simd_double2, b: simd_double2) {
        switch primaries {
        case .bt709: return (simd_double2(0.640, 0.330), simd_double2(0.300, 0.600), simd_double2(0.150, 0.060))
        case .bt2020: return (simd_double2(0.708, 0.292), simd_double2(0.170, 0.797), simd_double2(0.131, 0.046))
        case .displayP3: return (simd_double2(0.680, 0.320), simd_double2(0.265, 0.690), simd_double2(0.150, 0.060))
        }
    }

    // Normalised primary matrix (SMPTE RP 177): linear RGB -> CIE XYZ with white Y = 1.
    static func rgbToXYZ(_ primaries: ColourPrimaries) -> simd_double3x3 {
        func xyz(_ c: simd_double2) -> simd_double3 { simd_double3(c.x / c.y, 1, (1 - c.x - c.y) / c.y) }
        let p = chromaticities(primaries)
        let m = simd_double3x3(columns: (xyz(p.r), xyz(p.g), xyz(p.b)))
        let s = m.inverse * xyz(d65)
        return simd_double3x3(columns: (m.columns.0 * s.x, m.columns.1 * s.y, m.columns.2 * s.z))
    }

    static func primariesToDisplayP3(_ primaries: ColourPrimaries) -> simd_double3x3 {
        if primaries == .displayP3 { return matrix_identity_double3x3 }
        return rgbToXYZ(.displayP3).inverse * rgbToXYZ(primaries)
    }

    static func lumaCoefficients(_ matrix: YCbCrMatrix) -> (kr: Double, kb: Double) {
        switch matrix {
        case .bt601: return (0.299, 0.114)
        case .bt709: return (0.2126, 0.0722)
        case .bt2020: return (0.2627, 0.0593)
        }
    }

    // code = sample * sampleScale. 8-bit planes are r8Unorm; deeper planes (x420 etc.) hold the code in the MSBs of a
    // 16-bit word read as r16Unorm, so a 10-bit code c samples as (c << 6) / 65535.
    static func sampleScale(bitDepth: Int) -> Double {
        bitDepth <= 8 ? 255 : 65535 / Double(1 << (16 - bitDepth))
    }

    static func sampleValue(code: Double, bitDepth: Int) -> Float {
        Float(code / sampleScale(bitDepth: bitDepth))
    }

    // ITU-T H.273 quantisation inverted: full range E'Y = c / (2^n - 1), E'P = (c - 2^(n-1)) / (2^n - 1);
    // limited range E'Y = (c / 2^(n-8) - 16) / 219, E'P = (c / 2^(n-8) - 128) / 224.
    static func yuvToRGBMatrix(matrix: YCbCrMatrix, fullRange: Bool, bitDepth: Int) -> simd_float4x4 {
        let (kr, kb) = lumaCoefficients(matrix)
        let kg = 1 - kr - kb
        let n = Double(bitDepth)
        let scale = sampleScale(bitDepth: bitDepth)
        let ySlope, yOffset, cSlope, cOffset: Double
        if fullRange {
            let maxCode = pow(2, n) - 1
            ySlope = scale / maxCode
            yOffset = 0
            cSlope = scale / maxCode
            cOffset = -pow(2, n - 1) / maxCode
        } else {
            let step = pow(2, n - 8)
            ySlope = scale / (219 * step)
            yOffset = -16 / 219
            cSlope = scale / (224 * step)
            cOffset = -128 / 224
        }
        // R = E'Y + 2(1-Kr) E'PR; G = E'Y - 2Kb(1-Kb)/Kg E'PB - 2Kr(1-Kr)/Kg E'PR; B = E'Y + 2(1-Kb) E'PB
        let fromY = simd_double3(1, 1, 1)
        let fromCb = simd_double3(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb))
        let fromCr = simd_double3(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0)
        let offset = fromY * yOffset + (fromCb + fromCr) * cOffset
        func col(_ v: simd_double3, _ w: Double) -> simd_float4 { simd_float4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
        return simd_float4x4(col(fromY * ySlope, 0), col(fromCb * cSlope, 0), col(fromCr * cSlope, 0), col(offset, 1))
    }

    // Arguments are the CMFormatDescription extension values (kCVImageBuffer* strings, FullRangeVideo,
    // BitsPerComponent), nil when absent. Each field is parsed on its own: bit depth never implies a gamut.
    // planeBitDepth is the code depth of the planes the shader samples; nil falls back to the stream's bit depth.
    static func select(primaries: String?, transfer: String?, matrix: String?, fullRange: Bool?, bitDepth: Int?, planeBitDepth: Int? = nil) -> ColourSelection {
        let parsedPrimaries: ColourPrimaries?
        switch primaries {
        case "ITU_R_709_2": parsedPrimaries = .bt709
        case "ITU_R_2020": parsedPrimaries = .bt2020
        case "P3_D65": parsedPrimaries = .displayP3
        default: parsedPrimaries = nil
        }
        let parsedTransfer: ColourTransfer
        switch transfer {
        case "IEC_sRGB": parsedTransfer = .sRGB
        case "ITU_R_709_2", "ITU_R_2020": parsedTransfer = .bt709
        case "Linear": parsedTransfer = .linear
        case "SMPTE_ST_2084_PQ": parsedTransfer = .pq
        case "ITU_R_2100_HLG": parsedTransfer = .hlg
        default: parsedTransfer = .unknown
        }
        let parsedMatrix: YCbCrMatrix?
        switch matrix {
        case "ITU_R_601_4": parsedMatrix = .bt601
        case "ITU_R_709_2": parsedMatrix = .bt709
        case "ITU_R_2020": parsedMatrix = .bt2020
        default: parsedMatrix = nil
        }
        // Unsignalled: BT.709 (ALVR's SDR signalling and HD video practice); H.273 default range is limited.
        let p = parsedPrimaries ?? .bt709
        let m = parsedMatrix ?? .bt709
        let full = fullRange ?? false
        let bits = bitDepth ?? 8
        let planeBits = planeBitDepth ?? bits
        let hdrTransfer = parsedTransfer == .pq || parsedTransfer == .hlg
        let gamut = hdrTransfer ? matrix_identity_double3x3 : primariesToDisplayP3(p)
        return ColourSelection(
            primaries: p, transfer: parsedTransfer, matrix: m, fullRange: full, bitDepth: bits, planeBitDepth: planeBits,
            primariesAssumed: parsedPrimaries == nil, matrixAssumed: parsedMatrix == nil, rangeAssumed: fullRange == nil,
            yuvToRGB: yuvToRGBMatrix(matrix: m, fullRange: full, bitDepth: planeBits),
            sourceToDisplayP3: simd_float3x3(columns: (simd_float3(gamut.columns.0), simd_float3(gamut.columns.1), simd_float3(gamut.columns.2))))
    }

    // Swift mirror of Shaders.metal NonlinearToLinearRGB: sRGB EOTF, odd-symmetric outside [0, 1], pow on |x| only.
    static func srgbEOTF(_ x: Float) -> Float {
        let m = abs(x)
        let y = m < 0.04045 ? m / 12.92 : pow((m + 0.055) / 1.055, 2.4)
        return x < 0 ? -y : y
    }

    // Swift mirror of Shaders.metal EncodingNonlinearToLinearRGB.
    static func encodingGammaToLinear(_ x: Float, gamma: Float) -> Float {
        let y = pow(abs(x), gamma)
        return x < 0 ? -y : y
    }

    // CoreVideo pixel format as its four-character code ("x420"), or hex when not printable.
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(format: "0x%08x", code)
    }
}
