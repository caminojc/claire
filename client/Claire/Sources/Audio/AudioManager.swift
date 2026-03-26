import AVFoundation

/// Manages audio capture and playback for Claire.
/// Placeholder — will be replaced by SmplCoreAudioEngine + Zipper SDK
/// once ported from Atria's C++ layer.
class AudioManager: NSObject {

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    var onAudioCaptured: ((Data) -> Void)?

    // MARK: - Audio Session

    func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredIOBufferDuration(0.01) // 10ms
            try session.setActive(true)
        } catch {
            print("Audio session configuration failed: \(error)")
        }
        #endif
    }

    // MARK: - Capture

    func startCapture() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        inputNode = engine.inputNode
        let format = inputNode?.outputFormat(forBus: 0)

        // Install tap for mic audio
        inputNode?.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            // TODO: Route through SMPL AFE for echo cancellation
            // TODO: Encode with mel codec
            // For now, convert to PCM 16-bit data
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            var pcmData = Data(capacity: frameCount * 2)

            for i in 0..<frameCount {
                var sample = Int16(channelData[i] * 32767)
                pcmData.append(Data(bytes: &sample, count: 2))
            }

            self?.onAudioCaptured?(pcmData)
        }

        do {
            try engine.start()
        } catch {
            print("Audio engine start failed: \(error)")
        }
    }

    func stopCapture() {
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - Playback

    /// Play PCM audio data received from TTS server.
    /// TODO: Replace with Zipper SDK playout path (handles ducking, time-stretch, etc.)
    func playAudio(pcmData: Data, sampleRate: Double = 24000) {
        // Placeholder — will use SmplAudioProc render path
    }

    // MARK: - Controls

    func setMuted(_ muted: Bool) {
        // TODO: zipperClient.muteMic(muted)
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if enabled {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            print("Speaker toggle failed: \(error)")
        }
        #endif
    }
}
