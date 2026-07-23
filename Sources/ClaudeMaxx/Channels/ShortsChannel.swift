import AppKit
import WebKit

/// Layer 3 channel adapter for YouTube Shorts (SPEC §8.1/§8.2). Highest DOM
/// stability of the three video platforms, so it's the first channel built
/// (§15 decision #10) and the reference implementation the Reels/TikTok
/// adapters will mirror in M4.
final class ShortsChannel: ContentChannel {
    let id = "shorts"
    let displayName = "Shorts"
    let url = URL(string: "https://www.youtube.com/shorts/")!
    let preferredAspect = NSSize(width: 9, height: 16)
    let supportsAutoAdvance = true

    /// Injected at `.atDocumentEnd` (SPEC §8.1). Implements the watch-complete
    /// auto-advance pattern from §8.2: a 500 ms poll re-acquires the active
    /// `<video>` element (YouTube's SPA recycles player nodes on scroll),
    /// hooks `ended` (after forcing `loop = false` so it actually fires),
    /// with a currentTime-based fallback for players that re-loop before
    /// `ended` dispatches. All `window.__cm*` globals are namespaced per
    /// the repo-wide convention so multiple channel scripts can never clash.
    ///
    /// `advance()` applies the required timing jitter (§8.2 "Timing jitter"):
    /// skip entirely with ~1/12 probability, else fire the click after a
    /// uniform random 0.8–3.0 s delay — never synchronously on `ended`, since
    /// a metronome-perfect click is the one remaining machine-legible
    /// signature once synthetic input is off the table. A successful click
    /// is reported through the `cm` WKScriptMessageHandler so the native side
    /// can append a StatsStore `advance` event (§9.2); the `try/catch` around
    /// the postMessage call makes the script safe to run before that handler
    /// is registered.
    func userScript() -> WKUserScript {
        let source = """
        (function() {
          if (window.__cmInstalled) return;
          window.__cmInstalled = true;
          window.__cmAutoAdvance = true;              // native toggles this flag

          var CM_MIN_DELAY_MS = 800;
          var CM_MAX_DELAY_MS = 3000;
          var CM_SKIP_PROBABILITY = 1 / 12;

          function cmClickNext() {
            var primary = document.querySelector('#navigation-button-down button');
            if (primary) { primary.click(); return true; }
            var fallback = document.querySelector('button[aria-label="Next video"]');
            if (fallback) { fallback.click(); return true; }
            return false;
          }

          function cmNotifyAdvance() {
            try {
              window.webkit.messageHandlers.cm.postMessage({ event: 'advance', channel: 'shorts' });
            } catch (e) {
              // messageHandler not installed yet (or webkit bridge unavailable) — safe no-op.
            }
          }

          function advance() {
            if (!window.__cmAutoAdvance) return;
            if (Math.random() < CM_SKIP_PROBABILITY) return;   // let it sit; not every completion advances
            var delay = CM_MIN_DELAY_MS + Math.random() * (CM_MAX_DELAY_MS - CM_MIN_DELAY_MS);
            setTimeout(function() {
              if (!window.__cmAutoAdvance) return;              // re-check: flag may have flipped during the delay
              if (cmClickNext()) cmNotifyAdvance();
            }, delay);
          }

          setInterval(() => {
            if (!window.__cmAutoAdvance) return;
            const v = document.querySelector('video');  // active video is first/only match
            if (!v) return;
            v.loop = false;                             // make `ended` fire
            if (!v.__cmHooked) { v.__cmHooked = true; v.addEventListener('ended', advance); }
            // Fallback: players that re-loop programmatically before `ended`
            if (v.duration && isFinite(v.duration)) {
              if (v.currentTime > v.duration - 0.35 && !v.__cmFired) { v.__cmFired = true; advance(); }
              else if (v.currentTime < 1) { v.__cmFired = false; }
            }
          }, 500);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Native-side flag flip (§8.2) — no reload, so pause→show on the same
    /// channel keeps the live feed position.
    func setAutoAdvance(_ on: Bool, in webView: WKWebView) {
        webView.evaluateJavaScript("window.__cmAutoAdvance = \(on);")
    }

    /// Called before hide, and reused by `attention(in:)` (§8.4's "video
    /// channels pause playback" interrupt) — same polite action either way.
    func pause(in webView: WKWebView) {
        webView.evaluateJavaScript("document.querySelector('video')?.pause();")
    }

    /// §8.4: video channels' channel-specific `/attention` behavior is to
    /// pause playback; the unconditional `.criticalRequest` bounce is
    /// FeedPanel's responsibility, not this channel's.
    func attention(in webView: WKWebView) {
        pause(in: webView)
    }
}
