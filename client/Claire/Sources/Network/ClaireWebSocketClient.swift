import Foundation

/// WebSocket client for Claire server.
/// Will be replaced by SmplIxWebSocketTransport (C++) once ported from Atria.
/// This Swift implementation serves as a reference / fallback.
class ClaireWebSocketClient: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let serverUrl: String

    weak var delegate: ClaireWebSocketDelegate?

    init(serverUrl: String = "ws://localhost:8080/unified") {
        self.serverUrl = serverUrl
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - Connection

    func connect() {
        guard let url = URL(string: serverUrl) else { return }
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()
        listenForMessages()
        delegate?.didConnect()
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        delegate?.didDisconnect()
    }

    // MARK: - Send

    func sendConfig(uuid: String, codecUpstream: String = "pcm16_16kHz") {
        let config: [String: Any] = [
            "type": "config_request",
            "uuid": uuid,
            "codec_version": 0,
            "codec_upstream": codecUpstream,
            "enable_llm": true,
            "enable_tts": true,
            "send_llm_response_to_client": true,
            "stt_name": "parakeet",
            "llm_name": "claude",
            "tts_prefs": [
                "verNumber": 5,
                "format": "pcm_24000",
                "voiceId": "af_heart",
                "ttsProvider": "kokoro",
            ],
            "tts_protobuf_version": 2,
            "payload_protobuf_version": 1,
            "respond_back": true,
        ] as [String: Any]

        if let data = try? JSONSerialization.data(withJSONObject: config),
           let text = String(data: data, encoding: .utf8) {
            webSocket?.send(.string(text)) { error in
                if let error { print("Config send error: \(error)") }
            }
        }
    }

    func sendAudio(uuid: String, audioData: Data, messages: [[String: String]]) {
        // TODO: Use protobuf PayloadRequestMessage for binary transport
        // For now, send as JSON payload
        let payload: [String: Any] = [
            "type": "payload_request",
            "uuid": uuid,
            "payload": audioData.base64EncodedString(),
            "time_ms": Int(Date().timeIntervalSince1970 * 1000),
            "chat_completion_request": [
                "model": "claude",
                "messages": messages,
            ],
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            webSocket?.send(.string(text)) { error in
                if let error { print("Payload send error: \(error)") }
            }
        }
    }

    // MARK: - Receive

    private func listenForMessages() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.delegate?.didReceiveText(text)
                case .data(let data):
                    self?.delegate?.didReceiveBinary(data)
                @unknown default:
                    break
                }
                // Keep listening
                self?.listenForMessages()

            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self?.delegate?.didDisconnect()
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension ClaireWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        delegate?.didConnect()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        delegate?.didDisconnect()
    }
}

// MARK: - Delegate Protocol

protocol ClaireWebSocketDelegate: AnyObject {
    func didConnect()
    func didDisconnect()
    func didReceiveText(_ text: String)
    func didReceiveBinary(_ data: Data)
}
