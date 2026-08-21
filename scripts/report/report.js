const B = D.buckets, S = D.series, N = B.length;
const NS = "http://www.w3.org/2000/svg";
const VOID = new Set(D.voids);
const RESET = new Set(D.resetMinutes);

const el = (n, a, t) => {
  const e = document.createElementNS(NS, n);
  for (const k in a) if (a[k] != null) e.setAttribute(k, a[k]);
  if (t != null) e.textContent = t;
  return e;
};
const h = (n, a, t) => {
  const e = document.createElement(n);
  for (const k in a) if (a[k] != null) e.setAttribute(k, a[k]);
  if (t != null) e.textContent = t;
  return e;
};

const int = v => Math.round(v).toLocaleString("en-US");
const short = v => Math.abs(v) >= 1e6 ? +(v / 1e6).toFixed(1) + "M"
  : Math.abs(v) >= 1000 ? +(v / 1000).toFixed(Math.abs(v) < 10000 ? 1 : 0) + "k"
  : +v.toFixed(v < 10 && v % 1 ? 1 : 0) + "";

const FMT = {
  ms: { ax: v => v >= 1000 ? +(v / 1000).toFixed(2) + "s" : short(v), tip: v => v >= 1000 ? (v / 1000).toFixed(2) + " s" : v.toFixed(v < 10 ? 2 : 0) + " ms" },
  s: { ax: v => short(v) + "s", tip: v => v.toFixed(v < 10 ? 2 : 1) + " s" },
  rows: { ax: short, tip: v => int(v) + " rows/s" },
  req: { ax: short, tip: v => int(v) + " req" },
  int: { ax: short, tip: int },
  num: { ax: short, tip: v => (v % 1 ? v.toFixed(1) : int(v)) }
};

const charts = [];
const tt = document.getElementById("tt");

/* ---------------------------------------------------------------- charts */

function mount(host, spec) {
  const inst = { host, spec, hover: () => {} };
  charts.push(inst);
  const draw = () => {
    host.textContent = "";
    host.appendChild(render(Math.max(320, host.clientWidth), spec, inst));
  };
  draw();
  new ResizeObserver(() => { clearTimeout(inst.t); inst.t = setTimeout(draw, 60); }).observe(host);
  wire(inst);
  return inst;
}

