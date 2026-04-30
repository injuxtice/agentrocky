//
//  GeminiAPIClient.swift
//  agentrocky
//

import Foundation

struct GeminiAPIClient {
    static let chatModel = "gemini-3-flash-preview"
    static let ttsModel = "gemini-3.1-flash-tts-preview"
    static let liveModel = "gemini-3.1-flash-live-preview"

    let apiKey: String
    var urlSession: URLSession = .shared

    func sendMessage(
        _ prompt: String,
        history: [GeminiConversationTurn],
        useSearchGrounding: Bool,
        systemInstruction: String
    ) async throws -> GeminiChatResponse {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.chatModel):generateContent")!
        var contents = history.suffix(12).map { turn in
            [
                "role": turn.role,
                "parts": [
                    ["text": turn.text]
                ]
            ]
        }
        contents.append([
            "role": "user",
            "parts": [
                ["text": prompt]
            ]
        ])

        var payload: [String: Any] = [
            "contents": contents,
            "systemInstruction": [
                "parts": [
                    ["text": systemInstruction]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.rockyResponseSchema
            ]
        ]
        if useSearchGrounding {
            payload["tools"] = [
                ["google_search": [:]]
            ]
        }

        let data = try await postJSON(payload, to: endpoint)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.invalidResponse
        }

        guard let candidates = object["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiError.invalidResponse
        }

        let rawText = parts
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { throw GeminiError.noTextOutput }

        let response = Self.parseRockyResponse(from: rawText)
        return GeminiChatResponse(
            text: response.text,
            mood: response.mood,
            action: response.action,
            speechBubble: response.speechBubble,
            sources: Self.parseGroundingSources(from: firstCandidate)
        )
    }

    func synthesizeSpeech(_ text: String, voiceName: String, mood: RockyMood) async throws -> Data {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.ttsModel):generateContent")!
        let speechPrompt = """
        # AUDIO PROFILE: Rocky
        ## Tiny desktop companion for Zoe

        ### DIRECTOR'S NOTES
        Style: Warm, loyal, curious alien buddy. \(mood.voiceDirection) Never polished-announcer.
        Pacing: \(mood.pacingDirection)
        Performance: Bracketed cues such as [delighted tiny laugh], [curious bright chirp], and [soft concerned hum] are acting directions only. Perform the sound or emotion briefly; do not read the bracket text aloud.

        #### TRANSCRIPT
        \(text)
        """
        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": speechPrompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": voiceName
                        ]
                    ]
                ]
            ]
        ]

        let data = try await postJSON(payload, to: endpoint)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiError.invalidResponse
        }

        for part in parts {
            if let inlineData = part["inlineData"] as? [String: Any],
               let base64 = inlineData["data"] as? String,
               let audio = Data(base64Encoded: base64) {
                return audio
            }
            if let inlineData = part["inline_data"] as? [String: Any],
               let base64 = inlineData["data"] as? String,
               let audio = Data(base64Encoded: base64) {
                return audio
            }
        }

        throw GeminiError.noAudioOutput
    }

    private func postJSON(_ payload: [String: Any], to endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw GeminiError.api(message)
        }

        return data
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return nil
        }
        return error["message"] as? String
    }

    private static var rockyResponseSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "reply": [
                    "type": "string",
                    "description": "Rocky's user-visible reply."
                ],
                "mood": [
                    "type": "string",
                    "enum": RockyMood.allCases.map(\.rawValue),
                    "description": "The emotional color Rocky should use for animation and voice."
                ],
                "action": [
                    "type": "string",
                    "enum": RockyAction.allCases.map(\.rawValue),
                    "description": "A small desktop action Rocky should perform after the reply."
                ],
                "speechBubble": [
                    "type": "string",
                    "description": "A short two-to-four-word bubble. Empty string is allowed."
                ]
            ],
            "required": ["reply", "mood", "action", "speechBubble"]
        ]
    }

    private static func parseRockyResponse(from rawText: String) -> (text: String, mood: RockyMood, action: RockyAction, speechBubble: String?) {
        let cleaned = RockyTextCleaner.splitStructuredPreamble(from: rawText)

        guard let data = rawText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let metadata = cleaned.metadata
            let mood = Self.parseMood(metadata?["mood"] as? String)
            let action = RockyAction(rawValue: metadata?["action"] as? String ?? "") ?? .none
            let visibleText = cleaned.visibleText.isEmpty ? RockyTextCleaner.visibleText(from: rawText) : cleaned.visibleText
            return (visibleText, mood, action, nil)
        }

        let text = RockyTextCleaner.visibleText(from: object["reply"] as? String ?? rawText)
        let mood = Self.parseMood(object["mood"] as? String)
        let action = RockyAction(rawValue: object["action"] as? String ?? "") ?? .none
        let speechBubble = (object["speechBubble"] as? String).map(RockyTextCleaner.visibleText)
        return (text.isEmpty ? rawText : text, mood, action, speechBubble?.isEmpty == true ? nil : speechBubble)
    }

    private static func parseMood(_ rawValue: String?) -> RockyMood {
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized == "calm" { return .neutral }
        return RockyMood(rawValue: normalized) ?? .neutral
    }

    private static func parseGroundingSources(from candidate: [String: Any]) -> [GeminiGroundingSource] {
        guard let metadata = candidate["groundingMetadata"] as? [String: Any],
              let chunks = metadata["groundingChunks"] as? [[String: Any]] else {
            return []
        }

        return chunks.compactMap { chunk in
            guard let web = chunk["web"] as? [String: Any],
                  let uri = web["uri"] as? String else {
                return nil
            }
            return GeminiGroundingSource(title: web["title"] as? String ?? uri, uri: uri)
        }
    }
}

