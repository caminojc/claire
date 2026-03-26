import Foundation
import Combine

enum CallState {
    case idle
    case connecting
    case connected
    case disconnecting
}

/// Manages Claire voice call lifecycle and state.
/// Will integrate with Zipper SDK and WebSocket transport once ported.
@MainActor
class CallManager: ObservableObject {
    @Published var state: CallState = .idle
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var callDuration: TimeInterval = 0

    private var callTimer: Timer?
    private var callStartTime: Date?

    var formattedDuration: String {
        let minutes = Int(callDuration) / 60
        let seconds = Int(callDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Call Lifecycle

    func startCall() {
        state = .connecting

        // TODO: Initialize Zipper SDK audio engine
        // TODO: Connect WebSocket to server
        // TODO: Send UnifiedRequest.Config

        // For now, simulate connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.state = .connected
            self?.callStartTime = Date()
            self?.startTimer()
        }
    }

    func endCall() {
        state = .disconnecting
        stopTimer()

        // TODO: Stop audio engine
        // TODO: Close WebSocket

        state = .idle
        callDuration = 0
        isMuted = false
    }

    func toggleMute() {
        isMuted.toggle()
        // TODO: callZipperSdk.muteMic(isMuted)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        // TODO: Update AVAudioSession route
    }

    // MARK: - Timer

    private func startTimer() {
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
