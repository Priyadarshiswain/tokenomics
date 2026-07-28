#!/usr/bin/env bash
# tokenomics.sh — measure a Claude Code session transcript and render it as HTML.
#
# Deterministic: same transcript in → byte-identical output. No wall-clock reads in the
# measurement, no randomness, no network.
#
# TWO OUTPUT MODES
#   bundle (default)  a directory with index.html + data.json. The page fetches data.json,
#                     has a Refresh button and an auto-refresh timer. Live, local.
#   --inline          one self-contained .html with the data baked in. Use this for
#                     publishing as an Artifact (artifact CSP blocks all fetches).
#
# USAGE
#   tokenomics.sh                          # newest session of the CURRENT project
#   tokenomics.sh <session-id>             # a specific session (searched everywhere)
#   tokenomics.sh /path/to/x.jsonl         # explicit transcript
#   tokenomics.sh --list                   # recent sessions of the current project
#   tokenomics.sh --project <path|slug>    # target another project
#   tokenomics.sh --sessions 10            # how many sessions the picker offers
#   tokenomics.sh --all-projects           # picker spans EVERY project, not just this one
#
# The bundle carries a session PICKER. Finished sessions are immutable, so their data is
# generated once; only the session you targeted keeps refreshing under --watch.
#
# Nothing is hardcoded to a project. With no argument it resolves, in order: --project,
# then $CLAUDE_PROJECT_DIR, then $PWD — each treated as a WORKING directory and slugged to
# its transcript folder under ~/.claude/projects — and only failing all that, the most
# recently touched project on the machine.
#   tokenomics.sh -d ~/tok                 # choose the bundle directory
#   tokenomics.sh --watch 30               # regenerate data.json every 30s (foreground)
#   tokenomics.sh --serve 8899             # serve the bundle over http
#   tokenomics.sh --watch 30 --serve 8899  # live dashboard: server + refresh loop
#   tokenomics.sh --inline -o page.html    # self-contained snapshot, for publishing
#   tokenomics.sh --json                   # just the measured data
#
# NOTE ON PUBLISHING: no shell command can push to an artifact URL — only a Claude turn can
# call the Artifact tool. Workflow: run with --inline, then ask Claude to publish that path.
# Republishing the same path keeps the same URL.
#
# Narrative companion: docs/tokenomics-explained.md
set -uo pipefail

MODE="bundle"; OUT=""; DIR=""; WATCH=0; SERVE=0; ARG=""; PROJECT=""; NSESS=6; ALLPROJ=0
while [ $# -gt 0 ]; do
  case "$1" in
    --inline)   MODE="inline"; shift ;;
    --json)     MODE="json"; shift ;;
    --list)     MODE="list"; shift ;;
    --projects) MODE="projects"; shift ;;
    --all-projects) ALLPROJ=1; shift ;;
    --project)  PROJECT="${2:-}"; shift 2 ;;
    --sessions) NSESS="${2:-6}"; shift 2 ;;
    -o)        OUT="${2:-}"; shift 2 ;;
    -d)        DIR="${2:-}"; shift 2 ;;
    --watch)   WATCH="${2:-30}"; shift 2 ;;
    --serve)   SERVE="${2:-8899}"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *)         ARG="$1"; shift ;;
  esac
done

command -v jq >/dev/null || { echo "tokenomics: jq is required" >&2; exit 1; }

PROJ_ROOT="$HOME/.claude/projects"

# Claude Code stores a project's transcripts under a slug of its absolute path, with
# "/" and "." both flattened to "-":
#   /Users/me/Projects/App            -> -Users-me-Projects-App
#   /Users/me/Projects/App/.claude/wt -> -Users-me-Projects-App--claude-wt
slugdir() { printf '%s/%s' "$PROJ_ROOT" "$(printf '%s' "$1" | sed 's#[/.]#-#g')"; }

