import Foundation

/// The `/dashboard` page: a fully self-contained HTML document rendering the
/// stats event log, served by `HookServer` on the loopback socket it already
/// owns. Everything is computed client-side from the raw events embedded at
/// serve time — the server does no aggregation, so the page and `stats.jsonl`
/// can never disagree, and a browser refresh is a full data refresh.
///
/// Self-contained on purpose: no CDN scripts, no fonts, no external requests.
/// The stats never leave the machine (SPEC §9), and a dashboard that phones
/// out for a chart library would quietly break that promise the first time it
/// loaded.
enum StatsDashboard {

    /// Serializes `events` into the template. Events are end-stamped
    /// (`t` = episode end, `seconds` = duration) — the JS deals in that
    /// shape directly, splitting episodes across hour/day boundaries.
    static func html(events: [StatsEvent], channelNames: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let eventsJSON = (try? encoder.encode(events)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let namesJSON = (try? encoder.encode(channelNames)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return template
            .replacingOccurrences(of: "__CM_EVENTS__", with: eventsJSON)
            .replacingOccurrences(of: "__CM_CHANNEL_NAMES__", with: namesJSON)
    }

    /// Raw string so the CSS/JS inside needs no Swift escaping; the two
    /// placeholders above are the only dynamic parts.
    private static let template = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Maxx — Stats</title>
<style>
  /* Palette roles (validated: categorical slots 1–2 pass CVD + contrast in
     both modes; sequential = one blue ramp, light→dark). Text wears text
     tokens, never series color. */
  :root {
    color-scheme: light;
    --page: #f9f9f7; --surface: #fcfcfb;
    --ink: #0b0b0b; --ink-2: #52514e; --muted: #898781;
    --grid: #e1e0d9; --axis: #c3c2b7; --ring: rgba(11,11,11,0.10);
    --s1: #2a78d6; --s2: #eb6834;
    --seq-1:#cde2fb; --seq-2:#9ec5f4; --seq-3:#6da7ec; --seq-4:#3987e5;
    --seq-5:#256abf; --seq-6:#184f95; --seq-7:#0d366b;
  }
  @media (prefers-color-scheme: dark) {
    :root:where(:not([data-theme="light"])) {
      color-scheme: dark;
      --page: #0d0d0d; --surface: #1a1a19;
      --ink: #ffffff; --ink-2: #c3c2b7; --muted: #898781;
      --grid: #2c2c2a; --axis: #383835; --ring: rgba(255,255,255,0.10);
      --s1: #3987e5; --s2: #d95926;
      --seq-1:#0d366b; --seq-2:#104281; --seq-3:#184f95; --seq-4:#1c5cab;
      --seq-5:#256abf; --seq-6:#3987e5; --seq-7:#86b6ef;
    }
  }
  * { box-sizing: border-box; margin: 0; }
  body {
    background: var(--page); color: var(--ink);
    font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif;
    padding: 28px clamp(16px, 4vw, 48px) 48px;
  }
  header h1 { font-size: 17px; font-weight: 650; }
  header .sub { color: var(--muted); font-size: 12.5px; margin-top: 2px; }

  /* One filter row above everything it scopes. */
  .filters { display: flex; gap: 6px; margin: 18px 0 20px; flex-wrap: wrap; }
  .filters button {
    font: 600 12.5px system-ui, sans-serif; color: var(--ink-2);
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 7px; padding: 5px 12px; cursor: pointer;
  }
  .filters button[aria-pressed="true"] { color: var(--ink); border-color: var(--axis); }
  .filters button[aria-pressed="true"]::before { content: "✓ "; font-weight: 700; }

  .hero-card {
    background: var(--surface); border: 1px solid var(--ring);
    border-radius: 12px; padding: 20px 24px; margin-bottom: 14px;
    display: flex; align-items: baseline; gap: 18px; flex-wrap: wrap;
  }
  .hero-value { font-size: 52px; font-weight: 650; letter-spacing: -0.02em; }
  .hero-label { color: var(--ink-2); font-size: 13px; max-width: 340px; }

  .tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 14px; margin-bottom: 14px; }
  .tile { background: var(--surface); border: 1px solid var(--ring); border-radius: 12px; padding: 14px 16px; }
  .tile .label { color: var(--ink-2); font-size: 12.5px; }
  .tile .value { font-size: 26px; font-weight: 650; margin-top: 2px; }
  .tile .note { color: var(--muted); font-size: 11.5px; margin-top: 2px; }

  .cards { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
  @media (max-width: 760px) { .cards { grid-template-columns: 1fr; } }
  .card { background: var(--surface); border: 1px solid var(--ring); border-radius: 12px; padding: 16px 18px; min-width: 0; }
  .card.wide { grid-column: 1 / -1; }
  .card-head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 12px; gap: 8px; }
  .card-head h2 { font-size: 13.5px; font-weight: 650; }
  .card-head .toggle {
    font: 600 11.5px system-ui, sans-serif; color: var(--muted);
    background: none; border: 1px solid var(--ring); border-radius: 6px;
    padding: 2px 8px; cursor: pointer;
  }
  .subtitle { color: var(--muted); font-size: 11.5px; margin: -8px 0 10px; }
  .card-head .toggle[aria-pressed="true"].opt { color: var(--ink); border-color: var(--axis); }
  .legend { display: flex; gap: 14px; font-size: 12px; color: var(--ink-2); margin-bottom: 10px; }
  .legend .key { display: inline-flex; align-items: center; gap: 6px; }
  .legend .swatch { width: 10px; height: 10px; border-radius: 3px; display: inline-block; }

  table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
  th { text-align: left; color: var(--muted); font-weight: 600; padding: 4px 10px 4px 0; border-bottom: 1px solid var(--grid); }
  td { padding: 4px 10px 4px 0; border-bottom: 1px solid var(--grid); font-variant-numeric: tabular-nums; color: var(--ink-2); }
  td:first-child { color: var(--ink); }

  .empty { color: var(--muted); font-size: 13px; padding: 24px 0; }
  svg text { font: 11px system-ui, sans-serif; fill: var(--muted); }
  svg .val { fill: var(--ink-2); font-weight: 600; }

  #tooltip {
    position: fixed; pointer-events: none; z-index: 10; display: none;
    background: var(--ink); color: var(--page);
    font-size: 12px; line-height: 1.4; border-radius: 7px; padding: 6px 10px;
    max-width: 260px;
  }
  footer { color: var(--muted); font-size: 11.5px; margin-top: 22px; }
</style>
</head>
<body>
<header>
  <h1>Claude Maxx</h1>
  <div class="sub" id="asof"></div>
</header>

<div class="filters" id="filters" role="group" aria-label="Date range"></div>

<div class="hero-card">
  <div class="hero-value" id="hero">—</div>
  <div class="hero-label">minutes of content per minute of waiting — how much scroll each unit of dead time actually bought</div>
</div>

<div class="tiles" id="tiles"></div>

<div class="cards">
  <div class="card wide" id="card-heatmap"></div>
  <div class="card" id="card-daily"></div>
  <div class="card" id="card-channels"></div>
</div>

<div id="tooltip" role="status"></div>
<footer>Local only — served from 127.0.0.1, computed in this page from <code>stats.jsonl</code>. Refresh for latest.</footer>

<script>
"use strict";
const EVENTS = __CM_EVENTS__;
const CHANNEL_NAMES = __CM_CHANNEL_NAMES__;
const MS_H = 3600e3, MS_D = 86400e3;

// Episodes are end-stamped: t = end, seconds = duration.
const parsed = EVENTS.map(e => ({ ...e, end: new Date(e.t).getTime() }))
  .filter(e => isFinite(e.end))
  .map(e => ({ ...e, start: e.end - (e.seconds || 0) * 1000 }));

const RANGES = [["7d", 7], ["14d", 14], ["30d", 30], ["All", null]];
let rangeDays = 14;
const tableOpen = {};   // per-card chart⇄table state, survives re-render

function rangeBounds() {
  const end = Date.now();
  if (rangeDays === null) {
    const first = Math.min(...parsed.map(e => e.start), end);
    return [startOfDay(first), end];
  }
  return [startOfDay(end - (rangeDays - 1) * MS_D), end];
}
function startOfDay(ms) { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); }
function overlap(e, a, b) { return Math.max(0, Math.min(e.end, b) - Math.max(e.start, a)); }
function fmtMin(m) {
  if (m >= 90) return (m / 60).toFixed(m >= 600 ? 0 : 1) + "h";
  return Math.round(m) + "m";
}
function fmtDay(ms) { return new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" }); }
function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }

