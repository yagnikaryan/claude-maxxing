import AppKit
import WebKit

/// What Orchestrator needs from a feed presenter — mirrors `ChipPresenting`'s
/// pattern so Orchestrator stays unit-testable without a real AppKit window.
/// No callbacks: unlike the chip's Watch/Skip buttons, the feed panel never
/// originates state-machine transitions on its own.
protocol FeedPresenting: AnyObject {
    func show(channel: ContentChannel?)   // must be safe to call from any thread
    func hide()                           // must be safe to call from any thread
    func pause()                          // must be safe to call from any thread
    func attention()                      // must be safe to call from any thread
}

/// The content window (SPEC §7.1, §8). A non-activating `NSPanel` hosting one
/// shared `WKWebView` that channel adapters (Layer 3) drive. Pause-and-hide,
/// never kill-and-reload, so login state and feed position survive a wait
/// (SPEC decision #9) — `hide()` deliberately leaves `activeChannel` and the
/// webview's loaded page alone.
final class FeedPanel: NSPanel, FeedPresenting {
    static let defaultAspect = NSSize(width: 9, height: 16)
    /// 9:16 base desired size; the actual on-screen size is clamped by
    /// `WindowGeometry.clampedSize` against the target screen's visible frame.
    static let defaultDesiredSize = NSSize(width: 360, height: 640)

    private let settings: SettingsStore
    private let webView: WKWebView
    private(set) var activeChannel: ContentChannel?

    init(settings: SettingsStore = .shared) {
        self.settings = settings

        let configuration = WKWebViewConfiguration()
        // `.default()` (not `.nonPersistent()`) is what makes this a
        // *persistent* data store — login cookies survive relaunch, per
        // SPEC §8.1 ("each platform is a one-time manual sign-in"). This is
        // the load-bearing distinction; it isn't obvious from the call site.
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultDesiredSize),
            styleMask: [.nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func configure() {
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = true   // real content, unlike ChipPanel's translucent chip
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        webView.navigationDelegate = self
        installWebView()

        // Re-set per-channel in show(channel:) once a channel's real
        // preferredAspect is known; these are just sane up-front defaults.
        contentAspectRatio = Self.defaultAspect
        contentMinSize = WindowGeometry.minSize(aspectRatio: Self.defaultAspect)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func installWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: Self.defaultDesiredSize))
        content.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        self.contentView = content
    }

    // MARK: FeedPresenting

    func show(channel: ContentChannel?) {
        DispatchQueue.main.async { [weak self] in
            self?.performShow(channel: channel)
        }
    }

    private func performShow(channel: ContentChannel?) {
        activeChannel = channel

        let aspect = channel?.preferredAspect ?? Self.defaultAspect
        contentAspectRatio = aspect
        contentMinSize = WindowGeometry.minSize(aspectRatio: aspect)

        // Reload only when switching channels/URLs, so pause→show on the
        // *same* channel resumes the live page instead of reloading it —
        // preserves scroll/feed position (SPEC §9.3's login/position framing).
        if let channel, webView.url != channel.url {
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(channel.userScript())
            webView.load(URLRequest(url: channel.url))
        }

        guard let fallback = mainScreenInfo() else { return }   // no displays — nothing to show
        let screens = NSScreen.screens.map { WindowGeometry.ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let restored = settings.windowFrame.map { NSRectFromString($0) }

        let frame = WindowGeometry.resolvedFrame(
            restored: restored,
            desiredSize: Self.defaultDesiredSize,
            aspectRatio: aspect,
            screens: screens,
            mouseLocation: NSEvent.mouseLocation,
            fallbackScreen: fallback,
            corner: .bottomRight
        )
        setFrame(frame, display: true)
        orderFrontRegardless()   // no makeKeyAndOrderFront: never takes key/activates app

        if let channel {
            channel.setAutoAdvance(settings.autoAdvance, in: webView)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settings.windowFrame = NSStringFromRect(self.frame)
            self.orderOut(nil)
            // Deliberately does NOT clear activeChannel or reload — the
            // webview stays alive so relaunch/resume keeps login + feed
            // position (SPEC decision #9).
        }
    }

    func pause() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeChannel?.pause(in: self.webView)
        }
    }

    func attention() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Per SPEC §8.4, the .criticalRequest bounce is unconditional
            // (fires even with activeChannel == nil); the channel-specific
            // interrupt is not.
            self.activeChannel?.attention(in: self.webView)
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    // MARK: Rule 5 — re-clamp on screen change (SPEC §7.1)

    @objc private func screenParametersChanged() {
        guard isVisible else { return }
        guard let fallback = mainScreenInfo() else { return }
        let screens = NSScreen.screens.map { WindowGeometry.ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let aspect = activeChannel?.preferredAspect ?? Self.defaultAspect

        let newFrame = WindowGeometry.reclamped(
            currentFrame: frame,
            aspectRatio: aspect,
            screens: screens,
            mouseLocation: NSEvent.mouseLocation,
            fallbackScreen: fallback,
            corner: .bottomRight
        )
        setFrame(newFrame, display: true, animate: true)
    }

    // MARK: Helpers

    /// Same `NSScreen.main ?? NSScreen.screens.first` fallback pattern
    /// already used in `ChipPanel.reposition()`. `nil` means no displays
    /// exist at all, in which case callers skip the frame/order-front steps
    /// (defensive — never crash).
    private func mainScreenInfo() -> WindowGeometry.ScreenInfo? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return WindowGeometry.ScreenInfo(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}

// MARK: - WKNavigationDelegate

extension FeedPanel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Re-applies the flag after every real navigation/reload, matching
        // §8.2 ("native toggles this flag").
        activeChannel?.setAutoAdvance(settings.autoAdvance, in: webView)
    }
}
