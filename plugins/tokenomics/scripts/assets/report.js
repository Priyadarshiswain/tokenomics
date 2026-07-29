/* Deliberately money-free. An earlier build priced every call from an API rate card and
   led with a dollar total; it was pulled because Claude Code usage on a subscription is not
   billed that way, and a dollar headline reads as a bill no matter how it is captioned.
   Tokens and context are what this measures, so tokens are what it shows. */

/* no locale argument: digit grouping follows the viewer's own locale */
const f = n => (n || 0).toLocaleString();
const pct = (a,b) => b ? (a/b*100) : 0;
const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

function render(DATA, root) {
  const T = DATA.totals, C = DATA.calls, KS = DATA.compacts || [], o = [];
  if (!C.length) { root.innerHTML = '<section class="card">No API calls in this transcript yet.</section>'; return; }

  const alt = [DATA.aiTitle, DATA.slug].filter(x => x && x !== DATA.title);
  o.push(`<header>
    <div class="eyebrow">Session tokenomics &middot; measured from the transcript</div>
    <h1>${esc(DATA.title)}</h1>
    <div class="sub">Where this session's tokens went &middot;
      <code>${esc(DATA.session.slice(0,8))}</code>${alt.length?` &middot; ${alt.map(a=>esc(a)).join(" &middot; ")}`:``} &middot;
      ${esc(DATA.firstCall.slice(11,16))}&ndash;${esc(DATA.measuredThrough.slice(11,16))} UTC on
      ${esc(DATA.measuredThrough.slice(0,10))}. Derived from <code>.message.usage</code>, deduped by
      <code>message.id</code>. Token counts only &mdash; no pricing, no dollars.</div>
    <div class="chips">
      <span class="chip">calls <b>${f(T.calls)}</b></span>
      <span class="chip">models <b>${DATA.models.map(m=>esc(m.name)+" ×"+m.n).join(" · ")}</b></span>
      <span class="chip">effort <b>${esc(DATA.effort)}</b></span>
      <span class="chip">tier <b>${esc(DATA.tier)}</b></span>
      <span class="chip">entrypoint <b>${esc(DATA.entrypoint)}</b></span>
      <span class="chip">cache TTL <b>${T.cc1h&&T.cc5m?"1h + 5m":T.cc1h?"1h":T.cc5m?"5m":"—"}</b></span>
      ${KS.map(K=>`<span class="chip">compact <b>${esc(K.t)}</b> (${esc(K.trigger)})</span>`).join("")}
    </div>
  </header>`);

  const seg = [
    ["cache read",  T.cread,  "--s-cread",  "the whole conversation, re-sent on every call"],
    ["cache write", T.cwrite, "--s-cwrite", "context filed into the cache so later calls can re-read it"],
    ["output",      T.output, "--s-out",    "what the model actually wrote"],
    ["fresh input", T.input,  "--s-in",     "genuinely new words you typed"]
  ];
  o.push(`<section class="card">
    <div class="eyebrow">Token composition, by class</div>
    <div class="hero-num">${f(T.total)} <small>tokens over ${f(T.calls)} API calls &middot; ${f(Math.round(T.total/T.calls))} per call on average</small></div>
    <div class="eyebrow" style="margin-top:14px">share of TOKENS</div>
    <div class="comp" role="img" aria-label="Token composition by class">
      ${seg.map(([n,v,c,d])=>`<div style="flex:${Math.max(pct(v,T.total),0.35)};background:var(${c})"
        data-tip="${n}|${f(v)} tokens &middot; ${pct(v,T.total).toFixed(1)}% &middot; ${d}"></div>`).join("")}
    </div>
    <div class="legend">${seg.map(([n,v,c])=>
      `<span><i class="sw" style="background:var(${c})"></i>${n} <b>${f(v)}</b> &middot; ${pct(v,T.total).toFixed(1)}%</span>`).join("")}
    </div>
    <p class="sub" style="margin-bottom:0">Cache read dominates every long session:
      <b>${pct(T.cread,T.total).toFixed(1)}%</b> of all tokens here. That is the conversation being
      re-sent on each call &mdash; not new work. Output, the part that feels like the session,
      is <b>${pct(T.output,T.total).toFixed(1)}%</b>.</p>
  </section>`);

  /* --- per model, in tokens --- */
  const byModel = DATA.models.map(m => {
    const cs = C.filter(c => c.model === m.name), sum = k => cs.reduce((a,c)=>a+(c[k]||0),0);
    return [m.name, m.n, sum("inp"), sum("cr"), sum("cw"), sum("out")];
  });
  o.push(`<section class="card">
    <div class="eyebrow">By model &middot; tokens</div>
    <div class="scroll"><table class="t">
      <tr><th>model</th><th>calls</th><th>fresh input</th><th>cache read</th><th>cache write</th><th>output</th></tr>
      ${byModel.map(([m,n,i,cr,cw,ou])=>`<tr><td class="l">${esc(m)}</td>
        <td>${f(n)}</td><td>${f(i)}</td><td>${f(cr)}</td><td>${f(cw)}</td><td><b>${f(ou)}</b></td></tr>`).join("")}
    </table></div>
  </section>`);

  for (const K of KS) {
    const savePer = K.readBefore - K.readAfter;
    const be = savePer > 0 ? Math.ceil(K.write / savePer) : null;
    const after = T.calls - K.callIndex, peak = C.reduce((m,c)=>Math.max(m,c.cr),0);
    o.push(`<section class="card ledger">
      <div class="eyebrow">What <code>/compact</code> did &middot; ${esc(K.t)} UTC (${esc(K.trigger)})</div>
      <h2>${f(K.write)} tokens written once, to stop re-reading ${f(savePer)} on every later call</h2>
      <div class="scroll"><table class="t">
        <tr><th></th><th>before</th><th>after</th></tr>
        <tr><td class="l">context re-read every call</td><td>${f(K.readBefore)}</td>
            <td><b>${f(K.readAfter)}</b> (&minus;${pct(K.readBefore-K.readAfter,K.readBefore).toFixed(0)}%)</td></tr>
        <tr><td class="l">one-off write to file the summary</td>
            <td colspan="2"><b>${f(K.write)}</b> tokens</td></tr>
        <tr><td class="l">break-even, counting tokens only</td><td colspan="2">${be?`<b>&asymp; ${be} call${be>1?"s":""}</b>`:"—"} &middot; ${after} calls followed</td></tr>
        <tr><td class="l">the transcript's own accounting</td><td colspan="2">preTokens ${f(K.preTokens)}
            → postTokens ${f(K.postTokens)} · dropped ${f(K.droppedTokens)}
            · took ${(K.durationMs/1000).toFixed(1)}s</td></tr>
      </table></div>
      <p class="sub" style="margin-top:14px;margin-bottom:0">Break-even here counts raw tokens and
        nothing else. A written token and a re-read token are not interchangeable in practice — writes
        are the heavier of the two — so treat this as the optimistic bound. What a compact cannot do is
        stop new work from re-inflating the stack: context has since peaked at <b>${f(peak)}</b>${
        peak>K.readBefore?`, <b>${pct(peak-K.readBefore,K.readBefore).toFixed(0)}% above the pre-compact level</b>`:``}.</p>
    </section>`);
  }

  /* A 17k-call session cannot be drawn as 17k bars — they land sub-pixel and the chart
     reads as a solid block. Above the cap, aggregate consecutive calls into buckets and
     say so on the axis. (Spread-based Math.max would also risk a stack overflow here.) */
  /* Cap chosen so every bar keeps real width: at ~960px of card, 180 bars leaves ~4px
     per bar after a 1px gap. Going denser makes the gap eat the bar entirely (317 bars
     at a 3px gap rendered 0.08px-wide bars — a chart that looked blank). */
  const MAXBARS = 180;
  const bucketSize = Math.ceil(C.length / MAXBARS);
  const B = bucketSize <= 1 ? C : (() => {
    const out = [];
    for (let i = 0; i < C.length; i += bucketSize) {
      const g = C.slice(i, i + bucketSize);
      out.push({
        i: out.length, t: g[0].t, tEnd: g[g.length-1].t, n: g.length,
        model: g[0].model,
        /* mean per call, so bar height stays comparable to the un-bucketed view */
        cr:  Math.round(g.reduce((a,c)=>a+c.cr, 0) / g.length),
        cw:  Math.round(g.reduce((a,c)=>a+c.cw, 0) / g.length),
        out: Math.round(g.reduce((a,c)=>a+c.out,0) / g.length),
        rebuild: g.some(c=>c.rebuild),
        cause: (g.find(c=>c.rebuild)||{}).cause || null
      });
    }
    return out;
  })();
  /* the gap has to shrink with density, or it crowds the bars out entirely */
  const GAP = B.length > 110 ? "1px" : B.length > 60 ? "2px" : "3px";
  const mx = (arr, fn) => arr.reduce((m,x)=>Math.max(m, fn(x)), 0);
  const MAXC = mx(B, c=>c.cr+c.cw)*1.02 || 1;
  const MAXO = mx(B, c=>c.out)*1.05 || 1;
  const step = Math.max(1, Math.ceil(B.length/9));
  o.push(`<section class="card">
    <div class="eyebrow">Context tax per API call</div>
    <h2>Every call re-sends the whole conversation</h2>
    <div class="sub" style="margin-bottom:6px">One bar per call: <b style="color:var(--s-cread)">cache read</b>
      + <b style="color:var(--s-cwrite)">cache write</b>, stacked. <b class="mono">↻</b> marks a rebuild.
      Read the <em>write</em>, not the read — a small write is a normal turn paying rent; a large one means
      the cache broke and the whole conversation is being re-filed.</div>
    <div class="tl" style="grid-template-columns:repeat(${B.length},1fr);gap:${GAP}">
      ${B.map(c=>`<div class="col${c.rebuild?" rb":""}"
        data-tip="${c.n?`calls ${c.i*bucketSize+1}–${c.i*bucketSize+c.n} · ${esc(c.t)}–${esc(c.tEnd)} UTC`:`call ${c.i+1} · ${esc(c.t)} UTC · ${esc(c.model)}`}${c.cause?" · ↻ "+esc(c.cause):""}|${c.n?"mean per call: ":""}read ${f(c.cr)} · write ${f(c.cw)} · out ${f(c.out)}">
        <div style="background:var(--s-cread);height:${c.cr/MAXC*100}%"></div>
        <div style="background:var(--s-cwrite);height:${c.cw/MAXC*100}%"></div></div>`).join("")}
    </div>
    <div class="tl-x" style="grid-template-columns:repeat(${B.length},1fr);gap:${GAP}">
      ${B.map((c,i)=>`<div>${i%step===0?esc(c.t):""}</div>`).join("")}</div>
    <div class="axis-note">y: tokens per call, 0 → ${f(Math.round(MAXC))} &middot; x: call time (UTC)${
      bucketSize>1?` &middot; <b>${f(C.length)} calls bucketed ${bucketSize}-per-bar (mean), ${B.length} bars</b> — a bar is marked ↻ if any call in it rebuilt`:``}</div>
    <div class="eyebrow" style="margin-top:20px">Output tokens per call (same x-axis)</div>
    <div class="tl-out" style="grid-template-columns:repeat(${B.length},1fr);gap:${GAP}">
      ${B.map(c=>`<div style="height:${c.out/MAXO*100}%"
        data-tip="output · ${esc(c.t)}${c.n?"–"+esc(c.tEnd):" · "+esc(c.model)}|${f(c.out)} tokens${c.n?" mean/call":""}"></div>`).join("")}</div>
    <div class="axis-note">y: 0 → ${f(Math.round(MAXO))} — note the scale change: this whole row is a sliver on the chart above</div>
  </section>`);

  if (DATA.rebuilds.length) {
    /* Rank by write volume and show the top slice — 261 rows is not a table anyone reads.
       The cap is stated on the page; a silently truncated list reads as "that was all". */
    const RB_MAX = 20;
    /* Rank by re-filed tokens — the write is what a rebuild actually costs you. */
    const rbCost = r => r.cw || 0;
    const rbAll = [...DATA.rebuilds].sort((a,b)=>rbCost(b)-rbCost(a));
    const rbShown = rbAll.slice(0, RB_MAX);
    const rbTotal = rbAll.reduce((a,r)=>a+rbCost(r), 0);
    /* Group on the cause KIND, not the full label: causes carry their gap length
       ("idle gap — cache TTL expiry (426m)"), so grouping on the raw string produces one
       row per distinct minute count instead of one row per kind. */
    const causeKind = r => (r.cause || "—").replace(/\s*\([^)]*\)\s*$/, "");
    const byCause = [...rbAll.reduce((m, r) => {
      const k = causeKind(r), v = m.get(k) || { n: 0, c: 0 };
      return m.set(k, { n: v.n + 1, c: v.c + rbCost(r) });
    }, new Map())].sort((a,b)=>b[1].c-a[1].c);
    o.push(`<section class="card">
      <div class="eyebrow">Cache rebuilds &middot; the expensive events</div>
      <h2>${DATA.rebuilds.length} rebuild${DATA.rebuilds.length>1?"s":""} — ${f(rbTotal)} tokens re-filed</h2>
      <div class="scroll"><table class="t" style="margin-bottom:16px">
        <tr><th>cause</th><th>count</th><th>tokens re-filed</th><th>share</th></tr>
        ${byCause.map(([c,v])=>`<tr><td class="l">${esc(c)}</td><td>${f(v.n)}</td>
          <td><b>${f(v.c)}</b></td><td>${pct(v.c,rbTotal).toFixed(1)}%</td></tr>`).join("")}
      </table></div>
      ${rbAll.length>RB_MAX?`<div class="eyebrow">the ${RB_MAX} largest of ${f(rbAll.length)}</div>`:``}
      <div class="scroll"><table class="t">
        <tr><th>time</th><th>cause</th><th>model</th><th>read before</th><th>read after</th><th>re-filed</th></tr>
        ${rbShown.map(r=>`<tr><td>${esc(r.t)}</td><td class="l">${esc(r.cause||"—")}</td>
          <td class="l">${esc(r.model||"—")}</td>
          <td>${f(r.crBefore)}</td><td>${f(r.cr)}</td><td><b>${f(r.cw)}</b></td></tr>`).join("")}
      </table></div>
      <p class="sub" style="margin-top:14px;margin-bottom:0">A cache hit needs the conversation to be
        byte-identical from the bottom up to a save-point. Anything that edits the middle voids everything
        above it, and the read falls back to the deepest save-point that still matches. Causes are attributed
        from the data: a changed model, a gap past the cache TTL, the compact-boundary record, or a preceding
        <code>end_turn</code> — a turn boundary, i.e. you sending a new message.</p>
    </section>`);
  }

  const bars = (rows, colorOf) => rows.length ? `<div class="barlist">${rows.map(r=>`
    <div class="r"><span class="lbl mono">${esc(r.name)}</span>
      <div class="bar" style="width:${Math.max(r.n/rows[0].n*100,2)}%;background:var(${colorOf?colorOf(r):"--s-cread"})"></div>
      <span class="val">${f(r.n)}</span></div>`).join("")}</div>` : "";
  const turns = (DATA.stops.find(s=>s.name==="end_turn")||{n:0}).n;
  const trips = (DATA.stops.find(s=>s.name==="tool_use")||{n:0}).n;
  o.push(`<div class="row3">
    <section class="card">
      <div class="eyebrow">stop_reason</div><h2>Turns vs tool round-trips</h2>
      ${bars(DATA.stops, r=>r.name==="end_turn"?"--s-out":"--s-cread")}
      <p class="sub" style="margin-bottom:0">${f(turns)} actual repl${turns===1?"y":"ies"} to you;
        ${f(trips)} tool round-trips, each re-sending the whole conversation. Inside a turn the cache holds; it is the
        seam between turns that breaks it.</p>
    </section>
    <section class="card">
      <div class="eyebrow">record type</div><h2>What's in the transcript</h2>
      ${bars(DATA.types.slice(0,8))}
      <p class="sub" style="margin-bottom:0">${f(DATA.dedup.records)} usage-bearing records map to only
        <b>${f(DATA.dedup.unique)}</b> real API calls — see below.</p>
    </section>
    <section class="card">
      <div class="eyebrow">toolUseResult &middot; bytes</div><h2>Tool output is re-read forever</h2>
      <div class="barlist">${DATA.tools.top.map(t=>`
        <div class="r"><span class="lbl">${esc(t.name)}</span>
          <div class="bar" style="width:${Math.max(t.size/DATA.tools.top[0].size*100,2)}%;background:var(--s-cwrite)"></div>
          <span class="val">${f(t.size)}</span></div>`).join("")}</div>
      <p class="sub" style="margin-bottom:0">${f(DATA.tools.bytes)} bytes over ${f(DATA.tools.n)} calls.
        Every byte lands in the conversation and is re-read on <em>every remaining call</em> — the true
        weight is size × calls left, not size once.</p>
    </section>
  </div>`);

  const ratio = DATA.dedup.unique ? DATA.dedup.records/DATA.dedup.unique : 1;
  o.push(`<section class="card callout">
    <div class="eyebrow">Measurement caveat &middot; applies to any transcript reader</div>
    <h2>The transcript double-writes: ${f(DATA.dedup.records)} records, ${f(DATA.dedup.unique)} real calls</h2>
    <p class="sub" style="margin-bottom:0">The harness re-writes the same assistant message while streaming,
      so a naive sum inflates every figure by about <b>${ratio.toFixed(1)}×</b> on this session. Everything
      here is deduped with <code>group_by(.message.id) | map(.[-1])</code>. Relative rankings between sessions
      survive naive summing; absolute numbers do not.</p>
  </section>`);

  o.push(`<footer class="sub" style="color:var(--muted)">Generated by
    <span class="mono">tokenomics.sh</span> from <span class="mono">${esc(DATA.session.slice(0,8))}.jsonl</span>,
    measured through ${esc(DATA.measuredThrough.slice(11,16))} UTC &middot; deterministic: same transcript in,
    identical page out &middot; narrative companion: <span class="mono">docs/tokenomics-explained.md</span></footer>`);

  root.innerHTML = o.join("");
}

const tip = document.getElementById("tip");
document.addEventListener("mousemove", e => {
  const t = e.target.closest("[data-tip]");
  if (!t) { tip.style.opacity = 0; return; }
  const [a,b] = t.dataset.tip.split("|");
  tip.innerHTML = '<div class="t"></div><div class="l"></div>';
  tip.querySelector(".t").textContent = a;
  tip.querySelector(".l").textContent = b || "";
  tip.style.opacity = 1;
  tip.style.left = Math.min(e.clientX+14, innerWidth  - tip.offsetWidth  - 10) + "px";
  tip.style.top  = Math.min(e.clientY+14, innerHeight - tip.offsetHeight - 10) + "px";
});
