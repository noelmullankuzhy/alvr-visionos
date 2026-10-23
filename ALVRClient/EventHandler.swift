//
//  EventHandler.swift
//
// ALVR client framework glue code, this thread is basically
// always running and includes a self-managing watchdog to
// ensure it is always running.
//
// Other notable things include:
// - mDNS/Bonjour management (handleMdnsBroadcasts)
// - Connection flavor text and versioning info for Entry UI
// - The main event thread (handleAlvrEvents)
//

import Foundation
import Metal
import VideoToolbox
import Combine
import AVKit
import Foundation
import Network
import UIKit

final class OutgoingWorker {
    private var currentIdxLock = NSCondition()
    private var condition = [NSCondition(), NSCondition(), NSCondition()]
    private var pendingWork: [(() -> Void)?] = [nil, nil, nil]
    private var shouldStop = false
    private var outgoingThreads: [Thread?] = [nil, nil, nil]
    private var currentIdx: Int = 0
    private var name: String = ""

    init(_ name: String = "") {
        self.name = name
        restartWorkers()
    }

    func enqueue(_ work: @escaping () -> Void) {
        currentIdxLock.lock()
        
        if shouldStop {
            restartWorkers()
        }
        
        condition[currentIdx].lock()
        pendingWork[currentIdx] = work
        condition[currentIdx].signal()
        condition[currentIdx].unlock()
        
        currentIdx = (currentIdx + 1) % 3
        currentIdxLock.unlock()
    }

    private func threadMain(_ idx: Int) {
        print((Thread.current.name ?? "OutgoingWorker Unknown") + " starting.")
        condition[idx].lock()
        while !shouldStop {
            while pendingWork[idx] == nil {
                condition[idx].wait()
                if shouldStop {
                    break
                }
            }
            let work = pendingWork[idx]!
            pendingWork[idx] = nil
            condition[idx].unlock()

            work()

            condition[idx].lock()
        }
        print((Thread.current.name ?? "OutgoingWorker Unknown") + " stopped.")
        condition[idx].unlock()
    }
    
    func stopWorkers() {
        print("Stopping all OutgoingWorkers.")
        currentIdxLock.lock()
        shouldStop = true
        for i in 0..<3 {
            outgoingThreads[i]?.cancel()
        }
        currentIdxLock.unlock()
    }
    
    func restartWorkers() {
        print("Starting all OutgoingWorkers.")
        currentIdxLock.lock()
        for i in 0..<3 {
            outgoingThreads[i] = Thread {
                self.threadMain(i)
            }
            outgoingThreads[i]?.qualityOfService = .userInteractive
            outgoingThreads[i]?.name = self.name + " " + String(i)
            outgoingThreads[i]?.start()
            
            pendingWork[i] = nil
            condition[i] = NSCondition()
        }
        
        shouldStop = false
        currentIdxLock.unlock()
    }
}

class EventHandler: ObservableObject {
    static let shared = EventHandler()
    // The current stream's immutable video inputs and generation (decision 63e (2), (3)), captured at
    // STREAMING_STARTED; the payload is the stream's foveation. Renderer.videoFramePipelines runs under its lock.
    static let videoStreams = VideoStreamGate<FoveationVars?>()

    var outgoingWorker : OutgoingWorker = OutgoingWorker("Outgoing Data")
    var trackingWorker : OutgoingWorker = OutgoingWorker("Tracking Worker")
    var eventsThread : Thread?
    var eventsWatchThread : Thread?
        
    var alvrInitialized = false
    var streamingActive = false {
        willSet { if Diag.isOn { DiagWorkGate.setStreaming(newValue) } }
    }
    
    
    @Published var connectionState: ConnectionState = .disconnected
    @Published var hostname: String = ""
    @Published var IP: String = ""
    @Published var alvrVersion: String = ""
    @Published var hostAlvrVersion: String = ""
    @Published var connectionFlavorText: String = ""
    
    var hostAlvrMajor = 20
    var hostAlvrMinor = 11
    var hostAlvrRevision = 0
    
    var renderStarted = false
    
    var inputRunning = false
    // stop() tears the decoder down on the event thread while handleNals copies it on the decode thread: the session,
    // its format and its codec live only in this slot, and the decode thread takes them in one snapshot.
    let decoder = DecoderSlot<VTDecompressionSession, CMFormatDescription>()
    var av1InstantiatedForReal = false
    var frameQueueLock = NSObject()
    // -ALVRAsyncDecode YES: pipelined hardware decode, at most DecodeInFlight.limit frames in flight; nil decodes synchronously.
    let asyncDecode: DecodeGate? = LaunchFlags.bool(DecodeInFlight.asyncDefaultsKey, setting: ALVRClientApp.gStore.settings.asyncDecode) ? DecodeGate() : nil

    var frameQueue = [QueuedFrame]()
    var frameQueueLastTimestamp: UInt64 = 0
    var frameQueueLastImageBuffer: CVImageBuffer? = nil
    // The last submitted frame and its pose: render threads set them, stop() clears them on the event thread, so every
    // access goes through this one lock (an unlocked assign racing stop() crashed in CVPixelBuffer finalize).
    let lastQueued = LastQueuedFrameSlot<QueuedFrame>()
    var lastRequestedTimestamp: UInt64 = 0
    var lastSubmittedTimestamp: UInt64 = 0
    var lastIpd: Float = -1
    var viewTransforms: [simd_float4x4] = [matrix_identity_float4x4, matrix_identity_float4x4]
    // One lock for every reader and writer: Renderer/RealityKit replace it, the decode callback (under frameQueueLock)
    // and the keepalive (under viewParamsLock) read it. A leaf lock, so nesting it under either takes no other lock.
    let viewFovsBox = LockedBox<[AlvrFov]>([AlvrFov(left: -1.0471973, right: 0.7853982, up: 0.7853982, down: -0.8726632), AlvrFov(left: -0.7853982, right: 1.0471973, up: 0.7853982, down: -0.8726632)])
    var sentViewTangents: [simd_float4] = [simd_float4(1.73205, 1.0, 1.0, 1.19175), simd_float4(1.0, 1.73205, 1.0, 1.19175)]
    var realViewTangents: [simd_float4] = [simd_float4(1.73205, 1.0, 1.0, 1.19175), simd_float4(1.0, 1.73205, 1.0, 1.19175)]
    /// capture.json debug_eye_tangents while -ALVRDebugEyeTangents is active (DebugEyeTangents); nil otherwise.
    var debugEyeTangentsRecord: [String: Any]? = nil

