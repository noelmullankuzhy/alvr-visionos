//
//  Renderer.swift
//
// Primarily, stuff for the MetalClientSystem rendering, but portions are shared
// with RealityKitClientSystem
//
// Notable portions include:
// - Pipeline setup for different color formats and compiled Metal constants (rebuildRenderPipelines)
//
import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import ARKit
import VideoToolbox
import ObjectiveC

// The 256 byte aligned size of our uniform structure
let alignedUniformsSize = (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100
let alignedPlaneUniformSize = (MemoryLayout<PlaneUniform>.size + 0xFF) & -0x100

let maxBuffersInFlight = 6
let maxPlanesDrawn = 512

enum RendererError: Error {
    case badVertexDescriptor
}

// Focal depth of the timewarp panel, ideally would be adjusted based on the depth
// of what the user is looking at.
let panel_depth: Float = 1

// TODO(zhuowei): what's the z supposed to be?
// x, y, z
// u, v
let fullscreenQuadVertices:[Float] = [-panel_depth, -panel_depth, -panel_depth,
                                       panel_depth, -panel_depth, -panel_depth,
                                       -panel_depth, panel_depth, -panel_depth,
                                       panel_depth, panel_depth, -panel_depth,
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

let hudQuadVertices: [Float] = [
    -0.5, -0.5, 0.0,
     0.5, -0.5, 0.0,
    -0.5,  0.5, 0.0,
     0.5,  0.5, 0.0,
     0.0,  1.0,
     1.0,  1.0,
     0.0,  0.0,
     1.0,  0.0
]
                                       
let unitVectorXYZVertices:[Float] = [0.0, 0.0, 0.0,
                                       1.0, 0.0, 0.0,
                                       0.01,0.0,0.0,
                                       
                                       0.0, 0.0, 0.0,
                                       0.0, 1.0, 0.0,
                                       0.0,0.01,0.0,
                                       
                                       0.0, 0.0, 0.0,
                                       0.0, 0.0, 1.0,
                                       0.0,0.0,0.01,
                                       
                                       0, 1,
                                       0.5, 1,
                                       0, 0,
                                       0.5, 0]

func NonlinearToLinearRGB(_ color: simd_float3) -> simd_float3 {
    let DIV12: Float = 1.0 / 12.92;
    let DIV1: Float = 1.0 / 1.055;
    let THRESHOLD: Float = 0.04045;
    let GAMMA = simd_float3(repeating: 2.4);
        
    let condition = simd_float3(color.x < THRESHOLD ? 1.0 : 0.0, color.y < THRESHOLD ? 1.0 : 0.0, color.z < THRESHOLD ? 1.0 : 0.0);
    let lowValues = color * DIV12;
    let highValues = pow((color + 0.055) * DIV1, GAMMA);
    return condition * lowValues + (1.0 - condition) * highValues;
}

class Renderer {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    var pipelineState: MTLRenderPipelineState
    var depthStateAlways: MTLDepthStencilState
    var depthStateGreater: MTLDepthStencilState

    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<UniformsArray>
    
    var dynamicPlaneUniformBuffer: MTLBuffer
    var planeUniformBufferOffset = 0
    var planeUniformBufferIndex = 0
    var planeUniforms: UnsafeMutablePointer<PlaneUniform>

    let layerRenderer: LayerRenderer?
    var metalTextureCache: CVMetalTextureCache!
    let mtlVertexDescriptor: MTLVertexDescriptor
    let mtlVertexDescriptorNoUV: MTLVertexDescriptor
    // Video frame pipelines (explicit planes, private formats), published with the stream colour state and generation
    // they were built for. Each renderer owns its slot; the state key also includes its display headroom.
    let videoFramePipelines = VideoPipelineSlot<FoveationVars?, (biplanar: MTLRenderPipelineState, secret: MTLRenderPipelineState)>(gate: EventHandler.videoStreams)
var videoFrameDepthPipelineState: MTLRenderPipelineState!
    var fullscreenQuadBuffer:MTLBuffer!
    var unitVectorXYZBuffer:MTLBuffer!
    /// Steam Controller body wireframe. Built on first use rather than at init,
    /// because the overwhelmingly common case is that no Steam Controller is
    /// connected and nothing ever asks to draw it.
    private var ibexMeshBufferStorage:MTLBuffer?
    private var ibexMeshBuildAttempted = false
    var ibexMeshVertexCount: Int = 0

    /// Uploads `IbexModel`'s decimated shell on first call. Returns nil if the
    /// resource is missing, and does not retry — a missing bundle resource will
    /// not fix itself, and retrying every frame would spam the log.
    func ibexMeshBuffer() -> MTLBuffer? {
        if ibexMeshBuildAttempted { return ibexMeshBufferStorage }
        ibexMeshBuildAttempted = true
        let verts = IbexModel.wireframeVertices
        guard !verts.isEmpty else { return nil }
        verts.withUnsafeBytes {
            ibexMeshBufferStorage = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        ibexMeshVertexCount = IbexModel.wireframeVertexCount
        print("Renderer: Ibex wireframe uploaded, \(ibexMeshVertexCount) verts")
        return ibexMeshBufferStorage
    }
    var hudPipelineState: MTLRenderPipelineState!
    var hudQuadBuffer: MTLBuffer!
    var depthStateAlwaysNoWrite: MTLDepthStencilState!
    var performanceHudRenderer: PerformanceHudRenderer?
    var lastReconfigureTime: Double = 0.0
    
    var drawPlanesWithInformedColors: Bool = false
    var fadeInOverlayAlpha: Float = 0.0
    var coolPulsingColorsTime: Float = 0.0
    private let chaperoneSystem = ChaperoneSystem()
#if CHAPERONE_PROFILE
    private var chaperoneProfileAccumMs: Double = 0.0
    private var chaperoneProfileSamples: Int = 0
    private var chaperoneProfileLastLog: Double = 0.0
    private var chaperoneProfileWindow: [Double] = []
    private let chaperoneProfileWindowSize: Int = 120
#endif
    var reprojectedFramesInARow: Int = 0
    var roundTripRenderTime: Double = 0.0
    var lastRoundTripRenderTimestamp: Double = 0.0
    // Opt-in deadline-budgeted frame selection (UserDefaults ALVRDeadlineSelect); off keeps the 5 ms poll.
    let deadlineSelect = LaunchFlags.bool(FramePacing.defaultsKey, setting: ALVRClientApp.gStore.settings.deadlineSelect)
    let gpuTimes = GpuTimeEstimator()
    var lastVideoPipelineRequestTime: Double = 0.0
    var loggedPQBindFailures = Set<OSType>()
    
    // Was curious if it improved; it's still juddery.
    var useApplesReprojection = false
    
    // More readable helper var than layerRenderer == nil
    var isRealityKit = false
    // Diagnostics M5/M6/M9 (GM decision 65): Metal renderer only, nil when Diagnostics is off.
    let diagProbe: DiagRenderProbe?
    private var rqSweep: RQRenderer?
    // Corner chart (decision 65): Metal renderer, no stream; nil unless Diagnostics is on and the setting picks a mode.
    let cornerChart: CornerChartRenderer?
    // Resolution chart (ResolutionChart.swift): same conditions, Resolution chart setting; the corner chart wins.
    let resolutionChart: ResolutionChartRenderer?
    // Golden frame (GoldenFrame.swift): Diagnostics on and a Golden frame set picked, both charts off; drawn in place of
    // the stream (or the no-stream pass) until its exit control.
    private(set) var goldenFrame: GoldenFrameRenderer?
    private var diagEye: DiagEyeRenderer?
    let diagFrameCapture: DiagFrameCaptureSession?
    // Sharpness-chain capture (DiagStreamStages): the planes and state this frame's stream was drawn with. Set only while
    // frame capture is on, cleared after the capture encode so no decoded frame is held past its frame.
    var diagStreamSource: (planes: [MTLTexture], cvTextures: [CVMetalTexture], secret: Bool, colour: StreamColourState,
                           chromaKey: ChromaKeySnapshot, pixelFormat: OSType)?
    var hdrEnabled = false
    var currentRenderColorFormat = renderColorFormatSDR
    var currentDrawableRenderColorFormat = renderColorFormatDrawableSDR
    
    //
    // Chroma keying shader vars
    //
    var frameChromaKey: ChromaKeySnapshot?
    var chromaKeyEnabled = false
    var chromaKeyColor = simd_float3(0.0, 1.0, 0.0); // green
    
    //chromaKeyLerpDistRange is used to decide the amount of color to be used from either foreground or background
    //if the current distance from pixel color to chromaKey is smaller then chromaKeyLerpDistRange.x we use background,
    //if the current distance from pixel color to chromaKey is bigger then chromaKeyLerpDistRange.y we use foreground,
    //else, we alpha blend them
    //playing with this variable will decide how much the foreground and background blend together
    var chromaKeyLerpDistRange = simd_float2(0.005, 0.1);
    
    let renderOwnership: MetalRenderOwnership
    let displayHeadroom: Float
    let displayFullImmersion: Bool
    private let displayHeadroomSource: String

    init(_ layerRenderer: LayerRenderer?, offlineDiagnostics: Bool = false, displayFullImmersion: Bool = false) {
        let headroomOverride = LaunchFlags.double(HDRPipeline.headroomDefaultsKey, setting: ALVRClientApp.gStore.settings.hdrHeadroom)
        self.displayFullImmersion = layerRenderer != nil && displayFullImmersion
        self.displayHeadroom = HDRPipeline.headroom(defaultsValue: headroomOverride, fullImmersion: layerRenderer != nil && displayFullImmersion)
        self.displayHeadroomSource = headroomOverride >= 1 ? "override" : "measured"
        self.renderOwnership = MetalRenderOwnership(offlineDiagnostics: offlineDiagnostics)
        self.layerRenderer = layerRenderer
        let rendererName = layerRenderer == nil ? "realitykit" : "metal"
        StreamTelemetry.shared.updateFormat { $0.renderer = rendererName }
        if layerRenderer == nil {
            isRealityKit = true
        }
        else {
#if XCODE_BETA_26
            if #available(visionOS 26.0, *) {
                //self.layerRenderer?.renderQuality = .init(1.0)
            }
#endif
        }

        hdrEnabled = EventHandler.shared.enableHdr
        if hdrEnabled {
            currentRenderColorFormat = renderColorFormatHDR
            currentDrawableRenderColorFormat = renderColorFormatDrawableHDR
        }
        else {
            currentRenderColorFormat = renderColorFormatSDR
            currentDrawableRenderColorFormat = renderColorFormatSDR
        }

        self.device = layerRenderer?.device ?? MTLCreateSystemDefaultDevice()!
        self.commandQueue = self.device.makeCommandQueue()!
        self.diagProbe = layerRenderer != nil && Diag.isOn ? DiagRenderProbe(device: self.device) : nil
        self.cornerChart = layerRenderer.flatMap { CornerChartRenderer.make(device: $0.device, layerRenderer: $0) }
        self.resolutionChart = layerRenderer.flatMap { ResolutionChartRenderer.make(device: $0.device, layerRenderer: $0) }
        self.diagFrameCapture = layerRenderer != nil && Diag.isOn && ALVRClientApp.gStore.settings.captureDiagnosticFrames
            ? DiagFrameCaptureSession() : nil
        if layerRenderer == nil && Diag.isOn { DiagEye.unsupported() }

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        self.dynamicUniformBuffer = self.device.makeBuffer(length:uniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicUniformBuffer.label = "UniformBuffer"
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:UniformsArray.self, capacity:1)

        let planeUniformBufferSize = alignedPlaneUniformSize * maxPlanesDrawn
        self.dynamicPlaneUniformBuffer = self.device.makeBuffer(length:planeUniformBufferSize,
                                                           options:[MTLResourceOptions.storageModeShared])!
        self.dynamicPlaneUniformBuffer.label = "PlaneUniformBuffer"
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents()).bindMemory(to:PlaneUniform.self, capacity:1)
        
        mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()
        mtlVertexDescriptorNoUV = Renderer.buildMetalVertexDescriptorNoUV()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                       depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                       viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                       vertexShaderName: "vertexShader",
                                                                       fragmentShaderName: "fragmentShader")
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }
        do {
            hudPipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                          mtlVertexDescriptor: mtlVertexDescriptor,
                                                                          colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                          depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                          viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                          vertexShaderName: "hudVertexShader",
                                                                          fragmentShaderName: "hudFragmentShader")
        } catch {
            fatalError("Unable to compile HUD render pipeline state.  Error info: \(error)")
        }

        let depthStateDescriptorAlways = MTLDepthStencilDescriptor()
        depthStateDescriptorAlways.depthCompareFunction = MTLCompareFunction.always
        depthStateDescriptorAlways.isDepthWriteEnabled = true
        self.depthStateAlways = device.makeDepthStencilState(descriptor:depthStateDescriptorAlways)!
        let depthStateDescriptorAlwaysNoWrite = MTLDepthStencilDescriptor()
        depthStateDescriptorAlwaysNoWrite.depthCompareFunction = .always
        depthStateDescriptorAlwaysNoWrite.isDepthWriteEnabled = false
        self.depthStateAlwaysNoWrite = device.makeDepthStencilState(descriptor: depthStateDescriptorAlwaysNoWrite)!
        
        let depthStateDescriptorGreater = MTLDepthStencilDescriptor()
        depthStateDescriptorGreater.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptorGreater.isDepthWriteEnabled = true
        self.depthStateGreater = device.makeDepthStencilState(descriptor:depthStateDescriptorGreater)!
        
        if CVMetalTextureCacheCreate(nil, nil, self.device, nil, &metalTextureCache) != 0 {
            fatalError("CVMetalTextureCacheCreate")
        }
        fullscreenQuadVertices.withUnsafeBytes {
            fullscreenQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        hudQuadVertices.withUnsafeBytes {
            hudQuadBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        
        unitVectorXYZVertices.withUnsafeBytes {
            unitVectorXYZBuffer = device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)
        }
        
        self.videoFrameDepthPipelineState = try! Renderer.buildRenderPipelineForVideoFrameDepthWithDevice(
                device: self.device,
                mtlVertexDescriptor: self.mtlVertexDescriptor,
                colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                viewCount: layerRenderer?.properties.viewCount ?? renderViewCount
        )
        
        rebuildRenderPipelines()
        self.goldenFrame = layerRenderer.flatMap { GoldenFrameRenderer.make(renderer: self, layerRenderer: $0) }

        if renderOwnership.publishesRenderStarted {
            EventHandler.shared.handleRenderStarted()
            EventHandler.shared.renderStarted = true
        }
    }
    
    func logStreamingSpace(id: String) {
        let line = "STREAMSPACE id=\(id) immersion=\(displayFullImmersion ? "full" : "mixed")"
            + " headroom=\(displayHeadroom) headroom_src=\(displayHeadroomSource)"
        alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), line)
    }

    func rebuildRenderPipelines(chromaKey snapshot: ChromaKeySnapshot? = nil) {
        let chromaKey = snapshot ?? ChromaKeySnapshot(settings: ALVRClientApp.gStore.settings)
        chromaKeyEnabled = chromaKey.enabled
        if #unavailable(visionOS 2.0) { chromaKeyEnabled = chromaKeyEnabled && isRealityKit }
        chromaKeyColor = chromaKey.colour
        chromaKeyLerpDistRange = chromaKey.range
        print("rebuildRenderPipelines")

        hdrEnabled = EventHandler.shared.enableHdr
        if hdrEnabled {
            currentRenderColorFormat = renderColorFormatHDR
            currentDrawableRenderColorFormat = renderColorFormatDrawableHDR
        }
        else {
            currentRenderColorFormat = renderColorFormatSDR
            currentDrawableRenderColorFormat = renderColorFormatSDR
        }

        // Everything below builds the *video frame* pipelines, and both of its
        // inputs only exist once a streamer has told us about the stream:
        // `settings` comes from the session config, and `streamEvent` from
        // STREAMING_STARTED. The renderer can legitimately be running before
        // either arrives — the offline input debug space brings it up with no
        // server at all — so this is a normal state, not a failure.
        //
        // Nothing is lost by deferring: there are no video frames to draw yet,
        // the pipeline states are implicitly-unwrapped optionals that stay nil
        // until used, and the first IPD report after streaming goes active
        // re-enters this function (see the `lastIpd == -1` branch in
        // renderFrame) and builds them for real.
        guard Settings.getAlvrSettings() != nil, EventHandler.shared.streamEvent != nil else {
            print("rebuildRenderPipelines: no stream yet, deferring video pipelines")
            return
        }

        // Both variants are built from one snapshot of one stream generation (decision 63e (3)): the requested colour
        // state (with that stream's encoding gamma and this renderer's display headroom) and the foveation captured at its STREAMING_STARTED.
        // A build that finishes after the stream stopped or restarted is discarded by publish. None is requested
        // until the first frame (its bind requests one).
        if let inputs = videoFramePipelines.buildInputs() {
            buildVideoFramePipelines(colour: inputs.colour, foveationVars: inputs.payload, chromaKey: chromaKey)
        }

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: device,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor,
                                                                       colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                                                                       depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                                                                       viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                                                                       vertexShaderName: "vertexShader",
                                                                       fragmentShaderName: "fragmentShader")
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }

        self.videoFrameDepthPipelineState = try! Renderer.buildRenderPipelineForVideoFrameDepthWithDevice(
                device: self.device,
                mtlVertexDescriptor: self.mtlVertexDescriptor,
                colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                depthFormat: layerRenderer?.configuration.depthFormat ?? renderDepthFormat,
                viewCount: layerRenderer?.properties.viewCount ?? renderViewCount
        )
    }

    // Both video variants from one generation's snapshot (rebuildRenderPipelines), published together with it.
    private func buildVideoFramePipelines(colour: StreamColourState, foveationVars: FoveationVars?, chromaKey: ChromaKeySnapshot) {
        guard let foveationVars else {
            print("rebuildRenderPipelines: stream \(colour.stream.generation) started without settings, no video pipelines")
            return
        }
        let biplanar = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            colour: colour,
                            chromaKey: chromaKey,
                            variantName: "YpCbCrBiPlanar"
        )
        let secret = try! buildRenderPipelineForVideoFrameWithDevice(
                            device: device,
                            mtlVertexDescriptor: mtlVertexDescriptor,
                            colorFormat: layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat,
                            viewCount: layerRenderer?.properties.viewCount ?? renderViewCount,
                            foveationVars: foveationVars,
                            colour: colour,
                            chromaKey: chromaKey,
                            variantName: "SecretYpCbCrFormats"
        )
        if !videoFramePipelines.publish((biplanar, secret), builtFor: colour) {
            print("rebuildRenderPipelines: discarded video pipelines for stream \(colour.stream.generation) (stale)")
        }
    }

    // Vertex descriptor with float3 position and float2 UVs
    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }
    
    // Vertex descriptor without any UV info
    class func buildMetalVertexDescriptorNoUV() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    // Generic render pipeline, used for the wireframe rendering.
    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             mtlVertexDescriptor: MTLVertexDescriptor,
                                             colorFormat: MTLPixelFormat,
                                             depthFormat: MTLPixelFormat,
                                             viewCount: Int,
                                             vertexShaderName: String,
                                             fragmentShaderName: String) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: vertexShaderName)
        let fragmentFunction = library?.makeFunction(name: fragmentShaderName)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Copy/"passthrough" pipeline for transferring from an offscreen MTLTexture
    // to the final RealityKit MTLTexture.
    func buildCopyPipelineWithDevice(device: MTLDevice,
                                             colorFormat: MTLPixelFormat,
                                             viewCount: Int,
                                             vrrScreenSize: MTLSize?,
                                             vrrPhysSize: MTLSize?,
                                             vertexShaderName: String,
                                             fragmentShaderName: String) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()
        
        let chromaKey = frameChromaKey ?? ChromaKeySnapshot(settings: ALVRClientApp.gStore.settings)
        let fragmentConstants = MTLFunctionConstantValues()
        var enabled = chromaKey.enabled
        if #unavailable(visionOS 2.0) { enabled = enabled && isRealityKit }
        var colourLinear = NonlinearToLinearRGB(chromaKey.colour)
        var range = chromaKey.range

        var mutVrrScreenSize = simd_float2(Float(vrrScreenSize?.width ?? 1), Float(vrrScreenSize?.height ?? 1))
        var mutVrrPhysSize = simd_float2(Float(vrrPhysSize?.width ?? 1), Float(vrrPhysSize?.height ?? 1))
        fragmentConstants.setConstantValue(&enabled, type: .bool, index: ALVRFunctionConstant.chromaKeyEnabled.rawValue)
        fragmentConstants.setConstantValue(&colourLinear, type: .float3, index: ALVRFunctionConstant.chromaKeyColor.rawValue)
        fragmentConstants.setConstantValue(&range, type: .float2, index: ALVRFunctionConstant.chromaKeyLerpDistRange.rawValue)
        fragmentConstants.setConstantValue(&isRealityKit, type: .bool, index: ALVRFunctionConstant.realityKitEnabled.rawValue)
        fragmentConstants.setConstantValue(&mutVrrScreenSize, type: .float2, index: ALVRFunctionConstant.vrrScreenSize.rawValue)
        fragmentConstants.setConstantValue(&mutVrrPhysSize, type: .float2, index: ALVRFunctionConstant.vrrPhysSize.rawValue)

        let vertexFunction = try! library?.makeFunction(name: vertexShaderName, constantValues: fragmentConstants)
        let fragmentFunction = try! library?.makeFunction(name: fragmentShaderName, constantValues: fragmentConstants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptorNoUV

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // Depth-only renderer, for correcting after overlay render just so Apple's compositor isn't annoying about it
    class func buildRenderPipelineForVideoFrameDepthWithDevice(device: MTLDevice,
                                                          mtlVertexDescriptor: MTLVertexDescriptor,
                                                          colorFormat: MTLPixelFormat,
                                                          depthFormat: MTLPixelFormat,
                                                          viewCount: Int) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "videoFrameVertexShader")
        let fragmentFunction = library?.makeFunction(name: "videoFrameDepthFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameDepthRenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        //pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // True when a video pipeline build should start for the frame's colour state: the state changed, or its build has
    // not been published within 1 s (a rebuild deferred before the stream existed).
    func videoPipelinesNeedBuild(for colour: StreamColourState) -> Bool {
        let now = CACurrentMediaTime()
        if videoFramePipelines.request(colour) || (videoFramePipelines.pipelines(for: colour) == nil && now - lastVideoPipelineRequestTime > 1.0) {
            lastVideoPipelineRequestTime = now
            return true
        }
        return false
    }

    // Video frame renderer, incl my own YCbCr stage and/or Apple's 48 private YCbCr texture formats.
    func buildRenderPipelineForVideoFrameWithDevice(device: MTLDevice,
                                                          mtlVertexDescriptor: MTLVertexDescriptor,
                                                          colorFormat: MTLPixelFormat,
                                                          viewCount: Int,
                                                          foveationVars: FoveationVars,
                                                          colour: StreamColourState,
                                                          chromaKey: ChromaKeySnapshot,
                                                          variantName: String,
                                                          vertexShaderName: String = "videoFrameVertexShader") throws -> MTLRenderPipelineState {
        

        let library = device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: vertexShaderName)
        let fragmentConstants = FFR.makeFunctionConstants(foveationVars)
        
        var enabled = chromaKey.enabled
        if #unavailable(visionOS 2.0) { enabled = enabled && isRealityKit }
        var colourLinear = NonlinearToLinearRGB(chromaKey.colour)
        var range = chromaKey.range

        fragmentConstants.setConstantValue(&enabled, type: .bool, index: ALVRFunctionConstant.chromaKeyEnabled.rawValue)
        fragmentConstants.setConstantValue(&colourLinear, type: .float3, index: ALVRFunctionConstant.chromaKeyColor.rawValue)
        fragmentConstants.setConstantValue(&range, type: .float2, index: ALVRFunctionConstant.chromaKeyLerpDistRange.rawValue)
        fragmentConstants.setConstantValue(&isRealityKit, type: .bool, index: ALVRFunctionConstant.realityKitEnabled.rawValue)
        var encodingGamma = colour.encodingGamma
        fragmentConstants.setConstantValue(&encodingGamma, type: .float, index: ALVRFunctionConstant.encodingGamma.rawValue)
        var yuvTransform = colour.yuvToRGB
        var gamutTransform = colour.gamutToOutput
        var hdrPQ = colour.hdrPQ
        fragmentConstants.setConstantValue(&yuvTransform.columns.0, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform0.rawValue)
        fragmentConstants.setConstantValue(&yuvTransform.columns.1, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform1.rawValue)
        fragmentConstants.setConstantValue(&yuvTransform.columns.2, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform2.rawValue)
        fragmentConstants.setConstantValue(&yuvTransform.columns.3, type: .float4, index: ALVRFunctionConstant.encodingYUVTransform3.rawValue)
        fragmentConstants.setConstantValue(&gamutTransform.columns.0, type: .float3, index: ALVRFunctionConstant.gamutToOutput_0.rawValue)
        fragmentConstants.setConstantValue(&gamutTransform.columns.1, type: .float3, index: ALVRFunctionConstant.gamutToOutput_1.rawValue)
        fragmentConstants.setConstantValue(&gamutTransform.columns.2, type: .float3, index: ALVRFunctionConstant.gamutToOutput_2.rawValue)
        var hdrPQScale = Float(10000 / colour.stream.referenceWhiteNits)
        var headroom = colour.headroom // Derived from this renderer's immutable displayHeadroom.
        fragmentConstants.setConstantValue(&hdrPQ, type: .bool, index: ALVRFunctionConstant.hdrPQ.rawValue)
        fragmentConstants.setConstantValue(&hdrPQScale, type: .float, index: ALVRFunctionConstant.hdrPQScale.rawValue)
        fragmentConstants.setConstantValue(&headroom, type: .float, index: ALVRFunctionConstant.edrHeadroom.rawValue)

        let fragmentFunction = try library?.makeFunction(name: "videoFrameFragmentShader_" + variantName, constantValues: fragmentConstants)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "VideoFrameRenderPipeline_" + variantName
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        //pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat

        pipelineDescriptor.maxVertexAmplificationCount = viewCount
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // Advances the uniform buffer for the next frame, values can be written to `uniforms`
    // after this is called.
    private func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:UniformsArray.self, capacity:1)
    }
    
    // Advances the Plane uniform buffer, values can be written to `planeUniforms`
    // after this is called.
    private func selectNextPlaneUniformBuffer() {
        /// Update the state of our uniform buffers before rendering

        planeUniformBufferIndex = (planeUniformBufferIndex + 1) % maxPlanesDrawn
        planeUniformBufferOffset = alignedPlaneUniformSize * planeUniformBufferIndex
        planeUniforms = UnsafeMutableRawPointer(dynamicPlaneUniformBuffer.contents() + planeUniformBufferOffset).bindMemory(to:PlaneUniform.self, capacity:1)
    }

    // Writes FOV/tangents/etc information to the uniform buffer.
    private func updateGameStateForVideoFrame(_ whichIdx: Int, drawable: LayerRenderer.Drawable?, viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4) {
        let settings = ALVRClientApp.gStore.settings
        func uniforms(forViewIndex viewIndex: Int) -> Uniforms {
            let realTangents = realViewTangents[viewIndex]
            let sentTangents = sentViewTangents[viewIndex]

            let viewMatrix = (simdDeviceAnchor * viewTransforms[viewIndex]).inverse
            let viewMatrixFrame = StreamReprojection.viewMatrixFrame(framePose: framePose, deviceAnchor: simdDeviceAnchor, viewTransform: viewTransforms[viewIndex])
            let viewMatrixFrameRk = StreamReprojection.viewMatrixFrameRealityKit(framePose: framePose, deviceAnchor: simdDeviceAnchor)
            var projection = matrix_identity_float4x4
            if #available(visionOS 2.0, *), drawable != nil {
#if XCODE_BETA_16
                projection = drawable!.computeProjection(viewIndex: viewIndex)
#else
                let p = ProjectiveTransform3D(leftTangent: Double(realTangents[0]),
                          rightTangent: Double(realTangents[1]),
                          topTangent: Double(realTangents[2]),
                          bottomTangent: Double(realTangents[3]),
                          nearZ: nearZ,
                          farZ: farZ,
                          reverseZ: true)
                projection = matrix_float4x4(p)
#endif
            }
            else {
                let p = ProjectiveTransform3D(leftTangent: Double(realTangents[0]),
                          rightTangent: Double(realTangents[1]),
                          topTangent: Double(realTangents[2]),
                          bottomTangent: Double(realTangents[3]),
                          nearZ: nearZ,
                          farZ: farZ,
                          reverseZ: true)
                projection = matrix_float4x4(p)
            }
            return Uniforms(projectionMatrix: projection, modelViewMatrixFrame: isRealityKit ? viewMatrixFrameRk : viewMatrixFrame, modelViewMatrix: viewMatrix, tangents: sentTangents)
        }
        
        self.uniforms[0].uniforms.0 = uniforms(forViewIndex: 0)
        if viewTransforms.count > 1 {
            self.uniforms[0].uniforms.1 = uniforms(forViewIndex: 1)
        }
    }
    
    // Checks if eye tracking was secretly added, maybe, hard to know really.
    func checkEyes(drawable: LayerRenderer.Drawable) {
        print("begin -----")
        print(drawable.colorTextures.first?.width as Any, drawable.colorTextures.first?.height as Any)
        //print(drawable.views[0].transform - EventHandler.shared.viewTransforms[0])
        //print(drawable.views[1].transform - EventHandler.shared.viewTransforms[1])
        if let vrr = drawable.rasterizationRateMaps.first {
            let eyeCenterX = Float(vrr.screenSize.width) / 2.0
            let eyeCenterY = Float(vrr.screenSize.height) / 2.0
            let physSizeL = vrr.physicalSize(layer: 0)
            let physCoordsL = vrr.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: eyeCenterX, y: eyeCenterY), layer: 0)
            
            let physSizeR = vrr.physicalSize(layer: 1)
            let physCoordsR = vrr.physicalCoordinates(screenCoordinates: MTLCoordinate2D(x: eyeCenterX, y: eyeCenterY), layer: 1)
            
            print(physSizeL, physSizeR, vrr.screenSize.width, vrr.screenSize.height, ":::", Float(physCoordsL.x) / Float(physSizeL.width), Float(physCoordsL.y) / Float(physSizeL.height), ":::", Float(physCoordsR.x) / Float(physSizeR.width), Float(physCoordsR.y) / Float(physSizeR.height))
        }
        
        print("end -------")
    }
    
    // Adjust view transforms for debugging various issues.
    func fixTransform(_ transform: simd_float4x4) -> simd_float4x4 {
        //var out = matrix_identity_float4x4
        //out.columns.3 = transform.columns.3
        //out.columns.3.w = 1.0
        return transform.translationOnly() // TODO: undo this when we fix canted views in 20.15
    }
    
    // Adjusts view tangents for debugging various issues.
    func fixTangents(_ tangents: simd_float4) -> simd_float4 {
        return tangents
    }
    
    // Nanoseconds since the LayerRenderer clock epoch, the clock of frame timing and video timestamps.
    private func layerClockNs(_ instant: LayerRenderer.Clock.Instant) -> UInt64 {
        UInt64(max(LayerRenderer.Clock.Instant.epoch.duration(to: instant).timeInterval, 0) * Double(NSEC_PER_SEC))
    }

    func renderToDrawable(_ drawable: LayerRenderer.Drawable) {
        
    }

    func stopQualitySweep() {
        if let layer = layerRenderer { rqSweep?.update(layer: layer, enabled: false, streaming: false) }
    }

    // Render the frame, only used in MetalClientSystem renderer.
    func renderFrame() {
        let chromaKey = ChromaKeySnapshot(settings: ALVRClientApp.gStore.settings)
        frameChromaKey = chromaKey
        if !renderOwnership.offlineDiagnostics {
            EventHandler.shared.framesRendered += 1
            EventHandler.shared.totalFramesRendered += 1
        }
        if diagProbe != nil, let layer = layerRenderer {
            let enabled = ALVRClientApp.gStore.settings.renderQualitySweep
            if enabled && !EventHandler.shared.streamingActive && rqSweep == nil {
                do { rqSweep = try RQRenderer(device: device, library: device.makeDefaultLibrary()!) }
                catch { Diag.log("rq", ["error": error.localizedDescription]) }
            }
            rqSweep?.update(layer: layer, enabled: enabled, streaming: EventHandler.shared.streamingActive)
            if !enabled { rqSweep = nil }
        }
        var streamingActiveForFrame = !renderOwnership.offlineDiagnostics && EventHandler.shared.streamingActive
        var isReprojected = false
        
        var queuedFrame:QueuedFrame? = nil
        
        guard let frame = layerRenderer!.queryNextFrame() else { return }
        guard let timing = frame.predictTiming() else { return }

        frame.startUpdate()
        frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        
        roundTripRenderTime = CACurrentMediaTime() - lastRoundTripRenderTimestamp
        lastRoundTripRenderTimestamp = CACurrentMediaTime()

        let startPollTime = CACurrentMediaTime()
        var selectionSource = FrameSelectionSource.none
        var selectionSkipped = 0
        if !renderOwnership.offlineDiagnostics && !deadlineSelect {
        while true {
            sched_yield()

            // If visionOS skipped our last frame, let the queue fill up a bit
            // One locked copy: EventHandler.stop() clears lastQueued on another thread (a nil check then `!` crashed).
            objc_sync_enter(EventHandler.shared.frameQueueLock)
            let last = EventHandler.shared.lastQueued.frame
            let queueCount = EventHandler.shared.frameQueue.count
            objc_sync_exit(EventHandler.shared.frameQueueLock)
            if let last = last {
                if FramePacing.shouldRetry(lastTimestamp: last.timestamp, lastSubmitted: EventHandler.shared.lastSubmittedTimestamp, queueCount: queueCount) {
                    queuedFrame = last
                    EventHandler.shared.framesRendered -= 1
                    isReprojected = false
                    selectionSource = .retry
                    break
                }
            }

            objc_sync_enter(EventHandler.shared.frameQueueLock)
            queuedFrame = EventHandler.shared.frameQueue.count > 0 ? EventHandler.shared.frameQueue.removeFirst() : nil
            objc_sync_exit(EventHandler.shared.frameQueueLock)
            if queuedFrame != nil {
                selectionSource = .new
                break
            }

            if CACurrentMediaTime() - startPollTime > 0.005 {
                //EventHandler.shared.framesRendered -= 1
                break
            }
        }

        // Recycle old frame with old timestamp/anchor (visionOS doesn't do timewarp for us?)
        objc_sync_enter(EventHandler.shared.frameQueueLock)
        let lastForReuse = EventHandler.shared.lastQueued.frame
        objc_sync_exit(EventHandler.shared.frameQueueLock)
        if queuedFrame == nil, let lastForReuse = lastForReuse {
            //print("Using last frame...")
            queuedFrame = lastForReuse
            EventHandler.shared.framesRendered -= 1
            isReprojected = true
            selectionSource = .reuse
        }
        }
        else if !renderOwnership.offlineDiagnostics {
            // Newest decoded frame not newer than this vsync, chosen in one locked step; wait only while
            // renderingDeadline - GPU p95 - margin leaves budget (never past the old 5 ms), else reproject.
            let targetNs = layerClockNs(timing.presentationTime)
            let waitDeadlineNs = FramePacing.waitDeadlineNs(startNs: layerClockNs(LayerRenderer.Clock().now), renderingDeadlineNs: layerClockNs(timing.renderingDeadline), gpuP95Ns: gpuTimes.p95Ns(), marginNs: FramePacing.marginNs)
            while true {
                objc_sync_enter(EventHandler.shared.frameQueueLock)
                let lastFrame = EventHandler.shared.lastQueued.frame
                let choice = FramePacing.choose(queue: EventHandler.shared.frameQueue.map { $0.timestamp }, targetNs: targetNs, lastTimestamp: lastFrame?.timestamp, lastSubmitted: lastFrame == nil || lastFrame!.timestamp == EventHandler.shared.lastSubmittedTimestamp, canWait: FramePacing.budgetRemains(nowNs: layerClockNs(LayerRenderer.Clock().now), waitDeadlineNs: waitDeadlineNs))
                if case .queued(let index) = choice {
                    queuedFrame = EventHandler.shared.frameQueue[index]
                    EventHandler.shared.frameQueue.removeFirst(index + 1)
                    selectionSkipped = index
                }
                objc_sync_exit(EventHandler.shared.frameQueueLock)

                switch choice {
                case .queued:
                    selectionSource = .new
                case .retry:
                    queuedFrame = lastFrame
                    EventHandler.shared.framesRendered -= 1
                    isReprojected = false
                    selectionSource = .retry
                case .reuse:
                    queuedFrame = lastFrame
                    EventHandler.shared.framesRendered -= 1
                    isReprojected = true
                    selectionSource = .reuse
                case .none:
                    break
                case .wait:
                    sched_yield()
                    continue
                }
                break
            }
        }
        StreamTelemetry.shared.recordSelection(timestampNs: queuedFrame?.timestamp, source: selectionSource, pollWaitNs: UInt64(max(CACurrentMediaTime() - startPollTime, 0) * Double(NSEC_PER_SEC)), skipped: selectionSkipped)

        if queuedFrame == nil && streamingActiveForFrame {
            streamingActiveForFrame = false
        }
        let renderingStreaming = streamingActiveForFrame && queuedFrame != nil
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

#if XCODE_BETA_26
        // MTLSize(width: 4338, height: 3478, depth: 1) MTLSize(width: 1888, height: 1792, depth: 1) by default
        // MTLSize(width: 6262, height: 5020, depth: 1) MTLSize(width: 2496, height: 2432, depth: 1) at 1.0 render quality
        var mainDrawable = LayerRenderer.Drawable()
        var drawables: [LayerRenderer.Drawable] = []
        if #available(visionOS 26.0, *) {
            drawables = frame.queryDrawables()
            if drawables.isEmpty {
                if queuedFrame != nil {
                    EventHandler.shared.lastQueued.frame = queuedFrame
                }
                return
            }
            mainDrawable = drawables[0]
            //print(drawable.rasterizationRateMaps[0].screenSize, drawable.rasterizationRateMaps[0].physicalSize(layer: 0))
        }
        else {
            guard let _drawable = frame.queryDrawable() else {
                if queuedFrame != nil {
                    EventHandler.shared.lastQueued.frame = queuedFrame
                }
                return
            }
            mainDrawable = _drawable
            drawables = [_drawable]
        }
