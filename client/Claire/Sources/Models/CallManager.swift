import Foundation
import Combine
import AVFoundation
#if os(macOS)
import AVKit
#endif

enum CallState {
    case idle
    case connecting
    case connected
    case disconnecting
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String   // "user" or "assistant"
    var text: String
}

@MainActor
class CallManager: ObservableObject {
    @Published var state: CallState = .idle
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var callDuration: TimeInterval = 0
    @Published var statusMessage: String = ""
    @Published var isSpeaking = false
    @Published var userLevel: Float = 0
    @Published var streamingLevel: Float = 0
    @Published var textInput: String = ""
    @Published var messages: [ChatMessage] = []

    private var callTimer: Timer?
    private var callStartTime: Date?
    private let webSocketClient = ClaireWebSocketClient()
    private var audioBridge: ClaireAudioBridge?
    private let bridgeDelegate = BridgeDelegateAdapter()
    private var conversationHistory: [[String: String]] = []
    private var currentLlmResponse: String = ""
    private var sessionUuid: String = ""
    private var pendingPayloads: [Int32: Data] = [:]
    private var currentStreamId: Int32 = 0
    private var ttsPlayer: AVAudioPlayer?

    var formattedDuration: String {
        let m = Int(callDuration) / 60, s = Int(callDuration) % 60
        return String(format: "%d:%02d", m, s)
    }

    init() {
        webSocketClient.delegate = self
        bridgeDelegate.callManager = self
    }

    // MARK: - Call Lifecycle

    func startCall() {
        state = .connecting
        statusMessage = "Requesting mic..."
        sessionUuid = UUID().uuidString
        conversationHistory = [
            ["role": "prompt", "content": "You are Claire, a helpful voice agent."]
        ]
        messages = []

        #if os(macOS)
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                if granted { self?.initAndConnect() }
                else { self?.statusMessage = "Mic access denied"; self?.state = .idle }
            }
        }
        #else
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                if granted { self?.initAndConnect() }
                else { self?.statusMessage = "Mic access denied"; self?.state = .idle }
            }
        }
        #endif
    }

    private func initAndConnect() {
        statusMessage = "Connecting..."
        let modelDir = Bundle.main.resourcePath ?? ""
        audioBridge = ClaireAudioBridge(modelDirectory: modelDir)
        audioBridge?.delegate = bridgeDelegate
        webSocketClient.connect()
    }

    func endCall() {
        state = .disconnecting
        stopTimer()
        audioBridge?.stop()
        audioBridge = nil
        ttsPlayer?.stop()
        webSocketClient.disconnect()
        state = .idle
        callDuration = 0
        isMuted = false
        isSpeaking = false
        statusMessage = ""
        conversationHistory = []
        currentLlmResponse = ""
        pendingPayloads = [:]
    }

    func sendText() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textInput = ""
        conversationHistory.append(["role": "user", "content": text])
        messages.append(ChatMessage(role: "user", text: text))
        currentLlmResponse = ""
        webSocketClient.sendAudio(uuid: UUID().uuidString, audioData: Data(), messages: conversationHistory)
    }

    func toggleMute() { isMuted.toggle(); audioBridge?.muteMic(isMuted) }
    func toggleSpeaker() { isSpeakerOn.toggle() }

    // MARK: - Zipper SDK Callbacks

    func handleEncodedPayload(_ data: Data, startTimeMs: Int32, timeMs: Int32) {
        pendingPayloads[timeMs] = data
    }

    func handleSegmentFinished(timeMs: Int32) {
        guard let payload = pendingPayloads[timeMs] else { return }
        pendingPayloads.removeAll()
        currentStreamId = timeMs
        currentLlmResponse = ""
        webSocketClient.sendAudio(uuid: UUID().uuidString, audioData: payload, messages: conversationHistory)
    }

    func handleSegmentCancelled(timeMs: Int32) {
        pendingPayloads.removeValue(forKey: timeMs)
    }

    func handleUserSpeechChanged(_ active: Bool) {
        isSpeaking = active
        if active { statusMessage = "Listening..." }
    }

    // MARK: - TTS Playback Queue

    private var ttsQueue: [Data] = []
    private var ttsPlaying = false
    private var ttsDelegate: TtsDelegate?

    private func playTtsAudio(_ pcmData: Data) {
        ttsQueue.append(pcmData)
        if !ttsPlaying { playNextTtsChunk() }
    }

    private func playNextTtsChunk() {
        guard !ttsQueue.isEmpty else { ttsPlaying = false; return }
        ttsPlaying = true
        let pcmData = ttsQueue.removeFirst()

        let sr = 24000, ch = 1, bps = 16
        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        var fs = UInt32(36 + pcmData.count).littleEndian; wav.append(Data(bytes: &fs, count: 4))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        var cs = UInt32(16).littleEndian; wav.append(Data(bytes: &cs, count: 4))
        var af = UInt16(1).littleEndian; wav.append(Data(bytes: &af, count: 2))
        var nc = UInt16(ch).littleEndian; wav.append(Data(bytes: &nc, count: 2))
        var s = UInt32(sr).littleEndian; wav.append(Data(bytes: &s, count: 4))
        var br = UInt32(sr * ch * bps / 8).littleEndian; wav.append(Data(bytes: &br, count: 4))
        var ba = UInt16(ch * bps / 8).littleEndian; wav.append(Data(bytes: &ba, count: 2))
        var bp = UInt16(bps).littleEndian; wav.append(Data(bytes: &bp, count: 2))
        wav.append(contentsOf: "data".utf8)
        var ds = UInt32(pcmData.count).littleEndian; wav.append(Data(bytes: &ds, count: 4))
        wav.append(pcmData)

        do {
            ttsPlayer = try AVAudioPlayer(data: wav)
            ttsDelegate = TtsDelegate { [weak self] in
                Task { @MainActor in self?.playNextTtsChunk() }
            }
            ttsPlayer?.delegate = ttsDelegate
            ttsPlayer?.play()
        } catch {
            print("[Call] TTS play error: \(error)")
            playNextTtsChunk()
        }
    }

    class TtsDelegate: NSObject, AVAudioPlayerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) { onDone() }
    }

    // MARK: - Timer

    private func startTimer() {
        callStartTime = Date()
        callTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.callStartTime else { return }
                self.callDuration = Date().timeIntervalSince(start)
                self.userLevel = self.audioBridge?.userSpeechLevel ?? 0
                self.streamingLevel = self.audioBridge?.streamingLevel ?? 0
            }
        }
    }

    private func stopTimer() {
        callTimer?.invalidate(); callTimer = nil; callStartTime = nil
    }
}

