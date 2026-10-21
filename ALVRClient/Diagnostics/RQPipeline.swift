import Metal

enum RQPipeline {
    static func descriptor(library: MTLLibrary? = nil) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "diagRQVertex")
        descriptor.fragmentFunction = library?.makeFunction(name: "diagRQFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.inputPrimitiveTopology = .triangle
        return descriptor
    }
}