#else
        guard let _drawable = frame.queryDrawable() else {
            if queuedFrame != nil {
                EventHandler.shared.lastQueued.frame = queuedFrame
            }
            return
        }
        var mainDrawable = _drawable
        var drawables: [LayerRenderer.Drawable] = [_drawable]
#endif
        
        let nalViewsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        defer { nalViewsPtr.deallocate() }
        
        if queuedFrame != nil && !queuedFrame!.viewParamsValid /*&& EventHandler.shared.lastSubmittedTimestamp != queuedFrame!.timestamp*/ {
            alvr_report_compositor_start(queuedFrame!.timestamp, nalViewsPtr)
            queuedFrame = QueuedFrame(imageBuffer: queuedFrame!.imageBuffer, timestamp: queuedFrame!.timestamp, viewParamsValid: true, viewParams: [nalViewsPtr[0], nalViewsPtr[1]], videoFormat: queuedFrame!.videoFormat, stream: queuedFrame!.stream)
        }

        if EventHandler.shared.alvrInitialized && streamingActiveForFrame {
            let settings = ALVRClientApp.gStore.settings
            var ipd = mainDrawable.views.count > 1 ? simd_length(mainDrawable.views[0].transform.columns.3 - mainDrawable.views[1].transform.columns.3) : 0.063
#if targetEnvironment(simulator)
            ipd = 0.063
            print(EventHandler.shared.lastIpd)
#endif
            if abs(EventHandler.shared.lastIpd - ipd) > 0.001 {
                print("Send view config")
                
                if EventHandler.shared.lastIpd != -1 {
                    print("IPD changed!", EventHandler.shared.lastIpd, "->", ipd)
                }
                else {
                    print("IPD is", ipd)
                    EventHandler.shared.framesRendered = 0
                    lastReconfigureTime = CACurrentMediaTime()
                    
                    let rebuildThread = Thread {
                        self.rebuildRenderPipelines(chromaKey: chromaKey)
                    }
                    rebuildThread.name = "Rebuild Render Pipelines Thread"
                    rebuildThread.start()
                }
                
                // TODO: Fix tangents to fill entire FoV if canting ever becomes more intense like PFD was
                // One view (visionOS simulator): both eyes come from view 0, placed -/+ ipd/2 apart (ViewLayout).
                let eyeViews = ViewLayout.sourceViewIndices(viewCount: mainDrawable.views.count)
                let eyeTransforms = ViewLayout.eyeTransforms(viewTransforms: mainDrawable.views.map { $0.transform }, ipd: ipd)
                let tangentsLeft = mainDrawable.gimmeTangents(viewIndex: eyeViews[0])
                let tangentsRight = mainDrawable.gimmeTangents(viewIndex: eyeViews[1])
                let transformLeft = eyeTransforms[0]
                let transformRight = eyeTransforms[1]
                // gimmeTangents is (left, right, bottom, top): up comes from .w (docs/lumen/fov-updown.md).
                // -ALVRDebugEyeTangents (off unless given): pack those per-eye tangents instead; realViewTangents stays the drawable's.
                // Otherwise "Crop FOV to outline" packs the model lens's inset rectangle + margin (CropFov, docs/lumen/crop-fov.md).
                // The frame quad is drawn on the sent tangents (uniforms.tangents) under the device projection.
                let debugEyes = DebugEyeTangents.current
                let cropInset = CropFov.inset
                // The logical grid (rate map screen size, else the view's viewport) over the device frustum: px per tangent unit.
                // The connect-time recommendation uses the last measured grid (reference device's until then); recommended= in
                // fov_sent shows what was sent, render_1to1= what the frame sent now needs.
                let viewport = mainDrawable.views[eyeViews[0]].textureMap.viewport
                let screen = mainDrawable.rasterizationRateMaps.first?.screenSize
                CropFov.recordGrid(screenWidth: screen?.width ?? Int(viewport.width), screenHeight: screen?.height ?? Int(viewport.height),
                                   device: tangentsLeft)
                let sent = CropFov.choose(device: [tangentsLeft, tangentsRight], debug: debugEyes?.tangents,
                                          crop: settings.cropFovToOutline, insetDeg: cropInset, marginDeg: settings.cropMarginDeg)
                let leftAngles = ViewLayout.fovAngles(tangents: sent.tangents[0], scale: settings.fovRenderScale)
                let rightAngles = debugEyes != nil || mainDrawable.views.count > 1
                    ? ViewLayout.fovAngles(tangents: sent.tangents[1], scale: settings.fovRenderScale) : leftAngles
                let leftFov = AlvrFov(left: leftAngles.left, right: leftAngles.right, up: leftAngles.up, down: leftAngles.down)
                let rightFov = AlvrFov(left: rightAngles.left, right: rightAngles.right, up: rightAngles.up, down: rightAngles.down)

                let (leftFovCorrected, tangentsLeftCorrected, transformLeftCorrected) = mainDrawable._cantedViewToProportionalCircumscribedOrthogonal(fov: leftFov, viewTransform: transformLeft, fovPostScale: 1.0)
                let (rightFovCorrected, tangentsRightCorrected, transformRightCorrected) = mainDrawable._cantedViewToProportionalCircumscribedOrthogonal(fov: rightFov, viewTransform: transformRight, fovPostScale: 1.0)
                // The band centre on the sent frame's eye axis, for the session's centre size; the server takes the
                // shift from its session settings only, so the log shows both.
                let foveation = Settings.getAlvrSettings()?.video.foveated_encoding
                let sentGimme = [leftFovCorrected, rightFovCorrected].map { simd_float4(tan(-$0.left), tan($0.right), tan(-$0.down), tan($0.up)) }
                let axisShift = foveation.map { CropFov.centerShift(left: sentGimme[0], right: sentGimme[1],
                                                                     centerSize: [Double($0.centerSizeX), Double($0.centerSizeY)]) }
                let sessionShift = foveation.map { SIMD2<Double>(Double($0.centerShiftX), Double($0.centerShiftY)) }
                let sentSizes = sent.tangents.map { CropFov.oneToOne(density: CropFov.grid.density, sent: $0) }
                let render1to1 = (sentSizes.map(\.width).max() ?? 0, sentSizes.map(\.height).max() ?? 0)
                let recommended = EventHandler.shared.recommendedViewResolution.map { ($0.width, $0.height) }
                for (eye, fov) in [("L", leftFovCorrected), ("R", rightFovCorrected)] {
                    let crop = sent.source == "crop"
                    Diag.log("fov_sent", ViewLayout.fovSentFields(eye: eye, left: fov.left, right: fov.right, up: fov.up, down: fov.down,
                                                                  source: sent.source, marginDeg: crop ? settings.cropMarginDeg : nil,
                                                                  insetDeg: crop ? cropInset : 0, offsetDeg: crop ? 0 : nil,
                                                                  axisCenterShift: axisShift, sessionCenterShift: sessionShift,
                                                                  render1to1: crop ? render1to1 : nil, recommended: recommended))
                }

                EventHandler.shared.viewFovsBox.set([leftFovCorrected, rightFovCorrected])
                if let debugEyes {
                    EventHandler.shared.debugEyeTangentsRecord = DebugEyeTangents.captureRecord(
                        argument: debugEyes.argument, requested: debugEyes.tangents, fovRenderScale: settings.fovRenderScale,
                        reportedAngles: [leftFovCorrected, rightFovCorrected].map { simd_float4($0.left, $0.right, $0.up, $0.down) })
                }
                EventHandler.shared.viewTransforms = [fixTransform(transformLeftCorrected), fixTransform(transformRightCorrected)]
                // Wait, is this correct?
                if mainDrawable.views.count > 1 {
                    EventHandler.shared.sentViewTangents = [tangentsLeftCorrected, tangentsRightCorrected]
                    EventHandler.shared.realViewTangents = [tangentsLeft, tangentsRight]
                }
                else {
                    EventHandler.shared.sentViewTangents = [tangentsLeftCorrected, tangentsRightCorrected]
                    EventHandler.shared.realViewTangents = [tangentsLeft, tangentsLeft]
                }
                
                
                // Sets lastIpd under the lock that serialises fake tracking sends.
                EventHandler.shared.sendRealViewParams(ipd: ipd)
            }
            
            // Encoding gamma travels with the stream's colour state (a new stream is a new state, so it rebuilds below).
            var needsPipelineRebuild = false

            if CACurrentMediaTime() - lastReconfigureTime > 1.0 && (chromaKey.enabled != chromaKeyEnabled || chromaKey.colour != chromaKeyColor || chromaKey.range != chromaKeyLerpDistRange) {
                chromaKeyEnabled = chromaKey.enabled
                chromaKeyColor = chromaKey.colour
                chromaKeyLerpDistRange = chromaKey.range
                lastReconfigureTime = CACurrentMediaTime()
                needsPipelineRebuild = true
            }
            
            // Any change of the frame's colour state (yuv, gamut, PQ) rebuilds; until the matching pipelines are
            // published the frame is not drawn (beginRenderStreamingFrame).
            if let queuedFrame, let colour = VideoHandler.streamColourState(for: queuedFrame, realityKit: isRealityKit, displayHeadroom: displayHeadroom), videoPipelinesNeedBuild(for: colour) {
                needsPipelineRebuild = true
            }

            if needsPipelineRebuild {
                lastReconfigureTime = CACurrentMediaTime()
                let rebuildThread = Thread {
                    self.rebuildRenderPipelines(chromaKey: chromaKey)
                }
                rebuildThread.name = "Rebuild Render Pipelines Thread"
                rebuildThread.start()
            }
        }
        
        //checkEyes(drawable: mainDrawable)
        
        if !renderOwnership.offlineDiagnostics {
            objc_sync_enter(EventHandler.shared.frameQueueLock)
            EventHandler.shared.framesSinceLastDecode += 1
            objc_sync_exit(EventHandler.shared.frameQueueLock)
        }
        
        if queuedFrame != nil && !queuedFrame!.viewParamsValid {
            print("aaaaaaaa bad view params")
        }
        
        let vsyncTime = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.presentationTime).timeInterval
        let vsyncTimeNs = UInt64(vsyncTime * Double(NSEC_PER_SEC))
        let framePreviouslyPredictedPose = queuedFrame != nil ? WorldTracker.shared.convertSteamVRViewPose(queuedFrame!.viewParams) : nil
        if ALVRClientApp.gStore.settings.showPerformanceHud {
            PerformanceTracker.shared.recordFramePresentation(presentationTime: mainDrawable.frameTiming.presentationTime, timestampNs: queuedFrame?.timestamp)
            PerformanceTracker.shared.logIfNeeded(presentationTime: mainDrawable.frameTiming.presentationTime)
        }
        
        // Do NOT move this, just in case, because DeviceAnchor is wonkey and every DeviceAnchor mutates each other.
        if !renderOwnership.offlineDiagnostics && EventHandler.shared.alvrInitialized && EventHandler.shared.lastIpd != -1 {
            if #available(visionOS 2.0, *) {
                if mainDrawable.views.count > 1 {
                    EventHandler.shared.viewTransforms = [fixTransform(mainDrawable.views[0].transform), fixTransform(mainDrawable.views[1].transform)]
                }
                else {
                    // Same eyes as the view config sent above, so the server and convertSteamVRViewPose agree.
                    EventHandler.shared.viewTransforms = ViewLayout.eyeTransforms(viewTransforms: mainDrawable.views.map { $0.transform }, ipd: EventHandler.shared.lastIpd).map { fixTransform($0) }
                }
            }
            // TODO: I suspect Apple changes view transforms every frame to account for pupil swim, figure out how to fit the latest view transforms in?
            // Since pupil swim is purely an axial thing, maybe we can just timewarp the view transforms as well idk
            let viewFovs = EventHandler.shared.viewFovsBox.get()
            let viewTransforms = EventHandler.shared.viewTransforms

            let targetTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))//LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval

            if !ALVRClientApp.gStore.settings.targetHandsAtRoundtripLatency {
                if #available(visionOS 2.0, *) {
                    anchorTimestamp = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval
                }
                else {
                    anchorTimestamp = LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.renderingDeadline).timeInterval
                }
            }

            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)
        }
        else if !renderOwnership.offlineDiagnostics {
            EventHandler.shared.sendBootstrapTrackingIfNeeded()
#if DEBUG_ALVR_TRACKING
            let viewFovs = EventHandler.shared.viewFovsBox.get()
            let viewTransforms = EventHandler.shared.viewTransforms

            let targetTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))
            let reportedTargetTimestamp = vsyncTime
            var anchorTimestamp = vsyncTime// + (Double(min(alvr_get_head_prediction_offset_ns(), WorldTracker.maxPrediction)) / Double(NSEC_PER_SEC))//LayerRenderer.Clock.Instant.epoch.duration(to: mainDrawable.frameTiming.trackableAnchorTime).timeInterval
            
            WorldTracker.shared.sendTracking(viewTransforms: viewTransforms, viewFovs: viewFovs, targetTimestamp: targetTimestamp, reportedTargetTimestamp: reportedTargetTimestamp, anchorTimestamp: anchorTimestamp, delay: 0.0)
