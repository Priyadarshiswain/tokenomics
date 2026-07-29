#!/usr/bin/env python3
"""compact-nudge.py — Stop hook. Says "/compact" once, when it starts being worth it.

WHY A HOOK AND NOT THE STATUS LINE
The status line renders in the terminal only; the desktop app has no surface for it.
Hooks run everywhere, and unlike `statusLine` they ship with the plugin, so there is no
manual settings.json step. Stop fires when Claude finishes a turn — the same moment the
status line would have refreshed.

WHY IT READS THE TRANSCRIPT
Stop hooks do NOT receive context-window usage on stdin (the status-line payload does).
So context size is recomputed here as input + cache_read + cache_creation of the last
call, which is exactly how Claude Code derives its own context figure.

WHY IT IS QUIET
It speaks only when a threshold is CROSSED, not on every turn, and it re-arms when a
compact drops context back down. A nag on every message would be noise, and noise in a
plugin about wasted tokens would be self-defeating.
"""
import json
import os
import re
import sys
from pathlib import Path


def main():
    if os.environ.get("TOKENOMICS_NUDGE", "on") == "off":
        return 0

    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0

    f = payload.get("transcript_path")
    if not f or not Path(f).is_file():
        return 0

    # ---- context size, without reading the whole file ------------------------
    # Transcripts reach hundreds of MB. Read a bounded tail and take the last complete
    # usage-bearing line. A truncated first line in the window is harmless: only the LAST
    # match is used.
    window = os.environ.get("TOKENOMICS_NUDGE_WINDOW") or "262144"
    window = int(window) if window.isdigit() else 262144
    try:
        size = os.path.getsize(f)
        with open(f, "rb") as fh:
            fh.seek(max(0, size - window))
            tail = fh.read()
    except OSError:
        return 0

    last = None
    for line in tail.split(b"\n"):
        if b'"usage"' in line:
            last = line
    if last is None:
        return 0

    try:
        rec = json.loads(last.decode("utf-8", "replace"))
        u = (rec.get("message") or {}).get("usage") or {}
        ctx = ((u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
               + (u.get("cache_creation_input_tokens") or 0))
    except ValueError:
        # The tail can start mid-record; fall back to reading the numbers off the line.
        def n(key):
            m = re.search(rb'"' + key + rb'":([0-9]+)', last)
            return int(m.group(1)) if m else 0
        ctx = (n(b"input_tokens") + n(b"cache_read_input_tokens")
               + n(b"cache_creation_input_tokens"))
    if ctx <= 0:
        return 0

    # ---- one tier, absolute, COST only ---------------------------------------
    # The status line has a second and more urgent tier keyed on % of the context window:
    # room left, plus the point where a long context starts costing recall as well as
    # tokens. That tier cannot exist here — the status line is handed
    # .context_window.context_window_size, but no hook payload carries it and it is not in
    # the transcript either.
    #
    # The alternatives were both worse than doing without. A hardcoded constant is wrong
    # for somebody: a live opus-5 session measured here sat at 234k, which a 200k
    # assumption would have called 117%. Inferring the window from observed usage
    # false-alarms in the dangerous direction — at 140k on a fresh 1M-window session it
    # would assume 200k, call it 70%, and shout about a session sitting at 14%.
    #
    # So this makes the one argument it can make honestly: rent. 150k of context costs the
    # same on every call whether the window is 200k or 1M.
    nudge_at = os.environ.get("TOKENOMICS_NUDGE_AT") or "150000"
    nudge_at = int(nudge_at) if nudge_at.isdigit() else 150000
    level = 1 if ctx >= nudge_at else 0

    # ---- speak only on a crossing --------------------------------------------
    # State is per transcript, so /clear starts clean. Storing the level (not a flag) is
    # what re-arms the nudge after a compact: context falls, level falls, and the next
    # climb crosses again.
    stated = Path(os.environ.get("CLAUDE_PLUGIN_DATA")
                  or (Path.home() / ".claude" / ".tokenomics-statusline"))
    try:
        stated.mkdir(parents=True, exist_ok=True)
        nf = stated / (Path(f).stem + ".nudge")
        seen = 0
        if nf.is_file():
            t = nf.read_text(encoding="utf-8", errors="replace").strip()
            seen = int(t) if t.isdigit() else 0
        if level != seen:
            nf.write_text(str(level), encoding="utf-8")
    except OSError:
        seen = 0
    if level <= seen:
        return 0

    cut = ctx * 67 // 100
    msg = (f"◆ context {human(ctx)} — a /compact here would cut about {human(cut)} from "
           f"every call that follows (measured cut ≈67%). It repays over the calls "
           f"remaining, so it is worth doing while there are some.")
    sys.stdout.write(json.dumps({"systemMessage": msg}, ensure_ascii=False) + "\n")
    return 0


def human(n):
    n = int(n or 0)
    if n >= 1_000_000:
        return f"{n/1e6:.1f}M"
    if n >= 1000:
        return f"{n/1e3:.0f}k"
    return str(n)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # A Stop hook must never be the reason a turn fails.
        sys.exit(0)
