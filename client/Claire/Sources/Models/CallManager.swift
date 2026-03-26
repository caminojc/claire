import Foundation
import Combine

enum CallState {
    case idle
    case connecting
    case connected
    case disconnecting
}

/// Manages Claire voice call lifecycle.
/// macOS: uses Swift AVAudioEngine for capture + simple VAD, sends PCM to server
/// iOS: will use Zipper SDK (SmplCoreAudioEngine) once deployed on device
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
            ["role": "prompt", "content": "You are Claire, a helpful voice agent."]
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

            // Send config — PCM16 since we're using Swift capture (not mel codec)
            webSocketClient.sendConfig(uuid: sessionUuid, codecUpstream: "pcm16_16kHz")

            // Wire audio: speech segments sent to server
            audioManager.onSpeechSegment = { [weak self] segment in
                Task { @MainActor in
                    guard let self = self else { return }
                    let uuid = UUID().uuidString
                    self.currentLlmResponse = ""
                    print("[Call] Sending speech: \(segment.count) bytes (\(String(format: "%.1f", Double(segment.count) / 32000.0))s)")
                    self.webSocketClient.sendAudio(uuid: uuid, audioData: segment, messages: self.conversationHistory)
                }
            }

            audioManager.onVADStateChanged = { [weak self] speaking in
                Task { @MainActor in
                    self?.isSpeaking = speaking
                    if speaking {
                        self?.statusMessage = "Listening..."
                        // Barge-in: stop TTS playback
                        self?.audioManager.interruptPlayback()
                    }
                }
            }

            audioManager.startCapture()
            statusMessage = "Ready — speak to Claire"
        }
    }

    nonisolated func didDisconnect() {
        Task { @MainActor in
            if state != .idle {
                audioManager.stopCapture()
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
                    let display = currentLlmResponse.prefix(120)
                    statusMessage = "Claire: \(display)\(currentLlmResponse.count > 120 ? "..." : "")"
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
                if let ttsResult = json["tts_audio_result"] as? [String: Any],
                   let audioB64 = ttsResult["byteArray"] as? String,
                   let audioData = Data(base64Encoded: audioB64) {
                    audioManager.playAudio(pcmData: audioData)
                }

            case "config_response":
                print("[Call] Config acknowledged by server")

            case "error_response":
                let msg = json["message"] as? String ?? "Unknown error"
                statusMessage = "Error: \(msg)"
                print("[Call] Server error: \(msg)")

            default:
                print("[Call] Unknown response type: \(type)")
            }
        }
    }

    nonisolated func didReceiveBinary(_ data: Data) {
        Task { @MainActor in
            // Binary TTS audio
            audioManager.playAudio(pcmData: data)
        }
    }
}