// ---- shared tooltip (enhances, never gates: tables carry every value) ----
const tip = document.getElementById("tooltip");
function bindTips(root) {
  root.querySelectorAll("[data-tip]").forEach(el => {
    el.addEventListener("mousemove", ev => {
      tip.innerHTML = el.dataset.tip;
      tip.style.display = "block";
      const w = tip.offsetWidth, h = tip.offsetHeight;
      tip.style.left = Math.min(ev.clientX + 12, innerWidth - w - 8) + "px";
      tip.style.top = (ev.clientY - h - 10 < 0 ? ev.clientY + 14 : ev.clientY - h - 10) + "px";
    });
    el.addEventListener("mouseleave", () => { tip.style.display = "none"; });
  });
}

function card(id, title, chartHTML, tableHTML, headExtra, subtitle) {
  const el = document.getElementById(id);
  const showTable = !!tableOpen[id];
  el.innerHTML =
    '<div class="card-head"><h2>' + title + '</h2><div style="display:flex;gap:6px">' + (headExtra || "") +
    '<button class="toggle" id="' + id + '-tbl" aria-pressed="' + showTable + '">' + (showTable ? "chart" : "table") + "</button></div></div>" +
    (subtitle ? '<div class="subtitle">' + subtitle + "</div>" : "") +
    (showTable ? tableHTML : chartHTML);
  el.querySelector("#" + id + "-tbl").onclick = () => { tableOpen[id] = !showTable; render(); };
  bindTips(el);
}

