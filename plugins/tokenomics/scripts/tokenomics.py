#!/usr/bin/env python3
"""tokenomics.py — measure a Claude Code session transcript and render it as HTML.

Deterministic: same transcript in -> byte-identical output. No wall-clock reads in the
measurement, no randomness, no network.

TWO OUTPUT MODES
  bundle (default)  a directory with index.html + data.json. The page fetches data.json,
                    has a Refresh button and an auto-refresh timer. Live, local.
  --inline          one self-contained .html with the data baked in. Use this for
                    publishing as an Artifact (artifact CSP blocks all fetches).

This is a port of tokenomics.sh. Two things drove it: the incremental parser was regex
over raw JSONL lines, and `jq` is a hard dependency that macOS does not ship while it does
ship python3. The status line and the Stop hook stay in bash on purpose -- measured,
python3 startup is ~23ms against bash's ~3ms, which is the wrong trade for something that
runs on every assistant message.

Byte-identical `--json` output against the bash version is enforced by tests/run.sh.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
PROJ_ROOT = HOME / ".claude" / "projects"
ASSETS = Path(__file__).resolve().parent / "assets"

USAGE = """\
tokenomics.py — measure a Claude Code session transcript and render it as HTML.

usage:
  tokenomics                             newest session of the CURRENT project
  tokenomics <session-id>                a specific session (searched everywhere)
  tokenomics /path/to/x.jsonl            an explicit transcript
  tokenomics --list                      recent sessions of the current project
  tokenomics --projects                  every project: sizes, date ranges
  tokenomics --project <path|slug>       target another project
  tokenomics --sessions N                how many sessions --list / the picker offers
  tokenomics --all-projects              picker spans EVERY project, not just this one
  tokenomics -d DIR                      choose the bundle directory
  tokenomics --watch N                   regenerate data.json every N seconds (foreground)
  tokenomics --serve PORT                serve the bundle at http://localhost:PORT/
  tokenomics --watch 30 --serve 8899     live local dashboard
  tokenomics --inline -o page.html       one self-contained .html, for publishing
  tokenomics --json                      just the measured data
  tokenomics --statusline                show whether the status line is configured
  tokenomics --statusline init           configure it in ~/.claude/settings.json
  tokenomics --statusline init --force   overwrite an existing statusLine

Bundle mode (the default) writes index.html + data.json with a session picker and an
auto-refresh timer; serve it over http — file:// blocks fetch. --inline bakes the data
into a single file, which is what publishing as an Artifact needs.

A plugin cannot ship a statusLine (plugin settings.json honours only `agent` and
`subagentStatusLine`), so --statusline init writes the block for you. It backs up
settings.json first and refuses to overwrite an existing statusLine without --force.

--serve needs nothing beyond python3. Deterministic: same transcript in, same bytes out.
"""


def die(msg, code=1):
    print(f"tokenomics: {msg}", file=sys.stderr)
    sys.exit(code)


# ============================================================== transcript I/O ==

def read_records(path):
    """Parse a transcript. Malformed lines are skipped rather than aborting the run --
    a transcript being written to right now can end mid-line."""
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
    return out


def slugdir(path):
    return PROJ_ROOT / re.sub(r"[^A-Za-z0-9]", "-", str(path))


def project_dir(explicit=None):
    """Resolve, in order: --project, $CLAUDE_PROJECT_DIR, $PWD -- each treated as a
    WORKING directory and slugged -- and only failing all that, the most recently
    touched project on the machine."""
    if explicit:
        p = Path(explicit)
        if p.is_dir() and (p.parent == PROJ_ROOT):
            return p
        d = slugdir(explicit)
        if d.is_dir():
            return d
        if not os.path.isabs(explicit) and (PROJ_ROOT / explicit).is_dir():
            return PROJ_ROOT / explicit
        die(f"no project matching '{explicit}' under {PROJ_ROOT}")
    p = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    pp = Path(p)
    if pp.is_dir() and any(pp.glob("*.jsonl")):      # already a transcript dir
        return pp
    # NOT `PROJ_ROOT / p`: pathlib discards the left side when the right is absolute,
    # so an absolute cwd would "match" here and be returned as a transcript directory.
    if not os.path.isabs(p) and (PROJ_ROOT / p).is_dir():   # a bare slug
        return PROJ_ROOT / p
    d = slugdir(p)                                   # a working directory
    if d.is_dir():
        return d
    # Last resort — and say so: silently measuring the wrong project would produce
    # perfectly plausible numbers with nothing to flag them as someone else's.
    print(f"tokenomics: no transcripts found for '{p}' — falling back to the most "
          "recently used project", file=sys.stderr)
    dirs = [x for x in PROJ_ROOT.glob("*") if x.is_dir()]
    if not dirs:
        die(f"no transcripts under {PROJ_ROOT}")
    return max(dirs, key=lambda x: x.stat().st_mtime)


def newest_in(d):
    files = sorted(Path(d).glob("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)
    return files[0] if files else None


def resolve_transcript(arg, explicit_project):
    if arg:
        p = Path(arg)
        if p.is_file():
            return p
        hits = sorted(PROJ_ROOT.glob(f"*/{arg}*.jsonl"))
        if hits:
            return hits[0]
        die(f"no transcript matching '{arg}' under {PROJ_ROOT}")
    d = project_dir(explicit_project)
    f = newest_in(d)
    if not f:
        die(f"no transcripts under {d}")
    return f


# ================================================================= measurement ==

def _epoch(ts):
    """jq's: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601"""
    if not ts:
        return 0
    s = re.sub(r"\.[0-9]+Z$", "Z", ts)
    try:
        return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=timezone.utc).timestamp())
    except ValueError:
        return 0