# Which project's transcripts are we looking at?
#   --project <path|slug>  wins
#   else CLAUDE_PROJECT_DIR (a WORKING directory, not a transcript directory — slug it)
#   else $PWD
#   else the most recently touched project on the machine
project_dir() {
  local p="${PROJECT:-${CLAUDE_PROJECT_DIR:-$PWD}}" d
  [ -d "$p" ] && [ -n "$(ls "$p"/*.jsonl 2>/dev/null)" ] && { printf '%s' "$p"; return; }  # already a transcript dir
  [ -d "$PROJ_ROOT/$p" ] && { printf '%s' "$PROJ_ROOT/$p"; return; }                        # a bare slug
  d=$(slugdir "$p"); [ -d "$d" ] && { printf '%s' "$d"; return; }                           # a working directory
  ls -td "$PROJ_ROOT"/*/ 2>/dev/null | head -1 | sed 's#/$##'                               # last resort
}

resolve_transcript() {
  if [ -n "$ARG" ] && [ -f "$ARG" ]; then printf '%s' "$ARG"; return; fi
  if [ -n "$ARG" ]; then
    local hit
    hit=$(find "$PROJ_ROOT" -maxdepth 2 -name "${ARG}*.jsonl" -print 2>/dev/null | head -1)
    [ -n "$hit" ] && { printf '%s' "$hit"; return; }
    echo "tokenomics: no transcript matching '$ARG' under $PROJ_ROOT" >&2; exit 1
  fi
  local dir newest; dir=$(project_dir)
  newest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
  [ -n "$newest" ] || { echo "tokenomics: no transcripts under $dir" >&2; exit 1; }
  printf '%s' "$newest"
}

# --projects: every project that has transcripts. Deliberately cheap — it reads only the
# first line of each file for a date, never parsing whole transcripts, so it stays fast
# even when a single session is hundreds of megabytes.
if [ "$MODE" = "projects" ]; then
  printf '%5s %7s  %-10s %-10s  %s\n' "sess" "size" "oldest" "newest" "project"
  for d in "$PROJ_ROOT"/*/; do
    n=$(ls "$d"*.jsonl 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 0 ] || continue
    dates=$(for f in "$d"*.jsonl; do head -1 "$f" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null; done | sort)
    printf '%5s %7s  %-10s %-10s  %s\n' "$n" "$(du -sh "$d" 2>/dev/null | cut -f1)" \
      "$(printf '%s' "$dates" | head -1 | cut -c1-10)" \
      "$(printf '%s' "$dates" | tail -1 | cut -c1-10)" "$(basename "$d")"
  done | sort -k1 -rn
  exit 0
fi

# --list: sessions for the resolved project, newest first. --sessions N sets how many.
if [ "$MODE" = "list" ]; then
  d=$(project_dir)
  LIMIT=$NSESS; [ "$LIMIT" -le 6 ] && LIMIT=20   # a bare --list should show a useful page
  echo "project: $d"
  printf '%-10s %-17s %7s %12s  %s\n' "session" "started (UTC)" "calls" "tokens" "title"
  for t in $(ls -t "$d"/*.jsonl 2>/dev/null | head -"$LIMIT"); do
    jq -s -r --arg id "$(basename "$t" .jsonl)" '
      ([ .[] | select(.message.usage != null) ] | group_by(.message.id) | map(.[-1])) as $u
      | ([ .[] | select(.type=="custom-title") | .customTitle ] | last) as $ct
      | ([ .[] | select(.type=="ai-title")     | .aiTitle     ] | last) as $at
      | ([ .[] | .slug // empty ] | last) as $slug
      # The custom title names the SEAT and repeats across sessions; the AI title names the
      # WORK. Show both, or the list looks like five identical rows.
      | (if ($ct and $at) then $ct + " — " + $at
         elif $ct then $ct elif $at then $at else ($slug // "untitled") end) as $label
      | def n(k): (.message.usage[k] // 0);
      "\(($u[0].timestamp // "0000-00-00T00:00")[0:16] | sub("T";" "))\t\($id[0:8])\t\($u|length)\t" +
      "\($u | map(n("input_tokens")+n("output_tokens")
        +n("cache_creation_input_tokens")+n("cache_read_input_tokens")) | add // 0)\t" +
      "\($label[0:70])"' "$t"
  # sort by the column actually shown (start time), newest first — not by file mtime,
  # which is when the session last got written to and would order the list confusingly.
  done | sort -r | awk -F'\t' '{printf "%-10s %-17s %7s %12s  %s\n", $2, $1, $3, $4, $5}'
  exit 0
fi

F=$(resolve_transcript)
SESSION=$(basename "$F" .jsonl)
SHORT=${SESSION%%-*}

# With no explicit target, --watch follows whatever the newest transcript is, so a `/clear`
# (which mints a new file) moves the dashboard onto the new session instead of freezing on
# the old one. An explicit `--watch <id>` stays pinned to what was asked for.
AUTOFOLLOW=0; [ -n "$ARG" ] || AUTOFOLLOW=1

# =============================================================== measurement ==
# Deduped by message.id: the transcript re-writes the same assistant message while
# streaming, so a naive sum roughly doubles every figure.
measure() {
  jq -s '
    def num(k): (.message.usage[k] // 0);
    def epoch: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;

    . as $all

    | ([ $all[] | select(.type=="assistant")
         | (.message.content // []) | if type=="array" then .[] else empty end
         | select(.type=="tool_use") | {key: .id, value: .name} ] | from_entries) as $tname

    | ([ $all[] | select(.type=="system" and .subtype=="compact_boundary") ] | .[0]) as $cb

    | ([ $all[] | select(.message.usage != null) ]) as $raw
    | ($raw | group_by(.message.id) | map(.[-1]) | sort_by(.timestamp)) as $u

    | ($u | map({
        ts: .timestamp, t: .timestamp[11:16],
        model: ((.message.model // "?") | sub("^claude-";"") | sub("-[0-9]{8}$";"")),
        cr: num("cache_read_input_tokens"), cw: num("cache_creation_input_tokens"),
        # split the write by TTL: 1h costs 2x base, 5m only 1.25x — pricing them the same
        # would overstate any session that uses short-lived cache
        cw1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0),
        cw5m: (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0),
        out: num("output_tokens"), inp: num("input_tokens"),
        stop: (.message.stop_reason // "")
      })) as $calls

    | (if $cb == null then -1
       else ([ $calls | to_entries[] | select(.value.ts > $cb.timestamp) | .key ] | (.[0] // -1))
       end) as $cIdx

    # Idle-expiry threshold follows the TTL this session actually bought: a 5-minute
    # cache dies in 5 minutes, a 1-hour one in 60. Guessing 60 for a 5m session would
    # mislabel every expiry as something else.
    | (if ([ $u[] | .message.usage.cache_creation.ephemeral_1h_input_tokens // 0 ] | add // 0) > 0
       then 60 else 5 end) as $ttlMin

    | ($calls | to_entries | map(
        .key as $i | .value as $c | ($calls[$i-1] // null) as $p
        | $c + {
            i: $i,
            gapMin: (if $i == 0 or $p == null then 0
                     else ((($c.ts|epoch) - ($p.ts|epoch)) / 60 | floor) end),
            rebuild: (if $i == 0 or $p == null then false
                      else ($c.cw > 10000 and $c.cr < ($p.cr * 0.7)) end)
          }
        | . + { cause:
            (if (.rebuild | not) then null
             elif $i == $cIdx                       then "compact"
             elif .model != $calls[$i-1].model      then "model switch"
             elif .gapMin >= $ttlMin                then "idle gap — cache TTL expiry (\(.gapMin)m)"
             elif $calls[$i-1].stop == "end_turn"
               then (if .gapMin >= 10 then "turn boundary (after \(.gapMin)m idle)"
                     else "turn boundary" end)
             else "context rebuild" end) }
      )) as $C

    # Human-readable identity. A session id is unreadable; these are what the UI shows.
    # Precedence: what the user named it > what the model named it > the memorable slug.
    | ([ $all[] | select(.type=="custom-title") | .customTitle ] | last) as $ct
    | ([ $all[] | select(.type=="ai-title")     | .aiTitle     ] | last) as $at
    | ([ $all[] | select(.type=="last-prompt")  | .lastPrompt  ] | last) as $lp
    | ([ $all[] | .slug // empty ] | last) as $slug

    | {
        session: ($all[0].sessionId // "?"),
        title:       ($ct // $at // $slug // "untitled"),
        customTitle: $ct,
        aiTitle:     $at,
        slug:        $slug,
        lastPrompt:  $lp,
        # "measured through" comes from the data, never the clock — that is what keeps
        # this deterministic. Re-running on an unchanged transcript reproduces the file.
        measuredThrough: ($C[-1].ts // ""),
        firstCall: ($C[0].ts // ""),
        entrypoint: ([ $all[] | .entrypoint // empty ] | last // "-"),
        effort:     ([ $all[] | .effort // empty ] | last // "-"),
        tier:       ([ $u[] | .message.usage.service_tier // empty ] | last // "-"),

        calls: $C,
        totals: {
          calls:  ($C | length),
          input:  ($C | map(.inp) | add // 0),
          output: ($C | map(.out) | add // 0),
          cread:  ($C | map(.cr)  | add // 0),
          cwrite: ($C | map(.cw)  | add // 0),
          cc1h:   ($u | map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0),
          cc5m:   ($u | map(.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) | add // 0),
          total:  ($C | map(.inp + .out + .cr + .cw) | add // 0)
        },
        models: ($C | group_by(.model) | map({name: .[0].model, n: length}) | sort_by(-.n)),
        stops:  ($C | map(select(.stop != "")) | group_by(.stop)
                   | map({name: .[0].stop, n: length}) | sort_by(-.n)),
        types:  ($all | group_by(.type) | map({name: .[0].type, n: length}) | sort_by(-.n)),
        subagents: ([ $all[] | select(.isSidechain == true) ] | length),

        compact: (if $cb == null or $cIdx < 1 then null else {
          t: ($cb.timestamp[11:16]),
          trigger:       ($cb.compactMetadata.trigger // "?"),
          preTokens:     ($cb.compactMetadata.preTokens // 0),
          postTokens:    ($cb.compactMetadata.postTokens // 0),
          droppedTokens: ($cb.compactMetadata.cumulativeDroppedTokens // 0),
          durationMs:    ($cb.compactMetadata.durationMs // 0),
          callIndex:  $cIdx,
          readBefore: $C[$cIdx-1].cr,
          readAfter:  $C[$cIdx].cr,
          write:      $C[$cIdx].cw,
          model:      $C[$cIdx].model
        } end),

        rebuilds: ($C | map(select(.rebuild))
                     | map({i, t, cause, cw, cw1h, cw5m, cr, model,
                            crBefore: ($C[.i-1].cr // 0)})),

        tools: ([ $all[] | select(.toolUseResult != null)
                  | { id: ((.message.content // null)
                            | if type=="array" then (.[0].tool_use_id // "") else "" end),
                      size: (.toolUseResult | tostring | length) }
                  | . + { name: ($tname[.id] // "tool") } ]
                | { n: length, bytes: (map(.size) | add // 0),
                    top: (sort_by(-.size) | .[0:6] | map({name, size})) }),

        dedup: { records: ($raw | length), unique: ($C | length) }
      }
  ' "$F"
}

if [ "$MODE" = "json" ]; then measure; exit 0; fi

# ================================================================== rendering ==
emit_style() {
cat <<'CSS'
<style>
  :root {
    color-scheme: light;
    --page:#f9f9f7; --surface:#fcfcfb;
    --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
    --grid:#e1e0d9; --baseline:#c3c2b7; --ring:rgba(11,11,11,0.10);
    --s-cread:#2a78d6; --s-cwrite:#eb6834; --s-out:#1baf7a; --s-in:#eda100;
  }
  @media (prefers-color-scheme: dark) {
    :root:where(:not([data-theme="light"])) {
      color-scheme: dark;
      --page:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink-2:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --baseline:#383835; --ring:rgba(255,255,255,0.10);
      --s-cread:#3987e5; --s-cwrite:#d95926; --s-out:#199e70; --s-in:#c98500;
    }
  }
  :root[data-theme="dark"] {
    color-scheme: dark;
    --page:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink-2:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --baseline:#383835; --ring:rgba(255,255,255,0.10);
    --s-cread:#3987e5; --s-cwrite:#d95926; --s-out:#199e70; --s-in:#c98500;
  }
  :root[data-theme="light"] {
    color-scheme: light;
    --page:#f9f9f7; --surface:#fcfcfb; --ink:#0b0b0b; --ink-2:#52514e; --muted:#898781;
    --grid:#e1e0d9; --baseline:#c3c2b7; --ring:rgba(11,11,11,0.10);
    --s-cread:#2a78d6; --s-cwrite:#eb6834; --s-out:#1baf7a; --s-in:#eda100;
  }
  body { background:var(--page); color:var(--ink); margin:0; padding:32px 20px 80px;
    font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif; }
  .wrap { max-width:1020px; margin:0 auto; display:flex; flex-direction:column; gap:26px; }
  code,.mono { font-family:ui-monospace,"SF Mono",Menlo,monospace; }
  h1 { font-size:26px; margin:0; letter-spacing:-.01em; text-wrap:balance; }
  h2 { font-size:17px; margin:0 0 4px; }
  .eyebrow { font-size:11px; letter-spacing:.08em; text-transform:uppercase; color:var(--muted); font-weight:600; }
  .sub { color:var(--ink-2); font-size:13.5px; max-width:70ch; }
  .chips { display:flex; flex-wrap:wrap; gap:8px; margin-top:10px; }
  .chip { border:1px solid var(--ring); background:var(--surface); border-radius:999px;
    padding:3px 12px; font-size:12.5px; color:var(--ink-2); }
  .chip b { color:var(--ink); font-weight:600; }
  .card { background:var(--surface); border:1px solid var(--ring); border-radius:10px; padding:20px 22px; }
  .hero-num { font-size:44px; font-weight:700; letter-spacing:-.02em; line-height:1.1; }
  .hero-num small { font-size:16px; font-weight:500; color:var(--ink-2); letter-spacing:0; }
  .comp { display:flex; height:34px; border-radius:4px; overflow:hidden; gap:2px; margin:16px 0 10px; }
  .comp > div { min-width:3px; }
  .legend { display:flex; flex-wrap:wrap; gap:6px 20px; font-size:13px; color:var(--ink-2); margin-top:4px; }
  .legend span { display:inline-flex; align-items:center; gap:7px; }
  .sw { width:11px; height:11px; border-radius:3px; flex:none; }
  .legend b { color:var(--ink); font-variant-numeric:tabular-nums; font-weight:600; }
  .tl { display:grid; gap:3px; align-items:end; height:190px; border-bottom:1px solid var(--baseline); padding-top:22px; }
  .tl .col { display:flex; flex-direction:column-reverse; gap:2px; border-radius:4px 4px 0 0;
    overflow:hidden; height:100%; position:relative; }
  .tl .col:hover { outline:2px solid var(--ink); outline-offset:1px; }
  .tl .col.rb::after { content:"\21BB"; position:absolute; top:-20px; left:50%; transform:translateX(-50%);
    font-size:13px; color:var(--s-cwrite); font-weight:700; }
  .tl-out { display:grid; gap:3px; align-items:end; height:46px; border-bottom:1px solid var(--baseline); margin-top:14px; }
  .tl-out div { background:var(--s-out); border-radius:3px 3px 0 0; }
  .tl-x { display:grid; gap:3px; font-size:10.5px; color:var(--muted); text-align:center;
    margin-top:6px; font-variant-numeric:tabular-nums; }
  .tl-x div { white-space:nowrap; }
  .axis-note { font-size:12px; color:var(--muted); margin-top:4px; }
  table.t { border-collapse:collapse; font-size:13px; width:100%; }
  table.t th { text-align:left; font-weight:600; color:var(--muted); padding:6px 14px 6px 0; white-space:nowrap; }
  table.t td { padding:7px 14px 7px 0; border-top:1px solid var(--grid); font-variant-numeric:tabular-nums; }
  table.t td.l { font-variant-numeric:normal; color:var(--ink-2); }
  .scroll { overflow-x:auto; }
  .row3 { display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:16px; }
  .barlist { display:flex; flex-direction:column; gap:7px; margin-top:12px; }
  .barlist .r { display:grid; grid-template-columns:130px 1fr 66px; gap:10px; align-items:center; font-size:12.5px; }
  .barlist .r .lbl { color:var(--ink-2); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .barlist .r .bar { height:14px; border-radius:0 3px 3px 0; background:var(--s-cread); min-width:2px; }
  .barlist .r .val { text-align:right; font-variant-numeric:tabular-nums; }
  .callout { border-left:3px solid var(--s-cwrite); }
  .ledger  { border-left:3px solid var(--s-cread); }
  /* live controls (bundle mode only) */
  .bar-live { display:flex; flex-wrap:wrap; align-items:center; gap:12px; padding:10px 14px;
    border:1px solid var(--ring); background:var(--surface); border-radius:10px; font-size:13px; }
  .bar-live button, .bar-live select { font:inherit; color:var(--ink); background:var(--page);
    border:1px solid var(--ring); border-radius:7px; padding:5px 12px; cursor:pointer; }
  .bar-live button:hover { border-color:var(--s-cread); }
  .bar-live button:focus-visible, .bar-live select:focus-visible { outline:2px solid var(--s-cread); outline-offset:2px; }
  .stamp { color:var(--muted); font-variant-numeric:tabular-nums; }
  .pulse { display:inline-block; width:8px; height:8px; border-radius:50%; background:var(--s-out); }
  .pulse.off { background:var(--muted); }
  .pulse.err { background:#d03b3b; }
  #tip { position:fixed; pointer-events:none; background:var(--surface); border:1px solid var(--ring);
    border-radius:8px; padding:8px 12px; font-size:12.5px; box-shadow:0 4px 16px rgba(0,0,0,.18);
    opacity:0; transition:opacity 80ms; z-index:10; font-variant-numeric:tabular-nums; max-width:300px; }
  @media (prefers-reduced-motion: reduce) { #tip { transition:none; } }
  #tip .t { font-weight:600; margin-bottom:3px; }
  #tip .l { color:var(--ink-2); }
  @media (max-width:640px) { .hero-num { font-size:34px; } .barlist .r { grid-template-columns:100px 1fr 60px; } }
</style>
CSS
}

emit_renderer() {
cat <<'JS'
/* Deliberately money-free. An earlier build priced every call from an API rate card and
   led with a dollar total; it was pulled because Claude Code usage on a subscription is not
   billed that way, and a dollar headline reads as a bill no matter how it is captioned.
   Tokens and context are what this measures, so tokens are what it shows. */

const f = n => (n || 0).toLocaleString("en-IN");
const pct = (a,b) => b ? (a/b*100) : 0;
const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

function render(DATA, root) {
  const T = DATA.totals, C = DATA.calls, K = DATA.compact, o = [];
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
      ${K?`<span class="chip">compact <b>${esc(K.t)}</b> (${esc(K.trigger)})</span>`:``}
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

  if (K) {
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
JS
}

# ---------------------------------------------------------------- inline mode
if [ "$MODE" = "inline" ]; then
  [ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/tokenomics-${SHORT}.html"
  {
    echo "<title>Session Tokenomics</title>"
    emit_style
    echo '<div class="wrap" id="app"></div>'
    echo '<div id="tip" role="status"></div>'
    echo '<script>'
    emit_renderer
    echo 'const DATA ='
    measure
    echo ';'
    echo 'render(DATA, document.getElementById("app"));'
    echo '</script>'
  } > "$OUT"
  echo "$OUT"
  exit 0
fi

# ---------------------------------------------------------------- bundle mode
[ -n "$DIR" ] || DIR="$HOME/.claude/tokenomics/$SHORT"
mkdir -p "$DIR"

measure > "$DIR/data.json"
cp "$DIR/data.json" "$DIR/data-$SHORT.json"

# --- session picker -------------------------------------------------------------------
# Titles are pulled with grep, not jq: finding one small record in a 250 MB transcript by
# parsing every line takes seconds, grepping takes milliseconds.
title_of() {
  local f="$1" ct at sl
  ct=$(grep -a -o '"customTitle":"[^"]*"' "$f" 2>/dev/null | tail -1 | cut -d'"' -f4)
  at=$(grep -a -o '"aiTitle":"[^"]*"'     "$f" 2>/dev/null | tail -1 | cut -d'"' -f4)
  sl=$(grep -a -o '"slug":"[^"]*"'        "$f" 2>/dev/null | tail -1 | cut -d'"' -f4)
  if [ -n "$ct" ] && [ -n "$at" ]; then printf '%s — %s' "$ct" "$at"
  elif [ -n "$ct" ]; then printf '%s' "$ct"
  elif [ -n "$at" ]; then printf '%s' "$at"
  else printf '%s' "${sl:-untitled}"; fi
}

PDIR=$(dirname "$F")

# Readable project label: strip the machine-specific path prefix the slug encodes.
# Slugged project dirs start with the slugged $HOME, which differs per OS and per user
# (-Users-alice on macOS, -home-alice on Linux). Derive it rather than hardcoding either.
proj_label() {
  home_slug=$(printf '%s' "$HOME" | sed 's#[/.]#-#g')
  basename "$1" | sed "s#^${home_slug}-Projects-##; s#^-private-var-folders-.*-T-#tmp:#; s#^${home_slug}-##"
}

# Which transcripts go in the picker: this project only, or the N newest of EVERY project.
# A function, not a straight-line block, because --watch has to rebuild it: `/clear` mints a
# NEW transcript file, and a picker built once at startup can never show a session that did
# not exist yet. Pass "quiet" to suppress the banner on refresh ticks.
build_sessions_json() {
  local quiet="${1:-}"
  if [ "$ALLPROJ" = "1" ]; then
    CANDIDATES=$(for pd in "$PROJ_ROOT"/*/; do ls -t "$pd"*.jsonl 2>/dev/null | head -"$NSESS"; done)
    [ -n "$quiet" ] || echo "generating picker data: up to $NSESS sessions × $(ls -d "$PROJ_ROOT"/*/ | wc -l | tr -d ' ') projects…" >&2
  else
    CANDIDATES=$(ls -t "$PDIR"/*.jsonl 2>/dev/null | head -"$NSESS")
    [ -n "$quiet" ] || {
      echo "generating picker data for up to $NSESS sessions of $(proj_label "$PDIR")…" >&2
      echo "  (add --all-projects to include every project, --sessions N for more)" >&2
    }
  fi

{
  echo '['
  first=1
  for t in $CANDIDATES; do
    id=$(basename "$t" .jsonl); s=${id%%-*}
    # Finished sessions never change, so their data is generated once and reused across runs.
    # Always regenerate the targeted session — that is the one still growing.
    if [ ! -s "$DIR/data-$s.json" ] || [ "$s" = "$SHORT" ]; then
      ( F="$t"; measure ) > "$DIR/data-$s.tmp" 2>/dev/null \
        && mv "$DIR/data-$s.tmp" "$DIR/data-$s.json" || rm -f "$DIR/data-$s.tmp"
    fi
    [ -s "$DIR/data-$s.json" ] || continue
    # Some transcripts open with a record that carries no timestamp, so scan a few lines
    # for the first one that does rather than showing a blank date.
    started=$(head -40 "$t" 2>/dev/null | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | head -1)
    # stat is BSD on macOS, GNU on Linux — try both spellings before giving up.
    [ -n "$started" ] || started=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$t" 2>/dev/null \
      || stat -c '%y' "$t" 2>/dev/null | cut -c1-19 | tr ' ' 'T')
    [ $first -eq 1 ] || echo ','
    first=0
    jq -n --arg id "$s" --arg full "$id" --arg title "$(title_of "$t")" \
          --arg started "$started" --arg primary "$( [ "$s" = "$SHORT" ] && echo yes || echo no )" \
          --arg project "$(proj_label "$(dirname "$t")")" \
          --slurpfile d "$DIR/data-$s.json" \
      '{id:$id, full:$full, title:$title, started:$started, project:$project,
        primary:($primary=="yes"), calls:($d[0].totals.calls), tokens:($d[0].totals.total)}'
  done
  echo ']'
} > "$DIR/sessions.json.tmp" && mv "$DIR/sessions.json.tmp" "$DIR/sessions.json"
  [ -n "$quiet" ] || echo "picker: $(jq 'length' "$DIR/sessions.json") sessions" >&2
}

build_sessions_json

{
  # Standalone page: it owns its own <head>, so it must declare the encoding itself.
  # (The inline/artifact path omits this — that skeleton is supplied at publish time.)
  echo '<meta charset="utf-8">'
  echo '<meta name="viewport" content="width=device-width, initial-scale=1">'
  echo "<title>Session Tokenomics — live</title>"
  emit_style
  cat <<'SHELL'
<div class="wrap">
  <div class="bar-live">
    <span class="pulse off" id="pulse"></span>
    <label>session <select id="sess"></select></label>
    <button id="refresh" type="button">Refresh now</button>
    <label>auto
      <select id="every">
        <option value="0">off</option>
        <option value="10">10s</option>
        <option value="30" selected>30s</option>
        <option value="60">1m</option>
        <option value="300">5m</option>
      </select>
    </label>
    <span class="stamp" id="stamp">loading&hellip;</span>
  </div>
  <div id="app"></div>
</div>
<div id="tip" role="status"></div>
<script>
SHELL
  emit_renderer
  cat <<'LIVE'

/* ---------------- session picker + live refresh ---------------- */
const app   = document.getElementById("app");
const pulse = document.getElementById("pulse");
const stamp = document.getElementById("stamp");
const every = document.getElementById("every");
const sess  = document.getElementById("sess");
let timer = null, lastThrough = null, primaryId = null;

const nf = n => (n||0).toLocaleString("en-IN");

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
    sess.innerHTML = ordered.map(([g, ss]) =>
      `<optgroup label="${g} (${ss.length})">` +
      ss.sort((a,b) => b.started.localeCompare(a.started)).map(s =>
        `<option value="${s.id}"${s.primary?" selected":""}>${s.started.slice(0,10)} · ${s.title}` +
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
LIVE
} > "$DIR/index.html"

if [ "$SERVE" != "0" ]; then
  if command -v python3 >/dev/null; then
    ( cd "$DIR" && python3 -m http.server "$SERVE" >/dev/null 2>&1 ) &
    echo "serving  http://localhost:$SERVE/  (pid $!)"
  else
    echo "tokenomics: python3 not found — serve $DIR yourself" >&2
  fi
fi

echo "$DIR/index.html"

if [ "$WATCH" != "0" ]; then
  if [ "$AUTOFOLLOW" = "1" ]; then
    echo "watching $F (auto-following newest) — every ${WATCH}s (Ctrl-C to stop)"
  else
    echo "watching $F — regenerating data.json every ${WATCH}s (Ctrl-C to stop)"
  fi
  while true; do
    sleep "$WATCH"

    # Re-resolve first: a new session (or a new project transcript) must be able to enter the
    # picker mid-watch. resolve_transcript exits non-zero if the project has no transcripts;
    # in a loop that must not kill the watcher, so keep the previous target on failure.
    if [ "$AUTOFOLLOW" = "1" ]; then
      NEWF=$(resolve_transcript 2>/dev/null) || NEWF=""
      if [ -n "$NEWF" ] && [ "$NEWF" != "$F" ]; then
        F="$NEWF"; SESSION=$(basename "$F" .jsonl); SHORT=${SESSION%%-*}; PDIR=$(dirname "$F")
        echo "→ following new session $SHORT ($(title_of "$F"))"
        build_sessions_json quiet
      fi
    fi

    # Only the targeted session is re-measured — the others are finished and cannot change.
    if measure > "$DIR/data-$SHORT.tmp" 2>/dev/null; then
      mv "$DIR/data-$SHORT.tmp" "$DIR/data-$SHORT.json"
      cp "$DIR/data-$SHORT.json" "$DIR/data.json"
    else
      rm -f "$DIR/data-$SHORT.tmp"
    fi
  done
fi
