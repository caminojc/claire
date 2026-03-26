import Foundation
import Combine

enum CallState {
    case idle
    case connecting
    case connected
    case disconnecting
}

/// Manages Claire voice call lifecycle.
/// Uses SMPL Zipper SDK (via ClaireAudioBridge) for audio capture/playback
/// and WebSocket for server communication.
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

    private var callTimer: Timer?
    private var callStartTime: Date?
    private let webSocketClient = ClaireWebSocketClient()
    private var audioBridge: ClaireAudioBridge?
    private let audioBridgeDelegate = AudioBridgeDelegateAdapter()
    private var conversationHistory: [[String: String]] = []
    private var currentLlmResponse: String = ""
    private var sessionUuid: String = ""

    // Tracks pending encoded payloads by timeMs ID
    private var pendingPayloads: [Int32: Data] = [:]
    private var currentStreamId: Int32 = 0

    var formattedDuration: String {
        let minutes = Int(callDuration) / 60
        let seconds = Int(callDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    init() {
        webSocketClient.delegate = self
        audioBridgeDelegate.callManager = self
    }

    // MARK: - Call Lifecycle

    func startCall() {
        state = .connecting
        statusMessage = "Connecting..."
        sessionUuid = UUID().uuidString
        conversationHistory = [
            ["role": "prompt", "content": "You are Claire, a helpful voice agent."]
        ]

        // Initialize Zipper SDK audio bridge
        // TODO: Bundle AFE model files and pass correct paths
        let modelPath = Bundle.main.resourcePath ?? ""
        audioBridge = ClaireAudioBridge(
            afeModelPath: modelPath,
            aecModelPath: modelPath,
            vadModelPath: modelPath,
            afeConfigPath: modelPath
        )
        audioBridge?.delegate = audioBridgeDelegate

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

    func toggleMute() {
        isMuted.toggle()
        audioBridge?.muteMic(isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        // Speaker routing handled by CoreAudio engine inside Zipper SDK
    }

    // MARK: - Audio Bridge Callbacks (called by AudioBridgeDelegateAdapter)

    func handleEncodedPayload(_ data: Data, startTimeMs: Int32, timeMs: Int32) {
        // Store the encoded payload — will send when segment finishes
        pendingPayloads[timeMs] = data
        print("[Call] Encoded payload: \(data.count) bytes, timeMs=\(timeMs)")
    }

    func handleSegmentFinished(timeMs: Int32) {
        // Segment complete — send the payload to server
        guard let payload = pendingPayloads[timeMs] else {
            print("[Call] No payload for timeMs=\(timeMs)")
            return
        }
        pendingPayloads.removeAll()

        let uuid = UUID().uuidString
        currentStreamId = timeMs
        currentLlmResponse = ""

        print("[Call] Sending segment: \(payload.count) bytes")
        webSocketClient.sendAudio(uuid: uuid, audioData: payload, messages: conversationHistory)
    }

    func handleSegmentCancelled(timeMs: Int32) {
        // User kept speaking — payload will be resent with more data
        pendingPayloads.removeValue(forKey: timeMs)
    }

    func handleUserSpeechChanged(_ active: Bool) {
        isSpeaking = active
        if active {
            statusMessage = "Listening..."
            // Barge-in: stop any playing TTS
            audioBridge?.stopStreaming()
        }
    }

    func handleStreamingStarted(_ streamId: Int32) {
        // TTS playout started
    }

    func handleStreamingStopped(_ streamId: Int32, timeMs: Int32) {
        // TTS playout stopped (user interrupted or finished)
    }

    // MARK: - Timer

    private func startTimer() {
        callStartTime = Date()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.callStartTime else { return }
                self.callDuration = Date().timeIntervalSince(start)
                // Update audio levels
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

// MARK: - WebSocket Delegate

extension CallManager: ClaireWebSocketDelegate {
    nonisolated func didConnect() {
        Task { @MainActor in
            state = .connected
            statusMessage = "Connected"
            startTimer()

            // Send config — use mel codec since Zipper SDK encodes with it
            webSocketClient.sendConfig(uuid: sessionUuid, codecUpstream: "smpl-mel")

            // Start audio engine (Zipper SDK + CoreAudio)
            audioBridge?.start(withEncoderType: 0) // 0 = ENC_MelCodec
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
                if let sttText = json["stt_text_result"] as? String, !sttText.isEmpty {
                    statusMessage = "You: \(sttText)"
                    conversationHistory.append(["role": "user", "content": sttText])
                    currentLlmResponse = ""
                }

            case "llm_completion_result_response":
                if let chunk = json["llm_completion_result"] as? [String: Any],
                   let choices = chunk["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    currentLlmResponse += content
                    let display = currentLlmResponse.prefix(100)
                    statusMessage = "Claire: \(display)\(currentLlmResponse.count > 100 ? "..." : "")"
                }
                if let chunk = json["llm_completion_result"] as? [String: Any],
                   let choices = chunk["choices"] as? [[String: Any]],
                   let finishReason = choices.first?["finish_reason"] as? String,
                   finishReason == "stop" {
                    if !currentLlmResponse.isEmpty {
                        conversationHistory.append(["role": "assistant", "content": currentLlmResponse])
                    }
                }

            case "tts_audio_result_response":
                // JSON TTS audio — extract and feed to Zipper SDK playout
                if let ttsResult = json["tts_audio_result"] as? [String: Any],
                   let audioB64 = ttsResult["byteArray"] as? String,
                   let audioData = Data(base64Encoded: audioB64),
                   let isEnd = ttsResult["isEnd"] as? Bool {
                    audioBridge?.addStreamingData(
                        audioData,
                        streamId: currentStreamId,
                        format: "pcm_24000",
                        isEnd: isEnd
                    )
                }

            case "config_response":
                statusMessage = "Ready — speak to Claire"

            case "error_response":
                let msg = json["message"] as? String ?? "Unknown error"
                statusMessage = "Error: \(msg)"
                print("[Call] Server error: \(msg)")

            default:
                break
            }
        }
    }

    nonisolated func didReceiveBinary(_ data: Data) {
        Task { @MainActor in
            // Binary TTS audio (protobuf TtsResponseMessage)
            // Feed raw audio to Zipper SDK playout
            // TODO: Decode protobuf to extract audio bytes, format, isEnd
            audioBridge?.addStreamingData(
                data,
                streamId: currentStreamId,
                format: "pcm_24000",
                isEnd: false
            )
        }
    }
}

// MARK: - Audio Bridge Delegate Adapter
// Bridges ClaireAudioBridgeDelegate (Obj-C protocol) to CallManager (Swift @MainActor)

class AudioBridgeDelegateAdapter: NSObject, ClaireAudioBridgeDelegate {
    weak var callManager: CallManager?

    func onEncodedPayload(_ data: Data, startTimeMs: Int32, timeMs: Int32) {
        Task { @MainActor in
            callManager?.handleEncodedPayload(data, startTimeMs: startTimeMs, timeMs: timeMs)
        }
    }

    func onSegmentFinished(_ timeMs: Int32) {
        Task { @MainActor in
            callManager?.handleSegmentFinished(timeMs: timeMs)
        }
    }

    func onSegmentCancelled(_ timeMs: Int32) {
        Task { @MainActor in
            callManager?.handleSegmentCancelled(timeMs: timeMs)
        }
    }

    func onUserSpeechChanged(_ active: Bool) {
        Task { @MainActor in
            callManager?.handleUserSpeechChanged(active)
        }
    }

    func onStreamingStarted(_ streamId: Int32) {
        Task { @MainActor in
            callManager?.handleStreamingStarted(streamId)
        }
    }

    func onStreamingStopped(_ streamId: Int32, timeMs: Int32) {
        Task { @MainActor in
            callManager?.handleStreamingStopped(streamId, timeMs: timeMs)
        }
    }
}