function render() {
  const [a, b] = rangeBounds();
  const inR = t => parsed.filter(e => e.type === t && e.end > a && e.start < b);
  const content = inR("content"), waits = inR("wait");
  const advances = parsed.filter(e => e.type === "advance" && e.end >= a && e.end <= b);
  const attention = parsed.filter(e => e.type === "attention" && e.end >= a && e.end <= b);

  const cMin = content.reduce((s, e) => s + overlap(e, a, b), 0) / 60000;
  const wMin = waits.reduce((s, e) => s + overlap(e, a, b), 0) / 60000;

  // filters
  document.getElementById("filters").innerHTML = RANGES.map(([label, d]) =>
    '<button aria-pressed="' + (d === rangeDays) + '" data-d="' + d + '">' + label + "</button>").join("");
  document.querySelectorAll("#filters button").forEach(btn => {
    btn.onclick = () => { rangeDays = btn.dataset.d === "null" ? null : +btn.dataset.d; render(); };
  });

  // hero + tiles
  document.getElementById("hero").textContent = wMin > 0.5 ? (cMin / wMin).toFixed(1) + "×" : "—";
  const tiles = [
    ["Content", fmtMin(cMin), content.length + " sessions"],
    ["Waiting", fmtMin(wMin), waits.length + " waits"],
    ["Videos completed", String(advances.length), "confirmed advances"],
    ["Interrupts", String(attention.length), "Claude needed input"],
  ];
  document.getElementById("tiles").innerHTML = tiles.map(t =>
    '<div class="tile"><div class="label">' + t[0] + '</div><div class="value">' + t[1] +
    '</div><div class="note">' + t[2] + "</div></div>").join("");

  renderHeatmap(content, a, b);
  renderDaily(content, waits, a, b);
  renderChannels(content, a, b);

  const n = parsed.length;
  document.getElementById("asof").textContent =
    n + " events · " + new Date().toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

// ---- heatmap: hour-of-day × day (or weekday rhythm), sequential ramp ----
// View options live in the card head next to the table toggle (they change
// how the same slice is *drawn*, like chart⇄table — the data filter row above
// stays the only thing that changes what data is in play):
//   days ⇄ rhythm — calendar columns, or all weeks folded into Mon–Sun to
//                   show the recurring weekly pattern once history grows
//   trim          — quiet hours collapse to slivers so a mostly-empty day
//                   doesn't spend 24 full rows saying "nothing"
const heatOpts = { mode: "days", trim: true };

function renderHeatmap(content, a, b) {
  const rhythm = heatOpts.mode === "rhythm";
  const days = [];
  for (let d = startOfDay(a); d < b; d += MS_D) days.push(d);
  const weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  const cols = rhythm ? weekdayNames.map((_, i) => i) : days;
  const colLabel = c => rhythm ? weekdayNames[c] : fmtDay(c);
  const keyFor = h => {
    const col = rhythm ? (new Date(h).getDay() + 6) % 7 : startOfDay(h);
    return col + "|" + new Date(h).getHours();
  };

  const grid = new Map(); // "col|hour" -> minutes
  let maxV = 0;
  content.forEach(e => {
    for (let h = Math.floor(e.start / MS_H) * MS_H; h < e.end; h += MS_H) {
      const m = overlap(e, Math.max(h, a), Math.min(h + MS_H, b)) / 60000;
      if (m <= 0) continue;
      const k = keyFor(h);
      const v = (grid.get(k) || 0) + m;
      grid.set(k, v);
      if (v > maxV) maxV = v;
    }
  });

  const opts =
    '<button class="toggle opt hm-mode" aria-pressed="' + !rhythm + '">by date</button>' +
    '<button class="toggle opt hm-mode" aria-pressed="' + rhythm + '">by weekday</button>' +
    '<button class="toggle opt hm-trim" aria-pressed="' + heatOpts.trim + '">hide empty hours</button>';

  if (!grid.size) {
    card("card-heatmap", "When content plays", '<div class="empty">No content in this range yet.</div>', "", opts);
    wireHeatOpts();
    return;
  }

  const hourTotal = h => cols.reduce((s, c) => s + (grid.get(c + "|" + h) || 0), 0);
  const hours = [...Array(24).keys()];
  const ramp = ["--seq-1","--seq-2","--seq-3","--seq-4","--seq-5","--seq-6","--seq-7"];
  const colorFor = v => v <= 0 ? null :
    "var(" + ramp[Math.min(ramp.length - 1, Math.floor((v / maxV) * ramp.length))] + ")";

  let html = '<div style="overflow-x:auto"><table style="border-collapse:separate;border-spacing:2px;width:100%;table-layout:fixed"><thead><tr><th style="width:44px"></th>' +
    cols.map(c => '<th style="border:none;font-weight:600;font-size:10.5px;padding:0 2px;text-align:center">' + colLabel(c) + "</th>").join("") +
    "</tr></thead><tbody>";
  hours.forEach(h => {
    // Trim: a quiet hour keeps its slot (time stays continuous, no hidden
    // gaps) but collapses to a sliver instead of a full labeled row.
    const quiet = heatOpts.trim && hourTotal(h) <= 0;
    const cellH = quiet ? 3 : 16;
    html += '<tr><td style="border:none;padding:0 6px 0 0;font-size:10.5px;color:var(--muted);text-align:right">' +
      (!quiet && h % 3 === 0 ? String(h).padStart(2, "0") + ":00" : "") + "</td>";
    cols.forEach(c => {
      const v = grid.get(c + "|" + h) || 0;
      const col = colorFor(v);
      const label = (rhythm ? colLabel(c) + "s" : colLabel(c)) + " · " + String(h).padStart(2, "0") + ":00–" +
        String((h + 1) % 24).padStart(2, "0") + ":00<br><b>" + (v > 0 ? Math.round(v) + " min" : "no content") + "</b>" +
        (rhythm ? " <span style=\'opacity:.7\'>across the range</span>" : "");
      html += '<td data-tip="' + esc(label) + '" style="border:none;min-width:22px;height:' + cellH + 'px;border-radius:3px;padding:0;background:' +
        (col || "var(--grid)") + (col ? "" : ";opacity:.45") + '"></td>';
    });
    html += "</tr>";
  });
  html += "</tbody></table></div>" +
    '<div class="legend" style="margin-top:10px"><span class="key">0m</span>' +
    ramp.map(r => '<span class="swatch" style="background:var(' + r + ')"></span>').join("") +
    '<span class="key">' + Math.round(maxV) + "m / hour</span></div>";

  const rows = [...grid.entries()].sort((x, y) => x[0].localeCompare(y[0], undefined, { numeric: true })).map(([k, v]) => {
    const [c, h] = k.split("|");
    return "<tr><td>" + colLabel(+c) + "</td><td>" + String(h).padStart(2, "0") + ":00</td><td>" + Math.round(v) + " min</td></tr>";
  }).join("");
  card("card-heatmap", "When content plays",
    html,
    "<table><thead><tr><th>" + (rhythm ? "Weekday" : "Day") + "</th><th>Hour</th><th>Content</th></tr></thead><tbody>" + rows + "</tbody></table>",
    opts);
  wireHeatOpts();
}

function wireHeatOpts() {
  const el = document.getElementById("card-heatmap");
  const [daysBtn, rhythmBtn] = el.querySelectorAll(".hm-mode");
  if (daysBtn) daysBtn.onclick = () => { heatOpts.mode = "days"; render(); };
  if (rhythmBtn) rhythmBtn.onclick = () => { heatOpts.mode = "rhythm"; render(); };
  const trimBtn = el.querySelector(".hm-trim");
  if (trimBtn) trimBtn.onclick = () => { heatOpts.trim = !heatOpts.trim; render(); };
}

// ---- daily: content vs wait minutes, grouped columns, one shared axis ----
function renderDaily(content, waits, a, b) {
  const days = [];
  for (let d = startOfDay(a); d < b; d += MS_D) days.push(d);
  const per = days.map(d => ({
    day: d,
    c: content.reduce((s, e) => s + overlap(e, d, d + MS_D), 0) / 60000,
    w: waits.reduce((s, e) => s + overlap(e, d, d + MS_D), 0) / 60000,
  }));
  const active = per.filter(p => p.c > 0 || p.w > 0);
  if (!active.length) { card("card-daily", "Content vs waiting, by day", '<div class="empty">Nothing in this range yet.</div>', ""); return; }

  const shown = per.length > 16 ? per.filter(p => p.c > 0 || p.w > 0) : per;
  const maxV = Math.max(...shown.map(p => Math.max(p.c, p.w)), 1);
  const W = 420, plotH = 150, axisB = 22, padT = 18, H = plotH + axisB + padT;
  const band = W / shown.length;
  const barW = Math.min(14, (band - 8) / 2);   // thin marks; 2px sibling gap

  let svg = '<svg viewBox="0 0 ' + W + " " + H + '" style="width:100%;height:auto" role="img" aria-label="Daily content and waiting minutes">';
  // hairline gridlines at clean steps
  const step = maxV > 120 ? 60 : maxV > 40 ? 30 : 10;
  for (let g = step; g <= maxV; g += step) {
    const y = padT + plotH - (g / maxV) * plotH;
    svg += '<line x1="0" y1="' + y + '" x2="' + W + '" y2="' + y + '" stroke="var(--grid)" stroke-width="1"/>' +
      '<text x="2" y="' + (y - 3) + '">' + g + "m</text>";
  }
  shown.forEach((p, i) => {
    const x0 = i * band + band / 2;
    [["c", "--s1", -1], ["w", "--s2", 1]].forEach(([k, col, side]) => {
      const v = p[k], h = (v / maxV) * plotH;
      const x = x0 + (side < 0 ? -barW - 1 : 1);
      const tipTxt = fmtDay(p.day) + "<br><b>" + fmtMin(p.c) + "</b> content · <b>" + fmtMin(p.w) + "</b> waiting";
      svg += '<g data-tip="' + esc(tipTxt) + '">' +
        '<rect x="' + (x0 - band / 2) + '" y="0" width="' + band + '" height="' + H + '" fill="transparent"/>' +
        (v > 0 ? '<path d="M' + x + " " + (padT + plotH) +
          " v" + -(Math.max(h - 4, 0)) + " q0,-4 4,-4 h" + (barW - 8) + " q4,0 4,4 v" + Math.max(h - 4, 0) + ' z" fill="var(' + col + ')"/>' : "") +
        "</g>";
    });
    // Label selectively: first, last, and evenly spaced in between — 14
    // consecutive date labels collide into an unreadable strip.
    const every = Math.max(1, Math.ceil(shown.length / 6));
    // The last day is always labeled; an every-Nth tick that lands right
    // beside it gets dropped so the two never collide.
    if ((i % every === 0 && shown.length - 1 - i >= every) || i === shown.length - 1) {
      svg += '<text x="' + x0 + '" y="' + (H - 6) + '" text-anchor="middle">' + fmtDay(p.day) + "</text>";
    }
  });
  svg += '<line x1="0" y1="' + (padT + plotH) + '" x2="' + W + '" y2="' + (padT + plotH) + '" stroke="var(--axis)" stroke-width="1"/></svg>';

  const legend = '<div class="legend">' +
    '<span class="key"><span class="swatch" style="background:var(--s1)"></span>Content</span>' +
    '<span class="key"><span class="swatch" style="background:var(--s2)"></span>Waiting</span></div>';
  const rows = shown.map(p => "<tr><td>" + fmtDay(p.day) + "</td><td>" + Math.round(p.c) + " min</td><td>" +
    Math.round(p.w) + " min</td><td>" + (p.w > 0.5 ? (p.c / p.w).toFixed(1) + "×" : "—") + "</td></tr>").join("");
  card("card-daily", "Content vs waiting, by day", legend + svg,
    "<table><thead><tr><th>Day</th><th>Content</th><th>Waiting</th><th>Ratio</th></tr></thead><tbody>" + rows + "</tbody></table>",
    "", "Waiting = a Claude prompt running · Content = the feed window open (pinned setup windows count too)");
}

// ---- channels: single series → one hue, value at the tip ----
function renderChannels(content, a, b) {
  const byCh = new Map();
  content.forEach(e => {
    const k = e.channel || "unknown";
    byCh.set(k, (byCh.get(k) || 0) + overlap(e, a, b) / 60000);
  });
  const rows = [...byCh.entries()].filter(([, v]) => v >= 0.5).sort((x, y) => y[1] - x[1]);
  if (!rows.length) { card("card-channels", "Where the time went", '<div class="empty">Nothing in this range yet.</div>', ""); return; }

  const maxV = rows[0][1];
  const name = id => CHANNEL_NAMES[id] || id;
  let html = '<div role="img" aria-label="Content minutes by channel">';
  rows.forEach(([id, v]) => {
    const pct = Math.max((v / maxV) * 100, 1.5);
    html += '<div data-tip="' + esc(name(id) + "<br><b>" + fmtMin(v) + "</b>") + '" style="display:flex;align-items:center;gap:10px;margin:8px 0;min-height:24px">' +
      '<span style="flex:0 0 64px;font-size:12px;color:var(--ink-2)">' + esc(name(id)) + "</span>" +
      '<span style="flex:1;display:flex;align-items:center;gap:8px">' +
      '<span style="width:' + pct + '%;height:16px;background:var(--s1);border-radius:0 4px 4px 0"></span>' +
      '<span style="font-size:12px;font-weight:600;color:var(--ink-2)">' + fmtMin(v) + "</span></span></div>";
  });
  html += "</div>";
  const total = rows.reduce((s, r) => s + r[1], 0);
  const trows = rows.map(([id, v]) => "<tr><td>" + esc(name(id)) + "</td><td>" + Math.round(v) + " min</td><td>" +
    Math.round((v / total) * 100) + "%</td></tr>").join("");
  card("card-channels", "Where the time went", html,
    "<table><thead><tr><th>Channel</th><th>Content</th><th>Share</th></tr></thead><tbody>" + trows + "</tbody></table>");
}

render();
</script>
</body>
</html>
"""#
}