function render(W, spec, inst) {
  const wide = spec.wide !== false;
  const P = wide ? { l: 60, r: spec.type === "line" ? 92 : 22, t: 16, b: 30 }
    : { l: 48, r: 16, t: 16, b: 30 };
  const H = spec.h || 232;
  const pw = W - P.l - P.r, ph = H - P.t - P.b;
  const bw = pw / N, cx = i => P.l + (i + 0.5) * bw;
  const cols = spec.series.map(s => S[s.key] || new Array(N).fill(null));
  const fmt = FMT[spec.fmt] || FMT.num;

  let vmax = 0;
  if (spec.type === "stack" || spec.type === "sbars") {
    for (let i = 0; i < N; i++) { let a = 0; for (const c of cols) a += c[i] || 0; if (a > vmax) vmax = a; }
  } else {
    for (const c of cols) for (const v of c) if (v != null && v > vmax) vmax = v;
  }
  const tk = ticks(vmax), ymax = tk[tk.length - 1];
  const y = v => P.t + ph - (v / ymax) * ph;

  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img", "aria-label": spec.aria || spec.title });

  // unsampled buckets
  let run = null;
  for (let i = 0; i <= N; i++) {
    if (i < N && VOID.has(i)) { if (run == null) run = i; continue; }
    if (run != null) {
      svg.appendChild(el("rect", { x: cx(run) - bw / 2, y: P.t, width: bw * (i - run), height: ph, style: "fill:var(--void)" }));
      if (i - run >= 2) {
        svg.appendChild(el("text", {
          x: cx((run + i - 1) / 2), y: P.t + 12, "text-anchor": "middle",
          style: "fill:var(--ink-3);font:500 9.5px 'IBM Plex Mono',monospace;letter-spacing:.09em"
        }, "NO SCRAPE"));
      }
      run = null;
    }
  }

  for (const t of tk) {
    svg.appendChild(el("line", { x1: P.l, x2: W - P.r, y1: y(t), y2: y(t), style: `stroke:var(--${t === 0 ? "axis" : "grid"});stroke-width:1` }));
    svg.appendChild(el("text", { x: P.l - 9, y: y(t) + 3.5, "text-anchor": "end", style: "fill:var(--ink-3);font:400 10.5px 'IBM Plex Mono',monospace" }, fmt.ax(t)));
  }

  const every = Math.ceil(46 / bw);
  for (let i = 0; i < N; i++) {
    if (i % every) continue;
    svg.appendChild(el("text", { x: cx(i), y: H - 10, "text-anchor": "middle", style: "fill:var(--ink-3);font:400 10.5px 'IBM Plex Mono',monospace" }, B[i]));
  }

  const marks = el("g");
  svg.appendChild(marks);
  const ok = i => (spec.valid ? S[spec.valid] && S[spec.valid][i] != null : true);

  if (spec.type === "stack") {
    const base = new Array(N).fill(0);
    spec.series.forEach((s, si) => {
      const c = cols[si];
      for (const seg of runs(i => ok(i) && c[i] != null)) {
        if (seg.length < 2) continue;
        let d = seg.map((i, k) => (k ? "L" : "M") + cx(i).toFixed(1) + " " + y(base[i] + c[i]).toFixed(1)).join("");
        for (let k = seg.length - 1; k >= 0; k--) d += "L" + cx(seg[k]).toFixed(1) + " " + y(base[seg[k]]).toFixed(1);
        marks.appendChild(el("path", { d: d + "Z", style: `fill:var(--${s.c});fill-opacity:.9;stroke:var(--surface);stroke-width:2;stroke-linejoin:round` }));
      }
      for (let i = 0; i < N; i++) base[i] += c[i] || 0;
    });
  } else if (spec.type === "sbars") {
    const w = Math.min(26, bw * 0.6);
    for (let i = 0; i < N; i++) {
      let acc = 0;
      if (!cols.some(c => c[i] != null)) continue;
      spec.series.forEach((s, si) => {
        const v = cols[si][i];
        if (v == null || v <= 0) return;
        const yt = y(acc + v), yb = y(acc);
        marks.appendChild(el("rect", { x: cx(i) - w / 2, y: yt, width: w, height: Math.max(1.5, yb - yt - 1.5), rx: 2, style: `fill:var(--${s.c})` }));
        acc += v;
      });
    }
  } else if (spec.type === "bars") {
    const n = spec.series.length;
    const gw = Math.min(30, bw * 0.68), w = Math.max(2, gw / n - (n > 1 ? 2 : 0));
    spec.series.forEach((s, si) => {
      const c = cols[si];
      for (let i = 0; i < N; i++) {
        if (c[i] == null || c[i] <= 0) continue;
        const x = cx(i) - gw / 2 + si * (gw / n);
        marks.appendChild(el("rect", { x, y: y(c[i]), width: w, height: Math.max(1.5, ph - (y(c[i]) - P.t)), rx: 2, style: `fill:var(--${s.c})` }));
      }
    });
  } else {
    const ends = [];
    spec.series.forEach((s, si) => {
      const c = cols[si];
      const segs = runs(i => c[i] != null);
      for (const seg of segs) {
        if (seg.length === 1) { marks.appendChild(el("circle", { cx: cx(seg[0]), cy: y(c[seg[0]]), r: 3.2, style: `fill:var(--${s.c})` })); continue; }
        marks.appendChild(el("path", {
          d: seg.map((i, k) => (k ? "L" : "M") + cx(i).toFixed(1) + " " + y(c[i]).toFixed(1)).join(""),
          style: `fill:none;stroke:var(--${s.c});stroke-width:2;stroke-linejoin:round;stroke-linecap:round`
        }));
      }
      const tail = segs[segs.length - 1];
      if (tail && P.r > 40) ends.push({ s, i: tail[tail.length - 1], y: y(c[tail[tail.length - 1]]) });
    });
    ends.sort((a, b) => a.y - b.y);
    for (let k = 1; k < ends.length; k++) if (ends[k].y - ends[k - 1].y < 13) ends[k].y = ends[k - 1].y + 13;
    for (const e of ends) {
      marks.appendChild(el("circle", { cx: cx(e.i), cy: y(S[e.s.key][e.i]), r: 3.4, style: `fill:var(--${e.s.c});stroke:var(--surface);stroke-width:2` }));
      marks.appendChild(el("text", { x: Math.min(cx(e.i) + 9, W - P.r + 6), y: e.y + 3.5, style: "fill:var(--ink-2);font:500 11px 'IBM Plex Sans',sans-serif" }, e.s.name));
    }
  }

  const cross = el("line", { y1: P.t, y2: P.t + ph, style: "stroke:var(--ink-3);stroke-width:1;stroke-dasharray:3 3;opacity:0" });
  const dots = el("g", { style: "opacity:0" });
  svg.appendChild(cross);
  svg.appendChild(dots);

  inst.hover = i => {
    if (i == null) { cross.style.opacity = 0; dots.style.opacity = 0; return; }
    cross.setAttribute("x1", cx(i));
    cross.setAttribute("x2", cx(i));
    cross.style.opacity = 0.7;
    dots.textContent = "";
    if (spec.type === "line") {
      spec.series.forEach((s, si) => {
        const v = cols[si][i];
        if (v != null) dots.appendChild(el("circle", { cx: cx(i), cy: y(v), r: 4, style: `fill:var(--${s.c});stroke:var(--surface);stroke-width:2` }));
      });
    }
    dots.style.opacity = 1;
  };
  inst.idx = px => Math.max(0, Math.min(N - 1, Math.floor((px - P.l) / bw)));
  return svg;

  function runs(pred) {
    const out = [];
    let cur = [];
    for (let i = 0; i < N; i++) {
      if (pred(i)) cur.push(i);
      else if (cur.length) { out.push(cur); cur = []; }
    }
    if (cur.length) out.push(cur);
    return out;
  }
}

