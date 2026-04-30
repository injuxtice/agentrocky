//
//  RockyState.swift
//  agentrocky
//

import SwiftUI
import Combine

/// Shared observable state between AppDelegate (walk logic) and RockyView (display).
@MainActor
class RockyState: ObservableObject {
    @Published var walkFrameIndex: Int = 0
    @Published var jazzFrameIndex: Int = 0
    @Published var isJazzing: Bool = false
    @Published var isPaused: Bool = false
    @Published var direction: CGFloat = 1
    @Published var isChatOpen: Bool = false
    @Published var positionX: CGFloat = 0
    @Published var speechBubble: String? = nil
    var screenBounds: CGRect = .zero
    var dockY: CGFloat = 0

    /// Single persistent Gemini chat session — survives popover open/close.
    lazy var session: GeminiChatSession = GeminiChatSession()
}
