import AVFoundation

// The client and M7 use identical output requests; SDR lets VT choose its native format.
enum VideoDecoderOutput {
    static func attributes(_ format: CMFormatDescription) -> [NSString: AnyObject] {
        var attributes:[NSString: AnyObject] = [kCVPixelBufferMetalCompatibilityKey: true as NSNumber, kCVPixelBufferPoolMinimumBufferCountKey: 3 as NSNumber]
        // PQ: request uncompressed 10-bit biplanar output, so the explicit shader path decodes PQ (the private *_sRGB
        // samplers would apply the sRGB EOTF) and HDRProbe can read the codes. Costs a copy; SDR streams are untouched.
        // The decoder may ignore the request: streamColourState checks every frame's actual format (8-bit planes are
        // still PQ-converted, other formats dropped).
        if HDRPipeline.requiresExplicitPlanes(transfer: format.extensions[kCMFormatDescriptionExtension_TransferFunction] as? String) {
            let pixelFormat = ((format.extensions["FullRangeVideo" as CFString] as? NSNumber)?.intValue ?? 0) != 0 ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            attributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat as NSNumber
        }
        return attributes
    }
}