#endif
        }
        
        let deviceAnchor = WorldTracker.shared.worldTracking.queryDeviceAnchor(atTimestamp: vsyncTime)
        
        let gpuTimes = self.gpuTimes
        let diagProbe = self.diagProbe
        let diagTiming = Diag.capture(enabled: diagProbe != nil, DiagRenderProbe.timing(for: mainDrawable))
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            let completionNs = UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC))
            if let diagTiming { diagProbe?.completed(commandBuffer, timing: diagTiming, callbackHostNs: completionNs) }
            if commandBuffer.gpuEndTime > commandBuffer.gpuStartTime {
                gpuTimes.add(ns: UInt64((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * Double(NSEC_PER_SEC)))
            }
            if queuedFrame != nil {
                StreamTelemetry.shared.recordSubmitTiming(vsyncNs: vsyncTimeNs, completionNs: completionNs)
            }
            if EventHandler.shared.alvrInitialized && queuedFrame != nil && EventHandler.shared.lastSubmittedTimestamp != queuedFrame?.timestamp {
                let currentTimeNs = completionNs

                //let currentTimeNs = UInt64(commandBuffer.gpuEndTime * Double(NSEC_PER_SEC))
                //let actualRenderTimeNs = UInt64((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * Double(NSEC_PER_SEC))
                //print((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000.0)

                //print("Finished:", queuedFrame!.timestamp)
                // Saturated at 0: a late completion used to wrap to ~1.8e19 ns; lateness goes to ALVRSTATS.
                alvr_report_submit(queuedFrame!.timestamp, FramePacing.submitQueueNs(vsyncNs: vsyncTimeNs, completionNs: currentTimeNs))

                EventHandler.shared.lastSubmittedTimestamp = queuedFrame!.timestamp
            }
            if ALVRClientApp.gStore.settings.showPerformanceHud, let ts = queuedFrame?.timestamp {
                PerformanceTracker.shared.recordSubmit(timestampNs: ts)
                PerformanceTracker.shared.recordGpu(timestampNs: ts, gpuStartTime: commandBuffer.gpuStartTime, gpuEndTime: commandBuffer.gpuEndTime)
            }
        }

        // List of reasons to not display a frame
        var frameIsSuitableForDisplaying = true
        //print(EventHandler.shared.lastIpd, WorldTracker.shared.worldTrackingAddedOriginAnchor, EventHandler.shared.framesRendered)
        if EventHandler.shared.lastIpd == -1 || EventHandler.shared.framesRendered < Int(refreshRate) {
            // Don't show frame if we haven't sent the view config and received frames
            // with that config applied.
            frameIsSuitableForDisplaying = false
            print("IPD is bad, no frame", EventHandler.shared.framesRendered)
        }
        if !WorldTracker.shared.worldTrackingAddedOriginAnchor && EventHandler.shared.framesRendered < 300 {
            // Don't show frame if we haven't figured out our origin yet.
            frameIsSuitableForDisplaying = false
            print("Origin is bad, no frame")
        }
        if EventHandler.shared.decoder.format == nil {
            frameIsSuitableForDisplaying = false
            print("Missing video format, no frame")
        }
        StreamTelemetry.shared.recordRender(frameTimestampNs: queuedFrame?.timestamp, displayed: renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil, presentNs: vsyncTimeNs)
        let telemetryViewport0 = mainDrawable.views[0].textureMap.viewport
        let telemetryViewport1 = mainDrawable.views.count > 1 ? mainDrawable.views[1].textureMap.viewport : MTLViewport()
        StreamTelemetry.shared.noteDrawable(pixelFormat: mainDrawable.colorTextures[0].pixelFormat.rawValue, view0Width: Int(telemetryViewport0.width), view0Height: Int(telemetryViewport0.height), view1Width: Int(telemetryViewport1.width), view1Height: Int(telemetryViewport1.height))

        if !(renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil) {
            // Things to do once if no frame is rendering (show the wireframe)
            if EventHandler.shared.totalFramesRendered > 300 {
                fadeInOverlayAlpha += 0.02
            }
        }
        else {
            // Things to do if a frame is rendering (fade wireframe, or show wireframe is reprojection is too long)
            fadeInOverlayAlpha -= 0.01
            if fadeInOverlayAlpha < 0.0 {
                fadeInOverlayAlpha = 0.0
            }
            
            if isReprojected && useApplesReprojection {
                LayerRenderer.Clock().wait(until: mainDrawable.frameTiming.renderingDeadline)
            }
            
            if isReprojected {
                reprojectedFramesInARow += 1
                if reprojectedFramesInARow > Int(refreshRate) {
                    fadeInOverlayAlpha += 0.02
                }
            }
            else {
                reprojectedFramesInARow = 0
                fadeInOverlayAlpha -= 0.02
            }
        }

        
        if ALVRClientApp.gStore.settings.showPerformanceHud,
           renderingStreaming,
           frameIsSuitableForDisplaying,
           let queuedFrame {
            PerformanceTracker.shared.recordCompositorStart(timestampNs: queuedFrame.timestamp)
        }
        // Diagnostics: the video frame actually encoded this frame (nil: idle, or rejected by beginRenderStreamingFrame).
        var diagSourceId: UInt64? = nil
        var diagStreamFrame = false   // stream content composited this frame (streaming capture trigger)
        var diagPose: DiagFrameCapture.PoseRecord? = nil   // render vs display head pose of that frame (capture.json "pose")
        for drawable in drawables {
            drawable.deviceAnchor = deviceAnchor
            
            // TODO: check layerRenderer.configuration.layout == .layered ?
            let viewports = drawable.views.map { $0.textureMap.viewport }
            let rasterizationRateMap = drawable.rasterizationRateMaps.first
            let viewTransforms = drawable.views.map { $0.transform }
            let sentViewTangents = drawable.views.enumerated().map { (idx, v) in EventHandler.shared.sentViewTangents[idx] }
            let realViewTangents = drawable.views.enumerated().map { (idx, v) in EventHandler.shared.realViewTangents[idx] }
            let nearZ =  Double(drawable.depthRange.y)
            let farZ = Double(drawable.depthRange.x)
            let simdDeviceAnchor = WorldTracker.shared.floorCorrectionTransform.asFloat4x4() * (deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4)
            let framePose = framePreviouslyPredictedPose ?? matrix_identity_float4x4
            
#if DEBUG_ALVR_TRACKING
            WorldTracker.shared.lockDebuggables()
            
            let headDebug = (simdDeviceAnchor.columns.3.asFloat3() - simdDeviceAnchor.columns.2.asFloat3()).asFloat4x4() * simdDeviceAnchor.orientationOnly().asFloat4x4()
            WorldTracker.shared.addDebuggablePose(headDebug, 0.1)
            
            for transform in viewTransforms {
                let mat = headDebug * transform
                WorldTracker.shared.addDebuggablePose(mat, 0.05)
            }
            
            WorldTracker.shared.unlockDebuggables()
#endif
            
            if let goldenFrame, goldenFrame.active, let layerRenderer {
                reprojectedFramesInARow = 0
                goldenFrame.encode(renderer: self, commandBuffer: commandBuffer, layer: layerRenderer, drawable: drawable, viewports: viewports,
                                   viewTransforms: viewTransforms, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap,
                                   simdDeviceAnchor: simdDeviceAnchor)
            }
            else if renderingStreaming && frameIsSuitableForDisplaying && queuedFrame != nil {
                //print("render")
                if let encoder = beginRenderStreamingFrame(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable) {
                    diagSourceId = Diag.capture(enabled: diagProbe != nil, queuedFrame?.timestamp) ?? nil
                    diagStreamFrame = true
                    if diagFrameCapture != nil, let frame = queuedFrame {
                        let dither = WorldTracker.shared.simYawDither(timestampNs: frame.timestamp).map { Double($0) }
                        diagPose = (render: framePose, display: simdDeviceAnchor, renderT: Double(frame.timestamp) / Double(NSEC_PER_SEC),
                                    displayT: vsyncTime, simYawDitherRad: dither)
                    }
                    renderStreamingFrame(0, commandBuffer: commandBuffer, renderEncoder: encoder, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
                    endRenderStreamingFrame(renderEncoder: encoder)
                }
                renderStreamingFrameOverlays(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable)
            }
            else if let cornerChart, !renderingStreaming {
                reprojectedFramesInARow = 0
                cornerChart.encode(commandBuffer: commandBuffer, drawable: drawable, viewports: viewports, rasterizationRateMap: rasterizationRateMap)
            }
            else if let resolutionChart, let layerRenderer, !renderingStreaming {
                reprojectedFramesInARow = 0
                // drawableIndex is only the rrm log's drawable= field. This loop has no index (the streaming calls above
                // pass 0 too), so with several drawables per frame their samples all log drawable=0.
                resolutionChart.encode(commandBuffer: commandBuffer, layer: layerRenderer, drawable: drawable, drawableIndex: 0,
                                       viewports: viewports, rasterizationRateMap: rasterizationRateMap)
            }
            else
            {
                reprojectedFramesInARow = 0;

                let noFramePose = simdDeviceAnchor
                // TODO: draw a cool loading logo
                renderNothing(0, commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor, drawable: drawable)
                
                renderOverlay(commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: noFramePose, simdDeviceAnchor: simdDeviceAnchor)
                if !isRealityKit {
                    renderStreamingFrameDepth(commandBuffer: commandBuffer, renderTargetColor: drawable.colorTextures[0], renderTargetDepth: drawable.depthTextures[0], viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame)
                }
            }
            
        }
        if let rqSweep, !EventHandler.shared.streamingActive {
            rqSweep.encode(layer: layerRenderer!, drawables: drawables, buffer: commandBuffer)
        }
        if DiagEye.shouldDraw(badgesEnabled: EyeBadgeFlag.shared.enabled, isRealityKit: isRealityKit), let layerRenderer {
            if diagEye == nil { diagEye = DiagEyeRenderer(layerRenderer) }
            for drawable in drawables {
                diagEye?.encode(buffer: commandBuffer, drawable: drawable, mode: diagSourceId == nil ? "idle" : "streaming",
                                generation: EventHandler.videoStreams.currentStream?.generation)
            }
        } else {
            diagEye = nil
        }
        diagFrameCapture?.encode(buffer: commandBuffer, drawables: drawables,
                                 idle: !renderingStreaming && !EventHandler.shared.streamingActive,
                                 streamFrame: diagStreamFrame, pose: diagPose, chart: cornerChart,
                                 stages: { self.diagStreamStageTargets(commandBuffer: commandBuffer) })
        diagStreamSource = nil
        for drawable in drawables {
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        if let diagTiming { diagProbe?.frame(layerRenderer: layerRenderer!, drawables: drawables, predicted: timing, sourceId: diagSourceId, timing: diagTiming) }

        coolPulsingColorsTime += 0.005
        if coolPulsingColorsTime > 4.0 {
            coolPulsingColorsTime = 0.0
        }
        
        if fadeInOverlayAlpha > 1.0 {
            fadeInOverlayAlpha = 1.0
        }
        if fadeInOverlayAlpha < 0.0 {
            fadeInOverlayAlpha = 0.0
        }
        
        commandBuffer.commit()
        frame.endSubmission()
        
        if !renderOwnership.offlineDiagnostics {
            EventHandler.shared.lastQueued.set(queuedFrame, pose: framePreviouslyPredictedPose)
        }
    }
    
    // Pulse the wireframe between cyan and blue.
    func coolPulsingColor() -> simd_float4 {
        // Color picked from the ALVR logo
        let lightColor = simd_float4(0.05624, 0.73124, 0.75999, 1.0)
        let darkColor = simd_float4(0.01305, 0.26223, 0.63828, 1.0)
        var switchingFnT: Float = 0.0 // hold on light
        
        if coolPulsingColorsTime >= 1.0 && coolPulsingColorsTime < 2.0 {
            switchingFnT = coolPulsingColorsTime - 1.0 // light -> dark
        }
        else if coolPulsingColorsTime >= 2.0 && coolPulsingColorsTime < 3.0 {
            switchingFnT = 1.0 // hold on dark
        }
        else if coolPulsingColorsTime >= 3.0 && coolPulsingColorsTime < 4.0 {
            switchingFnT = coolPulsingColorsTime - 2.0 // dark -> light
        }

        var switchingFn = sin(switchingFnT * Float.pi * 0.5)
        if coolPulsingColorsTime >= 4.0 {
            switchingFn = 0.0
        }
        return simd_mix(lightColor, darkColor, simd_float4(repeating: switchingFn))
    }
    
    // Can draw planes with debug colors, or with a subtle transparency change based on the type.
    func planeToColor(plane: PlaneAnchor) -> simd_float4 {
        let planeAlpha = fadeInOverlayAlpha
        var subtleChange = 0.75 + ((Float(plane.id.hashValue & 0xFF) / Float(0xff)) * 0.25)
        
        if drawPlanesWithInformedColors {
            switch(plane.classification) {
                case .ceiling: // #62ea80
                    return simd_float4(0.3843137254901961, 0.9176470588235294, 0.5019607843137255, 1.0) * subtleChange * planeAlpha
                case .door: // #1a5ff4
                    return simd_float4(0.10196078431372549, 0.37254901960784315, 0.9568627450980393, 1.0) * subtleChange * planeAlpha
                case .floor: // #bf6505
                    return simd_float4(0.7490196078431373, 0.396078431372549, 0.0196078431372549, 1.0) * subtleChange * planeAlpha
                case .seat: // #ef67af
                    return simd_float4(0.9372549019607843, 0.403921568627451, 0.6862745098039216, 1.0) * subtleChange * planeAlpha
                case .table: // #c937d3
                    return simd_float4(0.788235294117647, 0.21568627450980393, 0.8274509803921568, 1.0) * subtleChange * planeAlpha
                case .wall: // #dced5e
                    return simd_float4(0.8627450980392157, 0.9294117647058824, 0.3686274509803922, 1.0) * subtleChange * planeAlpha
                case .window: // #4aefce
                    return simd_float4(0.2901960784313726, 0.9372549019607843, 0.807843137254902, 1.0) * subtleChange * planeAlpha
                case .unknown: // #0e576b
                    return simd_float4(0.054901960784313725, 0.3411764705882353, 0.4196078431372549, 1.0) * subtleChange * planeAlpha
                case .undetermined: // #749606
                    return simd_float4(0.4549019607843137, 0.5882352941176471, 0.023529411764705882, 1.0) * subtleChange * planeAlpha
                default:
                    return simd_float4(1.0, 0.0, 0.0, 1.0) * subtleChange * planeAlpha // red
            }
        }
        else {
            if plane.classification == .ceiling {
                subtleChange *= 0.4
            }
            else if plane.classification == .wall {
                subtleChange *= 0.1
            }
            else if plane.classification == .floor {
                subtleChange *= 0.2
            }
            else if plane.classification == .seat {
                subtleChange *= 0.5
            }
            else {
                subtleChange = 0.01
            }
            return coolPulsingColor() * subtleChange * planeAlpha
        }
    }
    
    // Line color for a given ARKit Plane
    func planeToLineColor(plane: PlaneAnchor) -> simd_float4 {
        let planeAlpha = fadeInOverlayAlpha
        let subtleChange = 0.75 + ((Float(plane.id.hashValue & 0xFF) / Float(0xff)) * 0.25)
        
        if drawPlanesWithInformedColors {
            return planeToColor(plane: plane)
        }
        else {
            return coolPulsingColor() * subtleChange * planeAlpha
        }
    }
    
    // Only renders the frame depth, used to correct depth after the overlay is rendered
    // because Apple's Metal renderer is kinda weird about it.
    func renderStreamingFrameDepth(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .dontCare
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: (frameChromaKey?.enabled ?? chromaKeyEnabled) ? 0.0 : 1.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.000000001
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Rerender depth"
        
        renderEncoder.pushDebugGroup("Draw ALVR Frame Depth")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(videoFrameDepthPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlways)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    // Clears the render target, nothing more nothing less.
    func renderNothing(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = isRealityKit ? (whichIdx == 0 ? .clear : .load) : .clear 
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Rendering Nothing"
        
        renderEncoder.pushDebugGroup("Draw Nothing")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setRenderPipelineState(videoFrameDepthPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlways)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(fullscreenQuadBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
    }
    
    // Renders a wireframe overlay on top of the existing video frame (or nothing)
    func renderOverlay(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4],  nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4)
    {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
        // Toss out the depth buffer, keep colors
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Plane Render Encoder"
        renderEncoder.pushDebugGroup("Draw planes")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif

        WorldTracker.shared.lockPlaneAnchors()
        
        var firstBind = true
        if fadeInOverlayAlpha > 0.0 {
            // Render planes
            for planeEntry in WorldTracker.shared.planeAnchors {
                let plane = planeEntry.value
                let faces = plane.geometry.meshFaces
                
                // VRR can't do lines
                if faces.primitive != GeometryElement.Primitive.triangle {
                    continue
                }
                
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
                
                //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
                self.planeUniforms[0].planeColor = planeToColor(plane: plane)
                self.planeUniforms[0].planeDoProximity = 1.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.fill)
                renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                    indexCount: faces.count*3,
                                                    indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                    indexBuffer: faces.buffer,
                                                    indexBufferOffset: 0)
            }
            
            // Render lines
            for planeEntry in WorldTracker.shared.planeAnchors {
                let plane = planeEntry.value
                let faces = plane.geometry.meshFaces
                
                // VRR can't do lines
                if faces.primitive != GeometryElement.Primitive.triangle {
                    continue
                }
                
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)
                
                //self.updateGameStateForVideoFrame(drawable: drawable, framePose: framePose, planeTransform: plane.originFromAnchorTransform)
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
                self.planeUniforms[0].planeColor = planeToLineColor(plane: plane)
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                    indexCount: faces.count*3,
                                                    indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                    indexBuffer: faces.buffer,
                                                    indexBufferOffset: 0)
            }
        }
        
        WorldTracker.shared.unlockPlaneAnchors()
        
        WorldTracker.shared.lockDebuggables()
        
        // Render lines
        for i in 0..<WorldTracker.shared.debuggableMats.count {
            let matTransform = WorldTracker.shared.debuggableMats[i]
            let basisColors = [simd_float4(1.0, 0.0, 0.0, 1.0), simd_float4(0.0, 1.0, 0.0, 1.0), simd_float4(0.0, 0.0, 1.0, 1.0)]
            let basisScaleFactor: Float = WorldTracker.shared.debuggableScales[i]
            let basisScale = simd_float3x3(basisScaleFactor).asFloat4x4()
            
            for i in 0..<3 {
                renderEncoder.setVertexBuffer(unitVectorXYZBuffer, offset: 0, index: VertexAttribute.position.rawValue)
                renderEncoder.setVertexBuffer(unitVectorXYZBuffer, offset: (3*4)*4, index: VertexAttribute.texcoord.rawValue)
                
                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = (matTransform.columns.3.asFloat3()).asFloat4x4() * (basisScale * matTransform.orientationOnly().asFloat4x4())
                self.planeUniforms[0].planeColor = basisColors[i]
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }
                
                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 3*i, vertexCount: 3)
            }
        }

        // Render solid bodies (currently only the Steam Controller shell).
        if !WorldTracker.shared.debuggableMeshes.isEmpty, let meshBuffer = ibexMeshBuffer(), ibexMeshVertexCount > 0 {
            for (matTransform, color) in WorldTracker.shared.debuggableMeshes {
                renderEncoder.setVertexBuffer(meshBuffer, offset: 0, index: VertexAttribute.position.rawValue)
                // Texcoords are unused by the plane fragment shader, which is
                // flat-coloured — bind the position buffer again rather than
                // carrying a second one purely to satisfy the descriptor.
                renderEncoder.setVertexBuffer(meshBuffer, offset: 0, index: VertexAttribute.texcoord.rawValue)

                selectNextPlaneUniformBuffer()
                self.planeUniforms[0].planeTransform = matTransform
                self.planeUniforms[0].planeColor = color
                self.planeUniforms[0].planeDoProximity = 0.0
                if firstBind {
                    renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                    firstBind = false
                } else {
                    renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                }

                renderEncoder.setTriangleFillMode(.lines)
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ibexMeshVertexCount)
            }
        }

        WorldTracker.shared.debuggableMats = []
        WorldTracker.shared.debuggableScales = []
        WorldTracker.shared.debuggableMeshes = []
        WorldTracker.shared.unlockDebuggables()
        
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    // Renders the chaperone proximity overlay on top of the existing video frame.
    func renderChaperone(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], rasterizationRateMap: MTLRasterizationRateMap?, simdDeviceAnchor: simd_float4x4) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        renderEncoder.label = "Chaperone Render Encoder"
        renderEncoder.pushDebugGroup("Draw chaperone")
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue) // unused

        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthStateGreater)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif

        let planesSnapshot = WorldTracker.shared.snapshotPlaneData()
