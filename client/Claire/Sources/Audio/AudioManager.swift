import AVFoundation
import Accelerate
#if os(macOS)
import AVKit
#endif

/// Minimal audio pipeline: AVAudioEngine capture → VAD → PCM segments
/// TTS playback via AVAudioPlayerNode
class AudioManager {

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureConverter: AVAudioConverter?
    private let captureSampleRate: Double = 16000

    // VAD
    private var isSpeaking = false
    private var speechBuffer = Data()
    private var silenceFrameCount = 0
    private var speechFrameCount = 0
    private let speechThresholdDB: Float = -40
    private let silenceTimeout = 30
    private var isMuted = false
    private var bufferCount = 0

    private lazy var playbackFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    }()

    // Callbacks
    var onSpeechSegment: ((Data) -> Void)?
    var onVADStateChanged: ((Bool) -> Void)?
    var onStatusMessage: ((String) -> Void)?

    // Levels
    var userSpeechLevel: Float = 0
    var playoutLevel: Float = 0

    // MARK: - Audio Session

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

    // MARK: - Start

    func startCapture() {
        print("[Audio] Requesting mic permission...")
        onStatusMessage?("Requesting mic access...")

        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("[Audio] Already authorized")
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        print("[Audio] Permission granted")
                        self?.startEngine()
                    } else {
                        print("[Audio] Permission denied")
                        self?.onStatusMessage?("Mic denied — check System Settings")
                    }
                }
            }
        default:
            print("[Audio] Permission denied/restricted")
            onStatusMessage?("Mic access denied")
        }
        #else
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted { self?.startEngine() }
                else { self?.onStatusMessage?("Mic denied") }
            }
        }
        #endif
    }

    private func startEngine() {
        print("[Audio] Starting engine...")
        onStatusMessage?("Starting audio...")

        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        guard let engine, let player = playerNode else {
            print("[Audio] FATAL: can't create engine")
            return
        }

        engine.attach(player)

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        print("[Audio] HW format: rate=\(hwFormat.sampleRate) ch=\(hwFormat.channelCount)")

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            print("[Audio] FATAL: invalid hw format")
            onStatusMessage?("No mic available")
            return
        }

        // Converter: hardware rate → 16kHz mono
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: captureSampleRate,
                                               channels: 1, interleaved: false) else { return }
        captureConverter = AVAudioConverter(from: hwFormat, to: targetFormat)

        // Connect player for TTS output
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        // Tap mic audio
        bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleCapture(buffer)
        }

        do {
            try engine.start()
            player.play()
            print("[Audio] Engine running!")
            onStatusMessage?("Ready — speak to Claire")
        } catch {
            print("[Audio] Start failed: \(error)")
            onStatusMessage?("Audio error: \(error.localizedDescription)")
        }
    }

    // MARK: - Capture Processing

    private func handleCapture(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted, let converter = captureConverter else { return }

        bufferCount += 1
        if bufferCount == 1 {
            print("[Audio] First buffer: \(buffer.frameLength) frames @ \(buffer.format.sampleRate)Hz")
        }

        // Resample to 16kHz mono
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * captureSampleRate / buffer.format.sampleRate)
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: max(outFrames, 160)) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let samples = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)

        // RMS energy
        var rms: Float = 0
        vDSP_measqv(samples, 1, &rms, vDSP_Length(count))
        let db = 10 * log10f(max(rms, 1e-10))
        userSpeechLevel = max(0, min(1, (db + 50) / 50))  // map -50..0 dB to 0..1

        let speaking = db > speechThresholdDB

        if speaking {
            speechFrameCount += 1
            silenceFrameCount = 0
            if !isSpeaking && speechFrameCount >= 3 {
                isSpeaking = true
                speechBuffer = Data()
                DispatchQueue.main.async { self.onVADStateChanged?(true) }
            }
        } else {
            silenceFrameCount += 1
            speechFrameCount = max(0, speechFrameCount - 1)
            if isSpeaking && silenceFrameCount >= silenceTimeout {
                isSpeaking = false
                DispatchQueue.main.async { self.onVADStateChanged?(false) }
                if speechBuffer.count > 6400 {
                    let seg = speechBuffer
                    DispatchQueue.main.async { self.onSpeechSegment?(seg) }
                }
                speechBuffer = Data()
            }
        }

        if isSpeaking {
            var pcm = Data(capacity: count * 2)
            for i in 0..<count {
                var s = Int16(max(-1, min(1, samples[i])) * 32767)
                withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
            }
            speechBuffer.append(pcm)
        }
    }

    // MARK: - Stop

    func stopCapture() {
        if isSpeaking && speechBuffer.count > 6400 {
            let seg = speechBuffer
            onSpeechSegment?(seg)
        }
        speechBuffer = Data()
        isSpeaking = false
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        captureConverter = nil
    }

    // MARK: - File Playback

    private var filePlayer: AVAudioPlayer?

    func playFile(_ url: URL) {
        do {
            filePlayer = try AVAudioPlayer(contentsOf: url)
            filePlayer?.play()
            print("[Audio] Playing file: \(url.lastPathComponent)")
        } catch {
            print("[Audio] playFile failed: \(error)")
        }
    }

    // MARK: - Playback

    private var ttsPlayer: AVAudioPlayer?

    func playAudio(pcmData: Data, sampleRate: Double = 24000) {
        guard pcmData.count > 1 else { return }

        // Wrap raw PCM in a WAV header so AVAudioPlayer can play it
        let wavData = createWavData(pcmData: pcmData, sampleRate: Int(sampleRate), channels: 1, bitsPerSample: 16)

        do {
            ttsPlayer = try AVAudioPlayer(data: wavData)
            ttsPlayer?.play()
            playoutLevel = 0.5
            print("[Audio] Playing TTS: \(pcmData.count) bytes (\(String(format: "%.1f", Double(pcmData.count) / 2.0 / sampleRate))s)")
        } catch {
            print("[Audio] playAudio error: \(error)")
        }
    }

    private func createWavData(pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let dataSize = pcmData.count
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var wav = Data()
        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + dataSize).littleEndian
        wav.append(Data(bytes: &fileSize, count: 4))
        wav.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        wav.append(contentsOf: "fmt ".utf8)
        var fmtSize = UInt32(16).littleEndian
        wav.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        wav.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = UInt16(channels).littleEndian
        wav.append(Data(bytes: &numChannels, count: 2))
        var sr = UInt32(sampleRate).littleEndian
        wav.append(Data(bytes: &sr, count: 4))
        var br = UInt32(byteRate).littleEndian
        wav.append(Data(bytes: &br, count: 4))
        var ba = UInt16(blockAlign).littleEndian
        wav.append(Data(bytes: &ba, count: 2))
        var bps = UInt16(bitsPerSample).littleEndian
        wav.append(Data(bytes: &bps, count: 2))
        // data chunk
        wav.append(contentsOf: "data".utf8)
        var ds = UInt32(dataSize).littleEndian
        wav.append(Data(bytes: &ds, count: 4))
        wav.append(pcmData)
        return wav
    }

    func interruptPlayback() {
        playerNode?.stop()
        playerNode?.play()
        playoutLevel = 0
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