struct GeminiChatResponse {
    let text: String
    let mood: RockyMood
    let action: RockyAction
    let speechBubble: String?
    let sources: [GeminiGroundingSource]
}

struct GeminiGroundingSource: Identifiable {
    let id = UUID()
    let title: String
    let uri: String
}

struct GeminiConversationTurn {
    let role: String
    let text: String
}

enum RockyTextCleaner {
    nonisolated static func visibleText(from text: String) -> String {
        splitStructuredPreamble(from: text).visibleText
    }

    nonisolated static func splitStructuredPreamble(from text: String) -> (metadata: [String: Any]?, visibleText: String) {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata: [String: Any]?

        while remaining.lowercased().hasPrefix("```json") {
            guard let firstLineEnd = remaining.firstIndex(of: "\n") else { break }
            let bodyStart = remaining.index(after: firstLineEnd)
            guard let closingFence = remaining[bodyStart...].range(of: "```") else { break }

            let jsonText = String(remaining[bodyStart..<closingFence.lowerBound])
            if metadata == nil {
                metadata = parseJSONObject(jsonText)
            }
            remaining = String(remaining[closingFence.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if remaining.first == "{",
           let objectEnd = matchingTopLevelJSONObjectEnd(in: remaining) {
            let jsonText = String(remaining[...objectEnd])
            if metadata == nil {
                metadata = parseJSONObject(jsonText)
            }
            let afterObject = remaining.index(after: objectEnd)
            remaining = String(remaining[afterObject...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let frontMatter = removeYAMLFrontMatter(from: remaining, existingMetadata: metadata)
        remaining = frontMatter.visibleText
        metadata = frontMatter.metadata

        let loosePreamble = removeLooseMetadataPreamble(from: remaining, existingMetadata: metadata)
        remaining = loosePreamble.visibleText
        metadata = loosePreamble.metadata

        remaining = removeFencedJSONBlocks(from: remaining)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (metadata, remaining)
    }

    nonisolated static func bubbleText(from text: String, limit: Int = 150) -> String {
        let visible = visibleText(from: text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard visible.count > limit else { return visible }
        let end = visible.index(visible.startIndex, offsetBy: limit - 3)
        return String(visible[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    nonisolated private static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated private static func removeFencedJSONBlocks(from text: String) -> String {
        var cleaned = text
        while let start = cleaned.range(of: "```json", options: [.caseInsensitive]),
              let end = cleaned[start.upperBound...].range(of: "```") {
            cleaned.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return cleaned
    }

    nonisolated private static func removeYAMLFrontMatter(
        from text: String,
        existingMetadata: [String: Any]?
    ) -> (metadata: [String: Any]?, visibleText: String) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return (existingMetadata, text)
        }

        guard let closingIndex = lines.indices.dropFirst().first(where: {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            return (existingMetadata, text)
        }

        var metadata = existingMetadata ?? [:]
        for line in lines[1..<closingIndex] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = stripWrappingQuotes(from: rawValue)

            guard ["action", "mood", "speechbubble", "reply"].contains(key) else { continue }
            metadata[key == "speechbubble" ? "speechBubble" : key] = value
        }

        let remainderStart = lines.index(after: closingIndex)
        let remainder = lines[remainderStart...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackReply = metadata["reply"] as? String

        return (
            metadata.isEmpty ? existingMetadata : metadata,
            remainder.isEmpty ? fallbackReply ?? "" : remainder
        )
    }

    nonisolated private static func stripWrappingQuotes(from text: String) -> String {
        guard text.count >= 2,
              let first = text.first,
              let last = text.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }

    nonisolated private static func removeLooseMetadataPreamble(
        from text: String,
        existingMetadata: [String: Any]?
    ) -> (metadata: [String: Any]?, visibleText: String) {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = existingMetadata ?? [:]
        var didParseMetadata = false

        while let parsed = consumeLooseMetadataField(from: remaining) {
            metadata[parsed.key] = parsed.value
            remaining = parsed.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            didParseMetadata = true
        }

        return (metadata.isEmpty && !didParseMetadata ? existingMetadata : metadata, remaining)
    }

    nonisolated private static func consumeLooseMetadataField(from text: String) -> (key: String, value: String, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyResult = consumeLooseMetadataKey(from: trimmed) else { return nil }

        let candidates: [String]
        switch keyResult.key {
        case "action":
            candidates = RockyAction.allCases.map(\.rawValue)
        case "mood":
            candidates = RockyMood.allCases.map(\.rawValue) + ["calm"]
        default:
            return nil
        }

        guard let valueResult = consumeLooseMetadataValue(from: keyResult.remainder, candidates: candidates) else {
            return nil
        }
        return (keyResult.key, valueResult.value, valueResult.remainder)
    }

    nonisolated private static func consumeLooseMetadataKey(from text: String) -> (key: String, remainder: String)? {
        let supportedKeys = ["action", "mood"]
        let lowercased = text.lowercased()

        for key in supportedKeys {
            guard lowercased.hasPrefix(key) else { continue }

            let keyEnd = text.index(text.startIndex, offsetBy: key.count)
            if keyEnd == text.endIndex {
                return nil
            }

            let separator = text[keyEnd]
            if separator == ":" {
                let remainder = String(text[text.index(after: keyEnd)...])
                return (key, remainder)
            }

            if separator.isWhitespace || separator.isNewline {
                let remainder = String(text[keyEnd...])
                return (key, remainder)
            }
        }

        return nil
    }

    nonisolated private static func consumeLooseMetadataValue(from text: String, candidates: [String]) -> (value: String, remainder: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        for candidate in candidates.sorted(by: { $0.count > $1.count }) {
            guard lowercased.hasPrefix(candidate) else { continue }

            let valueEnd = trimmed.index(trimmed.startIndex, offsetBy: candidate.count)
            if valueEnd == trimmed.endIndex {
                return (candidate, "")
            }

            let nextCharacter = trimmed[valueEnd]
            guard nextCharacter == ":" || nextCharacter == "\n" || nextCharacter == "\r" || nextCharacter.isWhitespace || !nextCharacter.isLowercaseLetter else {
                continue
            }

            var remainderStart = valueEnd
            if nextCharacter == ":" {
                remainderStart = trimmed.index(after: valueEnd)
            }
            let remainder = String(trimmed[remainderStart...])
            return (candidate, remainder)
        }

        return nil
    }

    nonisolated private static func matchingTopLevelJSONObjectEnd(in text: String) -> String.Index? {
        var depth = 0
        var isInString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                isInString.toggle()
                continue
            }
            guard !isInString else { continue }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
        }

        return nil
    }
}

private extension Character {
    nonisolated var isLowercaseLetter: Bool {
        unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
    }
}

enum RockyMood: String, CaseIterable, Identifiable {
    case neutral
    case curious
    case excited
    case sleepy
    case concerned
    case focused

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neutral: return "Neutral"
        case .curious: return "Curious"
        case .excited: return "Excited"
        case .sleepy: return "Sleepy"
        case .concerned: return "Concerned"
        case .focused: return "Focused"
        }
    }

    var voiceDirection: String {
        switch self {
        case .neutral:
            return "Upbeat and emotionally direct, with a bright vocal smile."
        case .curious:
            return "Curious and lifted, with tiny bright chirps and a questioning smile."
        case .excited:
            return "Sparkly, delighted, fast, and full of tiny celebration energy."
        case .sleepy:
            return "Soft, slow, cozy, drowsy, and gentle without becoming hard to hear."
        case .concerned:
            return "Gentle, careful, and warm, with a soft concerned hum underneath."
        case .focused:
            return "Practical, crisp, attentive, and calm like a small engineer solving a problem."
        }
    }

    var pacingDirection: String {
        switch self {
        case .sleepy:
            return "Slow clipped phrases with small comfortable pauses."
        case .excited:
            return "Quick clipped phrases with delighted tiny pauses."
        case .focused:
            return "Steady clipped phrases, clear and responsive."
        default:
            return "Short clipped phrases with tiny pauses, like translated speech. Keep it quick and responsive."
        }
    }
}

enum RockyAction: String, CaseIterable, Identifiable {
    case none
    case dance
    case think
    case pause
    case wave

    var id: String { rawValue }
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case noTextOutput
    case noAudioOutput
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Gemini API key first."
        case .invalidResponse:
            return "Gemini sent a response Rocky could not read."
        case .noTextOutput:
            return "Gemini did not send a text reply."
        case .noAudioOutput:
            return "Gemini did not send audio for that reply."
        case .api(let message):
            return message
        }
    }
}
