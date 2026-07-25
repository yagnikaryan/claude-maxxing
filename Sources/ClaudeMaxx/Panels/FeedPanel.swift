import AppKit
import WebKit

/// Breaks the retain cycle: a `userContentController` retains its message
/// handlers, and the panel owns the webview that owns the controller.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: FeedPanel?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleChannelMessage(message)
    }
}

/// Routes the keyboard to `window` when a click lands in a text field. A
/// non-activating panel can be key within the app while macOS still delivers
/// keystrokes to the active app — TikTok's SMS code went to the terminal.
/// Probing for an editable element keeps this from stealing focus on every
/// click (SPEC decision #7).
func cmActivateIfEditingText(in webView: WKWebView, window: NSWindow) {
    let probe = """
    (function() {
      var e = document.activeElement;
      if (!e) return false;
      var tag = (e.tagName || '').toLowerCase();
      return tag === 'input' || tag === 'textarea' || e.isContentEditable === true;
    })()
    """
    webView.evaluateJavaScript(probe) { result, _ in
        guard (result as? Bool) == true else { return }
        if !NSApp.isActive {
            cmLog("focus: click landed in a text field — activating so keystrokes reach it")
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow { window.makeKey() }
    }
}

/// Timestamped stderr trace — the only record of window and navigation behavior
/// in a headless daemon. Never `print()`; see CLAUDE.md.
func cmLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(stamp)] \(message)\n".data(using: .utf8)!)
}

/// A thin overlay strip so the otherwise-undraggable panel can be moved.
/// `isMovableByWindowBackground` has no effect when the `WKWebView` fills the
/// content view — no background is left to hit-test, so `performDrag` is the only
/// way. Also the one place the current channel name is visible.
private final class DragHandleView: NSView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Claims the whole strip, or hit-testing hands mouseDown to the label and
    /// the channel name — the obvious place to grab — isn't draggable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// What Orchestrator needs from a feed presenter, so it stays unit-testable