function ticks(max) {
  if (!(max > 0)) return [0, 1];
  const raw = max / 4, p = Math.pow(10, Math.floor(Math.log10(raw)));
  const step = [1, 2, 2.5, 5, 10].find(x => x * p >= raw - 1e-9) * p;
  const out = [];
  for (let v = 0; v <= max * 1.0001 + step * 0.001; v += step) out.push(+v.toFixed(10));
  if (out[out.length - 1] < max) out.push(+(out[out.length - 1] + step).toFixed(10));
  return out;
}

function tip(i, spec) {
  const fmt = FMT[spec.fmt] || FMT.num;
  let s = `<div class="t">${B[i]}${D.phases[i] ? " &middot; " + D.phases[i] : ""}</div>`;
  let any = false;
  for (const q of spec.series) {
    const v = (S[q.key] || [])[i];
    s += `<div class="r"><span><i style="background:var(--${q.c})"></i>${q.name}</span><b>${v == null ? "&mdash;" : fmt.tip(v)}</b></div>`;
    if (v != null) any = true;
  }
  if (!any) s += `<div class="r" style="color:var(--ink-3)">no usable sample</div>`;
  return s;
}

function wire(inst) {
  const move = ev => {
    const r = inst.host.getBoundingClientRect();
    const svg = inst.host.querySelector("svg");
    if (!svg) return;
    const i = inst.idx((ev.clientX - r.left) * (svg.viewBox.baseVal.width / r.width));
    for (const c of charts) if (c.spec.wide !== false) c.hover(i);
    if (inst.spec.wide === false) inst.hover(i);
    tt.innerHTML = tip(i, inst.spec);
    tt.style.opacity = 1;
    tt.style.left = Math.min(window.innerWidth - tt.offsetWidth - 12, Math.max(8, ev.clientX + 16)) + "px";
    tt.style.top = Math.min(window.innerHeight - tt.offsetHeight - 12, Math.max(8, ev.clientY - tt.offsetHeight - 14)) + "px";
  };
  inst.host.addEventListener("pointermove", move);
  inst.host.addEventListener("pointerleave", () => { for (const c of charts) c.hover(null); tt.style.opacity = 0; });
}

/* ------------------------------------------------------------- liveness */

function strip(host) {
  const draw = () => {
    const W = Math.max(320, host.clientWidth), rows = D.liveness;
    const P = { l: 60, r: 22 }, rh = 19, H = rows.length * rh + 20;
    const pw = W - P.l - P.r, bw = pw / N, cx = i => P.l + (i + 0.5) * bw;
    host.textContent = "";
    const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img", "aria-label": "Pods answering a scrape per tier, and counter resets" });
    rows.forEach((row, r) => {
      const yy = 4 + r * rh;
      svg.appendChild(el("text", { x: P.l - 9, y: yy + 11, "text-anchor": "end", style: "fill:var(--ink-3);font:400 10.5px 'IBM Plex Mono',monospace" }, row.tier));
      for (let i = 0; i < N; i++) {
        const n = row.counts[i], w = Math.min(24, bw * 0.62);
        const tone = n === 0 ? "crit" : n === row.total ? "good" : "warn";
        svg.appendChild(el("rect", { x: cx(i) - w / 2, y: yy + 1, width: w, height: 13, rx: 2, style: `fill:var(--${tone});fill-opacity:.82` }));
        svg.appendChild(el("text", { x: cx(i), y: yy + 11, "text-anchor": "middle", style: "fill:var(--surface);font:600 9px 'IBM Plex Mono',monospace" }, String(n)));
      }
    });
    const yy = 4 + rows.length * rh;
    for (let i = 0; i < N; i++) {
      if (!RESET.has(B[i])) continue;
      svg.appendChild(el("path", { d: `M${cx(i)} ${yy + 2} l4.5 8 h-9 Z`, style: "fill:var(--crit)" }));
    }
    svg.appendChild(el("text", { x: P.l - 9, y: yy + 11, "text-anchor": "end", style: "fill:var(--ink-3);font:400 10.5px 'IBM Plex Mono',monospace" }, "reset"));
    host.appendChild(svg);
  };
  draw();
  new ResizeObserver(() => { clearTimeout(host._t); host._t = setTimeout(draw, 60); }).observe(host);
}