    var framesSinceLastIDR:Int = 0
    var framesSinceLastDecode:Int = 0

    var streamEvent: AlvrEvent? = nil
    
    var framesRendered:Int = 0
    var totalFramesRendered:Int = 0
    var eventHeartbeat:Int = 0
    var lastEventHeartbeat:Int = -1
    
    var timeLastSentPeriodicUpdatedValues: Double = 0.0
    var timeLastSentMdnsBroadcast: Double = 0.0
    var timeLastCheckedBackgrounded: Double = 0.0
    var timeLastAlvrEvent: Double = 0.0
    var timeLastFrameGot: Double = 0.0
    var timeLastFrameSent: Double = 0.0
    var timeLastFrameDecoded: Double = 0.0
    var numberOfEventThreadRestarts: Int = 0
    var mdnsListener: NWListener? = nil
    var mdnsListenerRegistered = false
    
    var stutterSampleStart = 0.0
    var stutterEventsCounted = 0
    var lastStutterTime = 0.0
    var audioIsOff = false
    var needsEncoderReset = true
    var encodingGamma: Float = 1.0
    // The per-eye view size sent as default_view_width/height at the last alvr_initialize (fov_sent recommended=); nil before it.
    // Set in initializeAlvr, read by the render thread for the log only.
    var recommendedViewResolution: (width: Int, height: Int)?
    var enableHdr = false
    // Guarded by frameQueueLock (event, render and decoder threads).
    var streamBootstrap = StreamBootstrap()
    // Serialises fake tracking sends with the real view-params handoff.
    let viewParamsLock = NSObject()
    // Guarded by viewParamsLock (event and render threads).
    var poseKeepalive = PoseKeepalive()
    // The stream's last real head pose, resent by the keepalive (guarded by viewParamsLock).
    private var keepalivePose = KeepalivePose<AlvrDeviceMotion>()
    private var streamStartTiming = StreamStartTiming()
    private let streamStartTimingLock = NSLock()

    init() {}
    
