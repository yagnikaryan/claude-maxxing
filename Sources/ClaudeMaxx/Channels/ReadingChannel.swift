import AppKit
import WebKit

/// Layer 3 reading-list channel (SPEC §8.3). A user-supplied, paste-in list
/// of article URLs. Deliberately has **no auto-advance**: an earlier build
/// inferred "done reading" from scrolling near the bottom and loaded the next
/// article on its own, but reaching the end of a page is not a request for a
/// different one — people linger, re-read, and scroll past the fold to the
/// comments. Moving between articles is `advance()`, a manual action only.
/// Per-URL scroll offset is persisted through
/// `SettingsStore`'s existing `cm.scroll.<urlhash>` API (§9.1) so a
/// hide/show cycle — or an app relaunch — resumes mid-paragraph rather than
/// at the top.
final class ReadingChannel: ContentChannel {
    /// Shown when the list is empty — a harmless page `userScript()`'s
    /// scroll-restore/advance-detection logic no-ops safely against.
    static let placeholderURL = URL(string: "about:blank")!

    private let defaults: UserDefaults
    private let settings: SettingsStore

    /// `defaults` is injectable for isolated testing (matches
    /// `SettingsStore`'s own pattern); production code uses `.standard`.
    /// `settings` is where per-URL scroll offsets actually live (§9.1) —
    /// this channel does not duplicate that storage.
    init(defaults: UserDefaults = .standard, settings: SettingsStore = .shared) {
        self.defaults = defaults
        self.settings = settings
    }

    private enum Keys {
        static let urls = "cm.reading.urls"
        static let currentIndex = "cm.reading.currentIndex"
    }

    // MARK: ContentChannel

    let id = "reading"
    let displayName = "Reading"

    /// ~4:5, per §8.1 ("9:16 video, ~4:5 reading").
    let preferredAspect = NSSize(width: 4, height: 5)

    /// No auto behavior at all (see the type-level comment) — reading pace
    /// belongs to the reader.
    let supportsAutoAdvance = false

    /// The currently-selected article. Falls back to `placeholderURL` when
    /// the list is empty or `currentIndex` is out of range (e.g. the list
    /// was edited elsewhere) rather than trapping.
    var url: URL {
        let list = urls
        guard list.indices.contains(currentIndex) else { return Self.placeholderURL }
        return list[currentIndex]
    }