/// without a real AppKit window. No callbacks — unlike the chip's buttons, this
/// panel never originates state-machine transitions.
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
    /// Clamped on screen by `WindowGeometry.clampedSize`.
    static let defaultDesiredSize = NSSize(width: 360, height: 640)
    /// Layered *over* the webview rather than pushing it down, so the geometry
    /// math keeps treating the whole content rect as the video area.
    static let dragHandleHeight: CGFloat = 22

    private let settings: SettingsStore
    /// Internal so FeedPanelTests can assert the login-critical configuration.
    let webView: WKWebView
    private let dragHandle = DragHandleView(frame: .zero)
    private(set) var activeChannel: ContentChannel?
    /// `contentIdentity` of what was last actually loaded — the left-hand side of
    /// `shouldLoad`. Stored, not re-derived: channel instances are shared and
    /// mutable.
    private var loadedContentIdentity: String?
    /// Live `window.open()` popups (logins, mostly). Retained because
    /// `isReleasedWhenClosed` is false and nothing else owns them; dropped in each
    /// popup's `onClose`.
    private(set) var popupPanels: [PopupPanel] = []
    private let messageProxy = ScriptMessageProxy()
    /// Fired when a channel confirms the feed moved on. Wired to the stats store
    /// in `main.swift` — `videos_completed` counts these.
    var onAdvance: (() -> Void)?

    init(settings: SettingsStore = .shared) {
        self.settings = settings

        let configuration = WKWebViewConfiguration()
        // These three lines are load-bearing for login and playback and none of
        // them look it — see CLAUDE.md before touching any of them.
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        configuration.mediaTypesRequiringUserActionForPlayback = []
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        // Login flows fail in ways only the inspector can explain, and it is
        // loopback-only tooling, so leaving it on costs nothing.
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }

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

    /// Required for login forms to take a cursor at all; does not violate SPEC
    /// decision #7. See CLAUDE.md.
    override var canBecomeKey: Bool { true }

    /// Mouse-*up*, after WebKit has moved focus — at mouse-down
    /// `document.activeElement` is still what the user clicked away from.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard event.type == .leftMouseUp else { return }
        cmActivateIfEditingText(in: webView, window: self)
    }

    /// Channel scripts report through the `cm` bridge. The JS post is wrapped in
    /// try/catch, so a missing registration throws every event away in silence —
    /// which is how `videos_completed` once sat at zero.
    func handleChannelMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let event = body["event"] as? String ?? "?"
        let channel = body["channel"] as? String ?? "?"
        let detail = body["detail"] as? String ?? ""
        cmLog("channel \(channel): \(event)\(detail.isEmpty ? "" : " via \(detail)")")
        if event == "advance" { onAdvance?() }
    }

    private func configure() {
        isFloatingPanel = true
        level = .floating
        webView.configuration.userContentController.add(messageProxy, name: "cm")
        messageProxy.target = self
        // Partner to `canBecomeKey`: key status waits for a click on a view that
        // asks for it, so page content focuses the panel but the drag strip and a
        // plain show never do.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = true   // real content, unlike ChipPanel's translucent chip
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        webView.navigationDelegate = self
        webView.uiDelegate = self
        installWebView()

        // Deliberately no `contentAspectRatio`: it locks live resizing to a fixed
        // ratio, and Instagram/TikTok need real desktop width to render without
        // clipping their own chrome. `preferredAspect` still picks the opening
        // shape; this floor just stops a resize producing a sliver.
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
        dragHandle.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: Self.defaultDesiredSize))
        content.addSubview(webView)
        content.addSubview(dragHandle)   // added after webView: sits on top in z-order

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            dragHandle.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dragHandle.topAnchor.constraint(equalTo: content.topAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: Self.dragHandleHeight),
        ])

        self.contentView = content
    }

    // MARK: FeedPresenting

    func show(channel: ContentChannel?) {
        DispatchQueue.main.async { [weak self] in
            self?.performShow(channel: channel)
        }
    }

    /// Whether `performShow` should (re)load. Pure and internal so it can be
    /// asserted directly.
    ///
    /// Never compare `webView.url` to `channel.url`: in-site navigation makes them
    /// differ while the channel is unchanged, and since this runs every prompt it
    /// navigated users off half-finished logins (Instagram sessions "never
    /// saved"). Identity must be the one captured *at load time* — see CLAUDE.md.
    static func shouldLoad(loadedIdentity: String?, newIdentity: String, hasLoadedPage: Bool) -> Bool {
        loadedIdentity != newIdentity || !hasLoadedPage
    }

    private func performShow(channel: ContentChannel?) {
        activeChannel = channel
        dragHandle.label.stringValue = channel?.displayName ?? "Claude Maxx"

        let aspect = channel?.preferredAspect ?? Self.defaultAspect
        contentMinSize = WindowGeometry.minSize(aspectRatio: aspect)

        if let channel, Self.shouldLoad(
            loadedIdentity: loadedContentIdentity,
            newIdentity: channel.contentIdentity,
            hasLoadedPage: webView.url != nil
        ) {
            cmLog("performShow: LOADING \(channel.url.absoluteString) (loaded=\(loadedContentIdentity ?? "nil") new=\(channel.contentIdentity) currentURL=\(webView.url?.absoluteString ?? "nil"))")
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(channel.userScript())
            channel.load(into: webView)
            loadedContentIdentity = channel.contentIdentity
        } else {
            cmLog("performShow: no reload (loaded=\(loadedContentIdentity ?? "nil") new=\(channel?.contentIdentity ?? "nil") currentURL=\(webView.url?.absoluteString ?? "nil"))")
        }

        // Only place the window on a fresh open. While it's visible (channel
        // picker mid-episode), re-resolving from the persisted frame would
        // discard a resize the user just made.
        if !isVisible {
            guard let fallback = WindowGeometry.ScreenInfo.main else { return }   // no displays
            let restored = settings.windowFrame.map { NSRectFromString($0) }

            let frame = WindowGeometry.resolvedFrame(
                restored: restored,
                desiredSize: Self.defaultDesiredSize,
                aspectRatio: aspect,
                screens: WindowGeometry.ScreenInfo.all,
                mouseLocation: NSEvent.mouseLocation,
                fallbackScreen: fallback,
                corner: .bottomRight
            )
            setFrame(frame, display: true)
        }
        orderFrontRegardless()   // no makeKeyAndOrderFront: never takes key/activates app

        // Lifts hide()'s force-pause flag.
        webView.evaluateJavaScript("window.__cmHidden = false;")
        if let channel {
            channel.setAutoAdvance(settings.autoAdvance, in: webView)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settings.windowFrame = NSStringFromRect(self.frame)
            self.orderOut(nil)
            // A one-shot pause races page load — no <video> exists yet on a short
            // prompt, and it then autoplays audio into a hidden window. This flag
            // makes the pause persistent via the channels' 500 ms poll, and is
            // re-asserted in didFinish because navigation wipes it.
            self.webView.evaluateJavaScript("window.__cmHidden = true;")
            // Deliberately no clear/reload: the webview stays alive so login and
            // feed position survive (SPEC decision #9).
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
            // SPEC §8.4: the bounce is unconditional, the channel interrupt isn't.
            self.activeChannel?.attention(in: self.webView)
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    // MARK: Rule 5 — re-clamp on screen change (SPEC §7.1)

    @objc private func screenParametersChanged() {
        guard isVisible else { return }
        guard let fallback = WindowGeometry.ScreenInfo.main else { return }
        let aspect = activeChannel?.preferredAspect ?? Self.defaultAspect

        let newFrame = WindowGeometry.reclamped(
            currentFrame: frame,
            aspectRatio: aspect,
            screens: WindowGeometry.ScreenInfo.all,
            mouseLocation: NSEvent.mouseLocation,
            fallbackScreen: fallback,
            corner: .bottomRight
        )
        setFrame(newFrame, display: true, animate: true)
    }
}

// MARK: - WKNavigationDelegate

extension FeedPanel: WKNavigationDelegate {
    /// With `performShow`'s reload decisions, this is what distinguishes "the site
    /// redirected us" from "we navigated ourselves".
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cmLog("nav START\(webView === self.webView ? "" : " (popup)") -> \(webView.url?.absoluteString ?? "nil")")
    }

    /// A dead content process leaves a blank window that runs no JavaScript, and
    /// so cannot report anything — indistinguishable from a healthy idle channel.
    /// Log it and reload rather than sit blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cmLog("webview content process terminated — reloading \(activeChannel?.id ?? "no channel")")
        guard let channel = activeChannel else { return }
        channel.load(into: webView)
        loadedContentIdentity = channel.contentIdentity
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        cmLog("nav FINISH\(webView === self.webView ? "" : " (popup)") -> \(webView.url?.absoluteString ?? "nil")")
        // Playback flags belong to the feed only: a popup is a login form with no
        // video, and `isVisible` describes this panel, not the popup's window.
        guard webView === self.webView else { return }
        // Re-asserted here because a navigation completing *after* hide() runs in a
        // fresh window object — the "audio kept playing" race.
        webView.evaluateJavaScript("window.__cmHidden = \(!isVisible);")
        activeChannel?.setAutoAdvance(settings.autoAdvance, in: webView)
    }
}

