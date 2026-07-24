import AppKit
import WebKit

/// The stats dashboard as a native floating panel — the same self-contained
/// HTML `HookServer` serves at `/dashboard`, hosted in the app's own window
/// instead of a browser tab.
///
/// The page is regenerated and loaded via `loadHTMLString` on every
/// `present()`, so opening the panel *is* the data refresh — no HTTP round
/// trip, and closing it holds no stale state worth preserving. This webview
/// is deliberately separate from `FeedPanel`'s: that one belongs to the
/// channels and their pause/hide lifecycle, and a stats page has no business
/// being paused, reloaded to a feed URL, or counted as content time.
final class StatsPanel: NSPanel {
    static let shared = StatsPanel()

    private static let defaultSize = NSSize(width: 960, height: 780)
    private let webView: WKWebView

    /// Regenerates the dashboard from the current event log and shows the
    /// panel. Callable from any thread (Menu is main, Router is not).
    static func present(stats: StatsStore = .shared) {
        DispatchQueue.main.async {
            let html = StatsDashboard.html(
                events: stats.allEvents(),
                channelNames: Dictionary(uniqueKeysWithValues: ChannelRegistry.all.map { ($0.id, $0.displayName) })
            )
            shared.webView.loadHTMLString(html, baseURL: nil)
            if !shared.isVisible { shared.center() }
            shared.orderFrontRegardless()   // consistent with FeedPanel: never activates the app
        }
    }

    private init() {
        let configuration = WKWebViewConfiguration()
        // Nothing to persist — the page is static HTML with inline data.
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            // Titled and closable, unlike the feed panel: this is a document
            // the user opens on purpose and dismisses when done.
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "Claude Maxx — Stats"
        isFloatingPanel = true
        level = .floating
        // Same focus contract as the other panels: eligible for key so the
        // range buttons and table toggles are clickable, but it only takes
        // key when the user actually clicks into it.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 420, height: 480)

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
    }

    /// Interactive controls (range filter, chart⇄table toggles) need the
    /// panel to be able to hold key — see `FeedPanel.canBecomeKey`.
    override var canBecomeKey: Bool { true }
}
