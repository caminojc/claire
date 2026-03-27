import Foundation
import Combine

enum CallState {
    case idle
    case connecting
    case connected
    case disconnecting
}

/// Claire voice call manager.
/// Uses Zipper SDK (via ClaireAudioBridge) for audio with full AFE.
/// PortAudio on macOS, CoreAudio on iOS.
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
        statusMessage = "Connecting..."
        sessionUuid = UUID().uuidString
        conversationHistory = [
            ["role": "prompt", "content": "You are Claire, a helpful voice agent."]
        ]

        // Init Zipper SDK with model directory
        let modelDir = Bundle.main.resourcePath ?? ""
        print("[Call] Init Zipper SDK with models at: \(modelDir)")
        audioBridge = ClaireAudioBridge(modelDirectory: modelDir)
        audioBridge?.delegate = bridgeDelegate

        webSocketClient.connect()
    }

    func endCall() {
        state = .disconnecting
        stopTimer()
        audioBridge?.stop()
        audioBridge = nil
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
        statusMessage = "You: \(text)"
        currentLlmResponse = ""
        webSocketClient.sendAudio(uuid: UUID().uuidString, audioData: Data(), messages: conversationHistory)
    }

    func toggleMute() {
        isMuted.toggle()
        audioBridge?.muteMic(isMuted)
    }

    func toggleSpeaker() { isSpeakerOn.toggle() }

    // MARK: - Zipper SDK Callbacks

    func handleEncodedPayload(_ data: Data, startTimeMs: Int32, timeMs: Int32) {
        pendingPayloads[timeMs] = data
        print("[Call] Encoded: \(data.count)b id=\(timeMs)")
    }

    func handleSegmentFinished(timeMs: Int32) {
        guard let payload = pendingPayloads[timeMs] else { return }
        pendingPayloads.removeAll()
        currentStreamId = timeMs
        currentLlmResponse = ""
        print("[Call] Segment done: \(payload.count)b → server")
        webSocketClient.sendAudio(uuid: UUID().uuidString, audioData: payload, messages: conversationHistory)
    }

    func handleSegmentCancelled(timeMs: Int32) {
        pendingPayloads.removeValue(forKey: timeMs)
    }

    func handleUserSpeechChanged(_ active: Bool) {
        isSpeaking = active
        if active { statusMessage = "Listening..." }
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
        callTimer?.invalidate()
        callTimer = nil
        callStartTime = nil
    }
}

// MARK: - WebSocket

extension CallManager: ClaireWebSocketDelegate {
    nonisolated func didConnect() {
        Task { @MainActor in
            state = .connected
            startTimer()
            // PCM16 16kHz — server STT expects PCM, not mel
            webSocketClient.sendConfig(uuid: sessionUuid, codecUpstream: "pcm16_16kHz")
            // Start Zipper SDK audio (PortAudio + AFE + VAD) with PCM16 encoder
            audioBridge?.start(withEncoderType: 2) // ENC_PCM16_16KHZ
            statusMessage = "Ready — speak to Claire"
        }
    }

    nonisolated func didDisconnect() {
        Task { @MainActor in
            if state != .idle {
                audioBridge?.stop()
                state = .idle
                stopTimer()
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
                    statusMessage = "You: \(stt)"
                    conversationHistory.append(["role": "user", "content": stt])
                    currentLlmResponse = ""
                }
            case "llm_completion_result_response":
                if let c = json["llm_completion_result"] as? [String: Any],
                   let ch = c["choices"] as? [[String: Any]],
                   let d = ch.first?["delta"] as? [String: Any],
                   let t = d["content"] as? String {
                    currentLlmResponse += t
                    statusMessage = "Claire: \(currentLlmResponse.prefix(120))\(currentLlmResponse.count > 120 ? "..." : "")"
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
                    print("[Call] TTS: \(audio.count)b → Zipper playout")
                    // Feed to Zipper SDK for playout (with AEC reference)
                    audioBridge?.addStreamingData(audio, streamId: currentStreamId,
                                                  decoderFormat: 2, isEnd: false) // DEC_PCM16_24KHZ=2
                }
            case "config_response":
                print("[Call] Config OK")
            case "error_response":
                statusMessage = "Error: \(json["message"] as? String ?? "unknown")"
            default: break
            }
        }
    }

    nonisolated func didReceiveBinary(_ data: Data) {
        print("[Call] Binary: \(data.count)b (ignored)")
    }
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
