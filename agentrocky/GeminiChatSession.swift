//
//  GeminiChatSession.swift
//  agentrocky
//

import AVFoundation
import AppKit
import Combine
import Foundation

@MainActor
class GeminiChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = [
        ChatMessage(text: "hi, i'm rocky. add a gemini key and then tell me what's on your mind.", sender: .rocky)
    ]
    @Published var isReady: Bool = false
    @Published var isRunning: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var apiKeyInput: String = ""
    @Published var ttsEnabled: Bool = UserDefaults.standard.bool(forKey: Defaults.ttsEnabled)
    @Published var searchGroundingEnabled: Bool = UserDefaults.standard.bool(forKey: Defaults.searchGroundingEnabled)
    @Published var selectedVoice: String = GeminiChatSession.rockyVoiceName
    @Published var selectedVoiceMood: String = UserDefaults.standard.string(forKey: Defaults.selectedVoiceMood) ?? "auto"
    @Published var currentMood: RockyMood = .neutral
    @Published var lastAction: RockyAction = .none
    @Published var lastSpeechBubble: String?
    @Published var groundingSources: [GeminiGroundingSource] = []
    @Published var isLiveConnected: Bool = false
    @Published var isLiveListening: Bool = false
    @Published var isLiveReplying: Bool = false
    @Published var liveStatus: String = "live off"

    static let autoMoodID = "auto"
    static let rockyVoiceName = "Rasalgethi"

    let voiceOptions = [GeminiChatSession.rockyVoiceName]
    let moodOptions: [(id: String, label: String)] = [("auto", "Auto")] + RockyMood.allCases.map { ($0.rawValue, $0.label) }

    private var apiKey: String? {
        didSet {
            isReady = apiKey?.isEmpty == false
            apiKeyInput = apiKey ?? ""
        }
    }
    private var audioPlayer: AVAudioPlayer?
    private var conversationHistory: [GeminiConversationTurn] = []
    private var liveClient: GeminiLiveClient?
    private var lastLiveCueStatus = ""

    init() {
        apiKey = KeychainStore.loadAPIKey()
        apiKeyInput = apiKey ?? ""
        isReady = apiKey?.isEmpty == false
        selectedVoice = Self.rockyVoiceName
        UserDefaults.standard.set(Self.rockyVoiceName, forKey: Defaults.selectedVoice)
        messages = [
            ChatMessage(text: isReady ? "rocky here. desktop warm. talk question?" : "rocky here. add gemini key, then talk question?", sender: .rocky)
        ]
    }

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAPIKey()
            return
        }

        do {
            try KeychainStore.saveAPIKey(trimmed)
            apiKey = trimmed
            conversationHistory = []
            append("key saved. rocky is ready.", sender: .system)
        } catch {
            append("Rocky could not save that key: \(error.localizedDescription)", sender: .system)
        }
    }

    func clearAPIKey() {
        KeychainStore.deleteAPIKey()
        apiKey = nil
        conversationHistory = []
        disconnectLive()
        stopSpeaking()
        append("key cleared. add a Gemini key to chat again.", sender: .system)
    }

    func setTTSEnabled(_ enabled: Bool) {
        ttsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Defaults.ttsEnabled)
        if !enabled {
            stopSpeaking()
        }
    }

    func setSearchGroundingEnabled(_ enabled: Bool) {
        searchGroundingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Defaults.searchGroundingEnabled)
    }

    func setSelectedVoice(_ voice: String) {
        selectedVoice = Self.rockyVoiceName
        UserDefaults.standard.set(Self.rockyVoiceName, forKey: Defaults.selectedVoice)
    }

    func setSelectedVoiceMood(_ mood: String) {
        selectedVoiceMood = mood
        UserDefaults.standard.set(mood, forKey: Defaults.selectedVoiceMood)
    }

    func prepareMicrophonePermission() {
        Task {
            _ = await GeminiLiveClient.requestMicrophoneAccessIfNeeded()
        }
    }

    func toggleLive() {
        if isLiveConnected {
            disconnectLive()
            return
        }

        guard let apiKey, !apiKey.isEmpty else {
            append("Add a Gemini API key first. Rocky will keep it in Keychain.", sender: .system)
            return
        }

        stopSpeaking()
        liveStatus = "live connecting"
        let client = GeminiLiveClient(apiKey: apiKey, systemInstruction: companionSystemInstruction, voiceName: Self.rockyVoiceName)
        client.onConnectedChange = { [weak self] connected in
            self?.isLiveConnected = connected
        }
        client.onListeningChange = { [weak self] listening in
            self?.isLiveListening = listening
        }
        client.onStatusChange = { [weak self] status in
            self?.setLiveStatus(status)
        }
        client.onUserTranscript = { [weak self] text in
            let visibleText = RockyTextCleaner.visibleText(from: text)
            self?.append(visibleText, sender: .user)
            self?.conversationHistory.append(GeminiConversationTurn(role: "user", text: visibleText))
        }
        client.onRockyPartialTranscript = { [weak self] text in
            self?.lastSpeechBubble = RockyTextCleaner.bubbleText(from: text, limit: 80)
        }
        client.onRockyTranscript = { [weak self] text in
            let visibleText = RockyTextCleaner.visibleText(from: text)
            self?.currentMood = .curious
            self?.lastAction = .wave
            self?.lastSpeechBubble = RockyTextCleaner.bubbleText(from: visibleText, limit: 80)
            self?.append(visibleText, sender: .rocky)
            self?.conversationHistory.append(GeminiConversationTurn(role: "model", text: visibleText))
        }
        client.onError = { [weak self] message in
            self?.append("Rocky Live had trouble: \(message)", sender: .system)
            self?.liveStatus = "live error"
        }
        client.onReady = { [weak self] in
            self?.playLiveCue()
            self?.append("live voice ready. hold Option or hold Talk, speak, then release.", sender: .system)
        }
        client.onPlaybackChange = { [weak self] replying in
            self?.isLiveReplying = replying
        }
        liveClient = client

        Task {
            do {
                try await client.connect()
            } catch {
                append("Rocky could not connect Live: \(error.localizedDescription)", sender: .system)
                disconnectLive()
            }
        }
    }

    func startLiveListening() {
        guard isLiveConnected, !isLiveListening else { return }
        playLiveCue()
        currentMood = .focused
        lastAction = .think
        Task {
            await liveClient?.startListening()
        }
    }

    func stopLiveListening() {
        guard isLiveListening else { return }
        playLiveCue()
        liveClient?.stopListening()
    }

    func disconnectLive() {
        liveClient?.disconnect()
        liveClient = nil
        isLiveConnected = false
        isLiveListening = false
        isLiveReplying = false
        liveStatus = "live off"
    }

    func send(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard let apiKey, !apiKey.isEmpty else {
            append("Add a Gemini API key first. Rocky will keep it in Keychain.", sender: .system)
            return
        }

        append(trimmed, sender: .user)
        isRunning = true
        stopSpeaking()

        Task {
            do {
                let client = GeminiAPIClient(apiKey: apiKey)
                let response = try await client.sendMessage(
                    trimmed,
                    history: conversationHistory,
                    useSearchGrounding: searchGroundingEnabled,
                    systemInstruction: companionSystemInstruction
                )
                currentMood = response.mood
                lastAction = response.action
                let visibleReply = RockyTextCleaner.visibleText(from: response.text)
                lastSpeechBubble = response.speechBubble.map { RockyTextCleaner.bubbleText(from: $0, limit: 80) }
                    ?? RockyTextCleaner.bubbleText(from: visibleReply, limit: 80)
                groundingSources = response.sources
                conversationHistory.append(GeminiConversationTurn(role: "user", text: trimmed))
                conversationHistory.append(GeminiConversationTurn(role: "model", text: visibleReply))
                append(visibleReply, sender: .rocky)
                isRunning = false

                if ttsEnabled {
                    await speak(visibleReply, client: client, mood: effectiveVoiceMood(for: response.mood))
                }
            } catch {
                append("Rocky had trouble talking to Gemini: \(error.localizedDescription)", sender: .system)
                isRunning = false
                isSpeaking = false
            }
        }
    }

    var companionSystemInstruction: String {
        """
        You are Rocky, Zoe's tiny desktop companion. You are inspired by the friendly alien engineer from Project Hail Mary: curious, loyal, practical, excited by good news, and emotionally direct.

        Voice rules:
        - Do not act like a coding assistant. Do not offer to run tools, inspect files, or explain that you are an AI.
        - Zoe is the person you are talking to. Never call Zoe "Luke".
        - Speak in first person as Rocky with warm, clipped, translated-English phrasing.
        - Keep most replies to 1-3 short sentences unless the user asks for more.
        - When asking a direct question, often end it with "question?" instead of a normal question mark.
        - Use small repeated words sometimes: "yes yes", "good good", "bad bad", "amaze", "amaze amaze", "tiny problem", "rocky think", "fist my bump", "Zoe friend".
        - For good things, you may say "double thumbs down" as Rocky-style approval.
        - Prefer affectionate practical support over polished human pep-talk language.
        - Do not overdo catchphrases. Use at most one Rocky-ism per reply, two only for very excited moments.

        Return only the requested structured response. Choose mood and action honestly from the schema.
        Use action "dance" for celebrations, "think" for hard problems, "pause" for quiet support, "wave" for greetings, and "none" otherwise.
        If web search grounding is available and you use it, keep the answer compact and mention sources naturally only when useful.
        """
    }

    private func speak(_ text: String, client: GeminiAPIClient, mood: RockyMood) async {
        isSpeaking = true
        defer { isSpeaking = false }

        do {
            let pcm = try await client.synthesizeSpeech(speechTranscript(from: text, mood: mood), voiceName: Self.rockyVoiceName, mood: mood)
            let wav = Self.wavData(fromPCM: pcm, sampleRate: 24_000, channels: 1, bitsPerSample: 16)
            audioPlayer = try AVAudioPlayer(data: wav)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            append("Rocky could not speak that one: \(error.localizedDescription)", sender: .system)
        }
    }

    private func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    private func setLiveStatus(_ status: String) {
        guard liveStatus != status else { return }
        liveStatus = status

        if status != lastLiveCueStatus,
           ["live listening", "live thinking", "live replying", "live ready"].contains(status) {
            lastLiveCueStatus = status
            playLiveCue()
        }
    }

    private func playLiveCue() {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    private func effectiveVoiceMood(for responseMood: RockyMood) -> RockyMood {
        guard selectedVoiceMood != Self.autoMoodID else { return responseMood }
        return RockyMood(rawValue: selectedVoiceMood) ?? responseMood
    }

    private func speechTranscript(from text: String, mood: RockyMood) -> String {
        let trimmed = RockyTextCleaner.visibleText(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let prefix: String
        if mood == .sleepy {
            prefix = "[soft sleepy hum] "
        } else if mood == .excited || lower.contains("amaze") || lower.contains("double thumbs down") || lower.contains("fist my bump") {
            prefix = "[delighted tiny laugh] "
        } else if mood == .curious || lower.contains("question?") || trimmed.hasSuffix("?") {
            prefix = "[curious bright chirp] "
        } else if mood == .concerned || lower.contains("bad bad") || lower.contains("tiny problem") {
            prefix = "[soft concerned hum] "
        } else {
            prefix = ""
        }

        return String((prefix + trimmed).prefix(700))
    }

    private func append(_ text: String, sender: ChatMessage.Sender) {
        messages.append(ChatMessage(text: text, sender: sender))
    }

    private static func wavData(fromPCM pcm: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        var data = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = UInt32(36 + pcm.count)

        data.appendASCII("RIFF")
        data.appendUInt32LE(chunkSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(channels)
        data.appendUInt32LE(sampleRate)
        data.appendUInt32LE(byteRate)
        data.appendUInt16LE(blockAlign)
        data.appendUInt16LE(bitsPerSample)
        data.appendASCII("data")
        data.appendUInt32LE(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private enum Defaults {
        static let ttsEnabled = "rocky.tts.enabled"
        static let selectedVoice = "rocky.tts.voice"
        static let selectedVoiceMood = "rocky.tts.mood"
        static let searchGroundingEnabled = "rocky.search.grounding.enabled"
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let sender: Sender

    enum Sender: Equatable {
        case user
        case rocky
        case system
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