def _short_model(m):
    m = m or "?"
    m = re.sub(r"^claude-", "", m)
    return re.sub(r"-[0-9]{8}$", "", m)


def _usage(rec, key):
    return (rec.get("message") or {}).get("usage", {}).get(key, 0) or 0


def _cc(rec, key):
    cc = ((rec.get("message") or {}).get("usage") or {}).get("cache_creation") or {}
    return cc.get(key, 0) or 0


def _last_of(records, pred, field):
    val = None
    for r in records:
        if pred(r):
            v = r.get(field)
            if v is not None:
                val = v
    return val


def measure(path):
    """Deduped by message.id: the transcript re-writes the same assistant message while
    streaming, so a naive sum roughly doubles every figure."""
    allrecs = read_records(path)

    # tool_use id -> tool name, for labelling the biggest tool outputs
    tname = {}
    for r in allrecs:
        if r.get("type") != "assistant":
            continue
        content = (r.get("message") or {}).get("content") or []
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    tname[c.get("id")] = c.get("name")

    cbs = [r for r in allrecs
           if r.get("type") == "system" and r.get("subtype") == "compact_boundary"]

    raw = [r for r in allrecs if (r.get("message") or {}).get("usage") is not None]

    # jq: group_by(.message.id) | map(.[-1]) | sort_by(.timestamp)
    # group_by sorts by the key, and both group_by and sort_by are STABLE, so ties in
    # timestamp fall back to message-id order. Replicated exactly: keep the last record
    # per id, order by id, then stable-sort by timestamp.
    bykey = {}
    for r in raw:
        bykey[(r.get("message") or {}).get("id")] = r
    u = sorted(bykey.values(), key=lambda r: str((r.get("message") or {}).get("id")))
    u.sort(key=lambda r: r.get("timestamp") or "")

    calls = []
    for r in u:
        ts = r.get("timestamp") or ""
        calls.append({
            "ts": ts,
            "t": ts[11:16],
            "model": _short_model((r.get("message") or {}).get("model")),
            "cr": _usage(r, "cache_read_input_tokens"),
            "cw": _usage(r, "cache_creation_input_tokens"),
            # split the write by TTL: 1h costs 2x base, 5m only 1.25x -- pricing them the
            # same would overstate any session that uses short-lived cache
            "cw1h": _cc(r, "ephemeral_1h_input_tokens"),
            "cw5m": _cc(r, "ephemeral_5m_input_tokens"),
            "out": _usage(r, "output_tokens"),
            "inp": _usage(r, "input_tokens"),
            "stop": (r.get("message") or {}).get("stop_reason") or "",
        })

    # One entry per compact boundary: the index of the first call after it. Sessions
    # compact more than once; measuring only the first misattributes every later one.
    cidxs = []
    for b in cbs:
        bt = b.get("timestamp") or ""
        idx = next((i for i, c in enumerate(calls) if c["ts"] > bt), -1)
        cidxs.append(idx)

    # Idle-expiry threshold follows the TTL this session actually bought: a 5-minute
    # cache dies in 5 minutes, a 1-hour one in 60.
    ttl_min = 60 if sum(_cc(r, "ephemeral_1h_input_tokens") for r in u) > 0 else 5

    C = []
    for i, c in enumerate(calls):
        p = calls[i - 1] if i > 0 else None
        gap = 0 if p is None else (_epoch(c["ts"]) - _epoch(p["ts"])) // 60
        rebuild = False if p is None else (c["cw"] > 10000 and c["cr"] < p["cr"] * 0.7)
        e = dict(c)
        e["i"] = i
        e["gapMin"] = gap
        e["rebuild"] = rebuild
        if not rebuild:
            cause = None
        elif i in cidxs:
            cause = "compact"
        elif p is not None and c["model"] != p["model"]:
            cause = "model switch"
        elif gap >= ttl_min:
            cause = f"idle gap — cache TTL expiry ({gap}m)"
        elif p is not None and p["stop"] == "end_turn":
            cause = f"turn boundary (after {gap}m idle)" if gap >= 10 else "turn boundary"
        else:
            cause = "context rebuild"
        e["cause"] = cause
        C.append(e)

    # Human-readable identity. Precedence: what the user named it > what the model named
    # it > the memorable slug.
    ct = _last_of(allrecs, lambda r: r.get("type") == "custom-title", "customTitle")
    at = _last_of(allrecs, lambda r: r.get("type") == "ai-title", "aiTitle")
    lp = _last_of(allrecs, lambda r: r.get("type") == "last-prompt", "lastPrompt")
    slug = _last_of(allrecs, lambda r: True, "slug")

    def last_field(field, default="-"):
        v = _last_of(allrecs, lambda r: True, field)
        return v if v is not None else default

    tier = None
    for r in u:
        t = ((r.get("message") or {}).get("usage") or {}).get("service_tier")
        if t is not None:
            tier = t

    def group_count(items, key):
        seen, order = {}, []
        for it in items:
            k = key(it)
            if k not in seen:
                seen[k] = 0
                order.append(k)
            seen[k] += 1
        # jq: group_by(x) | map(...) | sort_by(-.n) -- group_by sorts by the key first,
        # then the stable sort by -n preserves that order within equal counts.
        rows = [{"name": k, "n": seen[k]} for k in sorted(order, key=lambda k: str(k))]
        rows.sort(key=lambda r: -r["n"])
        return rows

    compacts = []
    for k, b in enumerate(cbs):
        ci = cidxs[k]
        if ci < 1:
            continue
        md = b.get("compactMetadata") or {}
        compacts.append({
            "t": (b.get("timestamp") or "")[11:16],
            "trigger": md.get("trigger", "?"),
            "preTokens": md.get("preTokens", 0),
            "postTokens": md.get("postTokens", 0),
            "droppedTokens": md.get("cumulativeDroppedTokens", 0),
            "durationMs": md.get("durationMs", 0),
            "callIndex": ci,
            "readBefore": C[ci - 1]["cr"],
            "readAfter": C[ci]["cr"],
            "write": C[ci]["cw"],
            "model": C[ci]["model"],
        })

    rebuilds = [{
        "i": c["i"], "t": c["t"], "cause": c["cause"], "cw": c["cw"],
        "cw1h": c["cw1h"], "cw5m": c["cw5m"], "cr": c["cr"], "model": c["model"],
        "crBefore": C[c["i"] - 1]["cr"] if c["i"] >= 1 else 0,
    } for c in C if c["rebuild"]]

    tools = []
    for r in allrecs:
        if r.get("toolUseResult") is None:
            continue
        content = (r.get("message") or {}).get("content")
        tid = ""
        if isinstance(content, list) and content:
            first = content[0]
            tid = (first.get("tool_use_id") or "") if isinstance(first, dict) else ""
        tools.append({"id": tid,
                      "size": len(_jq_tostring(r["toolUseResult"])),
                      "name": tname.get(tid) or "tool"})
    top = sorted(tools, key=lambda x: -x["size"])[:6]

    return {
        "session": (allrecs[0].get("sessionId") if allrecs else None) or "?",
        "title": ct or at or slug or "untitled",
        "customTitle": ct,
        "aiTitle": at,
        "slug": slug,
        "lastPrompt": lp,
        # "measured through" comes from the data, never the clock -- that is what keeps
        # this deterministic. Re-running on an unchanged transcript reproduces the file.
        "measuredThrough": C[-1]["ts"] if C else "",
        "firstCall": C[0]["ts"] if C else "",
        "entrypoint": last_field("entrypoint"),
        "effort": last_field("effort"),
        "tier": tier if tier is not None else "-",
        "calls": C,
        "totals": {
            "calls": len(C),
            "input": sum(c["inp"] for c in C),
            "output": sum(c["out"] for c in C),
            "cread": sum(c["cr"] for c in C),
            "cwrite": sum(c["cw"] for c in C),
            "cc1h": sum(_cc(r, "ephemeral_1h_input_tokens") for r in u),
            "cc5m": sum(_cc(r, "ephemeral_5m_input_tokens") for r in u),
            "total": sum(c["inp"] + c["out"] + c["cr"] + c["cw"] for c in C),
        },
        "models": group_count(C, lambda c: c["model"]),
        "stops": group_count([c for c in C if c["stop"] != ""], lambda c: c["stop"]),
        "types": group_count(allrecs, lambda r: r.get("type")),
        "subagents": sum(1 for r in allrecs if r.get("isSidechain") is True),
        "compacts": compacts,
        "rebuilds": rebuilds,
        "tools": {"n": len(tools),
                  "bytes": sum(t["size"] for t in tools),
                  "top": [{"name": t["name"], "size": t["size"]} for t in top]},
        "dedup": {"records": len(raw), "unique": len(C)},
    }


