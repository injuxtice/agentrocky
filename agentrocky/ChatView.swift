//
//  ChatView.swift
//  agentrocky
//

import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var session: GeminiChatSession
    @State private var input: String = ""
    @State private var showSettings = false
    @State private var talkPressed = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(session.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if session.isRunning {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("rocky is thinking")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }

                        if !session.groundingSources.isEmpty {
                            SourceList(sources: session.groundingSources)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: session.messages.count) { _ in
                    if let last = session.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: session.isRunning) { _ in
                    if let last = session.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            if !session.isReady {
                apiKeySetup
            }

            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rocky")
                        .font(.system(size: 16, weight: .semibold))
                    Text(session.isReady ? session.liveStatus : "Gemini key needed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    session.toggleLive()
                } label: {
                    Label(session.isLiveConnected ? "Live On" : "Live", systemImage: session.isLiveConnected ? "waveform.circle.fill" : "waveform.circle")
                }
                .disabled(!session.isReady)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSettings.toggle()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Settings")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Close Rocky")
            }

            if session.isLiveConnected {
                liveControls
            }

            if showSettings {
                settingsPanel
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var liveControls: some View {
        HStack(spacing: 10) {
            LiveHoldControl(session: session, isPressed: $talkPressed)

            Label("Hold Option", systemImage: "option")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            if !session.groundingSources.isEmpty {
                Text("\(session.groundingSources.count) sources")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Toggle("Voice", isOn: Binding(
                    get: { session.ttsEnabled },
                    set: { session.setTTSEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(!session.isReady)

                Picker("Voice", selection: Binding(
                    get: { session.selectedVoice },
                    set: { session.setSelectedVoice($0) }
                )) {
                    ForEach(session.voiceOptions, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                .labelsHidden()
                .frame(width: 118)
                .disabled(!session.ttsEnabled || !session.isReady)

                Picker("Mood", selection: Binding(
                    get: { session.selectedVoiceMood },
                    set: { session.setSelectedVoiceMood($0) }
                )) {
                    ForEach(session.moodOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
                .disabled(!session.ttsEnabled || !session.isReady)
            }

            HStack {
                Toggle("Web search", isOn: Binding(
                    get: { session.searchGroundingEnabled },
                    set: { session.setSearchGroundingEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!session.isReady)

                Spacer()

                if session.isReady {
                    Button("Change key") {
                        session.apiKeyInput = ""
                        session.clearAPIKey()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var apiKeySetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a Gemini API key to start chatting.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                SecureField("Gemini API key", text: $session.apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.saveAPIKey() }

                Button("Save") {
                    session.saveAPIKey()
                    inputFocused = true
                }
                .disabled(session.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message Rocky", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .disabled(!session.isReady || session.isRunning || session.isLiveListening)
                .onSubmit { sendMessage() }

            Button("Send") {
                sendMessage()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!session.isReady || session.isRunning || session.isLiveListening || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
    }

    private func sendMessage() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session.isReady, !session.isRunning else { return }
        input = ""
        session.send(prompt: trimmed)
        inputFocused = true
    }
}

private struct LiveHoldControl: View {
    @ObservedObject var session: GeminiChatSession
    @Binding var isPressed: Bool

    var body: some View {
        Text(session.isLiveListening ? "Listening" : "Hold Talk")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(session.isLiveListening ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(session.isLiveListening ? Color.red : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule()
                    .stroke(session.isLiveListening ? Color.red.opacity(0.7) : Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        session.startLiveListening()
                    }
                    .onEnded { _ in
                        isPressed = false
                        session.stopLiveListening()
                    }
            )
            .help("Hold to talk to Rocky Live")
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 48) }

            Text(message.text)
                .font(.system(size: 13))
                .foregroundColor(foregroundColor)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 320, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)

            if message.sender != .user { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity)
    }

    private var alignment: Alignment {
        message.sender == .user ? .trailing : .leading
    }

    private var foregroundColor: Color {
        switch message.sender {
        case .user:
            return .white
        case .rocky:
            return .primary
        case .system:
            return .secondary
        }
    }

    private var background: Color {
        switch message.sender {
        case .user:
            return Color.accentColor
        case .rocky:
            return Color(nsColor: .controlBackgroundColor)
        case .system:
            return Color(nsColor: .textBackgroundColor)
        }
    }
}

struct SourceList: View {
    let sources: [GeminiGroundingSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(sources.prefix(3)) { source in
                if let url = URL(string: source.uri) {
                    Link(source.title, destination: url)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                } else {
                    Text(source.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
