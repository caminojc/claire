import SwiftUI

struct ContentView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack {
            // Animated ambient background with audio energy
            AudioEnergyBackground()
                .ignoresSafeArea()

            VStack {
                // Top bar
                TopBar()

                Spacer()

                // Center content depends on call state
                if callManager.state == .idle {
                    IdleView()
                } else {
                    // Status text during call
                    if !callManager.statusMessage.isEmpty {
                        Text(callManager.statusMessage)
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .lineLimit(3)
                    }
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

// MARK: - Audio Energy Background

struct AudioEnergyBackground: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                // Base dark background
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                if callManager.state == .connected {
                    let micLevel = CGFloat(callManager.userLevel)
                    let ttsLevel = CGFloat(callManager.streamingLevel)

                    // Mic energy: warm blue/cyan glow from bottom-left
                    if micLevel > 0.01 || callManager.isSpeaking {
                        let intensity = callManager.isSpeaking ? max(micLevel, 0.3) : micLevel
                        let radius = size.width * (0.3 + intensity * 0.5)
                        let pulse = sin(time * 4) * 0.1 + 0.9
                        let cx = size.width * 0.25
                        let cy = size.height * 0.7

                        let micGradient = Gradient(colors: [
                            Color(red: 0.1, green: 0.5, blue: 0.9).opacity(intensity * pulse * 0.6),
                            Color(red: 0.05, green: 0.3, blue: 0.7).opacity(intensity * pulse * 0.3),
                            Color.clear,
                        ])
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: cx - radius, y: cy - radius,
                                width: radius * 2, height: radius * 2
                            )),
                            with: .radialGradient(micGradient,
                                center: CGPoint(x: cx, y: cy),
                                startRadius: 0, endRadius: radius)
                        )
                    }

                    // TTS energy: warm amber/gold glow from top-right
                    if ttsLevel > 0.01 {
                        let radius = size.width * (0.3 + ttsLevel * 0.6)
                        let pulse = sin(time * 3 + 1.5) * 0.1 + 0.9
                        let cx = size.width * 0.75
                        let cy = size.height * 0.3

                        let ttsGradient = Gradient(colors: [
                            Color(red: 0.9, green: 0.6, blue: 0.1).opacity(ttsLevel * pulse * 0.5),
                            Color(red: 0.7, green: 0.4, blue: 0.05).opacity(ttsLevel * pulse * 0.25),
                            Color.clear,
                        ])
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: cx - radius, y: cy - radius,
                                width: radius * 2, height: radius * 2
                            )),
                            with: .radialGradient(ttsGradient,
                                center: CGPoint(x: cx, y: cy),
                                startRadius: 0, endRadius: radius)
                        )
                    }
                } else {
                    // Idle: subtle ambient glow
                    let pulse = sin(time * 0.5) * 0.03 + 0.07
                    let idleGradient = Gradient(colors: [
                        Color(red: 0.15, green: 0.15, blue: 0.3).opacity(pulse),
                        Color.clear,
                    ])
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: size.width * 0.1, y: size.height * 0.2,
                            width: size.width * 0.8, height: size.height * 0.6
                        )),
                        with: .radialGradient(idleGradient,
                            center: CGPoint(x: size.width * 0.5, y: size.height * 0.4),
                            startRadius: 0, endRadius: size.width * 0.5)
                    )
                }
            }
        }
    }
}

// MARK: - Top Bar

struct TopBar: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        HStack {
            Spacer()

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
                        .foregroundColor(Color(red: 0.16, green: 0.38, blue: 1.0))
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

                    // Mic toggle with speaking indicator
                    Button(action: {
                        callManager.toggleMute()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(callManager.isMuted ? 0.3 : 0.15))
                                .frame(width: 48, height: 48)

                            if callManager.isSpeaking && !callManager.isMuted {
                                Circle()
                                    .stroke(Color(red: 0.1, green: 0.5, blue: 0.9), lineWidth: 2)
                                    .frame(width: 52, height: 52)
                            }

                            Image(systemName: callManager.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 18))
                                .foregroundColor(callManager.isSpeaking ? Color(red: 0.1, green: 0.5, blue: 0.9) : .white)
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

#Preview {
    ContentView()
        .environmentObject(CallManager())
}
