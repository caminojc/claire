import AVFoundation
import Accelerate

/// Full audio pipeline for Claire.
/// Captures mic at 16kHz mono, runs energy-based VAD,
/// accumulates speech segments, plays TTS audio.
class AudioManager: NSObject {

    // Capture
    private var captureEngine: AVAudioEngine?
    private var captureConverter: AVAudioConverter?
    private let captureSampleRate: Double = 16000
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    // VAD state
    private var isSpeaking = false
    private var speechBuffer = Data()
    private var silenceFrameCount = 0
    private var speechFrameCount = 0
    private let speechThresholdDB: Float = -35   // dB threshold to detect speech
    private let silenceTimeout = 25               // ~500ms at 50Hz (10ms frames at 16kHz with 320 samples)
    private let minSpeechFrames = 10              // ~200ms minimum speech
    private var isMuted = false

    // Playback
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var isPlaybackSetup = false

    // Callbacks
    var onSpeechSegment: ((Data) -> Void)?
    var onVADStateChanged: ((Bool) -> Void)?

    // MARK: - Audio Session

    func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(captureSampleRate)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            print("[Audio] Session config failed: \(error)")
        }
        #endif
    }

    // MARK: - Capture + VAD

    func startCapture() {
        captureEngine = AVAudioEngine()
        guard let engine = captureEngine else { return }

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        print("[Audio] Hardware format: \(hardwareFormat)")

        // Target format: 16kHz mono Float32 (for conversion)
        guard let convertFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: captureSampleRate, channels: 1, interleaved: false) else {
            print("[Audio] Cannot create convert format")
            return
        }

        // Create converter from hardware format to 16kHz mono
        captureConverter = AVAudioConverter(from: hardwareFormat, to: convertFormat)

        // Tap at hardware rate, convert in callback
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, time in
            self?.processCaptureBuffer(buffer)
        }

        do {
            try engine.start()
            print("[Audio] Capture started")
        } catch {
            print("[Audio] Engine start failed: \(error)")
        }

        setupPlayback()
    }

    private func processCaptureBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted, let converter = captureConverter else { return }

        // Convert to 16kHz mono Float32
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * captureSampleRate / buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        var hasData = false
        converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
            if hasData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("[Audio] Conversion error: \(error)")
            return
        }

        guard convertedBuffer.frameLength > 0, let floatData = convertedBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(convertedBuffer.frameLength)

        // Compute RMS energy in dB
        var rms: Float = 0
        vDSP_measqv(floatData, 1, &rms, vDSP_Length(frameCount))
        let db = 10 * log10f(max(rms, 1e-10))

        let isSpeechFrame = db > speechThresholdDB

        if isSpeechFrame {
            speechFrameCount += 1
            silenceFrameCount = 0

            if !isSpeaking && speechFrameCount >= 3 {
                // Speech started
                isSpeaking = true
                speechBuffer = Data()
                onVADStateChanged?(true)
            }
        } else {
            silenceFrameCount += 1
            speechFrameCount = max(0, speechFrameCount - 1)

            if isSpeaking && silenceFrameCount >= silenceTimeout {
                // Speech ended — send segment if long enough
                isSpeaking = false
                onVADStateChanged?(false)

                if speechBuffer.count > Int(captureSampleRate) * 2 * minSpeechFrames / 50 {
                    // More than ~200ms of speech
                    let segment = speechBuffer
                    speechBuffer = Data()
                    onSpeechSegment?(segment)
                } else {
                    speechBuffer = Data()
                }
            }
        }

        // Accumulate PCM 16-bit data while speaking
        if isSpeaking {
            var pcmData = Data(capacity: frameCount * 2)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                var sample = Int16(clamped * 32767)
                withUnsafeBytes(of: &sample) { pcmData.append(contentsOf: $0) }
            }
            speechBuffer.append(pcmData)
        }
    }

    func stopCapture() {
        // Flush any remaining speech
        if isSpeaking && !speechBuffer.isEmpty {
            let segment = speechBuffer
            speechBuffer = Data()
            isSpeaking = false
            onSpeechSegment?(segment)
        }

        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        captureEngine = nil
        captureConverter = nil

        stopPlayback()
    }

    // MARK: - Playback

    private func setupPlayback() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        guard let engine = playbackEngine, let player = playerNode else { return }

        engine.attach(player)

        // Connect player to output with 24kHz format
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        // Use the mixer to handle format conversion
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        do {
            try engine.start()
            player.play()
            isPlaybackSetup = true
            print("[Audio] Playback engine started")
        } catch {
            print("[Audio] Playback engine failed: \(error)")
        }
    }

    /// Play PCM 16-bit 24kHz mono audio data from TTS server
    func playAudio(pcmData: Data, sampleRate: Double = 24000) {
        guard isPlaybackSetup, let player = playerNode, pcmData.count > 0 else { return }

        let frameCount = pcmData.count / 2  // 16-bit = 2 bytes per sample
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy PCM bytes into the buffer
        pcmData.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress else { return }
            memcpy(pcmBuffer.int16ChannelData![0], src, pcmData.count)
        }

        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    /// Stop any playing audio (for barge-in)
    func stopPlayback() {
        playerNode?.stop()
        playbackEngine?.stop()
        isPlaybackSetup = false
        playbackEngine = nil
        playerNode = nil
    }

    func interruptPlayback() {
        playerNode?.stop()
        playerNode?.play() // Reset for next chunks
    }

    // MARK: - Controls

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            // Flush speech buffer on mute
            speechBuffer = Data()
            isSpeaking = false
        }
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        } catch {
            print("[Audio] Speaker toggle failed: \(error)")
        }
        #endif
    }
}
