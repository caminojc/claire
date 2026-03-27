import SwiftUI

struct ContentView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ZStack {
            // Dynamic background
            ClaireBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if callManager.state == .connected {
                    // Conversation
                    ConversationView()
                        .padding(.top, 8)

                    Spacer(minLength: 0)

                    // Call controls
                    CallControls()
                        .padding(.bottom, 8)
                } else {
                    Spacer()
                    LandingView()
                    Spacer()
                }

                // Text input (always visible)
                TextInputBar()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 640, idealHeight: 740)
        #endif
    }
}

// MARK: - Background

struct ClaireBackground: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.03)))

                guard callManager.state == .connected else {
                    // Idle: subtle slow pulse
                    let p = CGFloat(sin(t * 0.4) * 0.02 + 0.04)
                    let g = Gradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.35).opacity(p), .clear])
                    ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.15, y: size.height * 0.25,
                        width: size.width * 0.7, height: size.height * 0.5)),
                        with: .radialGradient(g, center: CGPoint(x: size.width * 0.5, y: size.height * 0.4),
                            startRadius: 0, endRadius: size.width * 0.45))
                    return
                }

                let mic = CGFloat(callManager.userLevel)
                let tts = CGFloat(callManager.streamingLevel)

                // User speech: blue, bottom-center
                if mic > 0.02 || callManager.isSpeaking {
                    let i = callManager.isSpeaking ? max(mic, 0.2) : mic * 0.3
                    let r = size.width * (0.25 + i * 0.4)
                    let p = CGFloat(sin(t * 4) * 0.06 + 0.94)
                    let g = Gradient(colors: [
                        Color(red: 0.2, green: 0.4, blue: 1.0).opacity(i * p * 0.5),
                        Color(red: 0.1, green: 0.25, blue: 0.8).opacity(i * p * 0.2),
                        .clear
                    ])
                    let c = CGPoint(x: size.width * 0.5, y: size.height * 0.8)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(g, center: c, startRadius: 0, endRadius: r))
                }

                // Claire speaking: warm gold, top-center
                if tts > 0.02 {
                    let r = size.width * (0.3 + tts * 0.4)
                    let p = CGFloat(sin(t * 2.5 + 1) * 0.06 + 0.94)
                    let g = Gradient(colors: [
                        Color(red: 1.0, green: 0.7, blue: 0.2).opacity(tts * p * 0.4),
                        Color(red: 0.85, green: 0.5, blue: 0.1).opacity(tts * p * 0.15),
                        .clear
                    ])
                    let c = CGPoint(x: size.width * 0.5, y: size.height * 0.2)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(g, center: c, startRadius: 0, endRadius: r))
                }
            }
        }
    }
}

// MARK: - Landing (Idle)

struct LandingView: View {
    @EnvironmentObject var callManager: CallManager
    @State private var hover = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Claire")
                .font(.system(size: 32, weight: .light, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            Button(action: { callManager.startCall() }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.45, blue: 1.0))
                        .frame(width: 80, height: 80)
                        .shadow(color: Color(red: 0.2, green: 0.45, blue: 1.0).opacity(hover ? 0.6 : 0.3), radius: hover ? 24 : 12)

                    Image(systemName: "phone.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .scaleEffect(hover ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.15), value: hover)

            Text("Tap to call")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

// MARK: - Conversation

struct ConversationView: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(callManager.messages) { msg in
                        HStack(alignment: .bottom, spacing: 8) {
                            if msg.role == "user" { Spacer(minLength: 60) }
                            Text(msg.text)
                                .font(.system(size: 14, design: .rounded))
                                .foregroundStyle(.white.opacity(msg.role == "user" ? 0.95 : 0.8))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    msg.role == "user"
                                        ? Color(red: 0.2, green: 0.45, blue: 1.0).opacity(0.35)
                                        : Color.white.opacity(0.06)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .textSelection(.enabled)
                            if msg.role == "assistant" { Spacer(minLength: 60) }
                        }
                        .id(msg.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if callManager.isSpeaking {
                        HStack {
                            Spacer(minLength: 60)
                            HStack(spacing: 4) {
                                ForEach(0..<3) { i in
                                    Circle()
                                        .fill(Color(red: 0.2, green: 0.45, blue: 1.0).opacity(0.5))
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.2, green: 0.45, blue: 1.0).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: callManager.messages.count) { _ in
                if let last = callManager.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - Call Controls

struct CallControls: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        HStack(spacing: 20) {
            // End call
            Button(action: { callManager.endCall() }) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Timer
            Text(callManager.formattedDuration)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            // Mic
            Button(action: { callManager.toggleMute() }) {
                ZStack {
                    Circle()
                        .fill(callManager.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.08))
                        .frame(width: 46, height: 46)

                    if callManager.isSpeaking && !callManager.isMuted {
                        Circle()
                            .stroke(Color(red: 0.2, green: 0.45, blue: 1.0).opacity(0.7), lineWidth: 2)
                            .frame(width: 50, height: 50)
                    }

                    Image(systemName: callManager.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(callManager.isSpeaking && !callManager.isMuted
                            ? Color(red: 0.3, green: 0.55, blue: 1.0) : .white.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Text Input

struct TextInputBar: View {
    @EnvironmentObject var callManager: CallManager

    var body: some View {
        HStack(spacing: 10) {
            TextField("Message Claire...", text: $callManager.textInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .onSubmit { callManager.sendText() }

            if !callManager.textInput.isEmpty {
                Button(action: { callManager.sendText() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(red: 0.2, green: 0.45, blue: 1.0))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .animation(.easeOut(duration: 0.15), value: callManager.textInput.isEmpty)
    }
}

#Preview {
    ContentView()
        .environmentObject(CallManager())
}