#if CHAPERONE_PROFILE
        let profileStart = CACurrentMediaTime()
#endif
        let output = chaperoneSystem.update(planes: planesSnapshot,
                                            headPose: simdDeviceAnchor,
                                            leftHandPose: WorldTracker.shared.lastLeftHandPose,
                                            rightHandPose: WorldTracker.shared.lastRightHandPose,
                                            worldFromSteamVR: WorldTracker.shared.worldTrackingSteamVRTransform,
                                            chaperoneDistanceCm: ALVRClientApp.gStore.settings.chaperoneDistanceCm,
                                            now: CACurrentMediaTime(),
                                            leftControllerPresent: WorldTracker.shared.leftControllerPose != nil,
                                            rightControllerPresent: WorldTracker.shared.rightControllerPose != nil) { isLeft, amplitude, duration in
            WorldTracker.shared.enqueueHapticsPulse(isLeft: isLeft, amplitude: amplitude, duration: duration)
        }

#if CHAPERONE_PROFILE
        let elapsedMs = (CACurrentMediaTime() - profileStart) * 1000.0
        chaperoneProfileAccumMs += elapsedMs
        chaperoneProfileSamples += 1
        chaperoneProfileWindow.append(elapsedMs)
        if chaperoneProfileWindow.count > chaperoneProfileWindowSize {
            chaperoneProfileWindow.removeFirst(chaperoneProfileWindow.count - chaperoneProfileWindowSize)
        }
        let now = CACurrentMediaTime()
        if now - chaperoneProfileLastLog > 2.0 {
            chaperoneProfileLastLog = now
            let avg = chaperoneProfileAccumMs / Double(max(1, chaperoneProfileSamples))
            let maxSample = chaperoneProfileWindow.max() ?? 0.0
            var median: Double = 0.0
            if !chaperoneProfileWindow.isEmpty {
                let sorted = chaperoneProfileWindow.sorted()
                median = sorted[sorted.count / 2]
            }
            let recomputeSamples = max(1, output.profile.recomputeSamples)
            let recomputePct = Int((Double(output.profile.recomputeTrue) / Double(recomputeSamples)) * 100.0)
            let avgRenderables = Double(output.profile.renderableCount) / Double(recomputeSamples)
            print("[ChaperoneProfile] avg=\(String(format: "%.3f", avg))ms median=\(String(format: "%.3f", median))ms max=\(String(format: "%.3f", maxSample))ms samples=\(chaperoneProfileSamples) planes=\(planesSnapshot.count) recompute=\(recomputePct)% exact=\(output.profile.exactProximityChecks) renderables=\(String(format: "%.1f", avgRenderables)) interval=\(output.profile.recomputeIntervalFrames)")
            chaperoneProfileAccumMs = 0.0
            chaperoneProfileSamples = 0
        }
