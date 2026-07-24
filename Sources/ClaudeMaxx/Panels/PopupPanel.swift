import AppKit
import WebKit

/// An auxiliary window hosting a `window.open()` popup.
///
/// Meta's login hands off to `instagram.com/auth_platform/?apc=…` in a popup
/// and expects to return the session to the page that opened it — the popup
/// posts back through `window.opener` and then calls `window.close()`.
/// Loading that URL into the main webview instead (the previous behavior)
/// destroys both halves of that contract: the opener is gone, so the callback
/// has nowhere to deliver the session, and the page that was waiting for it no
/// longer exists. Observed end result: the captcha solves, then Instagram
/// redirects back to `/reels/?e=<code>` and no `sessionid` cookie is ever set.
///
/// Returning a real second `WKWebView` from `createWebViewWith` — built from
/// the *configuration WebKit hands us*, never a fresh one — is what preserves
/// the opener relationship. WebKit loads the request itself in that case, so
/// callers must not call `load` on the returned webview.
final class PopupPanel: NSPanel {
    /// Sized for a login/consent form rather than the 9:16 feed shape.
    private static let fallbackSize = NSSize(width: 500, height: 680)

    let webView: WKWebView
    /// Invoked when the page calls `window.close()` (or the popup is closed
    /// another way) so the owner can drop its retain and let this deallocate.
    var onClose: (() -> Void)?

    init(configuration: WKWebViewConfiguration, windowFeatures: WKWindowFeatures, relativeTo parent: NSWindow?) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }

        let size = NSSize(
            width: windowFeatures.width?.doubleValue ?? Self.fallbackSize.width,
            height: windowFeatures.height?.doubleValue ?? Self.fallbackSize.height
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            // Titled and closable, unlike the feed panel: this is a transient
            // auth window the user must be able to identify and dismiss.
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "Sign in"
        isFloatingPanel = true
        level = .floating
        // Same focus contract as FeedPanel: eligible for key so login fields
        // take a caret, but only when the user actually clicks into it.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(webView)
        if let contentView {
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: contentView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }

        if let parent {
            let origin = NSPoint(
                x: parent.frame.midX - size.width / 2,
                y: parent.frame.midY - size.height / 2
            )
            setFrameOrigin(origin)
        } else {
            center()
        }
    }

    /// A login form is the whole point of this window, so it must be able to
    /// hold key — see `FeedPanel.canBecomeKey` for why the default is false.
    override var canBecomeKey: Bool { true }

    /// Key status alone isn't enough in an `.accessory` app whose panels
    /// don't activate it — see `cmActivateIfEditingText`. Without this, a
    /// user who clicks away mid-login and comes back types into the app they
    /// left instead of the form in front of them.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard event.type == .leftMouseUp else { return }
        cmActivateIfEditingText(in: webView, window: self)
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }
}