// MARK: - WebSocket

extension CallManager: ClaireWebSocketDelegate {
    nonisolated func didConnect() {
        Task { @MainActor in
            state = .connected
            startTimer()
            webSocketClient.sendConfig(uuid: sessionUuid, codecUpstream: "pcm16_16kHz")
            audioBridge?.start(withEncoderType: 2) // ENC_PCM16_16KHZ
            statusMessage = ""
        }
    }

    nonisolated func didDisconnect() {
        Task { @MainActor in
            if state != .idle {
                audioBridge?.stop(); state = .idle; stopTimer()
                statusMessage = "Disconnected"
            }
        }
    }

    nonisolated func didReceiveText(_ text: String) {
        Task { @MainActor in
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }

            switch type {
            case "stt_text_result_response":
                if let stt = json["stt_text_result"] as? String, !stt.isEmpty {
                    conversationHistory.append(["role": "user", "content": stt])
                    messages.append(ChatMessage(role: "user", text: stt))
                    currentLlmResponse = ""
                }

            case "llm_completion_result_response":
                if let c = json["llm_completion_result"] as? [String: Any],
                   let ch = c["choices"] as? [[String: Any]],
                   let d = ch.first?["delta"] as? [String: Any],
                   let t = d["content"] as? String {
                    if currentLlmResponse.isEmpty {
                        // Start new assistant message
                        messages.append(ChatMessage(role: "assistant", text: t))
                    } else {
                        // Append to last assistant message
                        if var last = messages.last, last.role == "assistant" {
                            messages[messages.count - 1].text += t
                        }
                    }
                    currentLlmResponse += t
                }
                if let c = json["llm_completion_result"] as? [String: Any],
                   let ch = c["choices"] as? [[String: Any]],
                   let fr = ch.first?["finish_reason"] as? String, fr == "stop",
                   !currentLlmResponse.isEmpty {
                    conversationHistory.append(["role": "assistant", "content": currentLlmResponse])
                }

            case "tts_audio_result_response":
                if let b64 = json["audio_base64"] as? String,
                   let audio = Data(base64Encoded: b64) {
                    audioBridge?.addStreamingData(audio, streamId: currentStreamId, decoderFormat: 2, isEnd: false)
                    playTtsAudio(audio)
                }

            case "config_response":
                print("[Call] Config OK")

            case "error_response":
                let msg = json["message"] as? String ?? "unknown"
                messages.append(ChatMessage(role: "assistant", text: "Error: \(msg)"))

            default: break
            }
        }
    }

    nonisolated func didReceiveBinary(_ data: Data) {}
}

// MARK: - Bridge Delegate

class BridgeDelegateAdapter: NSObject, ClaireAudioBridgeDelegate {
    weak var callManager: CallManager?
    func onEncodedPayload(_ data: Data, startTimeMs: Int32, timeMs: Int32) {
        Task { @MainActor in callManager?.handleEncodedPayload(data, startTimeMs: startTimeMs, timeMs: timeMs) }
    }
    func onSegmentFinished(_ timeMs: Int32) {
        Task { @MainActor in callManager?.handleSegmentFinished(timeMs: timeMs) }
    }
    func onSegmentCancelled(_ timeMs: Int32) {
        Task { @MainActor in callManager?.handleSegmentCancelled(timeMs: timeMs) }
    }
    func onUserSpeechChanged(_ active: Bool) {
        Task { @MainActor in callManager?.handleUserSpeechChanged(active) }
    }
    func onStreamingStarted(_ streamId: Int32) {}
    func onStreamingStopped(_ streamId: Int32, timeMs: Int32) {}
}