#endif

        var firstBind = true
        for (plane, planeColor) in output.renderables {
            let faces = plane.geometry.meshFaces

            // VRR can't do lines
            if faces.primitive != GeometryElement.Primitive.triangle {
                continue
            }

            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.position.rawValue)
            renderEncoder.setVertexBuffer(plane.geometry.meshVertices.buffer, offset: 0, index: VertexAttribute.texcoord.rawValue)

            selectNextPlaneUniformBuffer()
            self.planeUniforms[0].planeTransform = plane.originFromAnchorTransform
            self.planeUniforms[0].planeColor = planeColor
            self.planeUniforms[0].planeDoProximity = 1.0
            if firstBind {
                renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset:planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
                firstBind = false
            } else {
                renderEncoder.setVertexBufferOffset(planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)
            }
            
            renderEncoder.setTriangleFillMode(.fill)
            renderEncoder.drawIndexedPrimitives(type: faces.primitive == .triangle ? MTLPrimitiveType.triangle : MTLPrimitiveType.line,
                                                indexCount: faces.count*3,
                                                indexType: faces.bytesPerIndex == 2 ? MTLIndexType.uint16 : MTLIndexType.uint32,
                                                indexBuffer: faces.buffer,
                                                indexBufferOffset: 0)
        }

        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }

    func renderPerformanceHud(commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], rasterizationRateMap: MTLRasterizationRateMap?, simdDeviceAnchor: simd_float4x4) {
        guard ALVRClientApp.gStore.settings.showPerformanceHud else { return }
        if performanceHudRenderer == nil {
            performanceHudRenderer = PerformanceHudRenderer(device: device)
        }
        guard let hudTexture = performanceHudRenderer?.updateIfNeeded() else { return }
        selectNextPlaneUniformBuffer()
        let worldFromSteamVR = WorldTracker.shared.worldTrackingSteamVRTransform
        let handPose = WorldTracker.shared.lastLeftHandPose
        let handWorld = worldFromSteamVR * handPose.asFloat4x4()
        let handPosition = handWorld.columns.3.asFloat3()
        var handRight = simd_normalize(handWorld.columns.0.asFloat3())
        let handUp = simd_normalize(handWorld.columns.1.asFloat3())
        let handForward = simd_normalize(handWorld.columns.2.asFloat3())
        if simd_length(handRight) < 0.001 || simd_length(handUp) < 0.001 || simd_length(handForward) < 0.001 {
            return
        }
        handRight = simd_normalize(handRight)
        // Hand axes derived from the current left-hand pose.
        // thumbAxis: toward thumb side of the hand (local +X).
        // palmAxis: palm normal (local +Y).
        // elbowAxis: from fingers toward wrist/elbow (local -Z).
        let thumbAxis = -handForward
        let palmAxis = handRight
        let elbowAxis = handUp

        // Panel axes in world space:
        // panelFront: the face normal of the panel (should align with palmAxis).
        // panelTopEdge: the top edge of the panel (should align with elbowAxis).
        // panelRightEdge: the right edge of the panel (perpendicular to both).
        let panelFront = simd_normalize(-palmAxis)
        var panelTopEdge = simd_normalize(-elbowAxis)
        var panelRightEdge = simd_normalize(-thumbAxis)
        let palmTwist = simd_quatf(angle: Float.pi / 180.0 * 20.0, axis: simd_normalize(palmAxis))
        panelTopEdge = simd_normalize(palmTwist.act(panelTopEdge))
        panelRightEdge = simd_normalize(palmTwist.act(panelRightEdge))
        let forearmDir = panelTopEdge

        // Orientation uses panelRightEdge (X), panelTopEdge (Y), panelFront (Z).
        let orientation = simd_float4x4(simd_float4(panelRightEdge, 0.0),
                                        simd_float4(panelTopEdge, 0.0),
                                        simd_float4(panelFront, 0.0),
                                        simd_float4(0.0, 0.0, 0.0, 1.0))
        // Position offsets:
        // offsetIn: shift toward the inner forearm (away from thumb).
        // offsetArm: shift toward elbow along the forearm.
        // offsetDown: move slightly into the arm to sit on the surface.
        let offsetIn = simd_float3()
        let offsetArm = -forearmDir * 0.10
        let offsetDown = panelFront * 0.025
        let offset = offsetIn + offsetArm + offsetDown
        let position = handPosition + offset
        let translation = position.asFloat4x4()
        let sizeY: Float = 0.07
        let aspect = Float(hudTexture.width) / Float(hudTexture.height)
        let sizeX: Float = sizeY * aspect
        let scale = simd_float4x4(simd_float4(sizeX, 0.0, 0.0, 0.0),
                                  simd_float4(0.0, sizeY, 0.0, 0.0),
                                  simd_float4(0.0, 0.0, 1.0, 0.0),
                                  simd_float4(0.0, 0.0, 0.0, 1.0))
        let transform = translation * orientation * scale

        self.planeUniforms[0].planeTransform = transform
        self.planeUniforms[0].planeColor = simd_float4(1.0, 1.0, 1.0, 1.0)
        self.planeUniforms[0].planeDoProximity = 0.0

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.depthAttachment.texture = renderTargetDepth
        renderPassDescriptor.depthAttachment.loadAction = .load
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 0.0
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        renderPassDescriptor.renderTargetArrayLength = viewports.count

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create HUD render encoder")
        }

        renderEncoder.label = "HUD Render Encoder"
        renderEncoder.setCullMode(.back)
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setViewports(viewports)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(dynamicPlaneUniformBuffer, offset: planeUniformBufferOffset, index: BufferIndex.planeUniforms.rawValue)

        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        renderEncoder.setRenderPipelineState(hudPipelineState)
        renderEncoder.setDepthStencilState(depthStateAlwaysNoWrite)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        renderEncoder.setVertexBuffer(hudQuadBuffer, offset: 0, index: VertexAttribute.position.rawValue)
        renderEncoder.setVertexBuffer(hudQuadBuffer, offset: (3 * 4) * 4, index: VertexAttribute.texcoord.rawValue)
        renderEncoder.setFragmentTexture(hudTexture, index: TextureIndex.color.rawValue)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
    }
    
    // Sets up rendering a video frame, including uniforms
    // golden (W35b, GoldenFrameRenderer): a static server pair with its own colour state and pipelines, so the stream's
    // colour cache, pipeline slot and decoder telemetry/taps are not touched; nil (every live call) is the live path.
    func beginRenderStreamingFrame(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?, golden: GoldenStreamSource? = nil) -> (any MTLRenderCommandEncoder)? {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return nil
        }
        
        // TODO refactor this
        if isRealityKit {
            fadeInOverlayAlpha -= 0.01
            if fadeInOverlayAlpha < 0.0 {
                fadeInOverlayAlpha = 0.0
            }
        }
    
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = renderTargetColor
        renderPassDescriptor.colorAttachments[0].loadAction = whichIdx == 0 ? (isRealityKit ? .dontCare : .clear) : .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: (frameChromaKey?.enabled ?? chromaKeyEnabled) ? 0.0 : 1.0)
        renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
        
        renderPassDescriptor.renderTargetArrayLength = viewports.count
        
        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }
        
        renderEncoder.label = "Primary Render Encoder"
        renderEncoder.pushDebugGroup("Draw ALVR Frames")
        
        guard let queuedFrame = queuedFrame else {
            renderEncoder.endEncoding()
            return nil
        }
        
        // https://cs.android.com/android/platform/superproject/main/+/main:external/webrtc/sdk/objc/components/renderer/metal/RTCMTLNV12Renderer.mm;l=108;drc=a81e9c82fc3fbc984f0f110407d1e44c9c01958a
        let pixelBuffer = queuedFrame.imageBuffer
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let formatStr = VideoHandler.coreVideoPixelFormatToStr[format, default: "unknown"]
        // The frame's own colour state and the pipelines built for exactly it (decision 63c (4)); otherwise request
        // them and skip this frame rather than draw it with another state's constants. PQ in a format with no raw
        // plane binding is dropped (decision 63e (1), logged once by VideoHandler).
        guard let colour = golden?.colour ?? VideoHandler.streamColourState(for: queuedFrame, realityKit: isRealityKit, displayHeadroom: displayHeadroom), !colour.dropFrames else {
            renderEncoder.endEncoding()
            return nil
        }
        guard let pipelines = golden?.pipelines ?? videoFramePipelines.pipelines(for: colour) else {
            if videoPipelinesNeedBuild(for: colour) {
                let chromaKey = frameChromaKey ?? ChromaKeySnapshot(settings: ALVRClientApp.gStore.settings)
                let rebuildThread = Thread {
                    self.rebuildRenderPipelines(chromaKey: chromaKey)
                }
                rebuildThread.name = "Rebuild Render Pipelines Thread"
                rebuildThread.start()
            }
            renderEncoder.endEncoding()
            return nil
        }

        // PQ: raw normalised planes of the frame's own depth on the explicit (PQ) shader, never a private *_sRGB
        // format (decision 63e (1)). SDR: bound as before.
        let textureTypes: [MTLPixelFormat]
        switch colour.binding {
        case .explicitPlanes(let bits):
            renderEncoder.setRenderPipelineState(pipelines.biplanar)
            textureTypes = bits == 8 ? [MTLPixelFormat.r8Unorm, MTLPixelFormat.rg8Unorm] : [MTLPixelFormat.r16Unorm, MTLPixelFormat.rg16Unorm]
        case .decoderDefault, .drop:
            if VideoHandler.isFormatSecret(format) {
                renderEncoder.setRenderPipelineState(pipelines.secret)
            }
            else {
                renderEncoder.setRenderPipelineState(pipelines.biplanar)
            }
            textureTypes = VideoHandler.getTextureTypesForFormat(format)
        }

        //print("Pixel format \(formatStr) (\(format))")
        if golden == nil { StreamTelemetry.shared.noteDecoderOutput(pixelFormat: format, lumaTextureFormat: textureTypes[0].rawValue, chromaTextureFormat: textureTypes[1].rawValue, name: formatStr) }

        var diagPlanes: [MTLTexture] = [], diagCVTextures: [CVMetalTexture] = []
        for i in 0...1 {
            var textureOut:CVMetalTexture! = nil
            var err:OSStatus = 0
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i)
            
            if textureTypes[i] == MTLPixelFormat.invalid {
                break
            }
            
            err = CVMetalTextureCacheCreateTextureFromImage(
                    nil, metalTextureCache, pixelBuffer, nil, textureTypes[i],
                    width, height, i, &textureOut);
            
            if err != 0, colour.hdrPQ {
                // A PQ plane the cache cannot expose raw: drop the frame rather than draw it another way.
                if !loggedPQBindFailures.contains(format) {
                    loggedPQBindFailures.insert(format)
                    print("ALVRCOLOUR pq_dropped pixel_format=\(ColourPipeline.fourCC(format)) plane=\(i) err=\(err): raw plane binding failed, frames dropped")
                }
                renderEncoder.endEncoding()
                return nil
            }
            if err != 0 {
                fatalError("CVMetalTextureCacheCreateTextureFromImage \(err)")
            }
            guard let metalTexture = CVMetalTextureGetTexture(textureOut) else {
                fatalError("CVMetalTextureGetTexture")
            }
            if !((metalTexture.debugDescription?.contains("decompressedPixelFormat") ?? true) || (metalTexture.debugDescription?.contains("isCompressed = 1") ?? true)) && EventHandler.shared.totalFramesRendered % 90*5 == 0 {
                print("NO COMPRESSION ON VT FRAME!!!! AAAAAAAAA go file feedback again :(")
            }
            renderEncoder.setFragmentTexture(metalTexture, index: i)
            if diagFrameCapture != nil { diagPlanes.append(metalTexture); diagCVTextures.append(textureOut) }
        }
        if diagFrameCapture != nil, golden == nil {
            var secret = false
            if case .explicitPlanes = colour.binding {} else { secret = VideoHandler.isFormatSecret(format) }
            diagStreamSource = (diagPlanes, diagCVTextures, secret, colour,
                                frameChromaKey ?? ChromaKeySnapshot(settings: ALVRClientApp.gStore.settings), format)
        }
        if golden == nil {
            if HDRProbe.enabled {
                HDRProbe.shared.sample(pixelBuffer: pixelBuffer, colour: colour)
            }
            EyeDecodeWindows.shared.tap(pixelBuffer: pixelBuffer, colour: colour, timestampNs: queuedFrame.timestamp)
        }
        
        // Snoop for pixel formats
        /*for idx in 620..<0xFFFF {
            guard let format = MTLPixelFormat.init(rawValue: UInt(idx)) else {
                continue
            }
            do {
                var desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MTLPixelFormat.invalid, width: 1, height:1, mipmapped: false)
                desc.pixelFormat = format
                for line in desc.debugDescription.split(separator: "\n") {
                    if line.contains("pixelFormat") {
                        print(idx, line)
                        break
                    }
                }
            }
            catch {
                continue
            }
        }*/
        
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.counterClockwise)
#if !targetEnvironment(simulator)
        renderEncoder.setDepthClipMode(.clamp)