/* ---------------------------------------------------------------- build */

function legendOf(series) {
  const box = h("div", { class: "legend" });
  for (const s of series) {
    const sp = h("span", { class: "lg" });
    sp.appendChild(h("i", { class: s.line ? "ln" : "", style: `background:var(--${s.c})` }));
    sp.appendChild(document.createTextNode(s.name));
    box.appendChild(sp);
  }
  return box;
}

function panelOf(p) {
  const box = h("div", { class: "panel" });
  const hd = h("div", { class: "panel-hd" });
  hd.appendChild(h("h3", {}, p.title));
  if (p.unit) hd.appendChild(h("span", { class: "unit" }, p.unit));
  box.appendChild(hd);

  const c = p.chart;
  const present = c && c.series.some(s => (S[s.key] || []).some(v => v != null));
  if (!present) {
    box.appendChild(h("div", { class: "empty" }, p.emptyNote || "No counter moved during this run."));
  } else {
    if (c.series.length > 1) box.appendChild(legendOf(c.series.map(s => ({ ...s, line: c.type === "line" }))));
    const plot = h("div", { class: "plot" });
    box.appendChild(plot);
    mount(plot, { ...c, title: p.title });
  }
  if (p.note) box.appendChild(h("p", { class: "pnote" }, p.note));
  return box;
}

function tableOf(t) {
  const box = h("div", { class: "tw" });
  let s = "<table><thead><tr>" + t.columns.map(c => `<th>${c}</th>`).join("") + "</tr></thead><tbody>";
  for (const row of t.rows) {
    if (row.group) { s += `<tr class="grp"><td colspan="${t.columns.length}">${row.group}</td></tr>`; continue; }
    s += "<tr>" + row.cells.map((c, k) => {
      const v = c == null || c === "" ? "&mdash;" : c;
      const cls = c == null || c === "" ? "dim" : (row.wrap && k === row.wrap ? "wrap-cell" : "");
      return `<td class="${cls}">${v}</td>`;
    }).join("") + "</tr>";
  }
  box.innerHTML = s + "</tbody></table>";
  return box;
}

function blockOf(b) {
  if (b.kind === "panel") return panelOf(b);
  if (b.kind === "duo") {
    const d = h("div", { class: "duo" });
    for (const p of b.panels) d.appendChild(panelOf(p));
    return d;
  }
  if (b.kind === "table") {
    const box = h("div", {});
    box.style.display = "flex";
    box.style.flexDirection = "column";
    box.style.gap = "10px";
    if (b.title) box.appendChild(h("h3", {}, b.title));
    box.appendChild(tableOf(b));
    if (b.note) box.appendChild(h("p", { class: "pnote", style: "padding:0" }, b.note));
    return box;
  }
  if (b.kind === "callout") {
    const box = h("div", { class: "callout" + (b.tone === "crit" ? " crit" : "") });
    if (b.k) box.appendChild(h("div", { class: "k" }, b.k));
    const p = h("p");
    p.innerHTML = b.text;
    box.appendChild(p);
    return box;
  }
  if (b.kind === "strip") {
    const box = h("div", { class: "panel" });
    const hd = h("div", { class: "panel-hd" });
    hd.appendChild(h("h3", {}, b.title));
    if (b.unit) hd.appendChild(h("span", { class: "unit" }, b.unit));
    box.appendChild(hd);
    const plot = h("div", { class: "plot" });
    box.appendChild(plot);
    strip(plot);
    if (b.note) box.appendChild(h("p", { class: "pnote" }, b.note));
    return box;
  }
  const p = h("p");
  p.innerHTML = b.text;
  return p;
}

const root = document.getElementById("sections");
for (const sec of D.sections) {
  const s = h("section", { id: sec.id });
  const head = h("div", { class: "shead" });
  if (sec.eyebrow) head.appendChild(h("div", { class: "eyebrow" }, sec.eyebrow));
  head.appendChild(h("h2", {}, sec.title));
  if (sec.intro) { const p = h("p"); p.innerHTML = sec.intro; head.appendChild(p); }
  s.appendChild(head);
  for (const b of sec.blocks) s.appendChild(blockOf(b));
  root.appendChild(s);
}