    /// `WKUserScript` is created fresh per call (per `ContentChannel`'s
    /// contract — `FeedPanel` calls this once per channel/URL switch), so it
    /// can bake in the scroll offset and auto-advance flag current *at load
    /// time* for whichever article `url` currently points at.
    func userScript() -> WKUserScript {
        let hash = Self.urlHash(for: url)
        let restoreOffset = settings.scrollOffset(forURLHash: hash)
        let source = Self.scriptSource(restoreOffset: restoreOffset)
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Protocol requirement only. There is no auto behavior on this channel
    /// to gate (see the type-level comment).
    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {}

    /// Called before hide (per the protocol's contract). This is the
    /// channel's one chance to capture "where was the reader" before the
    /// window disappears and persist it via `SettingsStore` (§8.3, §9.1).
    /// Reads `webView.url` rather than `self.url` so the correct article is
    /// keyed even if an in-page advance already moved `currentIndex` ahead
    /// of what's actually still loaded.
    func pause(in webView: WKWebView) {
        let hash = Self.urlHash(for: webView.url ?? url)
        webView.evaluateJavaScript(Self.readScrollOffsetScript) { [settings] result, _ in
            guard let offset = result as? Double else { return }
            settings.setScrollOffset(offset, forURLHash: hash)
        }
    }

    /// Overlays a dismissible banner without touching scroll position
    /// (§8.4 — "yanking text mid-sentence is hostile"). The
    /// `NSApp.requestUserAttention` bounce is `FeedPanel`'s job, not this
    /// channel's (it fires unconditionally regardless of `activeChannel`).
    func attention(in webView: WKWebView) {
        webView.evaluateJavaScript(Self.attentionBannerScript)
    }

    // MARK: Reading list (persisted, "simple paste-in array" per §8.3)

    /// The user-supplied reading list, persisted under `cm.reading.urls`
    /// following `SettingsStore`'s cm.-prefixed UserDefaults pattern.
    /// Malformed stored strings are silently dropped rather than failing
    /// the whole list. Setting the list clamps `currentIndex` back into
    /// range (e.g. after the list shrinks) so `url` never needs to guess.
    var urls: [URL] {
        get { (defaults.stringArray(forKey: Keys.urls) ?? []).compactMap(URL.init(string:)) }
        set {
            defaults.set(newValue.map(\.absoluteString), forKey: Keys.urls)
            if !newValue.indices.contains(currentIndex) {
                currentIndex = max(0, newValue.count - 1)
            }
        }
    }

    /// Index into `urls` of the article currently loaded. Persisted (not
    /// just in-memory) so the reading position within the *list* survives
    /// relaunch, same as the per-article scroll offset does.
    private(set) var currentIndex: Int {
        get { defaults.integer(forKey: Keys.currentIndex) }
        set { defaults.set(newValue, forKey: Keys.currentIndex) }
    }

    /// Advances to the next article in the list — a *manual* action for a
    /// future chip/menu control; nothing calls it automatically (the old
    /// bottom-of-page detector is gone, see the type-level comment).
    /// Non-wrapping — returns `false` and leaves `currentIndex` unchanged at
    /// the end of the list, so a caller can tell whether there's anywhere
    /// left to advance to. Callers are responsible for reloading the webview
    /// against the new `url` afterward — this method only moves the cursor.
    @discardableResult
    func advance() -> Bool {
        let list = urls
        guard currentIndex + 1 < list.count else { return false }
        currentIndex += 1
        return true
    }

    // MARK: JS sources

    /// Reads the current vertical scroll offset. Shared between `pause(in:)`
    /// (native readback) and documented here so the two "what counts as the
    /// scroll offset" definitions (read side, restore side) never drift.
    private static let readScrollOffsetScript =
        "window.pageYOffset || document.documentElement.scrollTop || 0;"

    /// Injected at `.atDocumentEnd` (§8.1). Restores the persisted scroll
    /// offset for the article being loaded — and nothing else. The
    /// bottom-of-article advance detector that used to live here is gone
    /// (see the type-level comment): reaching the end of a page must never
    /// navigate the reader somewhere they didn't ask to go.
    private static func scriptSource(restoreOffset: Double) -> String {
        """
        (function() {
          if (window.__cmReadingInstalled) return;
          window.__cmReadingInstalled = true;
          var __cmRestoreY = \(restoreOffset);

          function __cmRestoreScroll() {
            if (__cmRestoreY > 0) { window.scrollTo(0, __cmRestoreY); }
          }

          // .atDocumentEnd may run before or after DOMContentLoaded/load —
          // cover both, and re-apply on 'load' since image/layout shifts
          // after the initial paint can move the target offset.
          __cmRestoreScroll();
          window.addEventListener('DOMContentLoaded', __cmRestoreScroll);
          window.addEventListener('load', __cmRestoreScroll);
        })();
        """
    }

    /// Idempotent (checks for its own id) so repeated `/attention` calls
    /// against the same loaded page don't stack duplicate banners. Pure
    /// DOM insertion — never calls `scrollTo`/`scrollIntoView`, per §8.4.
    private static let attentionBannerScript = """
        (function() {
          var id = '__cm-attention-banner';
          if (document.getElementById(id)) return;
          var banner = document.createElement('div');
          banner.id = id;
          banner.textContent = 'Claude needs input';
          banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483647;' +
            'background:#1a1a1a;color:#fff;font:13px -apple-system,sans-serif;' +
            'padding:8px 36px 8px 12px;text-align:center;box-shadow:0 2px 6px rgba(0,0,0,.3);';
          var dismiss = document.createElement('button');
          dismiss.textContent = String.fromCharCode(215);
          dismiss.setAttribute('aria-label', 'Dismiss');
          dismiss.style.cssText = 'position:absolute;right:8px;top:6px;background:transparent;' +
            'border:none;color:#fff;font-size:16px;line-height:1;cursor:pointer;padding:2px 6px;';
          dismiss.onclick = function() { banner.remove(); };
          banner.appendChild(dismiss);
          document.documentElement.appendChild(banner);
        })();
        """

    /// Stable (non-randomized) hash for the `cm.scroll.<urlhash>` key
    /// (§9.1, §8.3). Deliberately not `String.hashValue`/`Hasher` — those
    /// are randomized per-process in Swift, which would silently break
    /// scroll persistence across relaunches. FNV-1a is simple, dependency-
    /// free, and stable by construction; collision risk is irrelevant at
    /// reading-list scale.
    static func urlHash(for url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
