import Foundation

/// The shared auto-advance script for the vertical scroll feeds (Reels,
/// TikTok). Both sites present the same shape — one full-viewport video at a
/// time inside a virtualized scroller — and their adapters previously carried
/// byte-identical copies of this source. That duplication is what let a round
/// of scroll fixes land on Reels while TikTok silently kept the old broken
/// behavior, so the source lives here once and each channel passes its id.
///
/// A channel that later needs genuinely site-specific advancing (a real
/// next-chevron selector, say) should stop calling this rather than grow
/// conditionals inside it.
enum ScrollFeedScript {

    /// `channelID` is interpolated into the `cm` bridge messages so the
    /// native log can attribute an advance (or a failure) to a channel.
    static func source(channelID: String) -> String {
        """
        (function() {
          if (window.__cmInstalled) return;
          window.__cmInstalled = true;
          window.__cmAutoAdvance = true;

          var CM_MIN_DELAY_MS = 800;
          var CM_MAX_DELAY_MS = 3000;
          var CM_SKIP_PROBABILITY = 1 / 12;
          var CM_ADVANCE_COOLDOWN_MS = 2500;
          var CM_HEARTBEAT_MS = 30000;

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

          // The feed is virtualized: several <video> elements coexist, so
          // querySelector('video') returns whichever is first in the DOM, not
          // the one being watched. Everything below — ended detection,
          // pausing, and the advance check — has to follow the video nearest
          // the viewport's center instead, or it tracks an offscreen item and
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

          // Identity of the item on screen. Compared before/after an advance
          // so a stats event means the feed genuinely moved on, rather than
          // that we asked it to — the site may ignore or undo any single
          // mechanism below.
          function cmSnapshot() {
            var v = cmCurrentVideo();
            return (v && (v.currentSrc || v.src)) || location.href;
          }

          // The feed item holding this video: the ancestor that is a direct
          // child of the scroller, i.e. the thing one "reel" of scrolling is
          // supposed to move by.
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

          // These feeds set `scroll-snap-type: y mandatory` with items aligned
          // to `start`, so the browser pins each item's top edge to the top of
          // the scroller. With an item shorter than the viewport that leaves
          // all the slack at the bottom and the reel rides high; worse, any
          // scroll of ours that lands between snap points gets yanked to the
          // nearest one, so correcting the position by scrolling alone just
          // fights the browser.
          //
          // Re-aligning the snap points themselves is the fix: the browser
          // then centers each item natively, and our advance agrees with it
          // instead of competing. Items taller than the viewport keep `start`
          // — centering those would clip the top, which is the very thing this
          // is meant to prevent, and clipping the bottom is the lesser evil.
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
            // Changing where the snap points *are* doesn't move the page: a
            // freshly loaded feed keeps the scroll offset the site chose under
            // its own top-alignment, so the first reel rides high until
            // something scrolls. Correct once per page, after layout settles.
            // Deliberately not repeated for later items — the browser snaps
            // those into place on its own now, and re-running would yank the
            // page while the user is scrolling by hand.
            if (!window.__cmAlignedOnce) {
              window.__cmAlignedOnce = true;
              setTimeout(function() {
                if (window.__cmHidden) return;
                var off = cmRecenter();
                if (Math.abs(off) > 2) cmNotify('align', 'recentered ' + Math.round(off) + 'px');
              }, 600);
            }
          }

          // Nudge whatever is on screen back to centered. Scrolling by the
          // container's height assumes an item is exactly one viewport tall;
          // it is not, so each advance left the reel a little further off and
          // the top edge ended up cut. Called only right after our own
          // advance — never on a timer, which would fight the user's own
          // scrolling.
          // Where an item *should* sit: centered when it fits, top-aligned
          // when it is taller than the viewport. Same rule as cmAlignItems, so
          // scrolling and snapping never disagree about the target.
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

          // Tried in order of directness; returns a label for the log so a
          // failing channel says which mechanisms it exhausted. Prefers moving
          // to the *next item* and centering it, rather than scrolling a fixed
          // distance and hoping it lines up with a snap point.
          function cmTryAdvance() {
            var v = cmCurrentVideo();
            var container = v ? cmScrollable(v) : null;
            if (container) {
              var item = cmItemFor(v, container);
              var next = item && item.nextElementSibling;
              if (next) {
                // Must use the same rule as cmAlignItems/cmRecenter. Centering
                // an item taller than the viewport contradicts its `start`
                // snap alignment, and the correction afterwards scrolled a
                // full viewport back — undoing the advance entirely, which
                // showed up as advance-failed in a short window.
                var delta = cmDesiredOffset(next, container);
                var beforeNext = container.scrollTop;
                cmScrollByPx(container, delta);
                if (Math.abs(container.scrollTop - beforeNext) > 1) {
                  var vp = cmViewport(container);
                  var fits = next.getBoundingClientRect().height <= (vp.bottom - vp.top);
                  return 'next-item ' + (fits ? 'centered' : 'top-aligned');
                }
              }
              // No next sibling rendered yet (virtualized list) — fall back to
              // a viewport-sized scroll, which cmRecenter then tidies up.
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
            // the item arriving at center may already be mid-playback near
            // its end — which re-triggers the completion check immediately
            // and skips an item the user never saw. One advance per cooldown.
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
                // Correct after the feed has settled (lazy-loaded media and
                // scroll-snap both change an item's box after the scroll), and
                // report the correction so drift is visible in the log rather
                // than only on screen.
                var off = cmRecenter();
                var drift = Math.abs(off) > 2 ? ' recentered ' + Math.round(off) + 'px' : '';
                if (cmSnapshot() !== before) cmNotify('advance', how + drift);
                else cmNotify('advance-failed', how + drift);
              }, 900);
            }, delay);
          }

          // A feed that never starts playing never ends, so the
          // watch-complete check never runs and the channel simply sits
          // there. Nudge a paused video back into playback and report the
          // rejection if the site or WebKit refuses — `play()` rejects with a
          // named error, which is the only way to tell an autoplay block from
          // a site that paused itself.
          //
          // Bounded, and reset per item: a user who deliberately pauses gets
          // to keep it paused after a few attempts rather than fighting us.
          function cmEnsurePlaying(v) {
            var src = v.currentSrc || v.src || '';
            if (window.__cmPlaySrc !== src) { window.__cmPlaySrc = src; window.__cmPlayTries = 0; }
            if (!v.paused) return;
            if ((window.__cmPlayTries || 0) >= 3) return;
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
            if (window.__cmLastAdvanceAt && now - window.__cmLastAdvanceAt < CM_HEARTBEAT_MS * 2) return;
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
              if (v.currentTime > v.duration - 0.35 && !v.__cmFired) { v.__cmFired = true; advance(); }
              else if (v.currentTime < 1) { v.__cmFired = false; }
            }
          }, 500);
        })();
        """
    }
}
