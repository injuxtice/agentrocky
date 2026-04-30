//
//  agentrockyApp.swift
//  agentrocky
//

import SwiftUI
import AppKit
import Combine

@main
struct agentrockyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var rockyWindow: NSPanel?
    var rockyState = RockyState()

    private var walkTimer: Timer?
    private var frameTimer: Timer?
    private let rockyWidth: CGFloat = 180
    private let rockyHeight: CGFloat = 176
    private let walkSpeed: CGFloat = 100
    private var lastTick: Date = Date()

    private var jazzWorkItem: DispatchWorkItem?
    private var bubbleWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var liveLocalKeyMonitor: Any?
    private var liveGlobalKeyMonitor: Any?
    private var liveKeyIsHeld = false

    private let workingMessages = ["rocky thinking", "one tiny moment", "rocky has this"]
    private let speakingMessages = ["rocky says", "rocky voice", "answer coming"]
    private let jazzMessages = ["fist my bump", "amaze amaze amaze", "rocky says hi"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupRockyWindow()
        startWalking()
        setupJazzTriggers()
        setupSpeechBubble()
        setupSpeakingBubble()
        setupLiveStatusBubble()
        setupMoodAndActions()
        setupLivePushToTalkKey()
        rockyState.session.prepareMicrophonePermission()
    }

    // MARK: - Window

    func setupRockyWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: rockyWidth, height: rockyHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        if let screen = NSScreen.main {
            let dockTop = screen.visibleFrame.minY
            let startX = screen.frame.midX - rockyWidth / 2
            panel.setFrameOrigin(NSPoint(x: startX, y: dockTop))
            rockyState.positionX = startX
            rockyState.screenBounds = screen.frame
            rockyState.dockY = dockTop
        }

        let contentView = NSHostingView(rootView: RockyView(state: rockyState, session: rockyState.session))
        contentView.frame = panel.contentView!.bounds
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        panel.makeKeyAndOrderFront(nil)
        rockyWindow = panel
    }

    // MARK: - Walk

    func startWalking() {
        lastTick = Date()

        walkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.updatePosition() }
        }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.updateFrame() }
        }
    }

    private func updatePosition() {
        let now = Date()
        defer { lastTick = now }
        guard !rockyState.isChatOpen, !rockyState.isJazzing else { return }

        let dt = now.timeIntervalSince(lastTick)
        let screen = rockyState.screenBounds
        let maxX = screen.maxX - rockyWidth

        rockyState.positionX += CGFloat(dt) * walkSpeed * rockyState.direction

        if rockyState.positionX >= maxX {
            rockyState.positionX = maxX
            rockyState.direction = -1
        } else if rockyState.positionX <= screen.minX {
            rockyState.positionX = screen.minX
            rockyState.direction = 1
        }

        rockyWindow?.setFrameOrigin(NSPoint(x: rockyState.positionX, y: rockyState.dockY))
    }

    private func updateFrame() {
        if rockyState.isJazzing {
            rockyState.jazzFrameIndex = (rockyState.jazzFrameIndex + 1) % 3
        } else if !rockyState.isChatOpen {
            rockyState.walkFrameIndex = (rockyState.walkFrameIndex + 1) % 2
        }
    }

    // MARK: - Jazz

    private func setupJazzTriggers() {
        // Jazz when a Gemini reply finishes.
        rockyState.session.$isRunning
            .removeDuplicates()
            .dropFirst()                    // skip the initial false
            .filter { !$0 }                 // only when it becomes false (task done)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startJazz(duration: 3.0) }
            .store(in: &cancellables)

        // Random jazz while idle
        scheduleRandomJazz()
    }

    private func setupSpeechBubble() {
        rockyState.session.$isRunning
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                self.bubbleWorkItem?.cancel()
                if running {
                    withAnimation {
                        self.rockyState.speechBubble = self.workingMessages.randomElement()!
                    }
                } else if !self.rockyState.session.isSpeaking && !self.rockyState.session.isLiveReplying {
                    let work = DispatchWorkItem { [weak self] in
                        withAnimation { self?.rockyState.speechBubble = nil }
                    }
                    self.bubbleWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
                }
            }
            .store(in: &cancellables)
    }

    private func setupSpeakingBubble() {
        rockyState.session.$isSpeaking
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in
                guard let self else { return }
                self.bubbleWorkItem?.cancel()

                if speaking {
                    withAnimation {
                        self.rockyState.speechBubble = self.rockyState.session.lastSpeechBubble ?? self.speakingMessages.randomElement()!
                    }
                } else if !self.rockyState.session.isRunning && !self.rockyState.session.isLiveReplying {
                    let work = DispatchWorkItem { [weak self] in
                        withAnimation { self?.rockyState.speechBubble = nil }
                    }
                    self.bubbleWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
                }
            }
            .store(in: &cancellables)
    }

    private func setupLiveStatusBubble() {
        rockyState.session.$liveStatus
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case "live listening":
                    self.showSpeechBubble("listening...", clearAfter: nil)
                case "live thinking":
                    self.showSpeechBubble("rocky thinking", clearAfter: nil)
                case "live replying":
                    self.showSpeechBubble(self.rockyState.session.lastSpeechBubble ?? "rocky says", clearAfter: nil)
                case "live ready":
                    if !self.rockyState.session.isLiveReplying {
                        self.clearSpeechBubble(after: 1.4)
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func setupMoodAndActions() {
        rockyState.session.$lastSpeechBubble
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bubble in
                guard let self else { return }
                self.bubbleWorkItem?.cancel()
                self.showSpeechBubble(bubble, clearAfter: self.rockyState.session.isLiveReplying ? nil : 3.5)
            }
            .store(in: &cancellables)

        rockyState.session.$lastAction
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .dance:
                    self.startJazz(duration: 3.0)
                case .think:
                    withAnimation { self.rockyState.speechBubble = "rocky thinking" }
                case .pause:
                    self.rockyState.isPaused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.rockyState.isPaused = false
                    }
                case .wave:
                    self.startJazz(duration: 1.2)
                case .none:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func setupLivePushToTalkKey() {
        liveLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            self.handleLiveKeyEvent(event)
            return event
        }

        liveGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleLiveKeyEvent(event)
            }
        }
    }

    private func handleLiveKeyEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionIsDown = flags.contains(.option)
        let canUseLiveKey = rockyState.session.isLiveConnected

        if optionIsDown, canUseLiveKey, !liveKeyIsHeld {
            liveKeyIsHeld = true
            rockyState.session.startLiveListening()
        } else if (!optionIsDown || !canUseLiveKey), liveKeyIsHeld {
            liveKeyIsHeld = false
            rockyState.session.stopLiveListening()
        }
    }

    private func showSpeechBubble(_ text: String, clearAfter delay: TimeInterval?) {
        bubbleWorkItem?.cancel()
        withAnimation {
            rockyState.speechBubble = text
        }
        if let delay {
            clearSpeechBubble(after: delay)
        }
    }

    private func clearSpeechBubble(after delay: TimeInterval) {
        bubbleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation { self?.rockyState.speechBubble = nil }
        }
        bubbleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func startJazz(duration: TimeInterval) {
        guard !rockyState.isJazzing else { return }
        rockyState.isJazzing = true

        jazzWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rockyState.isJazzing = false
        }
        jazzWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func scheduleRandomJazz() {
        let delay = Double.random(in: 15...45)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if !self.rockyState.isChatOpen {
                self.startJazz(duration: 2.0)
                withAnimation { self.rockyState.speechBubble = self.jazzMessages.randomElement()! }
                self.bubbleWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    withAnimation { self?.rockyState.speechBubble = nil }
                }
                self.bubbleWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            }
            self.scheduleRandomJazz()
        }
    }
}
