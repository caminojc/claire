import SwiftUI

struct ContentView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack {
            // Ambient gradient background
            AmbientBackground()
                .ignoresSafeArea()

            VStack {
                // Top bar
                TopBar()

                Spacer()

                // Center content depends on call state
                if callManager.state == .idle {
                    IdleView()
                } else {
                    // Empty center during call (just the ambient background)
                }

                Spacer()

                // Bottom controls
                BottomBar()
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Top Bar

struct TopBar: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        HStack {
            if callManager.state != .idle {
                // No extra controls during idle
            }

            Spacer()

            // Name pill
            HStack(spacing: 4) {
                Text("Claire")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15))
            .clipShape(Capsule())

            Spacer()
        }
        .padding(.top, 8)
    }
}

// MARK: - Idle View (Start a Call)

struct IdleView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        VStack(spacing: 12) {
            Button(action: {
                callManager.startCall()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 72, height: 72)

                    Image(systemName: "phone.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.green.opacity(0.8))
                }
            }

            Text("Start a call")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: - Bottom Bar

struct BottomBar: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        VStack(spacing: 16) {
            if callManager.state == .connected {
                // In-call controls
                HStack {
                    // Hangup button
                    Button(action: {
                        callManager.endCall()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 56, height: 56)

                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.red)
                        }
                    }

                    // Call timer
                    Text(callManager.formattedDuration)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)

                    Spacer()

                    // Mic toggle
                    Button(action: {
                        callManager.toggleMute()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(callManager.isMuted ? 0.3 : 0.15))
                                .frame(width: 48, height: 48)

                            Image(systemName: callManager.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                        }
                    }

                    // Speaker toggle
                    Button(action: {
                        callManager.toggleSpeaker()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(callManager.isSpeakerOn ? 0.3 : 0.15))
                                .frame(width: 48, height: 48)

                            Image(systemName: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            // Text input (always visible)
            HStack {
                TextField("Send a text", text: .constant(""))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .foregroundColor(.white)
            }
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Ambient Background

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color.black

            // Warm ambient gradient matching the Maya UI reference
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.35, green: 0.35, blue: 0.15).opacity(0.8),
                    Color(red: 0.2, green: 0.2, blue: 0.1).opacity(0.5),
                    Color.black,
                ]),
                center: .init(x: 0.3, y: 0.3),
                startRadius: 50,
                endRadius: 400
            )
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(CallManager())
}
