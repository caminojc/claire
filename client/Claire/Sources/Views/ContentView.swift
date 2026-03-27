import SwiftUI

struct ContentView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack {
            AudioEnergyBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar()
                    .padding(.top, 16)

                Spacer()

                CenterContent()

                Spacer()

                BottomBar()
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 20)
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 600, idealHeight: 720)
        #endif
    }
}

// MARK: - Center Content

struct CenterContent: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        if callManager.state == .idle {
            IdleView()
        } else if callManager.state == .connecting {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white.opacity(0.6))
                Text("Connecting...")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        } else {
            // Scrolling conversation
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(callManager.messages) { msg in
                            HStack {
                                if msg.role == "user" { Spacer() }
                                Text(msg.text)
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(.white.opacity(msg.role == "user" ? 0.9 : 0.75))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        msg.role == "user"
                                            ? Color(red: 0.16, green: 0.38, blue: 1.0).opacity(0.4)
                                            : Color.white.opacity(0.08)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                if msg.role == "assistant" { Spacer() }
                            }
                            .id(msg.id)
                        }

                        if callManager.isSpeaking {
                            HStack {
                                Spacer()
                                Text("...")
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color(red: 0.16, green: 0.38, blue: 1.0).opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: callManager.messages.count) { _ in
                    if let last = callManager.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - Audio Energy Background

struct AudioEnergyBackground: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.04)))

                if callManager.state == .connected {
                    let micLevel = CGFloat(callManager.userLevel)
                    let ttsLevel = CGFloat(callManager.streamingLevel)

                    // Mic energy: cool blue from bottom
                    let micIntensity = callManager.isSpeaking ? max(micLevel, 0.25) : micLevel * 0.5
                    if micIntensity > 0.01 {
                        let r = size.width * (0.4 + micIntensity * 0.4)
                        let p = CGFloat(sin(time * 3.5) * 0.08 + 0.92)
                        let cx = size.width * 0.35
                        let cy = size.height * 0.75
                        let grad = Gradient(colors: [
                            Color(red: 0.16, green: 0.38, blue: 1.0).opacity(micIntensity * p * 0.45),
                            Color(red: 0.08, green: 0.22, blue: 0.7).opacity(micIntensity * p * 0.2),
                            Color.clear,
                        ])
                        context.fill(
                            Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                            with: .radialGradient(grad, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r)
                        )
                    }

                    // TTS energy: warm amber from top-right
                    if ttsLevel > 0.01 {
                        let r = size.width * (0.35 + ttsLevel * 0.5)
                        let p = CGFloat(sin(time * 2.8 + 1.2) * 0.08 + 0.92)
                        let cx = size.width * 0.7
                        let cy = size.height * 0.28
                        let grad = Gradient(colors: [
                            Color(red: 1.0, green: 0.65, blue: 0.15).opacity(ttsLevel * p * 0.4),
                            Color(red: 0.8, green: 0.45, blue: 0.08).opacity(ttsLevel * p * 0.18),
                            Color.clear,
                        ])
                        context.fill(
                            Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                            with: .radialGradient(grad, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r)
                        )
                    }
                } else {
                    // Idle: very subtle breathing glow
                    let breath = CGFloat(sin(time * 0.6) * 0.015 + 0.045)
                    let grad = Gradient(colors: [
                        Color(red: 0.16, green: 0.2, blue: 0.4).opacity(breath),
                        Color.clear,
                    ])
                    let r = size.width * 0.5
                    let cx = size.width * 0.5
                    let cy = size.height * 0.4
                    context.fill(
                        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 1.4)),
                        with: .radialGradient(grad, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r)
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
            Text("Claire")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial.opacity(0.6))
                .clipShape(Capsule())
            Spacer()
        }
    }
}

// MARK: - Idle View

struct IdleView: View {
    @EnvironmentObject var callManager: CallManager
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 16) {
            Button(action: { callManager.startCall() }) {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 76, height: 76)
                        .shadow(color: Color(red: 0.16, green: 0.38, blue: 1.0).opacity(isHovering ? 0.5 : 0.2), radius: isHovering ? 20 : 10)

                    Image(systemName: "phone.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .scaleEffect(isHovering ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)

            Text("Start a call")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: - Bottom Bar

struct BottomBar: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        VStack(spacing: 14) {
            if callManager.state == .connected {
                HStack(spacing: 16) {
                    // Hangup
                    Button(action: { callManager.endCall() }) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.9))
                                .frame(width: 54, height: 54)
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)

                    // Timer
                    Text(callManager.formattedDuration)
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 55, alignment: .leading)

                    Spacer()

                    // Mic
                    Button(action: { callManager.toggleMute() }) {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial.opacity(0.5))
                                .frame(width: 46, height: 46)

                            if callManager.isSpeaking && !callManager.isMuted {
                                Circle()
                                    .stroke(Color(red: 0.16, green: 0.5, blue: 1.0), lineWidth: 2)
                                    .frame(width: 50, height: 50)
                                    .transition(.scale.combined(with: .opacity))
                            }

                            Image(systemName: callManager.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(callManager.isSpeaking && !callManager.isMuted
                                    ? Color(red: 0.3, green: 0.6, blue: 1.0) : .white.opacity(0.8))
                        }
                        .animation(.easeOut(duration: 0.15), value: callManager.isSpeaking)
                    }
                    .buttonStyle(.plain)

                    // Speaker
                    Button(action: { callManager.toggleSpeaker() }) {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial.opacity(0.5))
                                .frame(width: 46, height: 46)
                            Image(systemName: callManager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
            }

            // Text input
            HStack {
                Image(systemName: "text.bubble")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Send a text", text: $callManager.textInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .onSubmit {
                        callManager.sendText()
                    }
                if !callManager.textInput.isEmpty {
                    Button(action: { callManager.sendText() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 1.0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(CallManager())
}
