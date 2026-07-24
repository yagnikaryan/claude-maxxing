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
        // All videos, not just the first — feed DOMs keep neighboring
        // (preloading) players around, and any of them can carry audio.
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause());")
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
          var CM_ADVANCE_COOLDOWN_MS = 2500;

          // The reel feed scrolls an inner container, not the document, so
          // window.scrollBy moves nothing and window.scrollY never changes —
          // the old advance reported failure forever and the feed sat still.
          // Walk up from the current video to whatever actually scrolls.
          function cmScrollable(el) {
            var node = el;
            while (node && node !== document.documentElement) {
              var style = getComputedStyle(node);
              if (/(auto|scroll|overlay)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 20) return node;
              node = node.parentElement;
            }
            var se = document.scrollingElement;
            if (se && se.scrollHeight > se.clientHeight + 20) return se;
            return null;
          }

          function cmDescribe(el) {
            if (!el) return 'none';
            var cls = (typeof el.className === 'string' && el.className.trim())
              ? '.' + el.className.trim().split(/\\s+/).slice(0, 2).join('.') : '';
            return el.tagName + (el.id ? '#' + el.id : '') + cls;
          }

          // The feed is virtualized: several <video> elements coexist, so
          // querySelector('video') returns whichever is first in the DOM, not
          // the one being watched. Everything below — ended detection,
          // pausing, and the advance check — has to follow the video nearest
          // the viewport's center instead, or it tracks an offscreen reel and
          // reports that nothing changed however far the feed scrolled.
          function cmCurrentVideo() {
            var vids = Array.prototype.slice.call(document.querySelectorAll('video'));
            if (!vids.length) return null;
            var mid = window.innerHeight / 2;
            var best = null, bestDist = Infinity;
            vids.forEach(function(v) {
              var r = v.getBoundingClientRect();
              if (r.height < 50) return;   // offscreen/collapsed preloads
              var d = Math.abs((r.top + r.bottom) / 2 - mid);
              if (d < bestDist) { bestDist = d; best = v; }
            });
            return best || vids[0];
          }

          // Identity of the reel on screen. Compared before/after an advance
          // so a stats event means the feed genuinely moved on, rather than
          // that we asked it to — the site may ignore or undo any single
          // mechanism below.
          function cmSnapshot() {
            var v = cmCurrentVideo();
            return (v && (v.currentSrc || v.src)) || location.href;
          }

          // Tried in order of directness; returns a label for the log so a
          // failing channel says which mechanisms it exhausted.
          function cmTryAdvance() {
            var v = cmCurrentVideo();
            var container = v ? cmScrollable(v) : null;
            if (container) {
              var before = container.scrollTop;
              container.scrollBy({ top: container.clientHeight, left: 0, behavior: 'instant' });
              if (Math.abs(container.scrollTop - before) > 1) return 'container ' + cmDescribe(container);
            }
            var wBefore = window.scrollY;
            window.scrollBy({ top: window.innerHeight, left: 0, behavior: 'instant' });
            if (Math.abs(window.scrollY - wBefore) > 1) return 'window';
            var target = v || document.body;
            ['keydown', 'keyup'].forEach(function(type) {
              target.dispatchEvent(new KeyboardEvent(type, {
                key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40, bubbles: true, cancelable: true
              }));
            });
            return 'arrowdown (container=' + cmDescribe(container) + ')';
          }

          function cmNotify(event, detail) {
            try {
              window.webkit.messageHandlers.cm.postMessage({ event: event, channel: '\(channelID)', detail: detail || '' });
            } catch (e) {
              // messageHandler not installed (or webkit bridge unavailable) — safe no-op.
            }
          }

          function advance() {
            if (!window.__cmAutoAdvance) return;
            // After a scroll the feed re-shuffles its <video> elements, and
            // the reel arriving at center may already be mid-playback near
            // its end — which re-triggers the completion check immediately
            // and skips a reel the user never saw. One advance per cooldown.
            var now = Date.now();
            if (window.__cmLastAdvanceAt && now - window.__cmLastAdvanceAt < CM_ADVANCE_COOLDOWN_MS) return;
            window.__cmLastAdvanceAt = now;
            if (Math.random() < CM_SKIP_PROBABILITY) return;
            var delay = CM_MIN_DELAY_MS + Math.random() * (CM_MAX_DELAY_MS - CM_MIN_DELAY_MS);
            setTimeout(function() {
              if (!window.__cmAutoAdvance) return;
              var before = cmSnapshot();
              var how = cmTryAdvance();
              // Confirm asynchronously: a container scroll settles
              // immediately, but a synthetic ArrowDown only lands once the
              // site's own handler runs.
              setTimeout(function() {
                if (cmSnapshot() !== before) cmNotify('advance', how);
                else cmNotify('advance-failed', how);
              }, 900);
            }, delay);
          }

          setInterval(() => {
            const v = cmCurrentVideo();
            if (!v) return;
            // __cmHidden: native sets this on window hide (and clears it on
            // show) — force-pause anything that starts while hidden, since a
            // one-shot pause() before hide can race a still-loading page.
            if (window.__cmHidden) { if (!v.paused) v.pause(); return; }
            if (!window.__cmAutoAdvance) return;
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
