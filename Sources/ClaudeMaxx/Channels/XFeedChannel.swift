import AppKit
import WebKit

/// Layer 3 channel adapter for the X (Twitter) home feed (SPEC §8.3).
///
/// Unlike the video channels, XFeed has no watch-complete concept — it is
/// ambient. Instead of a per-video `ended` advance, the channel drives a
/// slow, continuous auto-scroll that pauses whenever the pointer is over the
/// page (so the user can read/interact) and resumes when it leaves. Per
/// SPEC §8.4, `/attention` overlays a dismissible banner without touching
/// scroll position — yanking text mid-sentence is hostile.
///
/// Decision #10 (§15): X feed is the easiest ambient channel to build,
/// picked as the second channel after Shorts precisely because it needs no
/// per-site "next" selector — just scroll.
struct XFeedChannel: ContentChannel {
    let id = "xfeed"
    let displayName = "X"
    let url = URL(string: "https://x.com/home")!

    /// Non-video default aspect (SPEC §8.1: "reading channels get the same
    /// clamp with a ~4:5 ratio"). XFeed is a reading-shaped feed, not
    /// 9:16 video, so it shares that ~4:5 ratio rather than
    /// `FeedPanel.defaultAspect`.
    let preferredAspect = NSSize(width: 4, height: 5)

    /// Ambient, not completion-based (SPEC §8.3) — there is no "video
    /// ended" signal to advance on, so the chip/menu never offers
    /// auto-advance toggling for this channel's completion semantics.
    /// `setAutoAdvance` below still exists (protocol requirement) and is
    /// repurposed to gate the auto-scroll loop, since that's this channel's
    /// only "auto" behavior.
    let supportsAutoAdvance = false

    func userScript() -> WKUserScript {
        WKUserScript(
            source: Self.scriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {
        // Reuses the `__cmAutoAdvance` flag name from the shared injected-JS
        // convention (SPEC "Naming conventions"), repurposed here to gate
        // the auto-scroll `setInterval` loop instead of a video "next"
        // control — this channel has no completion event to advance on.
        webView.evaluateJavaScript("window.__cmAutoAdvance = \(on);")
    }

    func pause(in webView: WKWebView) {
        // Called before hide (SPEC §8.1). Stops the auto-scroll loop so the
        // page sits still while the panel is hidden; resumed on next
        // `show(channel:)` via FeedPanel's `setAutoAdvance` call.
        webView.evaluateJavaScript("window.__cmAutoAdvance = false;")
    }

    func attention(in webView: WKWebView) {
        // SPEC §8.4: reading/X channels overlay a dismissible injected
        // banner *without* touching scroll position. The banner itself is
        // installed by the user script; this just triggers it.
        webView.evaluateJavaScript("window.__cmShowAttentionBanner && window.__cmShowAttentionBanner();")
    }

    // MARK: - Injected JS

    /// Slow auto-scroll (2px / 30ms, per SPEC §8.3's literal
    /// `setInterval(() => scrollBy({top: 2, behavior:'instant'}), 30)`)
    /// paused on `mouseenter` and resumed on `mouseleave`, plus the
    /// dismissible attention banner from §8.4. Guarded by `__cmInstalled`
    /// like the §8.2 video pattern, so re-injection on reload is a no-op.
    private static let scriptSource = """
    (function() {
      if (window.__cmInstalled) return;
      window.__cmInstalled = true;
      window.__cmAutoAdvance = true;   // native toggles this via setAutoAdvance/pause

      var hovering = false;

      setInterval(function() {
        if (!window.__cmAutoAdvance || hovering) return;
        window.scrollBy({ top: 2, left: 0, behavior: 'instant' });
      }, 30);

      // mouseenter/mouseleave on documentElement don't bubble, so they fire
      // exactly once when the pointer crosses into/out of the page — not
      // per descendant hover.
      document.documentElement.addEventListener('mouseenter', function() {
        hovering = true;
      });
      document.documentElement.addEventListener('mouseleave', function() {
        hovering = false;
      });

      window.__cmShowAttentionBanner = function() {
        if (document.getElementById('__cm-attention-banner')) return;   // already showing

        var banner = document.createElement('div');
        banner.id = '__cm-attention-banner';
        banner.style.cssText = [
          'position:fixed', 'top:0', 'left:0', 'right:0', 'z-index:2147483647',
          'display:flex', 'align-items:center', 'justify-content:space-between',
          'background:#1d9bf0', 'color:#fff',
          'font:600 13px -apple-system,BlinkMacSystemFont,sans-serif',
          'padding:8px 12px', 'box-shadow:0 2px 6px rgba(0,0,0,0.25)'
        ].join(';');

        var label = document.createElement('span');
        label.textContent = 'Claude needs input';

        var dismiss = document.createElement('button');
        dismiss.textContent = 'Dismiss';
        dismiss.style.cssText = [
          'margin-left:12px', 'background:rgba(255,255,255,0.2)', 'color:#fff',
          'border:none', 'border-radius:4px', 'padding:4px 10px',
          'font:600 12px -apple-system,BlinkMacSystemFont,sans-serif', 'cursor:pointer'
        ].join(';');
        dismiss.addEventListener('click', function() {
          banner.remove();
        });

        banner.appendChild(label);
        banner.appendChild(dismiss);
        // Deliberately does NOT call scrollTo/scrollIntoView — SPEC §8.4:
        // "without touching scroll position".
        document.documentElement.appendChild(banner);
      };
    })();
    """
}
