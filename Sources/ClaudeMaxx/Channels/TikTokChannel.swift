import AppKit
import WebKit

/// Layer 3 channel adapter for TikTok's For You feed (SPEC §8.1/§8.2, M4).
///
/// URL confirmed working logged-out (verified against the live site while
/// building this channel). `advance()` is deliberately scroll-only, same
/// reasoning as `ReelsChannel`: the real next-chevron selector must come
/// from inspecting the live desktop DOM, not a guess, and an attempt to
/// find it during this build hit a narrow-viewport/no-accessible-name
/// variant of the page that never exposed one — so this ships with the
/// spec's own documented `scrollBy(innerHeight)` fallback (§8.2) as the
/// only advance mechanism for now. Swap `cmClickNext` for a real chevron
/// click once someone pins the live selector on a normal desktop-width,
/// logged-in session (§12 M4).
final class TikTokChannel: ContentChannel {
    let id = "tiktok"
    let displayName = "TikTok"
    let url = URL(string: "https://www.tiktok.com/foryou")!
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

    /// Same watch-complete detection as `ShortsChannel`/`ReelsChannel`; see
    /// the type-level doc comment for why `cmClickNext` is scroll-only.
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
