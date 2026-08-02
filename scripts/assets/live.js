
/* ---------------- session picker + live refresh ---------------- */
const app   = document.getElementById("app");
const pulse = document.getElementById("pulse");
const stamp = document.getElementById("stamp");
const every = document.getElementById("every");
const sess  = document.getElementById("sess");
let timer = null, lastThrough = null, primaryId = null;

const nf = n => (n||0).toLocaleString();

async function loadIndex() {
  try {
    const r = await fetch("sessions.json?t=" + Date.now(), { cache: "no-store" });
    const list = await r.json();
    /* Remember where the viewer was before the <select> is rebuilt. Someone who deliberately
       opened a finished session stays there; someone following the live one rolls forward
       with the watcher when it moves onto a newly started session. */
    const prev = sess.value || null;
    const wasFollowingLive = prev !== null && prev === primaryId;
    /* Group by project so a multi-project picker stays navigable; sort newest-first
       within each group, and put the group holding the targeted session at the top. */
    const groups = new Map();
    for (const s of list) {
      const g = s.project || "—";
      if (!groups.has(g)) groups.set(g, []);
      groups.get(g).push(s);
    }
    const primaryGroup = (list.find(s => s.primary) || {}).project;
    const ordered = [...groups.entries()].sort((a, b) =>
      (b[0] === primaryGroup) - (a[0] === primaryGroup) || a[0].localeCompare(b[0]));
    /* Titles are AI-generated free text — esc() them like everything else rendered,
       or one title containing < or & breaks (or injects into) the picker markup. */
    sess.innerHTML = ordered.map(([g, ss]) =>
      `<optgroup label="${esc(g)} (${ss.length})">` +
      ss.sort((a,b) => b.started.localeCompare(a.started)).map(s =>
        `<option value="${esc(s.id)}"${s.primary?" selected":""}>${s.started.slice(0,10)} · ${esc(s.title)}` +
        ` (${nf(s.calls)} calls, ${nf(Math.round(s.tokens/1000))}k)</option>`).join("") +
      `</optgroup>`).join("");
    const p = list.find(s => s.primary) || list[0];
    primaryId = p ? p.id : null;
    if (prev && !wasFollowingLive && list.some(s => s.id === prev)) sess.value = prev;
    else if (primaryId) sess.value = primaryId;
    return sess.value || null;
  } catch (e) { return null; }
}

async function load(reason, id) {
  id = id || sess.value || primaryId;
  if (!id) return;
  pulse.className = "pulse";
  try {
    /* cache-buster: the primary session's file is rewritten in place by the watch loop */
    const r = await fetch(`data-${id}.json?t=` + Date.now(), { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    render(d, app);
    const changed = d.measuredThrough !== lastThrough;
    lastThrough = d.measuredThrough;
    /* Only the targeted session keeps growing; the rest are finished and immutable, so
       "live" is an honest label for one of them and would be a lie for the others. */
    const live = id === primaryId;
    stamp.textContent = `${d.totals.calls} calls · through ${d.measuredThrough.slice(11,16)} UTC`
      + (live ? (changed ? " · updated" : " · no change") : " · finished session (static)")
      + ` · ${reason}`;
    pulse.className = live ? "pulse" : "pulse off";
  } catch (e) {
    pulse.className = "pulse err";
    stamp.textContent = `could not load data-${id}.json — ${e.message}`
      + " (serve the folder over http; file:// blocks fetch)";
  }
}

function schedule() {
  if (timer) clearInterval(timer);
  const s = Number(every.value);
  if (!s) return;
  /* Re-read the index on every tick, not just at page load: a session started after this
     page opened only reaches the picker if sessions.json is re-fetched. */
  timer = setInterval(async () => {
    const before = primaryId;
    await loadIndex();
    if (sess.value === primaryId) load(primaryId !== before ? "new session" : "auto");
  }, s * 1000);
}

document.getElementById("refresh").addEventListener("click", async () => {
  await loadIndex(); load("manual");
});
sess.addEventListener("change", () => { lastThrough = null; load("switched"); });
every.addEventListener("change", schedule);
document.addEventListener("visibilitychange", async () => {
  if (document.hidden) return;
  await loadIndex();
  if (sess.value === primaryId) load("focus");
});

(async () => { const id = await loadIndex(); await load("initial", id); schedule(); })();
</script>
