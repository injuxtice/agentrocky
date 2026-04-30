//
//  RockyView.swift
//  agentrocky
//

import SwiftUI

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct RockyView: View {
    @ObservedObject var state: RockyState
    @ObservedObject var session: GeminiChatSession
    @State private var showChat = false

    private var currentSpriteName: String {
        if state.isJazzing { return "jazz\(state.jazzFrameIndex + 1)" }
        if state.isChatOpen || state.isPaused { return "stand" }
        return state.walkFrameIndex == 0 ? "walkleft1" : "walkleft2"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear

            if let bubble = state.speechBubble {
                VStack(spacing: 0) {
                    Text(bubble)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .lineLimit(state.isChatOpen ? 3 : 4)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                        )
                    BubbleTail()
                        .fill(Color.white)
                        .frame(width: 14, height: 8)
                }
                .frame(maxWidth: state.isChatOpen ? 150 : 170)
                .padding(.bottom, state.isChatOpen ? 58 : 84)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                    removal: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity)
                ))
            }

            Button(action: {
                state.isChatOpen.toggle()
                showChat = state.isChatOpen
                if showChat {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }) {
                if let img = NSImage(named: currentSpriteName) {
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 80, height: 80)
                            .scaleEffect(x: state.direction > 0 ? -1 : 1, y: 1)
                            .shadow(
                                color: liveVisualState.color.opacity(liveVisualState == .off ? 0 : 0.42),
                                radius: liveVisualState == .off ? 0 : 12,
                                x: 0,
                                y: 0
                            )

                        if session.isLiveConnected {
                            LiveIndicator(state: liveVisualState)
                                .offset(x: -8, y: 8)
                        }
                    }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 60, height: 60)
                        .overlay(Text("R").foregroundColor(.white).font(.title))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showChat, arrowEdge: .top) {
                ChatView(session: state.session)
                    .frame(width: 440, height: 520)
            }
            .onChange(of: showChat) { open in
                state.isChatOpen = open
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: state.speechBubble)
        .animation(.easeInOut(duration: 0.2), value: session.isLiveConnected)
        .animation(.easeInOut(duration: 0.2), value: liveVisualState)
    }

    private var liveVisualState: RockyLiveVisualState {
        if session.isLiveListening { return .listening }
        if session.liveStatus == "live thinking" { return .thinking }
        if session.isLiveReplying || session.liveStatus == "live replying" { return .replying }
        if session.isLiveConnected { return .ready }
        return .off
    }
}

private struct LiveIndicator: View {
    let state: RockyLiveVisualState

    var body: some View {
        ZStack {
            Circle()
                .stroke(state.color.opacity(0.45), lineWidth: 3)
                .frame(width: state.emphasized ? 24 : 18, height: state.emphasized ? 24 : 18)
            Circle()
                .fill(state.color)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 1.5)
                )
        }
        .help(state.helpText)
    }
}

private enum RockyLiveVisualState: Equatable {
    case off
    case ready
    case listening
    case thinking
    case replying

    var color: Color {
        switch self {
        case .off:
            return .clear
        case .ready:
            return .green
        case .listening:
            return .red
        case .thinking:
            return .orange
        case .replying:
            return .blue
        }
    }

    var emphasized: Bool {
        self == .listening || self == .thinking || self == .replying
    }

    var helpText: String {
        switch self {
        case .off:
            return "Rocky Live is off"
        case .ready:
            return "Rocky Live is ready"
        case .listening:
            return "Rocky Live is listening"
        case .thinking:
            return "Rocky Live is thinking"
        case .replying:
            return "Rocky Live is replying"
        }
    }
}