def _jq_tostring(v):
    """jq's `tostring`: strings pass through unchanged, everything else is compact JSON.
    The tool-output sizes depend on this, so it has to match jq exactly -- including
    jq's separators, which have no spaces."""
    if isinstance(v, str):
        return v
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def dumps(obj):
    """jq's default output: 2-space indent, ": " separator, raw UTF-8, trailing newline."""
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


# ==================================================================== rendering ==

def asset(name):
    return (ASSETS / name).read_text(encoding="utf-8")


def render_inline(data, out):
    parts = [
        "<title>Session Tokenomics</title>\n",
        asset("report.css"),
        '<div class="wrap" id="app"></div>\n',
        '<div id="tip" role="status"></div>\n',
        "<script>\n",
        asset("report.js"),
        "const DATA =\n",
        dumps(data),
        ";\n",
        'render(DATA, document.getElementById("app"));\n',
        "</script>\n",
    ]
    Path(out).write_text("".join(parts), encoding="utf-8")
    return out


def render_bundle_index(path):
    parts = [
        # Standalone page: it owns its own <head>, so it must declare the encoding itself.
        # (The inline/artifact path omits this — that skeleton is supplied at publish time.)
        '<meta charset="utf-8">\n',
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
        "<title>Session Tokenomics — live</title>\n",
        asset("report.css"),
        asset("shell.html"),
        asset("report.js"),
        asset("live.js"),
    ]
    Path(path).write_text("".join(parts), encoding="utf-8")


