import AppKit
import WebKit

/// Layer 3 reading-list channel (SPEC §8.3): web articles *and* local files
/// (PDFs, mostly) in one list, picked from the menu's Reading submenu.
///
/// Deliberately **no auto-advance**. An earlier build inferred "done reading"
/// from scrolling near the bottom, but reaching the end of a page is not a
/// request for a different one — people linger, re-read, and scroll past the fold
/// to the comments. Moving between items is manual only.
///
/// Per-URL scroll offset persists through `cm.scroll.<urlhash>` (§9.1), so a
/// hide/show cycle resumes mid-paragraph. Web pages only — PDFs open at the top
/// every time, see CLAUDE.md.
final class ReadingChannel: ContentChannel {
    /// Stand-in for "the list is empty"; never loaded, because `load(into:)`
    /// intercepts that case — a blank white window looks like a broken one.
    static let placeholderURL = URL(string: "about:blank")!

    private let defaults: UserDefaults
    private let settings: SettingsStore

    /// `defaults` is injectable for isolated testing. Scroll offsets live in
    /// `settings` (§9.1); this channel does not duplicate that storage.
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

    /// `nil` rather than a trap when the list is empty or `currentIndex` is stale
    /// from an edit elsewhere.
    var currentURL: URL? {
        let list = urls
        guard list.indices.contains(currentIndex) else { return nil }
        return list[currentIndex]
    }

    var url: URL { currentURL ?? Self.placeholderURL }

    /// Folds the selected item into the identity `FeedPanel` keys reloads on
    /// — without this, picking a different article while Reading is already
    /// the active channel compares "reading" to "reading" and never reloads.
    var contentIdentity: String { "\(id)#\(currentIndex)#\(currentURL?.absoluteString ?? "")" }

