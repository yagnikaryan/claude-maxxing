import AppKit
import WebKit

/// Breaks the retain cycle WebKit would otherwise create: a
/// `userContentController` retains its message handlers, and the panel owns
/// the webview that owns the controller. Holding the panel weakly here keeps
/// that loop open without giving up the `cm` channel.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: FeedPanel?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleChannelMessage(message)
    }
}

/// Routes the keyboard to `window` when a click lands in a text field.
///
/// A `.nonactivatingPanel` in an `.accessory` app can become key *within the
/// app* without the app ever becoming active — and macOS delivers keystrokes
/// to the active app, not to a key window in an inactive one. So after the
/// user clicks away to another app and back, typing kept going to whatever
/// they left (reported as: TikTok's SMS code lands in Claude instead of the
/// code box). Typing worked immediately after a login only because the app
/// happened to still be active from the popup.
///
/// Activating unconditionally on click would violate SPEC decision #7 by
/// pulling focus off the user's editor whenever they unmute or scroll a
/// video. Asking the page whether the click actually focused an editable
/// element keeps the fix scoped to the one case that needs the keyboard.
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

/// Timestamped stderr trace. The daemon runs headless behind a menu bar icon,
/// so stderr (redirected to a log file by the launcher) is the only place
/// window/navigation behavior can be reconstructed after the fact — a login
/// flow that breaks only on a later prompt can't be caught by watching.
func cmLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(stamp)] \(message)\n".data(using: .utf8)!)
}

