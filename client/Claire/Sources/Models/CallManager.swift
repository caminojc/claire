import Foundation
import Combine

enum CallState {
    case idle
    case connecting
    case connected
    case disconnecting
}

/// Manages Claire voice call lifecycle.
/// Captures mic → VAD → send speech segment → receive STT/LLM/TTS → play audio.
@MainActor
class CallManager: ObservableObject {
    @Published var state: CallState = .idle
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var callDuration: TimeInterval = 0
    @Published var statusMessage: String = ""
    @Published var isSpeaking = false

    private var callTimer: Timer?
    private var callStartTime: Date?
    private let webSocketClient = ClaireWebSocketClient()
    private let audioManager = AudioManager()
    private var conversationHistory: [[String: String]] = []
    private var currentLlmResponse: String = ""
    private var sessionUuid: String = ""

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
        sessionUuid = UUID().uuidString
        conversationHistory = [
            ["role": "prompt", "content": "You are Claire, a warm and engaging voice AI companion."]
        ]
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
        isSpeaking = false
        statusMessage = ""
        conversationHistory = []
        currentLlmResponse = ""
    }

    func toggleMute() {
        isMuted.toggle()
        audioManager.setMuted(isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        audioManager.setSpeakerEnabled(isSpeakerOn)
    }

    // MARK: - Send Speech Segment

    private func sendSpeechSegment(_ pcmData: Data) {
        let uuid = UUID().uuidString

        // Interrupt any playing TTS (barge-in)
        audioManager.interruptPlayback()
        currentLlmResponse = ""

        print("[Call] Sending speech segment: \(pcmData.count) bytes (\(Double(pcmData.count) / 2.0 / 16000.0)s)")
        webSocketClient.sendAudio(uuid: uuid, audioData: pcmData, messages: conversationHistory)
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
            webSocketClient.sendConfig(uuid: sessionUuid)

            // Wire up audio: speech segments get sent to server
            audioManager.onSpeechSegment = { [weak self] segment in
                Task { @MainActor in
                    self?.sendSpeechSegment(segment)
                }
            }

            audioManager.onVADStateChanged = { [weak self] speaking in
                Task { @MainActor in
                    self?.isSpeaking = speaking
                    if speaking {
                        self?.statusMessage = "Listening..."
                    }
                }
            }

            audioManager.startCapture()
        }
    }

    nonisolated func didDisconnect() {
        Task { @MainActor in
            if state != .idle {
                state = .idle
                stopTimer()
                audioManager.stopCapture()
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
                    // Add to conversation history
                    conversationHistory.append(["role": "user", "content": sttText])
                    currentLlmResponse = ""
                }

            case "llm_completion_result_response":
                if let chunk = json["llm_completion_result"] as? [String: Any],
                   let choices = chunk["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    currentLlmResponse += content
                    // Show first ~100 chars
                    let display = currentLlmResponse.prefix(100)
                    statusMessage = "Claire: \(display)\(currentLlmResponse.count > 100 ? "..." : "")"
                }
                // Check for finish
                if let chunk = json["llm_completion_result"] as? [String: Any],
                   let choices = chunk["choices"] as? [[String: Any]],
                   let finishReason = choices.first?["finish_reason"] as? String,
                   finishReason == "stop" {
                    // Add assistant response to history
                    if !currentLlmResponse.isEmpty {
                        conversationHistory.append(["role": "assistant", "content": currentLlmResponse])
                    }
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
            // TTS audio — play it
            // For now treat as raw PCM (will need protobuf decode for TtsResponseMessage)
            audioManager.playAudio(pcmData: data)
        }
    }
}
