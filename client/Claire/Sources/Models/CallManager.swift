import Foundation
import Combine

enum CallState {
    case idle
    case connecting
    case connected
    case disconnecting
}

/// Manages Claire voice call lifecycle and state.
/// Connects to the Claire server via WebSocket and manages audio.
@MainActor
class CallManager: ObservableObject {
    @Published var state: CallState = .idle
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var callDuration: TimeInterval = 0
    @Published var lastSttText: String = ""
    @Published var lastLlmText: String = ""
    @Published var statusMessage: String = ""

    private var callTimer: Timer?
    private var callStartTime: Date?
    private let webSocketClient = ClaireWebSocketClient()
    private let audioManager = AudioManager()

    var formattedDuration: String {
        let minutes = Int(callDuration) / 60
        let seconds = Int(callDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    init() {
        webSocketClient.delegate = self
    }

    // MARK: - Call Lifecycle

    func startCall() {
        state = .connecting
        statusMessage = "Connecting..."
        audioManager.configureAudioSession()
        webSocketClient.connect()
    }

    func endCall() {
        state = .disconnecting
        stopTimer()
        audioManager.stopCapture()
        webSocketClient.disconnect()
        state = .idle
        callDuration = 0
        isMuted = false
        lastSttText = ""
        lastLlmText = ""
        statusMessage = ""
    }

    func toggleMute() {
        isMuted.toggle()
        audioManager.setMuted(isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        audioManager.setSpeakerEnabled(isSpeakerOn)
    }

    // MARK: - Timer

    private func startTimer() {
        callStartTime = Date()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.callStartTime else { return }
                self.callDuration = Date().timeIntervalSince(start)
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

            // Send config
            let uuid = UUID().uuidString
            webSocketClient.sendConfig(uuid: uuid)

            // Start audio capture
            audioManager.onAudioCaptured = { [weak self] pcmData in
                // TODO: Accumulate audio and send as payload
                // For now this is a placeholder — real implementation
                // will use Zipper SDK for VAD + segmentation
            }
            audioManager.startCapture()
        }
    }

    nonisolated func didDisconnect() {
        Task { @MainActor in
            if state != .idle {
                state = .idle
                stopTimer()
                statusMessage = "Disconnected"
            }
        }
    }

    nonisolated func didReceiveText(_ text: String) {
        Task { @MainActor in
            // Parse server response
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }

            switch type {
            case "stt_text_result_response":
                if let sttText = json["stt_text_result"] as? String {
                    lastSttText = sttText
                    statusMessage = "You: \(sttText)"
                }
            case "llm_completion_result_response":
                if let chunk = json["llm_completion_result"] as? [String: Any],
                   let choices = chunk["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    lastLlmText += content
                    statusMessage = "Claire: \(lastLlmText)"
                }
                if let chunk = json["llm_completion_result"] as? [String: Any],
                   let choices = chunk["choices"] as? [[String: Any]],
                   let finishReason = choices.first?["finish_reason"] as? String,
                   finishReason == "stop" {
                    // LLM done, reset for next turn
                    lastLlmText = ""
                }
            case "config_response":
                statusMessage = "Session configured"
            case "error_response":
                let msg = json["message"] as? String ?? "Unknown error"
                statusMessage = "Error: \(msg)"
            default:
                break
            }
        }
    }

    nonisolated func didReceiveBinary(_ data: Data) {
        Task { @MainActor in
            // TTS audio (protobuf TtsResponseMessage)
            // TODO: Decode protobuf and play audio via AudioManager
            audioManager.playAudio(pcmData: data)
        }
    }
}
