/// The `/attention` overlay for the reading-shaped channels (§8.4). X and
/// Reading each carried their own near-identical copy of this DOM building.
///
/// Deliberately never calls `scrollTo`/`scrollIntoView` — §8.4: yanking text
/// mid-sentence is hostile. That is the one rule this file exists to keep in
/// a single place.
enum AttentionBanner {
    /// Idempotent (checks its own id), so repeated `/attention` against the
    /// same page doesn't stack banners. Evaluated on demand rather than
    /// installed at document-end: nothing else needs to be resident, and one
    /// mechanism is easier to reason about than two.
    static func showScript(accent: String) -> String {
        """
        (function() {
          var id = '__cm-attention-banner';
          if (document.getElementById(id)) return;
          var bar = document.createElement('div');
          bar.id = id;
          bar.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:2147483647;' +
            'display:flex;align-items:center;justify-content:space-between;' +
            'background:\(accent);color:#fff;padding:8px 12px;' +
            'font:600 13px -apple-system,BlinkMacSystemFont,sans-serif;' +
            'box-shadow:0 2px 6px rgba(0,0,0,.25);';
          var label = document.createElement('span');
          label.textContent = 'Claude needs input';
          var dismiss = document.createElement('button');
          dismiss.textContent = 'Dismiss';
          dismiss.setAttribute('aria-label', 'Dismiss');
          dismiss.style.cssText = 'margin-left:12px;background:rgba(255,255,255,.2);color:#fff;' +
            'border:none;border-radius:4px;padding:4px 10px;cursor:pointer;' +
            'font:600 12px -apple-system,BlinkMacSystemFont,sans-serif;';
          dismiss.onclick = function() { bar.remove(); };
          bar.appendChild(label);
          bar.appendChild(dismiss);
          document.documentElement.appendChild(bar);
        })();
        """
    }
}
