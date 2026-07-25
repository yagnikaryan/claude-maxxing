import Foundation

/// Shared auto-advance for the vertical scroll feeds (Reels, TikTok): one
/// full-viewport video at a time inside a virtualized scroller. Lives here once
/// because byte-identical copies in each adapter let a round of scroll fixes land
/// on Reels while TikTok silently kept the old behavior.
///
/// A channel needing genuinely site-specific advancing should stop calling this
/// rather than grow conditionals inside it.
enum ScrollFeedScript {

    /// `channelID` is interpolated into the `cm` messages so the log can attribute
    /// an advance to a channel.
    ///
    /// `nextSelectors` are the site's own "next" controls, tried before scrolling.
    /// A site that ships one (Shorts) should use it — clicking the real control
    /// moves exactly one item. Where it would be a guess (Reels, TikTok), pass none
    /// and scroll.
    static func source(channelID: String, nextSelectors: [String] = []) -> String {
        let selectorList = "[" + nextSelectors.map { "'\($0)'" }.joined(separator: ", ") + "]"
        return """
        (function() {
          if (window.__cmInstalled) return;
          window.__cmInstalled = true;
          window.__cmAutoAdvance = true;

          var CM_MIN_DELAY_MS = 800;
          var CM_MAX_DELAY_MS = 3000;
          var CM_SKIP_PROBABILITY = 1 / 12;
          var CM_ADVANCE_COOLDOWN_MS = 2500;
          var CM_HEARTBEAT_MS = 30000;
          var CM_STUCK_RETRY_MS = 15000;
          var CM_NEXT_SELECTORS = \(selectorList);

          // These feeds scroll an inner container, not the document, so
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

          // Virtualized feed: several <video>s coexist, so querySelector('video')
          // returns the first in the DOM, not the one being watched. Track the one
          // nearest the viewport centre or everything below follows an offscreen
          // item and reports nothing changed however far the feed scrolled.
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

          // Compared before/after an advance, so a stats event means the feed
          // genuinely moved rather than that we asked it to — the site may ignore
          // or undo any single mechanism below.
          function cmSnapshot() {
            var v = cmCurrentVideo();
            return (v && (v.currentSrc || v.src)) || location.href;
          }

          // The ancestor that is a direct child of the scroller — the thing one
          // "reel" of scrolling moves by.
          function cmItemFor(v, container) {
            if (!v || !container) return null;
            var node = v;
            var root = (container === document.scrollingElement || container === document.documentElement)
              ? document.body : container;
            while (node && node.parentElement && node.parentElement !== root) node = node.parentElement;
            return (node && node.parentElement === root) ? node : null;
          }

          // The viewport an item should be centered in — the scroller's own
          // box, or the window when the document is what scrolls.
          function cmViewport(container) {
            if (!container || container === document.scrollingElement || container === document.documentElement) {
              return { top: 0, bottom: window.innerHeight };
            }
            var r = container.getBoundingClientRect();
            return { top: r.top, bottom: r.bottom };
          }

          // How far `el` sits from centered, in pixels (positive = too low).
          function cmCenterOffset(el, container) {
            var r = el.getBoundingClientRect();
            var vp = cmViewport(container);
            return ((r.top + r.bottom) / 2) - ((vp.top + vp.bottom) / 2);
          }

          function cmScrollByPx(container, delta) {
            if (!container || container === document.scrollingElement || container === document.documentElement) {
              window.scrollBy({ top: delta, left: 0, behavior: 'instant' });
            } else {
              container.scrollBy({ top: delta, left: 0, behavior: 'instant' });
            }
          }

          // These feeds use `scroll-snap-type: y mandatory` with items aligned to
          // `start`, so a short item leaves its slack at the bottom and rides high,
          // and any scroll of ours landing between snap points gets yanked back —
          // correcting by scrolling alone just fights the browser. Moving the snap
          // points instead makes the browser centre each item natively. Items
          // taller than the viewport keep `start`; centring those would clip the
          // top, and clipping the bottom is the lesser evil.
          function cmAlignItems(container) {
            if (!container) return;
            var vp = cmViewport(container);
            var vpH = vp.bottom - vp.top;
            if (vpH <= 0) return;
            var kids = container.children;
            for (var i = 0; i < kids.length; i++) {
              var k = kids[i];
              var h = k.getBoundingClientRect().height;
              if (!h) continue;
              var want = h <= vpH ? 'center' : 'start';
              if (k.style.scrollSnapAlign !== want) k.style.scrollSnapAlign = want;
            }
            // Moving the snap points doesn't move the page, so the first reel still
            // rides high at the offset the site chose. Correct it once, after layout
            // settles — the browser handles later items, and re-running would yank
            // the page while the user scrolls by hand.
            if (!window.__cmAlignedOnce) {
              window.__cmAlignedOnce = true;
              setTimeout(function() {
                if (window.__cmHidden) return;
                var off = cmRecenter();
                if (Math.abs(off) > 2) cmNotify('align', 'recentered ' + Math.round(off) + 'px');
              }, 600);
            }
          }

          // Scrolling by the container's height assumes an item is exactly one
          // viewport tall; it isn't, so each advance drifted further off until the
          // top edge was cut. Called only right after our own advance — on a timer
          // it would fight the user's scrolling. The target follows the same rule as
          // cmAlignItems, so scrolling and snapping never disagree.
          function cmDesiredOffset(item, container) {
            var vp = cmViewport(container);
            var vpH = vp.bottom - vp.top;
            var r = item.getBoundingClientRect();
            if (r.height > vpH) return r.top - vp.top;   // never clip the top
            return cmCenterOffset(item, container);
          }

          function cmRecenter() {
            var v = cmCurrentVideo();
            var container = v ? cmScrollable(v) : null;
            var item = cmItemFor(v, container) || v;
            if (!item || !container) return 0;
            var off = cmDesiredOffset(item, container);
            if (Math.abs(off) > 2) cmScrollByPx(container, off);
            return off;
          }

          // Every way we know to move the feed on, most site-native first; each
          // returns false when inapplicable so the caller falls through. All are
          // verified afterwards, because "the button exists" is not "the feed
          // moved" — YouTube's chevron clicks cleanly and does nothing, which the
          // old Shorts script reported as a successful advance.
          function cmMechanisms() {
            var v = cmCurrentVideo();
            var container = v ? cmScrollable(v) : null;
            var list = [];

            CM_NEXT_SELECTORS.forEach(function(sel) {
              list.push({ name: 'next-button', run: function() {
                var btn = document.querySelector(sel);
                if (!btn) return false;
                btn.click();
                return true;
              }});
            });

            list.push({ name: 'next-item', run: function() {
              if (!container) return false;
              var item = cmItemFor(v, container);
              var next = item && item.nextElementSibling;
              if (!next) return false;
              // Same rule as cmAlignItems/cmRecenter: centring a too-tall item
              // contradicts its `start` snap, and the correction then scrolled a
              // whole viewport back, undoing the advance.
              var beforeTop = container.scrollTop;
              cmScrollByPx(container, cmDesiredOffset(next, container));
              return Math.abs(container.scrollTop - beforeTop) > 1;
            }});

            list.push({ name: 'container', run: function() {
              if (!container) return false;
              var beforeTop = container.scrollTop;
              container.scrollBy({ top: container.clientHeight, left: 0, behavior: 'instant' });
              return Math.abs(container.scrollTop - beforeTop) > 1;
            }});

            list.push({ name: 'window', run: function() {
              var beforeY = window.scrollY;
              window.scrollBy({ top: window.innerHeight, left: 0, behavior: 'instant' });
              return Math.abs(window.scrollY - beforeY) > 1;
            }});

            list.push({ name: 'arrowdown', run: function() {
              var target = v || document.body;
              ['keydown', 'keyup'].forEach(function(type) {
                target.dispatchEvent(new KeyboardEvent(type, {
                  key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40, bubbles: true, cancelable: true
                }));
              });
              return true;   // fire-and-hope: only the confirm below can judge it
            }});

            return list;
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
            // The item arriving at centre after a scroll may already be near its
            // end, re-triggering completion and skipping an item the user never
            // saw. One advance per cooldown.
            var now = Date.now();
            if (window.__cmLastAdvanceAt && now - window.__cmLastAdvanceAt < CM_ADVANCE_COOLDOWN_MS) return;
            window.__cmLastAdvanceAt = now;
            if (Math.random() < CM_SKIP_PROBABILITY) return;
            var delay = CM_MIN_DELAY_MS + Math.random() * (CM_MAX_DELAY_MS - CM_MIN_DELAY_MS);
            setTimeout(function() {
              if (!window.__cmAutoAdvance) return;
              var before = cmSnapshot();
              var mechs = cmMechanisms();

              // Confirmation is what makes falling through possible: a mechanism
              // that runs without error still has to be checked.
              function attempt(i) {
                if (i >= mechs.length) {
                  cmNotify('advance-failed', 'exhausted all ' + mechs.length + ' mechanisms');
                  return;
                }
                var m = mechs[i];
                var ran = false;
                try { ran = m.run(); } catch (e) { cmNotify('error', m.name + ': ' + (e && e.message ? e.message : e)); }
                if (!ran) { attempt(i + 1); return; }

                // Two checks: a scroll settles at once, but an SPA (YouTube)
                // animates and reattaches its player, routinely taking over a
                // second. A single early check called a working advance a failure.
                function confirm(waitMs, isLast) {
                  setTimeout(function() {
                    try {
                    // After the feed settles: lazy media and scroll-snap both change
                    // an item's box. Reported so drift shows in the log, not only
                    // on screen.
                    var off = cmRecenter();
                    var drift = Math.abs(off) > 2 ? ' recentered ' + Math.round(off) + 'px' : '';
                    if (cmSnapshot() !== before) {
                      window.__cmLastAdvanceOkAt = Date.now();
                      cmNotify('advance', m.name + (isLast ? ' (slow)' : '') + drift);
                    } else if (isLast) {
                      attempt(i + 1);
                    } else {
                      confirm(1600, true);
                    }
                    } catch (e) { cmNotify('error', 'confirm: ' + (e && e.message ? e.message : e)); }
                  }, waitMs);
                }
                confirm(900, false);
              }
              attempt(0);
            }, delay);
          }

          // A feed that never starts never ends, so the watch-complete check never
          // runs and the channel just sits there. `play()`'s rejection is reported
          // because its named error is the only way to tell an autoplay block from
          // a site that paused itself. Bounded and reset per item, so a user who
          // deliberately pauses gets to keep it paused.
          function cmEnsurePlaying(v) {
            var src = v.currentSrc || v.src || '';
            if (window.__cmPlaySrc !== src) { window.__cmPlaySrc = src; window.__cmPlayTries = 0; }
            if (!v.paused) return;
            // An item still at zero never started — that is the site or WebKit
            // refusing autoplay, not the user pausing, so keep trying. Once it
            // has actually played, a pause is the user's and three nudges is
            // already generous. Spaced out either way: play() rejects with
            // AbortError when called again while the previous one is settling.
            var neverStarted = (v.currentTime || 0) < 0.5;
            var limit = neverStarted ? 15 : 3;
            var now = Date.now();
            if (now - (window.__cmPlayTriedAt || 0) < 2000) return;
            if ((window.__cmPlayTries || 0) >= limit) return;
            window.__cmPlayTriedAt = now;
            window.__cmPlayTries = (window.__cmPlayTries || 0) + 1;
            try {
              var p = v.play();
              if (p && p.catch) {
                p.catch(function(e) {
                  cmNotify('play-blocked', (e && e.name ? e.name : 'Error') + ': ' + (e && e.message ? e.message : '')
                    + ' | visibility=' + document.visibilityState + ' focus=' + document.hasFocus());
                });
              }
            } catch (e) {
              cmNotify('play-blocked', 'threw ' + (e && e.message ? e.message : ''));
            }
          }

          // A channel that never advances otherwise says nothing at all —
          // no 'advance', no 'advance-failed', because the completion check
          // itself never runs. Report why while idle: whether a video was
          // found, whether it is playing, and how far in it is. Only while
          // auto-advance is armed and the window is up, so a hidden or
          // disabled channel stays quiet.
          function cmHeartbeat(v) {
            var now = Date.now();
            // A channel that is advancing is self-evidently healthy, and its
            // advances already say so — only report while apparently stuck.
            // Keyed on the last *successful* advance, not the last attempt: a
            // channel retrying and failing every few seconds would otherwise
            // suppress its own heartbeat forever and go completely silent,
            // which is precisely when its diagnostics are wanted.
            if (window.__cmLastAdvanceOkAt && now - window.__cmLastAdvanceOkAt < CM_HEARTBEAT_MS * 2) return;
            if (window.__cmLastBeatAt && now - window.__cmLastBeatAt < CM_HEARTBEAT_MS) return;
            window.__cmLastBeatAt = now;
            var all = document.querySelectorAll('video').length;
            if (!v) { cmNotify('idle', 'no video (' + all + ' in DOM)'); return; }
            // Centering offset in the same breath as playback state: without
            // it, "is the reel cut off at the top?" can only be answered by
            // looking at the screen, and only right after an advance.
            var container = cmScrollable(v);
            var item = cmItemFor(v, container) || v;
            // Deviation from where the item *should* be, not from center, so
            // 0 means correct for both centered and top-aligned items.
            var off = container ? Math.round(cmDesiredOffset(item, container)) : 0;
            cmNotify('idle', all + ' videos, current ' + (v.paused ? 'paused' : 'playing')
              + ' t=' + (v.currentTime || 0).toFixed(1) + '/' + (isFinite(v.duration) ? v.duration.toFixed(1) : '?')
              + ' off=' + (off > 0 ? '+' : '') + off + 'px');
          }

          // Resizing the window (or moving it to a display that forces a
          // re-clamp) changes the viewport height, which changes both where an
          // item should sit and whether it still fits at all. The 500ms poll
          // re-applies snap alignment on its own, but the *scroll position*
          // stays where it was, leaving the reel off-center until the next
          // advance. Correct it here instead, debounced so a live drag-resize
          // settles once rather than fighting the pointer.
          window.addEventListener('resize', function() {
            clearTimeout(window.__cmResizeTimer);
            window.__cmResizeTimer = setTimeout(function() {
              if (window.__cmHidden) return;
              var v = cmCurrentVideo();
              var container = v ? cmScrollable(v) : null;
              cmAlignItems(container);
              var off = cmRecenter();
              if (Math.abs(off) > 2) cmNotify('resize', 'recentered ' + Math.round(off) + 'px');
            }, 250);
          });

          setInterval(() => {
            try {
            const v = cmCurrentVideo();
            if (!window.__cmHidden && window.__cmAutoAdvance) cmHeartbeat(v);
            if (!v) return;
            if (!window.__cmHidden && window.__cmAutoAdvance) cmEnsurePlaying(v);
            // Cheap and idempotent: the feed is virtualized, so items arriving
            // during scroll need the same alignment as the ones already here.
            if (!window.__cmHidden) cmAlignItems(cmScrollable(v));
            // __cmHidden: native sets this on window hide (and clears it on
            // show) — force-pause anything that starts while hidden, since a
            // one-shot pause() before hide can race a still-loading page.
            if (window.__cmHidden) { if (!v.paused) v.pause(); return; }
            if (!window.__cmAutoAdvance) return;
            v.loop = false;
            if (!v.__cmHooked) { v.__cmHooked = true; v.addEventListener('ended', advance); }
            if (v.duration && isFinite(v.duration)) {
              var atEnd = v.currentTime > v.duration - 0.35;
              if (atEnd && !v.__cmFired) { v.__cmFired = true; advance(); }
              else if (v.currentTime < 1) { v.__cmFired = false; }
              // If every mechanism failed, the item sits at its last frame and
              // __cmFired keeps it there forever — the channel dies silently
              // (observed on Shorts: t=59.0/59.0 for minutes). Re-arm after a
              // while so it keeps trying; the site may just have been mid-
              // transition, and a stalled feed is worse than a retry.
              else if (atEnd && v.__cmFired
                       && Date.now() - (window.__cmLastAdvanceAt || 0) > CM_STUCK_RETRY_MS) {
                v.__cmFired = false;
              }
            }
            } catch (e) {
              // A throw here would otherwise kill every tick in silence, which
              // looks exactly like a healthy idle channel.
              if (!window.__cmErrAt || Date.now() - window.__cmErrAt > 10000) {
                window.__cmErrAt = Date.now();
                cmNotify('error', 'poll: ' + (e && e.message ? e.message : e));
              }
            }
          }, 500);
        })();
        """
    }
}
