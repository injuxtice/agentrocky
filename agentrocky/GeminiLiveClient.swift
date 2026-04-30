//
//  GeminiLiveClient.swift
//  agentrocky
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class GeminiLiveClient {
    var onStatusChange: ((String) -> Void)?
    var onListeningChange: ((Bool) -> Void)?
    var onConnectedChange: ((Bool) -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onRockyPartialTranscript: ((String) -> Void)?
    var onRockyTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onPlaybackChange: ((Bool) -> Void)?

    private let apiKey: String
    private let systemInstruction: String
    private let voiceName: String
    private var urlSession: URLSession?
    private var socketDelegate: GeminiLiveSocketDelegate?
    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private let audioEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let playbackNode = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var audioConverter: AVAudioConverter?
    private var playbackPrepared = false
    private var scheduledPlaybackBuffers = 0
    private var pendingUserTranscript = ""
    private var pendingRockyTranscript = ""

    init(apiKey: String, systemInstruction: String, voiceName: String) {
        self.apiKey = apiKey
        self.systemInstruction = systemInstruction
        self.voiceName = voiceName
    }

    static func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func connect() async throws {
        guard webSocket == nil else { return }
        guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(encodedKey)") else {
            throw GeminiError.invalidResponse
        }

        let delegate = GeminiLiveSocketDelegate()
        delegate.onClose = { [weak self] code, reason in
            Task { @MainActor [weak self] in
                self?.handleSocketClose(code: code, reason: reason)
            }
        }
        socketDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        urlSession = session
        let socket = session.webSocketTask(with: url)
        webSocket = socket
        socket.resume()
        try await delegate.waitForOpen()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        try await sendJSON([
            "setup": [
                "model": "models/\(GeminiAPIClient.liveModel)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": [
                                "voiceName": voiceName
                            ]
                        ]
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": systemInstruction]
                    ]
                ]
            ]
        ])
        onStatusChange?("live setup sent")
    }

    func disconnect() {
        stopListening()
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        socketDelegate = nil
        stopPlayback()
        onConnectedChange?(false)
        onStatusChange?("live disconnected")
    }

    func startListening() async {
        guard webSocket != nil else {
            onError?("Connect Live first.")
            return
        }

        let granted = await Self.requestMicrophoneAccessIfNeeded()
        guard granted else {
            onError?("Microphone access is needed for Live voice.")
            return
        }

        do {
            try startAudioEngine()
            onListeningChange?(true)
            onStatusChange?("live listening")
        } catch {
            onError?("Rocky could not start the microphone: \(error.localizedDescription)")
        }
    }

    func stopListening() {
        guard audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioConverter = nil
        onListeningChange?(false)
        onStatusChange?("live thinking")
        Task { [weak self] in
            try? await self?.sendJSON([
                "realtimeInput": [
                    "audioStreamEnd": true
                ]
            ])
        }
    }

    private func startAudioEngine() throws {
        if audioEngine.isRunning { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw GeminiError.invalidResponse
        }
        audioConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let data = Self.convert(buffer: buffer, inputFormat: inputFormat, outputFormat: outputFormat, converter: converter),
                  !data.isEmpty else {
                return
            }

            Task { @MainActor [weak self] in
                try? await self?.sendAudio(data)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func sendAudio(_ data: Data) async throws {
        try await sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": data.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ])
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket else { throw GeminiError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let json = String(data: data, encoding: .utf8) else { throw GeminiError.invalidResponse }
        try await webSocket.send(.string(json))
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let webSocket else { return }
            do {
                let message = try await webSocket.receive()
                switch message {
                case .string(let text):
                    handleMessageText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessageText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    onError?("Live socket closed while waiting for Gemini setup. \(error.localizedDescription)")
                    disconnect()
                }
                return
            }
        }
    }

    private func handleMessageText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if object["setupComplete"] != nil {
            onConnectedChange?(true)
            onStatusChange?("live ready")
            onReady?()
        }

        if let serverContent = object["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            onError?(message)
        }
    }

    private func handleSocketClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }
        let detail = reasonText?.isEmpty == false ? ": \(reasonText!)" : ""
        if webSocket != nil {
            onError?("Live connection closed (\(code.rawValue))\(detail)")
            disconnect()
        }
    }

    private func handleServerContent(_ serverContent: [String: Any]) {
        if serverContent["interrupted"] as? Bool == true {
            stopPlayback()
            pendingRockyTranscript = ""
            onStatusChange?("live interrupted")
        }

        if let input = serverContent["inputTranscription"] as? [String: Any],
           let text = input["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingUserTranscript = text
        }

        if let output = serverContent["outputTranscription"] as? [String: Any],
           let text = output["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingRockyTranscript += text
            onRockyPartialTranscript?(pendingRockyTranscript)
        }

        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inlineData = Self.inlineData(from: part),
                   let base64 = inlineData["data"] as? String,
                   let audio = Data(base64Encoded: base64) {
                    playPCMChunk(audio)
                }
            }
        }

        if serverContent["turnComplete"] as? Bool == true {
            finishTurn()
        }
    }

    private func finishTurn() {
        let userText = pendingUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let rockyText = pendingRockyTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if !userText.isEmpty {
            onUserTranscript?(userText)
        }
        if !rockyText.isEmpty {
            onRockyTranscript?(rockyText)
        }

        pendingUserTranscript = ""
        pendingRockyTranscript = ""
        if scheduledPlaybackBuffers == 0 {
            onStatusChange?("live ready")
        }
    }

    private func playPCMChunk(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        do {
            try preparePlaybackIfNeeded()
            guard let buffer = Self.floatBuffer(fromLittleEndianPCM16: pcm, format: playbackFormat) else { return }
            scheduledPlaybackBuffers += 1
            onPlaybackChange?(true)
            playbackNode.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.finishPlaybackBuffer()
                }
            }
            if !playbackNode.isPlaying {
                playbackNode.play()
            }
            onStatusChange?("live replying")
        } catch {
            onError?("Rocky could not play Live audio: \(error.localizedDescription)")
        }
    }

    private func preparePlaybackIfNeeded() throws {
        if !playbackPrepared {
            playbackEngine.attach(playbackNode)
            playbackEngine.connect(playbackNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
            playbackPrepared = true
        }

        if !playbackEngine.isRunning {
            playbackEngine.prepare()
            try playbackEngine.start()
        }
    }

    private func stopPlayback() {
        if playbackNode.engine != nil {
            playbackNode.stop()
        }
        playbackEngine.stop()
        playbackEngine.reset()
        scheduledPlaybackBuffers = 0
        onPlaybackChange?(false)
    }

    private func finishPlaybackBuffer() {
        scheduledPlaybackBuffers = max(0, scheduledPlaybackBuffers - 1)
        if scheduledPlaybackBuffers == 0 {
            onPlaybackChange?(false)
            onStatusChange?("live ready")
        }
    }

    private static func inlineData(from part: [String: Any]) -> [String: Any]? {
        if let inlineData = part["inlineData"] as? [String: Any] {
            return inlineData
        }
        return part["inline_data"] as? [String: Any]
    }

    private static func floatBuffer(fromLittleEndianPCM16 pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = pcm.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            for index in 0..<frameCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                channel[index] = max(-1.0, Float(sample) / 32768.0)
            }
        }

        return buffer
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> Data? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var didProvideInput = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, converted.frameLength > 0 else {
            return nil
        }

        let audioBuffer = converted.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

}

private final class GeminiLiveSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?

    private var openContinuation: CheckedContinuation<Void, Error>?

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            openContinuation = continuation
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        openContinuation?.resume()
        openContinuation = nil
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if let openContinuation {
            openContinuation.resume(throwing: GeminiError.api("Live socket closed before opening."))
            self.openContinuation = nil
        }
        onClose?(closeCode, reason)
    }
}
