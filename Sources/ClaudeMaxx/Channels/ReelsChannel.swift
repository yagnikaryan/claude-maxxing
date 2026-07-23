import AppKit
import WebKit

/// Layer 3 channel adapter for Instagram Reels (SPEC §8.1/§8.2, M4).
///
/// Deliberately scroll-only for `advance()` right now. §8.2 flags the
/// Reels/TikTok next-chevron selectors as "unverified guesses by design...
/// not something an agent should trust" — pinning the real selector means
/// inspecting the live desktop DOM with the web inspector, and Reels
/// "effectively requires sign-in" (§8.1), so it needs a human with a real
/// account to do that safely. Rather than guess a selector, this channel
/// uses the spec's own documented fallback (`scrollBy(innerHeight)`,
/// §8.2's "Policy for Reels/TikTok") as the *only* advance mechanism for
/// now. Swap `cmClickNext` for a real chevron click once someone pins the
/// live selector (§12 M4) — everything else (jitter, `ended` detection,
/// stats reporting) is already wired and won't need to change.
final class ReelsChannel: ContentChannel {
    let id = "reels"
    let displayName = "Reels"
    let url = URL(string: "https://www.instagram.com/reels/")!
    let preferredAspect = NSSize(width: 9, height: 16)
    let supportsAutoAdvance = true

    func userScript() -> WKUserScript {
        WKUserScript(
            source: Self.scriptSource(channelID: id),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript("window.__cmAutoAdvance = \(on);")
    }

    func pause(in webView: WKWebView) {
        webView.evaluateJavaScript("document.querySelector('video')?.pause();")
    }

    func attention(in webView: WKWebView) {
        pause(in: webView)
    }

    /// Same watch-complete detection as `ShortsChannel` (§8.2's `ended`
    /// pattern with a currentTime-based fallback and the required timing
    /// jitter), but `cmClickNext` is scroll-only until a real chevron
    /// selector is pinned — see the type-level doc comment.
    static func scriptSource(channelID: String) -> String {
        """
        (function() {
          if (window.__cmInstalled) return;
          window.__cmInstalled = true;
          window.__cmAutoAdvance = true;

          var CM_MIN_DELAY_MS = 800;
          var CM_MAX_DELAY_MS = 3000;
          var CM_SKIP_PROBABILITY = 1 / 12;

          function cmClickNext() {
            // No pinned chevron selector yet (§8.2/§12 M4) — the spec's own
            // documented fallback is the only mechanism here for now.
            // 'instant' (not 'smooth') so the before/after comparison below
            // is synchronous — an honest success signal instead of always
            // reporting true, since a stats event should mean the page
            // actually moved, not just that we asked it to.
            var before = window.scrollY;
            window.scrollBy({ top: window.innerHeight, left: 0, behavior: 'instant' });
            return window.scrollY !== before;
          }

          function cmNotifyAdvance() {
            try {
              window.webkit.messageHandlers.cm.postMessage({ event: 'advance', channel: '\(channelID)' });
            } catch (e) {
              // messageHandler not installed yet (or webkit bridge unavailable) — safe no-op.
            }
          }

          function advance() {
            if (!window.__cmAutoAdvance) return;
            if (Math.random() < CM_SKIP_PROBABILITY) return;
            var delay = CM_MIN_DELAY_MS + Math.random() * (CM_MAX_DELAY_MS - CM_MIN_DELAY_MS);
            setTimeout(function() {
              if (!window.__cmAutoAdvance) return;
              if (cmClickNext()) cmNotifyAdvance();
            }, delay);
          }

          setInterval(() => {
            if (!window.__cmAutoAdvance) return;
            const v = document.querySelector('video');
            if (!v) return;
            v.loop = false;
            if (!v.__cmHooked) { v.__cmHooked = true; v.addEventListener('ended', advance); }
            if (v.duration && isFinite(v.duration)) {
              if (v.currentTime > v.duration - 0.35 && !v.__cmFired) { v.__cmFired = true; advance(); }
              else if (v.currentTime < 1) { v.__cmFired = false; }
            }
          }, 500);
        })();
        """
    }
}