/// A thin overlay strip so the otherwise-undraggable panel can be moved.
/// `isMovableByWindowBackground` has no effect here: the `WKWebView` fills
/// the entire content view, so nothing is left as true "window background"
/// for AppKit to hit-test — `performDrag(with:)` is the only reliable way to
/// make an arbitrary borderless-panel view draggable. Also doubles as the
/// one place a user can see which channel is currently loaded (SPEC §7.1
/// gives channels no on-window chrome otherwise).
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

    /// Without this, AppKit's normal front-to-back hit-testing would deliver
    /// mouseDown to the label subview (not this view) whenever the click
    /// lands on the visible channel-name text — exactly the most obvious
    /// spot to grab — and `performDrag` below would never fire there.
    /// Claiming the whole strip for self makes every point in it draggable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

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
    /// Deliberately layered *over* the webview rather than pushing it down,
    /// so the window's aspect-ratio/geometry math (§7.1, already covered by
    /// WindowGeometryTests) keeps treating the whole content rect as the
    /// video area — adding a drag handle doesn't change any of that math.
    static let dragHandleHeight: CGFloat = 22

    private let settings: SettingsStore
    /// Internal (not private) only so FeedPanelTests can assert the
    /// login-critical configuration (UA suffix, persistent data store).
    let webView: WKWebView
    private let dragHandle = DragHandleView(frame: .zero)
    private(set) var activeChannel: ContentChannel?
    /// `contentIdentity` of whatever was last actually loaded into the
    /// webview — the left-hand side of `shouldLoad`. Stored rather than
    /// re-derived because channel instances are shared and mutable; see
    /// `shouldLoad`.
    private var loadedContentIdentity: String?
    /// Live `window.open()` popups (logins, mostly). Retained here because
    /// `isReleasedWhenClosed` is false and nothing else owns them; entries are
    /// dropped in each popup's `onClose`. Internal (not private) so tests can
    /// assert a popup was hosted rather than swallowed into the feed.
    private(set) var popupPanels: [PopupPanel] = []
    private let messageProxy = ScriptMessageProxy()
    /// Fired when a channel confirms the feed actually moved to the next
    /// item. Wired to the stats store in `main.swift`; `StatsEvent.advance`
    /// is what `videos_completed` counts, and nothing was ever appending it.
    var onAdvance: (() -> Void)?

    init(settings: SettingsStore = .shared) {
        self.settings = settings

        let configuration = WKWebViewConfiguration()
        // `.default()` (not `.nonPersistent()`) is what makes this a
        // *persistent* data store — login cookies survive relaunch, per
        // SPEC §8.1 ("each platform is a one-time manual sign-in"). This is
        // the load-bearing distinction; it isn't obvious from the call site.
        // (Verified working unbundled too: storage lands under
        // ~/Library/WebKit/ClaudeMaxx keyed by process name.)
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        // WKWebView's default UA ends at "(KHTML, like Gecko)" — no
        // "Version/x Safari/x" suffix — which is the fingerprint of an
        // embedded webview. Meta/Google login flows treat those as
        // untrusted: Instagram would run the full password+captcha dance
        // and then silently withhold the `sessionid` cookie, so login could
        // never persist no matter how the data store was configured.
        // `applicationNameForUserAgent` appends the suffix to the genuine
        // WebKit UA, composing exactly what real Safari sends.
        configuration.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
        // WebKit otherwise requires a user gesture before a video may play,
        // and nothing in this window ever supplies one — the whole point is
        // that content plays on its own while Claude works. TikTok's player
        // sat paused at t=0 forever because of this, which also starved the
        // watch-complete check that drives auto-advance (a video that never
        // plays never ends). Reels happened to be allowed under the default,
        // which is what made this look like a TikTok-only scrolling bug.
        // Safe against the "audio kept playing after the window closed"
        // failure: hide() and the channels' __cmHidden poll still force-pause.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        // Right-click → Inspect Element. Login flows fail in ways only the
        // inspector can explain (e.g. Instagram completes password+captcha
        // but the login XHR response withholds `sessionid`; TikTok's SMS
        // code boxes won't take focus) — and the inspector is loopback-only
        // developer tooling, so leaving it on costs nothing in production.
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

    /// A borderless panel defaults to `canBecomeKey == false`, which made
    /// the webview permanently unfocusable: WebKit treated every page as
    /// blurred, so login forms never took a cursor and typing was
    /// impossible ("I can't type into the Instagram login"). Overriding to
    /// `true` does NOT violate decision #7 ("never steal keyboard focus") —
    /// the panel still never *takes* key on show (`performShow` uses
    /// `orderFrontRegardless`, never `makeKeyAndOrderFront`, and
    /// `.nonactivatingPanel` keeps the app from activating). It only
    /// *accepts* key when the user deliberately clicks into it, Spotlight-
    /// style, which is precisely what a login flow needs.
    override var canBecomeKey: Bool { true }

    /// Checked on mouse-*up*, after WebKit has handled the click and moved
    /// focus — at mouse-down `document.activeElement` is still the element
    /// the user is clicking away from.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard event.type == .leftMouseUp else { return }
        cmActivateIfEditingText(in: webView, window: self)
    }

    /// Channel scripts report through the `cm` bridge. Registering it was
    /// missing entirely, and the JS post is wrapped in a try/catch, so every
    /// advance event was thrown away silently — `videos_completed` sat at
    /// zero and a channel that could no longer advance had no way to say so.
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
        // Partner to `canBecomeKey` above: defer key status until a click
        // lands on a view that asks for it (`needsPanelToBecomeKey`). The
        // webview reports it always wants key, so in practice any click on
        // page content focuses the panel — but the drag strip doesn't, and
        // merely *showing* the panel still never takes key either way.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = true   // real content, unlike ChipPanel's translucent chip
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        webView.navigationDelegate = self
        webView.uiDelegate = self
        installWebView()

        // Deliberately NOT setting contentAspectRatio: that AppKit property
        // locks live user resizing to a fixed ratio, which fought real usage
        // — sites like Instagram/TikTok need real desktop width to render
        // without clipping their own chrome, not just a bigger 9:16 rectangle.
        // The channel's preferredAspect is still used for the *initial*
        // frame in performShow (a nice default shape to open at) — it just
        // no longer constrains what the user resizes it to afterward.
        // contentMinSize stays as a floor so a resize can't produce an
        // unusable sliver (SPEC §7.1 rule 6).
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

    /// Whether `performShow` should (re)load the channel's feed URL. Pure and
    /// internal so it can be asserted directly, mirroring `WindowGeometry`.
    ///
    /// Reload only when the channel actually changes, so pause→show on the
    /// *same* channel resumes the live page instead of reloading it —
    /// preserving scroll/feed position (SPEC §9.3's login/position framing).
    ///
    /// Deliberately keyed on channel *identity*, never on comparing
    /// `webView.url` to `channel.url`. Any in-site navigation makes those two
    /// differ while the channel is unchanged — most importantly a login flow,
    /// where the user is legitimately parked on /accounts/login/ or a TikTok
    /// SMS-code screen. Since `presentWindow` fires on every prompt, the URL
    /// comparison this replaced re-navigated back to the feed mid-login on the
    /// user's very next prompt, wiping the half-finished form. That is why
    /// Instagram logins "never saved" (the session was never granted, because
    /// the flow never got to finish) and why TikTok's 6-digit code screen kept
    /// vanishing before a code could be entered.
    ///
    /// Keyed on `contentIdentity` rather than `id` so a channel that can
    /// change what it shows without changing which channel it is — Reading,
    /// picking a different article — actually reloads. Compared against the
    /// identity captured *at load time*, not one re-derived from
    /// `activeChannel`: channel instances are shared and live
    /// (`ChannelRegistry.all` is a `static let`), so by the time a menu
    /// selection reaches here the instance already reports its new identity
    /// and comparing it to itself would never reload.
    static func shouldLoad(loadedIdentity: String?, newIdentity: String, hasLoadedPage: Bool) -> Bool {
        loadedIdentity != newIdentity || !hasLoadedPage
    }

    private func performShow(channel: ContentChannel?) {
        activeChannel = channel
        dragHandle.label.stringValue = channel?.displayName ?? "Claude Maxx"

        let aspect = channel?.preferredAspect ?? Self.defaultAspect
        // aspect still drives the *initial* frame below and the min-size
        // floor — just not a live contentAspectRatio lock (see configure()).
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

        // Only place the window from scratch on a fresh open. If it's
        // already visible (e.g. Menu's channel picker switching channels
        // mid-episode via switchChannelIfShowing), re-resolving from the
        // last-*persisted* settings.windowFrame would discard any resize/
        // reposition the user just made in this still-open episode — leave
        // the live frame alone and only swap content.
        if !isVisible {
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
        }
        orderFrontRegardless()   // no makeKeyAndOrderFront: never takes key/activates app

        // Lift the hidden-enforcement flag (see hide()) so the channel
        // scripts stop force-pausing — the user can now play freely.
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
            // The one-shot channel.pause() the orchestrator fires before
            // hide races page load: on a short prompt the site is often
            // still loading, no <video> exists yet to pause, and the video
            // then autoplays audio into a hidden window. __cmHidden makes
            // the pause *persistent*: the channels' 500 ms poll force-pauses
            // any video that appears while it's set. Re-asserted in
            // didFinish below because a full navigation replaces `window`
            // and wipes the flag.
            self.webView.evaluateJavaScript("window.__cmHidden = true;")
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
    /// Diagnostic trail for login flows: every page the webview commits to,
    /// paired with `performShow`'s reload decisions, is what distinguishes
    /// "the site redirected us" from "we navigated ourselves".
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cmLog("nav START\(webView === self.webView ? "" : " (popup)") -> \(webView.url?.absoluteString ?? "nil")")
    }

    /// The web content process can die on its own (memory pressure, a site
    /// bug), leaving a blank window and a page that runs no JavaScript at all
    /// — indistinguishable from a healthy idle channel, since a dead page
    /// cannot report anything. Say so, and reload the channel so the window
    /// recovers instead of sitting blank until someone notices.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cmLog("webview content process terminated — reloading \(activeChannel?.id ?? "no channel")")
        guard let channel = activeChannel else { return }
        channel.load(into: webView)
        loadedContentIdentity = channel.contentIdentity
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        cmLog("nav FINISH\(webView === self.webView ? "" : " (popup)") -> \(webView.url?.absoluteString ?? "nil")")
        // Channel playback flags belong only to the feed. A popup is a login
        // form with no video to pause, and `isVisible` describes this panel,
        // not the popup's own window.
        guard webView === self.webView else { return }
        // Re-applies the flags after every real navigation/reload, matching
        // §8.2 ("native toggles this flag"). __cmHidden must be re-asserted
        // here because a navigation that *completes after hide()* runs in a
        // fresh window object — exactly the "audio kept playing after the
        // window closed" race this flag exists for.
        webView.evaluateJavaScript("window.__cmHidden = \(!isVisible);")
        activeChannel?.setAutoAdvance(settings.autoAdvance, in: webView)
    }
}

// MARK: - WKUIDelegate

extension FeedPanel: WKUIDelegate {
    /// Without a `uiDelegate` implementing this, WebKit has no way to honor
    /// a `target="_blank"` link or `window.open()` call — on macOS that
    /// falls through to the OS opening the URL in the user's *default*
    /// browser instead of the app's own contained webview (the real cause
    /// behind "why did TikTok open in the browser").
    ///
    /// This used to satisfy that by loading the request into the *same*
    /// webview and returning nil. That kept popups in-app but silently broke
    /// every popup-based login: see `PopupPanel` for why Meta's
    /// `auth_platform` handoff can't survive losing its opener. Hosting a
    /// real second webview keeps both properties — nothing escapes to the
    /// default browser, and `window.opener`/`window.close()` still work.
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