    func initializeAlvr() {
        fixAudioForDirectStereo()
        if !alvrInitialized {
            print("Initialize ALVR")
            alvrInitialized = true
            var refreshRates:[Float] = [100, 96, 90]
            
            // HACK: Detect hardware type
            if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
                refreshRates = [120, 100, 96, 90]
            }

            // "Crop FOV to outline": ask for the 1:1 render size of the frame the crop will send (CropFov.oneToOne), at the grid
            // density measured from the layer, else the reference device's; crop off keeps the default size. Fixed per stream.
            let settings = ALVRClientApp.gStore.settings
            CropFov.applyLaunch(insetSetting: settings.cropInsetDeg, marginSetting: settings.cropMarginDeg)
            let recommended = CropFov.recommendedViewResolution(
                crop: settings.cropFovToOutline, device: CropFov.referenceDevice, density: CropFov.grid.density,
                insetDeg: CropFov.inset, marginDeg: CropFov.margin, fallback: (renderWidth * 2, renderHeight * 2))
            recommendedViewResolution = recommended
            print("Recommended view resolution", recommended.width, "x", recommended.height)

            let capabilities = AlvrClientCapabilities(default_view_width: UInt32(recommended.width), default_view_height: UInt32(recommended.height), refresh_rates: refreshRates, refresh_rates_count: UInt64(refreshRates.count), foveated_encoding: true, encoder_high_profile: true, encoder_10_bits: true, encoder_av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1), prefer_10bit: true, prefer_full_range: true, preferred_encoding_gamma: 1.5, prefer_hdr: ALVRClientApp.gStore.settings.hdrPQ)
            if let filter = ClientLogging.defaultFilter(environment: ProcessInfo.processInfo.environment) {
                setenv("RUST_LOG", filter, 0)
            }
            alvr_initialize(/*capabilities=*/capabilities)
            alvr_initialize_logging()
            alvr_set_decoder_input_callback(nil, { data in return EventHandler.shared.handleNals(frameData: data) })
            alvr_resume()
        }
    }
    
    // Starts the EventHandler thread.
    func start() {
        alvr_resume()

        fixAudioForDirectStereo()
        if !inputRunning {
            print("Starting event thread")
            inputRunning = true
            eventsThread = Thread {
                self.handleAlvrEvents()
            }
            eventsThread?.qualityOfService = .userInteractive
            eventsThread?.name = "Events Thread"
            eventsThread?.start()
            
            eventsWatchThread = Thread {
                self.eventsWatchdog()
            }
            eventsThread?.qualityOfService = .background
            eventsWatchThread?.name = "Events Watchdog Thread"
            eventsWatchThread?.start()
            
            //outgoingWorker.restartWorkers()
        }
    }
    
    // Stops the EventHandler thread stream.
    func stop() {
        print("EventHandler.Stop")
        WorldTracker.inputGate.streamStopped()
        EventHandler.videoStreams.streamStopped()
        StreamTelemetry.shared.streamingStopped()
        EyeDecodeWindows.shared.stop()
        streamingActive = false
        // Cleared under the decoder lock first, then the old session drains outside it.
        finishAsyncDecode(decoder.replace(session: nil, format: nil, codec: -1))
        lastRequestedTimestamp = 0
        lastSubmittedTimestamp = 0
        framesRendered = 0
        framesSinceLastIDR = 0
        framesSinceLastDecode = 0
        lastIpd = -1
        lastQueued.clear()
        withStreamBootstrap { $0.streamStopped() }
        objc_sync_enter(viewParamsLock)
        poseKeepalive.reset()
        keepalivePose.reset()
        objc_sync_exit(viewParamsLock)
        streamStartTimingLock.lock()
        streamStartTiming.disconnected()
        streamStartTimingLock.unlock()

        //outgoingWorker.stopWorkers()
        
        updateConnectionState(.disconnected)
    }
    
    // Currently unused
    func handleHeadsetRemovedOrReentry() {
        print("EventHandler.handleHeadsetRemovedOrReentry")
        lastIpd = -1
        framesRendered = 0
        framesSinceLastIDR = 0
        framesSinceLastDecode = 0
        lastRequestedTimestamp = 0
        lastSubmittedTimestamp = 0
        lastQueued.clear()
        withStreamBootstrap { $0.reentered() }
    }

    func withStreamBootstrap<T>(_ body: (inout StreamBootstrap) -> T) -> T {
        objc_sync_enter(frameQueueLock)
        defer { objc_sync_exit(frameQueueLock) }
        return body(&streamBootstrap)
    }

    // Until the stream's first frame is queued, keep the server fed with fake view params and a head pose,
    // otherwise it never encodes a frame. Called from the render loops (the event thread's sendPoseKeepaliveIfStale
    // covers the time no render loop runs). Fake sends and the
    // real view-params handoff (sendRealViewParams) both hold viewParamsLock, and fake sends require
    // lastIpd == -1 under it, so a fake send can never land after the real view params.
    func sendBootstrapTrackingIfNeeded() {
        objc_sync_enter(viewParamsLock)
        defer { objc_sync_exit(viewParamsLock) }
        guard streamingActive && lastIpd == -1 else { return }
        if withStreamBootstrap({ $0.shouldSendFakeTracking(now: CACurrentMediaTime()) }) {
            WorldTracker.shared.sendFakeTracking(viewFovs: viewFovsBox.get(), targetTimestamp: CACurrentMediaTime() - 1.0)
            noteRenderPoseSent(realHead: nil)
        }
    }

    // Event thread: head poses reach the server whatever the immersive space is doing (not open yet, opening,
    // paused, switching, tracking lost). While no render loop has sent one for PoseKeepalive.staleAfter, every
    // PoseKeepalive.interval resend the stream's last real head pose (KeepalivePose), or, before there is one, the
    // fake pose with fake view params until the real ones are sent (the old bootstrap). Under viewParamsLock, so a
    // fake view-params send can never land after the real view params.
    func sendPoseKeepaliveIfStale() {
        objc_sync_enter(viewParamsLock)
        defer { objc_sync_exit(viewParamsLock) }
        guard streamingActive else { return }
        let now = CACurrentMediaTime()
        guard let send = poseKeepalive.shouldSend(now: now) else { return }
        let realViewParams = lastIpd != -1
        let kind: String
        switch keepalivePose.choose(target: now) {
        case .real(let head, let timestamp):
            WorldTracker.shared.sendKeepaliveHead(head, targetTimestamp: timestamp)
            kind = "real"
        case .fake:
            WorldTracker.shared.sendFakeTracking(viewFovs: viewFovsBox.get(), targetTimestamp: now - 1.0, includeViewParams: !realViewParams)
            kind = "fake"
        }
        if send.startsEpisode {
            logStreamStart(.poseKeepalive, [("state", "start"), ("pose", kind), ("view_params", realViewParams ? "real" : "fake")])
        }
        logStreamStart(.firstPoseSent, [("kind", kind)], once: true)
    }

    // A render loop sent a head pose (realHead: the real one sent, at timestamp): the keepalive stands down and,
    // for a real pose, caches it. Any thread.
    func noteRenderPoseSent(realHead: AlvrDeviceMotion?, timestamp: Double = 0) {
        objc_sync_enter(viewParamsLock)
        let episodeSends = poseKeepalive.renderSent(now: CACurrentMediaTime())
        if let realHead { keepalivePose.realSent(realHead, timestamp: timestamp) }
        objc_sync_exit(viewParamsLock)
        if let episodeSends {
            logStreamStart(.poseKeepalive, [("state", "end"), ("sent", "\(episodeSends)")])
        }
        logStreamStart(.firstPoseSent, [("kind", realHead != nil ? "real" : "fake")], once: true)
    }

    // One DIAG stream_start line (StreamStartTiming) to the server log. Any thread.
    func logStreamStart(_ event: StreamStartTiming.Event, _ fields: [(String, String)] = [], once: Bool = false) {
        streamStartTimingLock.lock()
        let line = streamStartTiming.line(event, now: CACurrentMediaTime(), fields: fields, once: once)
        streamStartTimingLock.unlock()
        guard let line else { return }
        print(line)
        alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), line)
    }

    // The renderers' handoff to real view params; ends fake sends (see sendBootstrapTrackingIfNeeded).
    func sendRealViewParams(ipd: Float) {
        objc_sync_enter(viewParamsLock)
        defer { objc_sync_exit(viewParamsLock) }
        lastIpd = ipd
        WorldTracker.shared.sendViewParams(viewTransforms: viewTransforms, viewFovs: viewFovsBox.get())
    }
    
    // Various hacks to be performed when the headset is removed or the app is exiting.
    func handleHeadsetRemoved() {
        preventAudioCracklingOnExit()
        // Hand the Steam Controller back to the system on the way out, for the
        // same reason the audio session is torn down here: leaving it out of
        // lizard mode while nobody is looking at the app means its trackpads
        // quietly drive the desktop instead.
        InputDebugSession.shared.suspend()
        SteamControllerManager.shared.stop(.streaming)
    }

    // Various hacks to be performed when the headset is donned and VR is entering.
    func handleHeadsetEntered() {
        fixAudioForDirectStereo()
        InputDebugSession.shared.resume()
        SteamControllerManager.shared.start(.streaming)
        Task {
            await WorldTracker.shared.initializeAr()
        }
    }
    
    // To be called when rendering is starting
    func handleRenderStarted() {
        // Prevent event thread rebooting if we can
        timeLastAlvrEvent = CACurrentMediaTime()
        timeLastFrameGot = CACurrentMediaTime()
        timeLastFrameSent = CACurrentMediaTime()
        timeLastFrameDecoded = CACurrentMediaTime()
    }

    // Ensure that the audio session is direct stereo, so that SteamVR can handle
    // all the fancy effects as it pleases.
    // Also ensures that the microphone uses the right noise cancellation.
    func fixAudioForDirectStereo() {
        audioIsOff = false
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(true)
            try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
            try audioSession.setMode(.voiceChat)
            try audioSession.setPreferredOutputNumberOfChannels(2)
            try audioSession.setIntendedSpatialExperience(.bypassed)
        } catch {
            print("Failed to set the audio session configuration?")
        }
    }
    
    // On visionOS 1, the app would have audio crackling on exiting, so
    // we avoid it by quickly shutting off the audio on exit.
    func preventAudioCracklingOnExit() {
        if audioIsOff {
            return
        }
        audioIsOff = true
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false)
        } catch {
            print("Failed to set the audio session configuration? \(error)")
        }
    }

    // Handle mDNS broadcasts, should be called periodically (1-5s)
    func handleMdnsBroadcasts() {
        // HACK: Some mDNS clients seem to only see edge updates (ie, when a client appears/disappears)
        // so we just create/destroy this every 2s until we're streaming.
        timeLastSentMdnsBroadcast = CACurrentMediaTime()
        if mdnsListener != nil {
            mdnsListener!.cancel()
            mdnsListener = nil
            mdnsListenerRegistered = false
        }

        if mdnsListener == nil && !streamingActive {
            do {
                mdnsListener = try NWListener(using: .tcp)
            } catch {
                mdnsListener = nil
                print("Failed to create mDNS NWListener?")
            }
            
            if let listener = mdnsListener {
                let txtRecord = NWTXTRecord(["protocol" : getMdnsProtocolId(), "device_id" : getHostname(), "salt" : CACurrentMediaTime().description])
                listener.service = NWListener.Service(name: "ALVR Apple Vision Pro", type: getMdnsService(), txtRecord: txtRecord)

                // Handle errors if any
                listener.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        print("mDNS listener is ready")
                    case .waiting(let error):
                        print("mDNS listener is waiting with error: \(error)")
                    case .failed(let error):
                        print("mDNS listener failed with error: \(error)")
                    default:
                        break
                    }
                    self.timeLastSentMdnsBroadcast = CACurrentMediaTime()
                }
                listener.serviceRegistrationUpdateHandler = { change in
                    print("mDNS registration updated:", change)
                    self.timeLastSentMdnsBroadcast = CACurrentMediaTime()
                    self.mdnsListenerRegistered = true
                }
                listener.newConnectionHandler = { connection in
                    connection.cancel()
                }

                listener.start(queue: DispatchQueue.global(qos: .background))
            }
        }
    }

    // Data which only needs to be sent periodically, such as battery percentage
    func handlePeriodicUpdatedValues() {
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        let batteryLevel = UIDevice.current.batteryLevel
        let isCharging = UIDevice.current.batteryState == .charging
        if streamingActive {
            alvr_send_battery(WorldTracker.deviceIdHead, batteryLevel, isCharging)
            alvr_send_battery(WorldTracker.deviceIdLeftHand, WorldTracker.shared.leftControllerBatteryPercent, WorldTracker.shared.leftControllerBatteryIsCharging)
            alvr_send_battery(WorldTracker.deviceIdRightHand, WorldTracker.shared.rightControllerBatteryPercent, WorldTracker.shared.rightControllerBatteryIsCharging)
        }
        
        timeLastSentPeriodicUpdatedValues = CACurrentMediaTime()
    }
    
    // Make sure the event thread is always running, sometimes it gets lost.
    func eventsWatchdog() {
        while true {
            if eventHeartbeat == lastEventHeartbeat {
                if (renderStarted && numberOfEventThreadRestarts > 3) || numberOfEventThreadRestarts > 10 {
                    print("Event thread is MIA, exiting")
                    exit(0)
                }
                else {
                    print("Event thread is MIA, restarting event thread")
                    /*eventsThread = Thread {
                        self.handleAlvrEvents()
                    }
                    eventsThread?.name = "Events Thread"
                    eventsThread?.start()
                    numberOfEventThreadRestarts += 1*/
                }
            }
            
            DispatchQueue.main.async {
                let state = UIApplication.shared.applicationState
                if state == .background {
                    print("App in background, exiting")
                    if let service = self.mdnsListener {
                        service.cancel()
                        self.mdnsListener = nil
                    }
                    exit(0)
                }
            }
            
            lastEventHeartbeat = eventHeartbeat
            for _ in 0...5 {
                usleep(1000*1000)
            }
        }
    }
    
    func resetEncoding() {
        needsEncoderReset = true
    }

    // Before a session is dropped or replaced, so no asynchronous output handler runs against it afterwards.
    // Not from a decoder output handler (it would wait on itself).
    private func finishAsyncDecode(_ session: VTDecompressionSession?) {
        guard let asyncDecode, let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let dropped = asyncDecode.drain()
        if dropped > 0 {
            print("Async decode: \(dropped) frames still in flight after the wait")
        }
    }
    
    // Poll for NALs and and, when decoded, add them to the frameQueue
    func handleNals(frameData: AlvrVideoFrameData) -> Bool {
        var retVal = true
        self.timeLastFrameGot = CACurrentMediaTime()
        StreamTelemetry.shared.recordReceived(timestampNs: frameData.timestamp_ns)

        // Prevent NAL buildup
        if !self.renderStarted {
            //VideoHandler.abandonAllPendingNals()
            StreamTelemetry.shared.recordDroppedBeforeDecode()
            retVal = true
            return retVal
        }

        if self.needsEncoderReset {
            self.needsEncoderReset = false
            print("Resetting encoder")
            StreamTelemetry.shared.recordDroppedBeforeDecode()
            retVal = false
            return retVal
        }
        
        let timestamp = frameData.timestamp_ns
        if ALVRClientApp.gStore.settings.showPerformanceHud {
            PerformanceTracker.shared.recordReceive(timestampNs: timestamp)
        }
        let nal = UnsafeMutableBufferPointer<UInt8>(start: UnsafeMutablePointer(mutating: frameData.buffer_ptr), count: Int(frameData.buffer_size))
        
        objc_sync_enter(self.frameQueueLock)
        self.framesSinceLastIDR += 1

        // If we're receiving NALs timestamped from >400ms ago, stop decoding them
        // to prevent a cascade of needless decoding lag
        let ns_diff_from_last_req_ts = self.lastRequestedTimestamp > timestamp ? self.lastRequestedTimestamp &- timestamp : 0
        let lagSpiked = (ns_diff_from_last_req_ts > 1000*1000*600 && self.framesSinceLastIDR > Int(refreshRate*2))
        
        if CACurrentMediaTime() - self.stutterSampleStart >= 60.0 {
            print("Stuttter events in the last minute:", self.stutterEventsCounted)
            self.stutterSampleStart = CACurrentMediaTime()
            
            if self.stutterEventsCounted >= 50 {
                print("stutter detected!")
            }
            
            self.stutterEventsCounted = 0
        }
        if ns_diff_from_last_req_ts > 1000*1000*40 {
            if (CACurrentMediaTime() - self.lastStutterTime > 0.25 && CACurrentMediaTime() - self.lastStutterTime < 10.0) || ns_diff_from_last_req_ts > 1000*1000*100 {
                self.stutterEventsCounted += 1
                //print(ns_diff_from_last_req_ts, CACurrentMediaTime() - lastStutterTime)
            }
            self.lastStutterTime = CACurrentMediaTime()
        }
        // TODO: adjustable framerate
        // TODO: maybe also call this if we fail to decode for too long.
        if self.lastRequestedTimestamp != 0 && (lagSpiked || self.framesSinceLastDecode > Int(refreshRate*2)) {
            objc_sync_exit(self.frameQueueLock)

            print("Handle spike! lagSpiked=\(lagSpiked) lastRequestedTimestamp=\(self.lastRequestedTimestamp), timestamp=\(timestamp), framesSinceLastDecode=\(self.framesSinceLastDecode) framesSinceLastIDR=\(self.framesSinceLastIDR) ns_diff_from_last_req_ts=\(ns_diff_from_last_req_ts)")

            // We have to request an IDR to resume the video feed
            
            self.framesSinceLastIDR = 0
            self.framesSinceLastDecode = 0
            StreamTelemetry.shared.recordDroppedBeforeDecode()

            retVal = false
            return retVal
        }
        objc_sync_exit(self.frameQueueLock)
        
        self.framesSinceLastDecode = 0
        
        let startedDecodeTime = CACurrentMediaTime()
        
        let codec = decoder.codec
        if codec == ALVR_CODEC_AV1.rawValue && !av1InstantiatedForReal {
            print("Creating AV1 codec for real now.")
            let (attemptVtDecompressionSession, attemptVideoFormat) = VideoHandler.createVideoDecoder(initialNals: nal, codec: codec)
            if attemptVtDecompressionSession != nil && attemptVideoFormat != nil {
                finishAsyncDecode(decoder.replace(session: attemptVtDecompressionSession, format: attemptVideoFormat, codec: codec))
                av1InstantiatedForReal = true
                VideoHandler.reportVideoFormat(attemptVideoFormat!)
            }
        }

        if let current = decoder.snapshot() {
            // The stream this frame was decoded for: its colour state is derived from it, not from a later videoFormat.
            let frameVideoFormat = current.format
            let frameStream = EventHandler.videoStreams.currentStream
            // -ALVRAsyncDecode: hold a slot (waits while DecodeInFlight.limit frames are in flight) and decode from a copy.
            var slot: (token: UInt64, inFlight: Int)? = nil
            var inputCopy: DecodeInputCopy? = nil
            if let asyncDecode {
                slot = asyncDecode.acquire(timestampNs: timestamp, timeout: 0.1)
                guard let acquired = slot else {
                    print("Async decode: no slot within 100 ms, dropping frame for an IDR")
                    StreamTelemetry.shared.recordDroppedBeforeDecode()
                    return false
                }
                StreamTelemetry.shared.recordDecodeInFlight(acquired.inFlight)
                inputCopy = DecodeInputCopy(nal)
            }
            let submitted = VideoHandler.feedVideoIntoDecoder(decompressionSession: current.session, nals: inputCopy?.buffer ?? nal, timestamp: timestamp, videoFormat: frameVideoFormat, codec: current.codec, asynchronous: asyncDecode != nil) { [self] imageBuffer in
                // Every output, decoded or not, releases its slot; the overrun is measured from this frame's own submit.
                var asyncFrame: DecodeInFlight.Frame? = nil
                if let asyncDecode, let slot {
                    withExtendedLifetime(inputCopy) {}
                    switch asyncDecode.complete(slot.token) {
                    case .inOrder(let frame):
                        asyncFrame = frame
                    case .outOfOrder(let frame):
                        asyncFrame = frame
                        print("Async decode: output out of submit order, timestamp \(frame.timestampNs)")
                    case .unknown:
                        break
                    }
                }
                guard let imageBuffer = imageBuffer else {
                    //print("Frame not decoded")
                    return
                }
                if ALVRClientApp.gStore.settings.showPerformanceHud {
                    PerformanceTracker.shared.recordDecodeEnd(timestampNs: timestamp)
                }
                //print("Frame decoded")
                
                let decodeSeconds = asyncFrame.map { Double(StreamTelemetry.nowNs() &- $0.submitNs) / 1e9 } ?? CACurrentMediaTime() - startedDecodeTime
                if (decodeSeconds > Double(50*MSEC_PER_SEC)) {
                    objc_sync_enter(frameQueueLock)

                    print("Handle decode overrun!", decodeSeconds, framesSinceLastDecode, framesSinceLastIDR, ns_diff_from_last_req_ts)

                    // We have to request an IDR to resume the video feed
                    resetEncoding()

                    framesSinceLastIDR = 0
                    framesSinceLastDecode = 0
                    objc_sync_exit(frameQueueLock)
                    StreamTelemetry.shared.recordDecodeOverrun()

                    return
                }
                
                timeLastFrameDecoded = CACurrentMediaTime()

                objc_sync_enter(frameQueueLock)
                framesSinceLastDecode = 0
                if frameQueueLastTimestamp != timestamp || true
                {
                    alvr_report_frame_decoded(timestamp)
                    
                    let dummyPose = AlvrPose()
                    let fovs = viewFovsBox.get()
                    let viewParamsDummy = [AlvrViewParams(pose: dummyPose, fov: fovs[0]), AlvrViewParams(pose: dummyPose, fov: fovs[1])]

                    // TODO: For some reason, really low frame rates seem to decode the wrong image for a split second?
                    // But for whatever reason this is fine at high FPS.
                    // From what I've read online, the only way to know if an H264 frame has actually completed is if
                    // the next frame is starting, so keep this around for now just in case.
                    if frameQueueLastImageBuffer != nil {
                        //frameQueue.append(QueuedFrame(imageBuffer: frameQueueLastImageBuffer!, timestamp: frameQueueLastTimestamp))
                        frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp, viewParamsValid: false, viewParams: viewParamsDummy, videoFormat: frameVideoFormat, stream: frameStream))
                    }
                    else {
                        frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp, viewParamsValid: false, viewParams: viewParamsDummy, videoFormat: frameVideoFormat, stream: frameStream))
                    }
                    // TODO: make this configurable
                    if frameQueue.count > 2 {
                        frameQueue.removeFirst()
                        StreamTelemetry.shared.recordQueueOverflow()
                    }


                    StreamTelemetry.shared.recordFrameQueued(timestampNs: timestamp)
                    frameQueueLastTimestamp = timestamp
                    frameQueueLastImageBuffer = imageBuffer
                    timeLastFrameSent = CACurrentMediaTime()
                    if let bootLine = streamBootstrap.frameQueued(now: CACurrentMediaTime()) {
                        print(bootLine)
                        logStreamStart(.firstDecodedFrame, once: true)
                    }
                }

                // Pull the very last imageBuffer for a given timestamp
                if frameQueueLastTimestamp == timestamp {
                    frameQueueLastImageBuffer = imageBuffer
                }

                objc_sync_exit(frameQueueLock)
                // After the lock: it takes its own lock and may write the once-a-second log line.
                EyeDecodeWindows.shared.decoded(timestampNs: timestamp)
                //print("End VT callback")
            }
            if !submitted, let asyncDecode, let slot {
                asyncDecode.cancel(slot.token)
            }
        } else {
            StreamTelemetry.shared.recordDroppedBeforeDecode()
            let nalViewsPtrDiscarded = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
            defer { nalViewsPtrDiscarded.deallocate() }

            alvr_report_frame_decoded(timestamp)
            alvr_report_compositor_start(timestamp, nalViewsPtrDiscarded)
            alvr_report_submit(timestamp, 0)
            
            print("Force reset decoder")
            
            //return false
            retVal = false
            return retVal
        }
        
        //print("Return from callback")
        
        if self.needsEncoderReset {
            self.needsEncoderReset = false
            //print("Resetting encoder (post)")
            return false
        }
        
        return retVal
    }
    
    func getHostVersion() -> String {
        var byteArray = [UInt8](repeating: 0, count: 256)

        byteArray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            
            alvr_get_server_version(cStringPtr)
        }
        
        if let utf8String = String(bytes: byteArray, encoding: .utf8) {
            let ret = utf8String.trimmingCharacters(in: ["\0"]);
            return ret;
        } else {
            print("Unable to decode alvr_get_server_version into a UTF-8 string.")
            return "failed to decode host version";
        }
    }
    
    // Returns the ALVR hostname in the format "NNNN.client.alvr"
    func getHostname() -> String {
        var byteArray = [UInt8](repeating: 0, count: 256)

        byteArray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            
            alvr_hostname(cStringPtr)
        }
        
        if let utf8String = String(bytes: byteArray, encoding: .utf8) {
            let ret = utf8String.trimmingCharacters(in: ["\0"]);
            return ret + ".alvr"; // Hack: runtime needs to fix this D:
        } else {
            print("Unable to decode alvr_hostname into a UTF-8 string.")
            return "unknown.client.alvr";
        }
    }
    
    // Gets the mDNS service name from the client framework, usually "_alvr._tcp"
    func getMdnsService() -> String {
        var byteArray = [UInt8](repeating: 0, count: 256)

        byteArray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            
            alvr_mdns_service(cStringPtr)
        }
        
        if let utf8String = String(bytes: byteArray, encoding: .utf8) {
            let ret = utf8String.trimmingCharacters(in: ["\0"]);
            return ret.replacing(".local", with: "", maxReplacements: 1);
        } else {
            print("Unable to decode alvr_mdns_service into a UTF-8 string.")
            return "_alvr._tcp";
        }
    }
    
    // Gets the mDNS protocol ID, used to identify the client version to the Streamer
    // and ensure the protocol versions match.
    func getMdnsProtocolId() -> String {
        var byteArray = [UInt8](repeating: 0, count: 256)

        byteArray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            
            alvr_protocol_id(cStringPtr)
        }
        
        if let utf8String = String(bytes: byteArray, encoding: .utf8) {
            let ret = utf8String.trimmingCharacters(in: ["\0"]);
            return ret;
        } else {
            print("Unable to decode alvr_protocol_id into a UTF-8 string.")
            return "unknown";
        }
    }
    
    // Restart the ALVR client framework's event thread if it's unresponsive.
    func kickAlvr() {
        stop()
        alvrInitialized = false
        alvr_destroy()
        initializeAlvr()
        
        timeLastAlvrEvent = CACurrentMediaTime()
        timeLastFrameGot = CACurrentMediaTime()
        timeLastFrameSent = CACurrentMediaTime()
        
        clearHostVersion()
    }

    // The main event thread
    func handleAlvrEvents() {
        print("Start event thread...")
        Thread.setThreadPriority(0.9)
        decoder.setCodec(-1)
        av1InstantiatedForReal = false
        while inputRunning {
            eventHeartbeat += 1
            // Send periodic updated values, such as battery percentage, once every five seconds
            let currentTime = CACurrentMediaTime()
            if currentTime - timeLastSentPeriodicUpdatedValues >= 15.0 {
                handlePeriodicUpdatedValues()
            }
            if (currentTime - timeLastSentMdnsBroadcast >= 2.1 && self.mdnsListenerRegistered) || (currentTime - timeLastSentMdnsBroadcast >= 5.1) {
                handleMdnsBroadcasts()
            }
            
            if currentTime - timeLastCheckedBackgrounded >= 0.1 {
                timeLastCheckedBackgrounded = CACurrentMediaTime()
                DispatchQueue.main.async {
                    let state = UIApplication.shared.applicationState
                    if state == .background {
                        print("App in background, exiting")
                        if let service = self.mdnsListener {
                            service.cancel()
                            self.mdnsListener = nil
                        }
                        // Stops the lizard-mode keepalive. This works precisely
                        // because it is the *absence* of traffic and not a
                        // write: nothing has to reach the controller before
                        // exit(0) kills us, and the controller's own watchdog
                        // restores lizard mode a few seconds later.
                        SteamControllerManager.shared.stopAll()
                        exit(0)
                    }
                }

                // Not gated on renderStarted: that is set when a renderer is built and never cleared, while the
                // render loop only sends poses once its layer runs.
                sendPoseKeepaliveIfStale()
            }
            
            let diffSinceLastEvent = 0.0//currentTime - timeLastAlvrEvent
            let diffSinceLastNal = currentTime - timeLastFrameGot
            let diffSinceLastDecode = currentTime - timeLastFrameSent
            /*if (!renderStarted && timeLastAlvrEvent != 0 && timeLastFrameGot != 0 && (diffSinceLastEvent >= 20.0 || diffSinceLastNal >= 20.0))
               || (renderStarted && timeLastAlvrEvent != 0 && timeLastFrameGot != 0 && (diffSinceLastEvent >= 30.0 || diffSinceLastNal >= 30.0))
               || (renderStarted && timeLastFrameSent != 0 && (diffSinceLastDecode >= 30.0)) {
                EventHandler.shared.updateConnectionState(.disconnected)
                
                print("Kick ALVR...")
                print("diffSinceLastEvent:", diffSinceLastEvent)
                print("diffSinceLastNal:", diffSinceLastNal)
                print("diffSinceLastDecode:", diffSinceLastDecode)
                kickAlvr()
            }*/
            
            if (!renderStarted && timeLastAlvrEvent != 0 && timeLastFrameGot != 0 && (diffSinceLastEvent >= 20.0 || diffSinceLastNal >= 20.0))
               || (renderStarted && timeLastAlvrEvent != 0 && timeLastFrameGot != 0 && (diffSinceLastEvent >= 30.0 || diffSinceLastNal >= 30.0))
               || (renderStarted && timeLastFrameSent != 0 && (diffSinceLastDecode >= 30.0)) {
                EventHandler.shared.updateConnectionState(.disconnected)
                
                print("Kick ALVR...")
                print("diffSinceLastEvent:", diffSinceLastEvent)
                print("diffSinceLastNal:", diffSinceLastNal)
                print("diffSinceLastDecode:", diffSinceLastDecode)
                
                alvr_report_fatal_decoder_error("Gimme frames >:(")
                
                timeLastAlvrEvent = CACurrentMediaTime()
                timeLastFrameGot = CACurrentMediaTime()
                timeLastFrameSent = CACurrentMediaTime()
            }
            
            if alvrInitialized && (diffSinceLastNal >= 5.0) {
                print("Request IDR")
                resetEncoding()
                timeLastFrameGot = CACurrentMediaTime()
            }

            var alvrEvent = AlvrEvent()
            let res = alvr_poll_event(&alvrEvent)
            if !res {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            timeLastAlvrEvent = CACurrentMediaTime()
            switch UInt32(alvrEvent.tag) {
            case ALVR_EVENT_HUD_MESSAGE_UPDATED.rawValue:
                print("hud message updated")
                if !renderStarted {
                    let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                    alvr_hud_message(hudMessageBuffer.baseAddress)
                    let message = String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8)!
                    if message.starts(with: "The streamer is restarting") {
                        if streamingActive {
                            streamingActive = false
                            stop()
                            timeLastAlvrEvent = CACurrentMediaTime()
                            timeLastFrameSent = CACurrentMediaTime()
                            decoder.setCodec(-1)
                        }
                    }
                    parseMessage(message)
                    print(message)
                    hudMessageBuffer.deallocate()
                }
                Settings.clearSettingsCache()
                updateHostVersion()
            case ALVR_EVENT_STREAMING_STARTED.rawValue:
                print("streaming started \(alvrEvent.STREAMING_STARTED)")
                // Every stream (connect and reconnect) re-reads the crop inset/margin settings and launch arguments.
                let cropSettings = ALVRClientApp.gStore.settings
                CropFov.applyLaunch(insetSetting: cropSettings.cropInsetDeg, marginSetting: cropSettings.cropMarginDeg)
                updateHostVersion()
                numberOfEventThreadRestarts = 0
                
                encodingGamma = alvrEvent.STREAMING_STARTED.encoding_gamma
                enableHdr = alvrEvent.STREAMING_STARTED.enable_hdr
                let started = alvrEvent.STREAMING_STARTED
                StreamTelemetry.shared.streamingStarted(viewWidth: Int(started.view_width), viewHeight: Int(started.view_height), refreshRateHint: Double(started.refresh_rate_hint), encodingGamma: Double(started.encoding_gamma), enableFoveatedEncoding: started.enable_foveated_encoding, enableHdr: started.enable_hdr, forceFastSecretTextureFormats: forceFastSecretTextureFormats)
                EyeDecodeWindows.shared.start(refreshRate: Double(started.refresh_rate_hint))
                if !streamingActive {
                    streamEvent = alvrEvent
                    streamingActive = true
                    resetEncoding()
                    framesSinceLastIDR = 0
                    framesSinceLastDecode = 0
                    lastIpd = -1
                    decoder.setCodec(-1)
                    EventHandler.shared.updateConnectionState(.connected)
                }
                // Outside the block above: a DecoderConfig may already have set streamingActive.
                let newStream = withStreamBootstrap { (bootstrap: inout StreamBootstrap) -> Bool in
                    guard bootstrap.phase == .idle else { return false }
                    bootstrap.streamStarted(now: CACurrentMediaTime())
                    return true
                }
                if newStream {
                    logStreamStart(.connect, [("full_immersion_setting", "\(ALVRClientApp.gStore.settings.streamFullImmersion)"),
                                              ("render_started", "\(renderStarted)")])
                }
                sendPoseKeepaliveIfStale()
                Settings.clearSettingsCache()
                // This stream's video inputs, captured once into a new generation (decision 63e (2), (3)): the HDR
                // setting, reference white and SDR output policy, the server's encoding gamma and the foveation. Decode and
                // render threads read only these; a setting changed mid-stream applies to the next stream.
                let foveation = Settings.getAlvrSettings().map { FFR.calculateFoveationVars(alvrEvent: started, foveationSettings: $0.video.foveated_encoding) }
                let whiteOverride = LaunchFlags.double(HDRPipeline.referenceWhiteDefaultsKey, setting: ALVRClientApp.gStore.settings.hdrReferenceWhiteNits)
                let serverWhite = Settings.getAlvrSettings()?.video.encoder_config?.hdr?.reference_white_nits
                let (referenceWhite, whiteSource) = HDRPipeline.resolveReferenceWhite(defaultsValue: whiteOverride, serverValue: serverWhite)
                let videoStream = EventHandler.videoStreams.streamStarted(
                    hdrEnabled: ALVRClientApp.gStore.settings.hdrPQ,
                    output: VideoHandler.colourOutput,
                    encodingGamma: started.encoding_gamma,
                    referenceWhiteNits: referenceWhite,
                    payload: foveation)
                let line = "HDRDISPLAY ref_white=\(referenceWhite) source=\(whiteSource)"
                alvr_log(AlvrLogLevel(ALVR_LOG_LEVEL_INFO.rawValue), line)
                print("ALVRCOLOUR stream=\(videoStream.generation) hdr_setting=\(videoStream.hdrEnabled) foveation=\(foveation != nil)")
                // Choose this stream's interaction profile once from the emulation mode (fixed for the stream), declare it, then open the gate.
                WorldTracker.shared.startInputStream()
            case ALVR_EVENT_STREAMING_STOPPED.rawValue:
                print("streaming stopped")
                WorldTracker.inputGate.streamStopped()
                EventHandler.videoStreams.streamStopped()
                if streamingActive {
                    streamingActive = false
                    stop()
                    timeLastAlvrEvent = CACurrentMediaTime()
                    timeLastFrameSent = CACurrentMediaTime()
                    decoder.setCodec(-1)
                }
                Settings.clearSettingsCache()
                clearHostVersion()
            case ALVR_EVENT_HAPTICS.rawValue:
                //print("haptics: \(alvrEvent.HAPTICS)")
                let haptics = alvrEvent.HAPTICS
                var duration = Double(haptics.duration_s)
                
                // Hack: Controllers can't do 10ms vibrations.
                if duration < 0.032 {
                    duration = 0.032
                }
                if haptics.device_id == WorldTracker.deviceIdLeftHand {
                    WorldTracker.shared.leftHapticsStart = CACurrentMediaTime()
                    WorldTracker.shared.leftHapticsEnd = CACurrentMediaTime() + duration
                    WorldTracker.shared.leftHapticsFreq = haptics.frequency
                    WorldTracker.shared.leftHapticsAmplitude = haptics.amplitude
                }
                else {
                    WorldTracker.shared.rightHapticsStart = CACurrentMediaTime()
                    WorldTracker.shared.rightHapticsEnd = CACurrentMediaTime() + duration
                    WorldTracker.shared.rightHapticsFreq = haptics.frequency
                    WorldTracker.shared.rightHapticsAmplitude = haptics.amplitude
                }
            case ALVR_EVENT_DECODER_CONFIG.rawValue:
                streamingActive = true
                let codec = Int(alvrEvent.DECODER_CONFIG.codec)
                print("create decoder \(alvrEvent.DECODER_CONFIG) codec ID: \(codec)")
                Settings.clearSettingsCache()
                updateHostVersion()

                // Don't reinstantiate the decoder if it's already created (each IDR resend carries the same codec).
                if decoder.session != nil {
                    decoder.setCodec(codec)
                } else {
                    let numBytes = alvr_get_decoder_config(nil)
                    var nalBuffer: UnsafeMutableBufferPointer<UInt8>? = nil
                    if numBytes > 0 {
                        nalBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(numBytes))
                    }
                    else {
                        nalBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(1))
                    }
                    defer { nalBuffer?.deallocate() }
                    alvr_get_decoder_config(nalBuffer?.baseAddress)

                    av1InstantiatedForReal = false
                    let (session, videoFormat) = VideoHandler.createVideoDecoder(initialNals: nalBuffer!, codec: codec)
                    // One step: handleNals never sees the new session with the old codec.
                    decoder.replace(session: session, format: videoFormat, codec: codec)
                    if let videoFormat {
                        VideoHandler.reportVideoFormat(videoFormat)
                    }
                }

                EventHandler.shared.updateConnectionState(.connected)
                //WorldTracker.shared.needsRecenterTrigger = true
             case ALVR_EVENT_REAL_TIME_CONFIG.rawValue:
                print("TODO real-time config")
             default:
                 print("unknown msg")
             }
             Thread.sleep(forTimeInterval: 0.0001)
        }
        
        print("Events thread stopped")
    }
    
    func updateConnectionState(_ newState: ConnectionState) {
        if renderStarted || self.connectionState == newState {
            return
        }
        DispatchQueue.main.async {
            self.connectionState = newState
        }
    }

    func parseMessage(_ message: String) {
        var flavorText = ""
        let lines = message.components(separatedBy: "\n")
        for line in lines {
            if line == "" {
                continue
            }
            if line.starts(with: "ALVR") {
                let split = line.split(separator: " ")
                if split.count == 2 {
                    updateVersion(split[1].trimmingCharacters(in: .whitespaces))
                    continue
                }
            }
            let keyValuePair = line.split(separator: ":")
            if keyValuePair.count == 2 {
                let key = keyValuePair[0].trimmingCharacters(in: .whitespaces)
                let value = keyValuePair[1].trimmingCharacters(in: .whitespaces)
                
                if key == "hostname" {
                    updateHostname(getHostname())
                } else if key == "IP" {
                    updateIP(value)
                }
            }
            else {
                flavorText += line + "\n"
            }
        }
        
        if flavorText == "The stream will begin soon\nPlease wait...\n" {
            flavorText = "The stream is ready."
        }
        
        DispatchQueue.main.async {
            self.connectionFlavorText = flavorText
        }
    }

    func updateHostname(_ newHostname: String) {
        DispatchQueue.main.async {
            self.hostname = newHostname
        }
    }

    func updateIP(_ newIP: String) {
        DispatchQueue.main.async {
            self.IP = newIP
        }
    }

    func updateVersion(_ newVersion: String) {
        DispatchQueue.main.async {
            self.alvrVersion = newVersion
        }
    }
    
    func updateHostVersion() {
        DispatchQueue.main.async {
            self.hostAlvrVersion = self.getHostVersion()
            let majorMinorRev = self.hostAlvrVersion.split(separator: ".")
            if majorMinorRev.count >= 3 {
                self.hostAlvrMajor = Int(majorMinorRev[0]) ?? 20
                self.hostAlvrMinor = Int(majorMinorRev[1]) ?? 11
                self.hostAlvrRevision = Int(majorMinorRev[2]) ?? 0
                print("Host version: v\(self.hostAlvrMajor).\(self.hostAlvrMinor).\(self.hostAlvrRevision), raw: \(self.hostAlvrVersion)")
            }
        }
    }
    
    func clearHostVersion() {
        DispatchQueue.main.async {
            self.hostAlvrVersion = ""
        }
    }

    func isHostVersionAtLeast(_ major: Int, _ minor: Int, _ revision: Int) -> Bool {
        if hostAlvrMajor != major { return hostAlvrMajor > major }
        if hostAlvrMinor != minor { return hostAlvrMinor > minor }
        return hostAlvrRevision >= revision
    }
}

enum ConnectionState {
    case connected, disconnected, connecting
}

struct QueuedFrame {
    let imageBuffer: CVImageBuffer
    let timestamp: UInt64
    let viewParamsValid: Bool
    let viewParams: [AlvrViewParams]
    // Format description of the stream the frame was decoded for (VideoHandler.streamColourState).
    let videoFormat: CMFormatDescription?
    // That stream's context (decision 63e (2)); nil for a frame fed before any stream started.
    let stream: StreamContext?
}