// MARK: - WKUIDelegate

extension FeedPanel: WKUIDelegate {
    /// Without this, `target="_blank"` and `window.open()` fall through to the
    /// user's *default browser* ("why did TikTok open in the browser").
    ///
    /// Loading into the same webview and returning nil also fixes that, but
    /// silently breaks every popup-based login — see `PopupPanel` for why Meta's
    /// `auth_platform` handoff cannot survive losing its opener. A real second
    /// webview keeps both.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        cmLog("popup requested -> \(navigationAction.request.url?.absoluteString ?? "nil")")
        let popup = PopupPanel(configuration: configuration, windowFeatures: windowFeatures, relativeTo: self)
        popup.webView.uiDelegate = self
        popup.webView.navigationDelegate = self
        popupPanels.append(popup)
        popup.onClose = { [weak self, weak popup] in
            guard let popup else { return }
            cmLog("popup closed -> \(popup.webView.url?.absoluteString ?? "nil")")
            self?.popupPanels.removeAll { $0 === popup }
        }
        popup.orderFrontRegardless()   // consistent with the feed panel: never activates the app
        // Deliberately no `load` here — WebKit loads the request into the
        // returned webview itself, and doing it manually would both
        // double-load and break the opener handoff.
        return popup.webView
    }

    /// `window.close()` from the popup's own script — the normal way an auth
    /// handoff ends once it has posted the session back to its opener.
    func webViewDidClose(_ webView: WKWebView) {
        popupPanels.first { $0.webView === webView }?.close()
    }
}
