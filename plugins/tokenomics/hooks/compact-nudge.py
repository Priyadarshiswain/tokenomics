#!/usr/bin/env python3
"""compact-nudge.py — Stop hook. Says "/compact" each time context climbs another 150k.

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
It speaks once per 150k of context — at 150k, 300k, 450k — and not on the turns in
between. A compact drops the context and re-arms the ladder. A nag on every message would
be noise, and noise in a plugin about wasted tokens would be self-defeating.
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
    nudge_at = int(nudge_at) if nudge_at.isdigit() and int(nudge_at) > 0 else 150000

    # A LADDER, not a one-shot. Speaking once at 150k and then never again is useless in a
    # session that reaches 500k -- the argument for compacting only gets stronger as the
    # context grows, so the reminder should keep pace. `level` is how many whole multiples
    # of the threshold the context has passed: 150k -> 1, 310k -> 2, 460k -> 3.
    level = ctx // nudge_at

    # ---- speak only when a new rung is reached -------------------------------
    # State is per transcript, so /clear starts clean. Storing the rung NUMBER rather than
    # a been-here flag does two jobs at once: it fires again on each new multiple, and it
    # re-arms after a compact, because context falls, the rung falls, and climbing back
    # crosses a rung again.
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

    # Escalate on ARITHMETIC, not adjectives. Each rung is a genuinely larger number, so
    # the facts carry the urgency; louder wording would just read as nagging, and nagging
    # is the failure mode a plugin about wasted tokens can least afford.
    cut = ctx * 67 // 100
    if level >= 3:
        msg = (f"⚠ context {human(ctx)} — {level}× past the point where a compact starts "
               f"paying for itself, and this is reminder {level}. Every call re-sends all "
               f"of it, and any turn boundary re-files the lot at 2×. A /compact would "
               f"take about {human(cut)} off every call from here on.")
    elif level == 2:
        msg = (f"◆ context {human(ctx)} — still climbing, and this is the second reminder. "
               f"Every call now re-sends {human(ctx)}; a /compact would cut about "
               f"{human(cut)} of that from all of them.")
    else:
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