# ================================================================ picker/labels ==

def title_of(f):
    """Titles are pulled by scanning bytes, not by parsing: finding one small record in a
    250 MB transcript by parsing every line takes seconds."""
    pats = {k: re.compile(rf'"{k}":"([^"]*)"'.encode()) for k in
            ("customTitle", "aiTitle", "slug")}
    found = {k: None for k in pats}
    try:
        with open(f, "rb") as fh:
            for line in fh:
                for k, rx in pats.items():
                    m = rx.search(line)
                    if m:
                        found[k] = m.group(1).decode("utf-8", "replace")
    except OSError:
        return "untitled"
    ct, at, sl = found["customTitle"], found["aiTitle"], found["slug"]
    if ct and at:
        return f"{ct} — {at}"
    return ct or at or sl or "untitled"


def proj_label(d):
    """Slugged project dirs start with the slugged $HOME, which differs per OS and per
    user (-Users-alice on macOS, -home-alice on Linux). Derive it, never hardcode."""
    home_slug = re.sub(r"[/.]", "-", str(HOME))
    b = Path(d).name
    for pat, rep in ((rf"^{re.escape(home_slug)}-Projects-", ""),
                     (r"^-private-var-folders-.*-T-", "tmp:"),
                     (rf"^{re.escape(home_slug)}-", "")):
        new = re.sub(pat, rep, b)
        if new != b:
            return new
    return b