    /// Fresh per call, so it can bake in the scroll offset current *at load time*
    /// for whichever article `url` points at.
    func userScript() -> WKUserScript {
        let hash = Self.urlHash(for: url)
        let restoreOffset = settings.scrollOffset(forURLHash: hash)
        let source = Self.scriptSource(restoreOffset: restoreOffset)
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Local files need `loadFileURL`; see CLAUDE.md.
    ///
    /// Read access is granted to the single file, not its parent directory — a PDF
    /// needs no subresources, and the webview has no business reading the rest of
    /// the folder. A local .html with relative assets would need the directory;
    /// that should be an explicit decision, not a default.
    func load(into webView: WKWebView) {
        guard let target = currentURL else {
            webView.loadHTMLString(Self.emptyStateHTML, baseURL: nil)
            return
        }
        guard target.isFileURL else {
            webView.load(URLRequest(url: target))
            return
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            // Files move and get deleted; the list holds paths, not handles.
            // Say which one is gone instead of showing an empty window.
            webView.loadHTMLString(Self.missingFileHTML(for: target), baseURL: nil)
            return
        }
        webView.loadFileURL(target, allowingReadAccessTo: target)
    }

    /// The one chance to capture where the reader was before the window
    /// disappears. Keys on `webView.url`, not `self.url`, so an in-page advance
    /// that already moved `currentIndex` doesn't file the offset under the wrong
    /// article.
    ///
    /// No-ops on PDFs and placeholders — no JS context, so `result` is nil and the
    /// guard drops it. Persisting a bogus 0 would be worse than persisting nothing.
    func pause(in webView: WKWebView) {
        let hash = Self.urlHash(for: webView.url ?? url)
        webView.evaluateJavaScript(Self.readScrollOffsetScript) { [settings] result, _ in
            guard let offset = result as? Double else { return }
            settings.setScrollOffset(offset, forURLHash: hash)
        }
    }

    /// The `NSApp.requestUserAttention` bounce is `FeedPanel`'s job, not this
    /// channel's (it fires regardless of `activeChannel`).
    func attention(in webView: WKWebView) {
        webView.evaluateJavaScript(AttentionBanner.showScript(accent: "#1a1a1a"))
    }

    // MARK: Reading list (persisted, "simple paste-in array" per §8.3)

    /// Persisted under `cm.reading.urls`. A malformed entry is dropped rather than
    /// failing the whole list, and setting the list clamps `currentIndex` back into
    /// range so `url` never has to guess.
    ///
    /// Read back through `normalized(_:)`, not `URL(string:)`, so hand-edited
    /// defaults work: a bare path has no scheme, and `URL(string:)` returns nil for
    /// an unescaped space — dropping exactly the files people actually have.
    var urls: [URL] {
        get { (defaults.stringArray(forKey: Keys.urls) ?? []).compactMap(Self.normalized) }
        set {
            defaults.set(newValue.map(\.absoluteString), forKey: Keys.urls)
            if !newValue.indices.contains(currentIndex) {
                currentIndex = max(0, newValue.count - 1)
            }
        }
    }

    /// Appends `raw` (a pasted link or a file path) and selects it, so the
    /// thing you just added is the thing you see. Returns the parsed URL, or
    /// `nil` if `raw` isn't usable as either. Already-present entries are
    /// selected rather than duplicated.
    @discardableResult
    func add(_ raw: String) -> URL? {
        guard let parsed = Self.normalized(raw) else { return nil }
        return add(parsed)
    }

    /// Direct-URL form, for callers that already have one (`NSOpenPanel`) and
    /// shouldn't have to round-trip through string parsing to add it.
    @discardableResult
    func add(_ parsed: URL) -> URL? {
        var list = urls
        if let existing = list.firstIndex(of: parsed) {
            currentIndex = existing
            return parsed
        }
        list.append(parsed)
        urls = list
        currentIndex = list.count - 1
        return parsed
    }

    /// Removes the item at `index` and keeps the selection pointing at
    /// something sensible — the next item down, or the new last item when
    /// the tail was removed.
    func remove(at index: Int) {
        var list = urls
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        let desired = index >= list.count ? list.count - 1 : index
        urls = list                                  // clamps currentIndex if it fell out of range
        currentIndex = max(0, desired)
    }

    /// Selects the item at `index`. Out-of-range indices are ignored rather
    /// than trapping (the menu is rebuilt from a list that could have been
    /// edited from another surface between build and click).
    func select(index: Int) {
        guard urls.indices.contains(index) else { return }
        currentIndex = index
    }

    /// Menu-friendly label: the filename for local files, host+path for web
    /// links, truncated so one long URL can't stretch the menu.
    static func displayTitle(for url: URL, maxLength: Int = 44) -> String {
        let full: String
        if url.isFileURL {
            full = url.lastPathComponent
        } else if let host = url.host {
            let path = url.path
            full = path.isEmpty || path == "/" ? host : host + path
        } else {
            full = url.absoluteString
        }
        guard full.count > maxLength else { return full }
        return full.prefix(maxLength - 1) + "…"
    }

    /// Parses one list entry / paste into a URL, accepting the forms people
    /// actually produce: a copied web link, a dragged-in `file://` URL, an
    /// absolute or tilde path, and a bare `example.com/x` with no scheme.
    /// Returns `nil` for anything left over rather than inventing a URL.
    static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://") {
            // `URL(string:)` handles the properly-encoded form; the fallback
            // covers a pasted/hand-written one containing raw spaces, which
            // `URL(string:)` rejects entirely.
            if let parsed = URL(string: trimmed), parsed.isFileURL { return parsed }
            let path = String(trimmed.dropFirst("file://".count))
            return URL(fileURLWithPath: (path.removingPercentEncoding ?? path))
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let parsed = URL(string: trimmed), parsed.scheme != nil, parsed.host != nil {
            return parsed
        }
        // Bare "example.com/article" — a link, just missing its scheme.
        if let parsed = URL(string: "https://" + trimmed), parsed.host != nil {
            return parsed
        }
        return nil
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

    // MARK: Placeholder pages

    /// Shown instead of `about:blank` when the list is empty. An unconfigured
    /// feature and a broken one look identical otherwise — which is exactly
    /// how this channel was first reported ("I selected Reading and it's just
    /// a blank white page").
    static let emptyStateHTML = page(
        title: "Nothing to read yet",
        body: "Add a link or a local PDF from the <b>CM</b> menu bar icon → " +
              "<b>Reading</b> → <b>Add Link…</b> / <b>Add PDF…</b>"
    )

    static func missingFileHTML(for url: URL) -> String {
        page(
            title: "That file has moved",
            body: "<code>" + escapedHTML(url.path) + "</code><br><br>" +
                  "The list stores a path, so renaming or deleting the file breaks the link. " +
                  "Remove it from the <b>Reading</b> menu, or add it again from its new location."
        )
    }

    /// Both placeholders share one shell. Follows the system appearance so the
    /// panel doesn't flash white against a dark desktop mid-wait.
    private static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
                     background:#f7f7f5;color:#3a3a38;
                     font:14px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;">
          <div style="max-width:30em;padding:0 2em;text-align:center">
            <div style="font-size:15px;font-weight:600;margin-bottom:.6em">\(title)</div>
            <div style="opacity:.72">\(body)</div>
          </div>
          <style>
            @media (prefers-color-scheme: dark) {
              body { background:#1c1c1a !important; color:#e8e8e4 !important; }
            }
            code { font:12px ui-monospace,SFMono-Regular,Menlo,monospace; opacity:.85;
                   word-break:break-all; }
          </style>
        </body></html>
        """
    }

    /// The file path lands inside markup — a path may legitimately contain
    /// `&` or `<`, and a half-escaped placeholder would render as garbage.
    private static func escapedHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
