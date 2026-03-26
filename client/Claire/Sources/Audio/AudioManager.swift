import AVFoundation
import Accelerate

/// Audio pipeline for Claire using AVAudioEngine + SMPL AFE.
/// Works on both macOS and iOS.
///
/// Capture: Mic → AVAudioEngine tap → resample 16kHz → AFE (AEC/NS) → VAD → segment
/// Render:  TTS PCM → AVAudioPlayerNode → AFE render (echo ref) → speaker
class AudioManager: NSObject {

    // Audio engine
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureConverter: AVAudioConverter?

    // SMPL AFE
    private var afeProcessor: SMPLAFEProcessor?

    // VAD state
    private var isSpeaking = false
    private var speechBuffer = Data()
    private var silenceFrameCount = 0
    private var speechFrameCount = 0
    private let speechThresholdDB: Float = -35
    private let silenceTimeout = 25      // ~500ms
    private let minSpeechFrames = 10     // ~200ms
    private var isMuted = false

    // Format constants
    private let captureSampleRate: Double = 16000
    private let playbackSampleRate: Double = 24000
    private lazy var playbackFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: playbackSampleRate, channels: 1, interleaved: true)!
    }()

    // Callbacks
    var onSpeechSegment: ((Data) -> Void)?
    var onVADStateChanged: ((Bool) -> Void)?

    // Levels
    var userSpeechLevel: Float { afeProcessor?.postAfeLevel() ?? 0 }
    var playoutLevel: Float { afeProcessor?.playoutLevel() ?? 0 }

    // MARK: - Setup

    func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            print("[Audio] Session config failed: \(error)")
        }
        #endif
    }

    func initAFE() {
        let modelPath = Bundle.main.path(forResource: "jrev_model_v82_smpl", ofType: "zip") ?? ""
        let configPath = Bundle.main.path(forResource: "jrev_params_v57k", ofType: "json") ?? ""

        guard !modelPath.isEmpty, !configPath.isEmpty else {
            print("[Audio] AFE model files missing! modelPath=\(modelPath) configPath=\(configPath)")
            return
        }

        print("[Audio] Initializing SMPL AFE")
        print("[Audio]   Model: \(modelPath)")
        print("[Audio]   Config: \(configPath)")

        afeProcessor = SMPLAFEProcessor(
            modelPath: modelPath,
            configPath: configPath,
            recordingOutputPath: nil,
            startupFilePath: nil,
            compressorMode: 0,
            useAgc: false
        )

        // Post-processing callback for capture metering
        afeProcessor?.postProcessingCallback = { [weak self] samples, frameCount, sampleRate, seqNum in
            // Audio has been through AEC + NS — this is clean speech
            // We can use this for VAD and sending to server
        }

        print("[Audio] SMPL AFE initialized")
    }

    // MARK: - Capture

    func startCapture() {
        initAFE()

        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        guard let engine = engine, let player = playerNode else { return }

        // Attach player for TTS playout
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        print("[Audio] Hardware format: \(hwFormat)")

        // Convert to 16kHz mono for capture
        guard let convertFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: captureSampleRate,
                                                 channels: 1, interleaved: false) else {
            print("[Audio] Cannot create convert format")
            return
        }
        captureConverter = AVAudioConverter(from: hwFormat, to: convertFormat)

        // Install capture tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, time in
            self?.processCaptureBuffer(buffer)
        }

        do {
            try engine.start()
            player.play()
            print("[Audio] Engine started, capture active")
        } catch {
            print("[Audio] Engine start failed: \(error)")
        }
    }

    private func processCaptureBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted, let converter = captureConverter else { return }

        // Convert to 16kHz mono
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * captureSampleRate / buffer.format.sampleRate)
        guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        var hasData = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if hasData { outStatus.pointee = .noDataNow; return nil }
            hasData = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard converted.frameLength > 0, let floatData = converted.floatChannelData?[0] else { return }
        let frameCount = Int(converted.frameLength)

        // Run through AFE capture processing (AEC + NS)
        if let afe = afeProcessor {
            var channelPtr = floatData
            // Scale to FloatS16 range for AFE
            var scale: Float = 32767.0
            vDSP_vsmul(floatData, 1, &scale, floatData, 1, vDSP_Length(frameCount))

            withUnsafeMutablePointer(to: &channelPtr) { ptr in
                afe.processCaptureChannels(ptr, frameCount: Int32(frameCount), numChannels: 1)
            }

            // Scale back
            var invScale: Float = 1.0 / 32767.0
            vDSP_vsmul(floatData, 1, &invScale, floatData, 1, vDSP_Length(frameCount))
        }

        // Energy VAD on post-AFE audio
        var rms: Float = 0
        vDSP_measqv(floatData, 1, &rms, vDSP_Length(frameCount))
        let db = 10 * log10f(max(rms, 1e-10))
        let isSpeechFrame = db > speechThresholdDB

        if isSpeechFrame {
            speechFrameCount += 1
            silenceFrameCount = 0
            if !isSpeaking && speechFrameCount >= 3 {
                isSpeaking = true
                speechBuffer = Data()
                onVADStateChanged?(true)
            }
        } else {
            silenceFrameCount += 1
            speechFrameCount = max(0, speechFrameCount - 1)
            if isSpeaking && silenceFrameCount >= silenceTimeout {
                isSpeaking = false
                onVADStateChanged?(false)
                if speechBuffer.count > 6400 { // >200ms at 16kHz 16-bit
                    onSpeechSegment?(speechBuffer)
                }
                speechBuffer = Data()
            }
        }

        // Accumulate PCM while speaking
        if isSpeaking {
            var pcm = Data(capacity: frameCount * 2)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                var sample = Int16(clamped * 32767)
                withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            }
            speechBuffer.append(pcm)
        }
    }

    func stopCapture() {
        if isSpeaking && !speechBuffer.isEmpty {
            onSpeechSegment?(speechBuffer)
            speechBuffer = Data()
            isSpeaking = false
        }
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        captureConverter = nil
        afeProcessor = nil
    }

    // MARK: - Playback

    func playAudio(pcmData: Data, sampleRate: Double = 24000) {
        guard let player = playerNode, pcmData.count > 1 else { return }

        let frameCount = pcmData.count / 2
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                                frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        pcmData.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress else { return }
            memcpy(pcmBuffer.int16ChannelData![0], src, pcmData.count)
        }

        // Feed to AFE render for echo reference
        if let afe = afeProcessor, let int16Data = pcmBuffer.int16ChannelData?[0] {
            // Convert to float for AFE
            let floatBuf = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            defer { floatBuf.deallocate() }
            for i in 0..<frameCount {
                floatBuf[i] = Float(int16Data[i])  // Already in FloatS16 range
            }
            var channelPtr = floatBuf
            withUnsafeMutablePointer(to: &channelPtr) { ptr in
                afe.processRenderChannels(ptr, frameCount: Int32(frameCount), numChannels: 1)
            }
        }

        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    func interruptPlayback() {
        playerNode?.stop()
        playerNode?.play()
    }

    // MARK: - Controls

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted { speechBuffer = Data(); isSpeaking = false }
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        #endif
    }
}