def first_timestamp(f):
    """Some transcripts open with a record carrying no timestamp, so scan a few lines for
    the first that does rather than showing a blank date."""
    try:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= 40:
                    break
                try:
                    ts = json.loads(line).get("timestamp")
                except ValueError:
                    continue
                if ts:
                    return ts
    except OSError:
        pass
    try:
        return datetime.fromtimestamp(Path(f).stat().st_mtime,
                                      timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        return ""


# ======================================================================= modes ==

def mode_projects():
    print(f'{"sess":>5} {"size":>7}  {"oldest":<10} {"newest":<10}  project')
    rows = []
    for d in sorted(PROJ_ROOT.glob("*")):
        if not d.is_dir():
            continue
        files = list(d.glob("*.jsonl"))
        if not files:
            continue
        dates = sorted(filter(None, (first_timestamp(f) for f in files)))
        # `du -sh` on the whole dir, not just *.jsonl: subagent transcripts live in a
        # subdirectory and are part of what this project costs on disk.
        # st_blocks, not st_size: `du` reports allocated blocks, and matching it keeps
        # this column comparable with what the shell reports for the same directory.
        size = sum(x.stat().st_blocks * 512 for x in d.rglob("*") if x.is_file())
        rows.append((len(files), _human_bytes(size),
                     (dates[0] if dates else "")[:10],
                     (dates[-1] if dates else "")[:10], d.name))
    for n, sz, o, nw, name in sorted(rows, key=lambda r: -r[0]):
        print(f"{n:>5} {sz:>7}  {o:<10} {nw:<10}  {name}")


def _human_bytes(n):
    """`du -sh` formatting: one decimal below 10 units, none at or above."""
    for unit, div in (("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)):
        if n >= div:
            v = n / div
            return f"{v:.0f}{unit}" if v >= 10 else f"{v:.1f}{unit}"
    return f"{n}B"


def mode_list(explicit_project, nsess, nsess_set):
    d = project_dir(explicit_project)
    # A bare --list should show a useful page; an explicit --sessions N means N.
    limit = nsess if nsess_set else 20
    print(f"project: {d}")
    print(f'{"session":<10} {"started (UTC)":<17} {"calls":>7} {"tokens":>12}  title')
    files = sorted(d.glob("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)[:limit]
    rows = []
    for t in files:
        data = measure(t)
        started = (data["firstCall"] or "0000-00-00T00:00")[:16].replace("T", " ")
        rows.append((started, t.stem[:8], data["totals"]["calls"],
                     data["totals"]["total"], title_of(t)[:70]))
    # sort by the column actually shown (start time), newest first -- not by file mtime,
    # which is when the session was last written to and orders the list confusingly.
    for started, sid, calls, tokens, label in sorted(rows, reverse=True):
        print(f"{sid:<10} {started:<17} {calls:>7} {tokens:>12}  {label}")


def mode_statusline(do_init, force):
    """The one piece of setup a plugin cannot do for you.

    Path choice matters and is not obvious: point at the MARKETPLACE clone, which
    `claude plugin marketplace update` refreshes in place, and never at the versioned
    plugin cache, whose directory name changes on every release."""
    plugin_root = Path(__file__).resolve().parent.parent
    settings = HOME / ".claude" / "settings.json"

    sl = None
    for c in sorted((HOME / ".claude/plugins/marketplaces").glob(
            "*/plugins/*/statusline/statusline.py")):
        sl = c
        break
    if sl is None:
        c = plugin_root / "statusline" / "statusline.py"
        sl = c if c.is_file() else None
    if sl is None:
        die("cannot find statusline.py")

    # ABSOLUTE paths, not ~. A shell does not expand ~ inside double quotes, and the
    # quotes are not optional -- program paths contain spaces. An earlier version wrote
    # `"..." "~/.claude/..."` and the status line silently went blank, because the shell
    # handed Python the literal tilde. Nothing here is portable between machines anyway:
    # sys.executable is already an absolute, machine-specific interpreter path.
    #
    # sys.executable rather than a bare "python3" is the point: this is the one place we
    # KNOW the right interpreter, because we are running in it.
    cmd = f'"{sys.executable}" "{sl}"'

    current = ""
    if settings.is_file():
        try:
            current = (json.loads(settings.read_text(encoding="utf-8"))
                       .get("statusLine", {}).get("command", "")) or ""
        except (ValueError, AttributeError):
            current = ""

    if not do_init:
        print(f"script:   {sl}")
        if not current:
            print("settings: no statusLine configured")
            print("run:      tokenomics --statusline init")
        elif current == cmd:
            print("settings: configured, pointing here ✓")
        else:
            print("settings: configured, but pointing elsewhere:")
            print(f"          {current}")
            print("run:      tokenomics --statusline init --force  to repoint it")
        return

    obj = {}
    if settings.is_file():
        try:
            obj = json.loads(settings.read_text(encoding="utf-8"))
        except ValueError:
            die(f"{settings} is not valid JSON — refusing to touch it")
        if not isinstance(obj, dict):
            die(f"{settings} is not a JSON object — refusing to touch it")
    if current and current != cmd and not force:
        print(f"tokenomics: a statusLine is already configured:\n  {current}\n"
              "re-run with --force to replace it", file=sys.stderr)
        sys.exit(1)

    settings.parent.mkdir(parents=True, exist_ok=True)
    if not settings.is_file():
        settings.write_text("{}\n", encoding="utf-8")
    # Always back up, including the {} we just created: the message promises a backup
    # path, and printing one that does not exist is worse than not offering it.
    shutil.copyfile(settings, str(settings) + ".tokenomics-bak")

    obj["statusLine"] = {"type": "command", "command": cmd, "padding": 0}
    # tmp + replace so an interrupted write cannot leave settings.json truncated.
    tmp = str(settings) + f".tokenomics-tmp.{os.getpid()}"
    try:
        Path(tmp).write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n",
                             encoding="utf-8")
        os.replace(tmp, settings)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"failed to update {settings} (left unchanged)")
    print(f"configured {settings}")
    print(f"  statusLine → {cmd}")
    print(f"  backup     → {settings}.tokenomics-bak")
    print("Takes effect on your next interaction with Claude Code.")


def build_sessions_json(dirpath, f, short, allproj, nsess, quiet=False):
    """Which transcripts go in the picker. Rebuilt on every --watch tick because
    `/clear` mints a NEW transcript file, and a picker built once at startup could never
    show a session that did not exist yet."""
    pdir = Path(f).parent
    if allproj:
        cands = []
        for pd in sorted(PROJ_ROOT.glob("*")):
            if pd.is_dir():
                cands += sorted(pd.glob("*.jsonl"),
                                key=lambda x: x.stat().st_mtime, reverse=True)[:nsess]
        if not quiet:
            n = len([d for d in PROJ_ROOT.glob('*') if d.is_dir()])
            print(f"generating picker data: up to {nsess} sessions × {n} projects…",
                  file=sys.stderr)
    else:
        cands = sorted(pdir.glob("*.jsonl"),
                       key=lambda x: x.stat().st_mtime, reverse=True)[:nsess]
        if not quiet:
            print(f"generating picker data for up to {nsess} sessions of "
                  f"{proj_label(pdir)}…", file=sys.stderr)
            print("  (add --all-projects to include every project, --sessions N for more)",
                  file=sys.stderr)

    out = []
    for t in cands:
        sid = t.stem
        s = sid.split("-")[0]
        dj = Path(dirpath) / f"data-{s}.json"
        # Finished sessions never change, so their data is generated once and reused.
        # Always regenerate the targeted session — that is the one still growing.
        if not dj.exists() or dj.stat().st_size == 0 or s == short:
            try:
                dj.write_text(dumps(measure(t)), encoding="utf-8")
            except Exception:
                continue
        try:
            d = json.loads(dj.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        out.append({"id": s, "full": sid, "title": title_of(t),
                    "started": first_timestamp(t), "project": proj_label(t.parent),
                    "primary": s == short,
                    "calls": d["totals"]["calls"], "tokens": d["totals"]["total"]})
    tmp = Path(dirpath) / "sessions.json.tmp"
    tmp.write_text(dumps(out), encoding="utf-8")
    os.replace(tmp, Path(dirpath) / "sessions.json")
    if not quiet:
        print(f"picker: {len(out)} sessions", file=sys.stderr)


def port_answers(port):
    """Probe BOTH loopback families before binding. We bind 127.0.0.1, so a stale server
    on ::1 (or an IPv6 wildcard) would not collide — both binds succeed, yet browsers
    resolve localhost to ::1 first and silently get the stale data."""
    import socket
    for fam, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            s = socket.socket(fam, socket.SOCK_STREAM)
            s.settimeout(0.5)
            s.connect((addr, port))
            s.close()
            return True
        except OSError:
            pass
    return False


# ======================================================================== main ==

def main(argv):
    mode, out, dirp, watch, serve = "bundle", "", "", 0, 0
    arg = project = ""
    nsess, nsess_set, allproj = 6, False, False
    sl_init = force = False

    def need(flag, i):
        # Value-taking flags must verify the value exists before consuming it, or a
        # trailing flag silently swallows nothing and the loop misbehaves.
        if i + 1 >= len(argv):
            die(f"{flag} requires a value")
        return argv[i + 1]

    def need_num(flag, i):
        v = need(flag, i)
        if not v.isdigit():
            die(f"{flag} expects a number, got '{v}'")
        return int(v)

    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--inline":
            mode = "inline"; i += 1
        elif a == "--json":
            mode = "json"; i += 1
        elif a == "--list":
            mode = "list"; i += 1
        elif a == "--projects":
            mode = "projects"; i += 1
        elif a == "--all-projects":
            allproj = True; i += 1
        elif a == "--project":
            project = need(a, i); i += 2
        elif a == "--sessions":
            nsess = need_num(a, i); nsess_set = True; i += 2
        elif a == "-o":
            out = need(a, i); i += 2
        elif a == "-d":
            dirp = need(a, i); i += 2
        elif a == "--watch":
            watch = need_num(a, i); i += 2
        elif a == "--serve":
            serve = need_num(a, i); i += 2
        elif a == "--statusline":
            mode = "statusline"; i += 1
            if i < len(argv) and argv[i] == "init":
                sl_init = True; i += 1
        elif a == "--force":
            force = True; i += 1
        elif a in ("-h", "--help"):
            sys.stdout.write(USAGE); return 0
        else:
            arg = a; i += 1

    if mode == "statusline":
        mode_statusline(sl_init, force); return 0
    if mode == "projects":
        mode_projects(); return 0
    if mode == "list":
        mode_list(project, nsess, nsess_set); return 0

    f = resolve_transcript(arg, project)
    short = Path(f).stem.split("-")[0]
    # With no explicit target, --watch follows whatever the newest transcript is, so a
    # `/clear` (which mints a new file) moves the dashboard onto the new session.
    autofollow = not arg

    if mode == "json":
        sys.stdout.write(dumps(measure(f))); return 0

    if mode == "inline":
        dest = out or os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                   f"tokenomics-{short}.html")
        print(render_inline(measure(f), dest)); return 0

    # ------------------------------------------------------------- bundle mode
    d = Path(dirp) if dirp else HOME / ".claude" / "tokenomics" / short
    d.mkdir(parents=True, exist_ok=True)
    data = measure(f)
    (d / "data.json").write_text(dumps(data), encoding="utf-8")
    shutil.copyfile(d / "data.json", d / f"data-{short}.json")
    build_sessions_json(d, f, short, allproj, nsess)
    render_bundle_index(d / "index.html")
    print(d / "index.html")

    if serve:
        if port_answers(serve):
            print(f"tokenomics: something is already answering on port {serve} — likely a "
                  f"dashboard from an earlier run. Stop it first "
                  f"(lsof -nP -iTCP:{serve} -sTCP:LISTEN) or pick another port with "
                  f"--serve. The bundle at {d} is still valid.", file=sys.stderr)
        else:
            # Loopback only: transcripts are private, and the default is EVERY interface —
            # that would offer this machine's session data to the whole LAN.
            proc = subprocess.Popen(
                [sys.executable, "-m", "http.server", "--bind", "127.0.0.1", str(serve)],
                cwd=str(d), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(1)
            if proc.poll() is None:
                print(f"serving  http://localhost:{serve}/  (pid {proc.pid})")
            else:
                print(f"tokenomics: could not serve on port {serve} — already in use? "
                      f"The bundle at {d} is still valid.", file=sys.stderr)

    if watch:
        target = f
        print(f"watching {target}"
              f"{' (auto-following newest)' if autofollow else ''} — every {watch}s "
              f"(Ctrl-C to stop)", file=sys.stderr)
        try:
            while True:
                time.sleep(watch)
                if autofollow:
                    nf = newest_in(Path(f).parent)
                    if nf:
                        target = nf
                sh = Path(target).stem.split("-")[0]
                (d / "data.json").write_text(dumps(measure(target)), encoding="utf-8")
                shutil.copyfile(d / "data.json", d / f"data-{sh}.json")
                build_sessions_json(d, target, sh, allproj, nsess, quiet=True)
        except KeyboardInterrupt:
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