#endif
        
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        return renderEncoder
    }
    
    // Actually do the video frame render.
    func renderStreamingFrame(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderEncoder: any MTLRenderCommandEncoder, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
        
        renderEncoder.setViewports(viewports)
        
        if viewports.count > 1 {
            var viewMappings = (0..<viewports.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: whichIdx*4, vertexCount: 4)
    }
    
    // Finish video frame encoding.
    func endRenderStreamingFrame(renderEncoder: any MTLRenderCommandEncoder) {
        renderEncoder.popDebugGroup()
        renderEncoder.endEncoding()
    }
    
    // Render an overlay on top of the video frame.
    func renderStreamingFrameOverlays(_ whichIdx: Int, commandBuffer: MTLCommandBuffer, renderTargetColor: MTLTexture, renderTargetDepth: MTLTexture, viewports: [MTLViewport], viewTransforms: [simd_float4x4], sentViewTangents: [simd_float4], realViewTangents: [simd_float4], nearZ: Double, farZ: Double, rasterizationRateMap: MTLRasterizationRateMap?, queuedFrame: QueuedFrame?, framePose: simd_float4x4, simdDeviceAnchor: simd_float4x4, drawable: LayerRenderer.Drawable?) {
        if currentRenderColorFormat != renderTargetColor.pixelFormat && isRealityKit {
            return
        }
    
        self.updateDynamicBufferState()
        
        self.updateGameStateForVideoFrame(whichIdx, drawable: drawable, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        
        if fadeInOverlayAlpha > 0.0 || WorldTracker.shared.debuggableMats.count > 0 || WorldTracker.shared.debuggableMeshes.count > 0 {
            // Not super kosher--we need the depth to be correct for the video frame box, but we can't have the view
            // outside of the video frame box be 0.0 depth or it won't get rastered by the compositor at all.
            // So we re-render the frame depth.
            renderOverlay(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame, framePose: framePose, simdDeviceAnchor: simdDeviceAnchor)
        }
        if ALVRClientApp.gStore.settings.chaperoneDistanceCm > 0 || chaperoneSystem.hasActiveState {
            renderChaperone(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, rasterizationRateMap: rasterizationRateMap, simdDeviceAnchor: simdDeviceAnchor)
        }
        if !isRealityKit {
            renderStreamingFrameDepth(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, viewTransforms: viewTransforms, sentViewTangents: sentViewTangents, realViewTangents: realViewTangents, nearZ: nearZ, farZ: farZ, rasterizationRateMap: rasterizationRateMap, queuedFrame: queuedFrame)
        }
        if !isRealityKit && ALVRClientApp.gStore.settings.showPerformanceHud {
            renderPerformanceHud(commandBuffer: commandBuffer, renderTargetColor: renderTargetColor, renderTargetDepth: renderTargetDepth, viewports: viewports, rasterizationRateMap: rasterizationRateMap, simdDeviceAnchor: simdDeviceAnchor)
        }
    }
}

// Sharpness-chain capture stages (docs/lumen/sharpness-chain.md, DiagStreamStages): on a capture frame, draws the decoded
// and the FFR-expanded stream of each eye with the stream's own fragment shader (same planes, sampler and colour
// constants) through diagStageVertexShader (no warp) into private textures of the stream pipeline's colour format.
// Pipelines are built per capture: debug path only, and captures are rare.
extension Renderer {
    func diagStreamStageTargets(commandBuffer: MTLCommandBuffer) -> [DiagFrameCapture.Target] {
        guard let source = diagStreamSource, let luma = source.planes.first,
              let foveation = videoFramePipelines.buildInputs()?.payload ?? nil else {
            Diag.log("capture", ["error": "stages_unavailable", "why": diagStreamSource == nil ? "no_stream_planes" : "no_foveation_vars"])
            return []
        }
        let variant = source.secret ? "SecretYpCbCrFormats" : "YpCbCrBiPlanar"
        let colorFormat = layerRenderer?.configuration.colorFormat ?? currentRenderColorFormat
        let unfoveated = FoveationVars(enabled: false, targetEyeWidth: foveation.targetEyeWidth, targetEyeHeight: foveation.targetEyeHeight,
                                       optimizedEyeWidth: foveation.optimizedEyeWidth, optimizedEyeHeight: foveation.optimizedEyeHeight,
                                       eyeWidthRatio: foveation.eyeWidthRatio, eyeHeightRatio: foveation.eyeHeightRatio,
                                       centerSizeX: foveation.centerSizeX, centerSizeY: foveation.centerSizeY,
                                       centerShiftX: foveation.centerShiftX, centerShiftY: foveation.centerShiftY,
                                       edgeRatioX: foveation.edgeRatioX, edgeRatioY: foveation.edgeRatioY)
        func pipeline(_ vars: FoveationVars) -> MTLRenderPipelineState? {
            try? buildRenderPipelineForVideoFrameWithDevice(device: device, mtlVertexDescriptor: mtlVertexDescriptor, colorFormat: colorFormat,
                                                            viewCount: 1, foveationVars: vars, colour: source.colour, chromaKey: source.chromaKey,
                                                            variantName: variant, vertexShaderName: "diagStageVertexShader")
        }
        guard let decodedPipeline = pipeline(unfoveated), let expandedPipeline = pipeline(foveation) else {
            Diag.log("capture", ["error": "stage_pipeline_failed", "variant": variant])
            return []
        }
        let planes = source.planes.map { (format: DiagFrameCapture.formatName($0.pixelFormat), width: $0.width, height: $0.height) }
        let decoderFormat = ColourPipeline.fourCC(source.pixelFormat)
        var targets: [DiagFrameCapture.Target] = []
        for plan in DiagStreamStages.plans(decodedWidth: luma.width, decodedHeight: luma.height, viewWidth: Int(foveation.targetEyeWidth),
                                           viewHeight: Int(foveation.targetEyeHeight), ffr: foveation.enabled) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: plan.width, height: plan.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = .renderTarget
            let pass = MTLRenderPassDescriptor()
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                Diag.log("capture", ["error": "stage_texture_allocation_failed", "stage": plan.stage, "eye": plan.eye])
                return []
            }
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return [] }
            encoder.label = "Diagnostic stream stage \(plan.stage) \(plan.eye)"
            encoder.setRenderPipelineState(plan.ffr ? expandedPipeline : decodedPipeline)
            var rect = plan.uvRect
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            for (index, plane) in source.planes.enumerated() {
                encoder.setFragmentTexture(plane, index: index)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            targets.append(DiagFrameCapture.Target(texture: texture, views: [], rateMap: nil, drawableIndex: -1,
                                                   stage: DiagStreamStages.record(plan, planes: planes, shader: "videoFrameFragmentShader_" + variant,
                                                                                  decoderPixelFormat: decoderFormat)))
        }
        let retained = source.cvTextures   // the planes' CoreVideo backing lives until the stage passes have run
        commandBuffer.addCompletedHandler { _ in _ = retained }
        return targets
    }
}
