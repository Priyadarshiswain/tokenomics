#!/usr/bin/env python3
"""statusline.py — the four token classes Claude Code does NOT show you, a context-window
bar, and a compact nudge.

Ported from statusline.sh. The bash version spawned ten `jq` processes per render; this
does the same work in one process. It keeps the SAME state-file format, so switching over
does not reset anyone's accumulated session totals.

Verified against claude-code 2.1.220 status-line payload.
  .context_window.current_usage  = the LAST call only
Deliberately money-free: no rate card, no dollars. Tokens and context only.
Session totals are NOT in the payload, so we read the transcript — incrementally, by byte
offset, so a 265 MB file costs the same per tick as a 2 MB one.
"""
import json
import os
import re
import sys
from pathlib import Path

HOME = Path.home()
STATED = HOME / ".claude" / ".tokenomics-statusline"


# ---- colour ------------------------------------------------------------------
# Claude Code captures stdout, so isatty() is always False and cannot be the test.
# Assume ANSI works, and back off only where it demonstrably does not: NO_COLOR, or a
# legacy Windows console (Windows Terminal, ConEmu and VS Code all advertise themselves).
def _use_colour():
    if os.environ.get("NO_COLOR"):
        return False
    if os.name == "nt":
        return bool(os.environ.get("WT_SESSION") or os.environ.get("ANSICON")
                    or os.environ.get("TERM") or os.environ.get("TERM_PROGRAM"))
    return True


if _use_colour():
    DIM, R, B = "\033[2m", "\033[0m", "\033[1m"
    GRN, AMB, RED = "\033[32m", "\033[33m", "\033[31m"
    CYA, MAG, BLU = "\033[36m", "\033[35m", "\033[34m"
else:
    DIM = R = B = GRN = AMB = RED = CYA = MAG = BLU = ""
SEP = f"{DIM} · {R}"


def human(n):
    n = int(n or 0)
    if n >= 1_000_000_000:
        return f"{n/1e9:.2f}B"
    if n >= 1_000_000:
        return f"{n/1e6:.1f}M"
    if n >= 1000:
        return f"{n/1e3:.1f}k"
    return str(n)


def g(payload, *path):
    cur = payload
    for k in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


# ---- locate the transcript ---------------------------------------------------
def find_transcript(p):
    """.transcript_path is the documented field; the others are belt-and-braces for
    builds where the base payload spread differs."""
    f = g(p, "transcript_path")
    if f and Path(f).is_file():
        return Path(f)
    root = HOME / ".claude" / "projects"
    sid = g(p, "session_id")
    if sid:
        hits = sorted(root.glob(f"*/{sid}.jsonl"))
        if hits:
            return hits[0]
    cwd = g(p, "workspace", "project_dir") or g(p, "cwd")
    if cwd:
        d = root / re.sub(r"[^A-Za-z0-9]", "-", str(cwd))
        files = sorted(d.glob("*.jsonl"), key=lambda x: x.stat().st_mtime, reverse=True)
        if files:
            return files[0]
    return None


# ---- incremental session totals ----------------------------------------------
# Dedup by message.id: the transcript REWRITES an assistant message while streaming, so
# the same id appears on several lines and only the last is real. Naive sums run ~2x high.
# We keep the running contribution of the newest id and subtract it when that id reappears,
# which makes the dedup work across ticks, not just within one chunk.
_RX = re.compile(rb'"usage"')
_ID = re.compile(rb'"id":"(msg_[A-Za-z0-9_]+)"')
_MODEL = re.compile(rb'"model":"([^"]+)"')


def _num(line, key):
    m = re.search(rb'"' + key + rb'":([0-9]+)', line)
    return int(m.group(1)) if m else 0


def session_totals(f):
    STATED.mkdir(parents=True, exist_ok=True)
    st = STATED / (f.stem + ".state")

    per_model = {}          # model -> [in, out, cread, cwrite, 1h]
    last = None             # (id, model, in, out, cread, cwrite, 1h)
    partial = False
    off = 0

    if st.is_file():
        try:
            for line in st.read_text(encoding="utf-8", errors="replace").splitlines():
                parts = line.split()
                if not parts:
                    continue
                if parts[0] == "OFFSET":
                    off = int(parts[1])
                elif parts[0] == "PARTIAL":
                    partial = True
                elif parts[0] == "LAST" and len(parts) >= 8:
                    last = (parts[1], parts[2], *[int(x) for x in parts[3:8]])
                elif parts[0] == "M" and len(parts) >= 7:
                    per_model[parts[1]] = [int(x) for x in parts[2:7]]
        except (OSError, ValueError):
            per_model, last, off, partial = {}, None, 0, False

    try:
        size = f.stat().st_size
    except OSError:
        return None, False

    if size < off:                                   # file replaced
        try:
            st.unlink()
        except OSError:
            pass
        per_model, last, off, partial = {}, None, 0, False

    # Cold start on a huge transcript would block the status line. Scan at most CAP bytes
    # of history; totals are then marked partial with a leading ~.
    cap = int(os.environ.get("TOKENOMICS_COLD_CAP") or 33554432)
    if off == 0 and size > cap:
        off = size - cap
        partial = True

    if size > off:
        with open(f, "rb") as fh:
            fh.seek(off)
            chunk = fh.read()
        consumed = 0
        lines = chunk.split(b"\n")
        # A trailing fragment means the file is mid-write: leave it unconsumed so the
        # whole record is re-read next tick rather than being lost.
        complete = lines[:-1] if chunk and not chunk.endswith(b"\n") else lines
        for line in complete:
            consumed += len(line) + 1
            if not _RX.search(line):
                continue
            mid = _ID.search(line)
            if not mid:
                continue
            mid = mid.group(1).decode()
            mm = _MODEL.search(line)
            model = mm.group(1).decode() if mm else "?"
            vals = [_num(line, b"input_tokens"), _num(line, b"output_tokens"),
                    _num(line, b"cache_read_input_tokens"),
                    _num(line, b"cache_creation_input_tokens"),
                    _num(line, b"ephemeral_1h_input_tokens")]
            if last and mid == last[0]:
                prev = per_model.setdefault(last[1], [0, 0, 0, 0, 0])
                for i in range(5):
                    prev[i] -= last[2 + i]
            cur = per_model.setdefault(model, [0, 0, 0, 0, 0])
            for i in range(5):
                cur[i] += vals[i]
            last = (mid, model, *vals)
        off += min(consumed, size - off)

        out = [f"OFFSET {off}"]
        if last:
            out.append("LAST " + " ".join(str(x) for x in last))
        if partial:
            out.append("PARTIAL 1")
        for m, v in per_model.items():
            out.append("M " + m + " " + " ".join(str(x) for x in v))
        try:
            tmp = st.with_suffix(".state.tmp")
            tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
            os.replace(tmp, st)
        except OSError:
            pass

    tot = [0, 0, 0, 0]
    for v in per_model.values():
        for i in range(4):
            tot[i] += v[i]
    return tot, partial


# ---- render ------------------------------------------------------------------
def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0

    model = g(payload, "model", "display_name") or ""
    used = g(payload, "context_window", "used_percentage")
    ctxmax = g(payload, "context_window", "context_window_size")
    ctxin = g(payload, "context_window", "total_input_tokens")
    cu = g(payload, "context_window", "current_usage") or {}
    l_in = cu.get("input_tokens") or 0
    l_out = cu.get("output_tokens") or 0
    l_cr = cu.get("cache_read_input_tokens") or 0
    l_cw = cu.get("cache_creation_input_tokens") or 0

    f = find_transcript(payload)
    tot, partial = (None, False)
    if f:
        tot, partial = session_totals(f)

    pad = " " * (len(model) + 3)
    rows = [f"{MAG}{model}{R}{SEP}{DIM}call{R}"
            f"  in {BLU}{human(l_in)}{R}"
            f"  {DIM}↻{R}{CYA}{human(l_cr)}{R}"
            f"  {DIM}✎{R}{AMB}{human(l_cw)}{R}"
            f"  out {GRN}{human(l_out)}{R}"]

    if tot:
        ti, to, tr, tw = tot
        p = "~" if partial else ""
        rows.append(f"{pad}{DIM}sess{p}{R}"
                    f"  in {BLU}{human(ti)}{R}"
                    f"  {DIM}↻{R}{CYA}{human(tr)}{R}"
                    f"  {DIM}✎{R}{AMB}{human(tw)}{R}"
                    f"  out {GRN}{human(to)}{R}")

    # ---- the context window --------------------------------------------------
    # Derive rather than depend. used_percentage is documented as possibly null early in a
    # session; an earlier version skipped the row when it was, which looked exactly like a
    # broken plugin. Fall back through what is present. Test usefulness, not presence: a
    # literal 0 is a value but carries nothing.
    ctxnow = ctxin if (isinstance(ctxin, int) and ctxin > 0) else (l_in + l_cr + l_cw)
    up = None
    if used is not None:
        try:
            up = int(float(used))
        except (TypeError, ValueError):
            up = None
    if up is None and isinstance(ctxmax, int) and ctxmax > 0 and ctxnow > 0:
        up = ctxnow * 100 // ctxmax

    if up is not None:
        # Dots, not blocks: the bar sits under two dense rows of digits and a heavy block
        # competes with them. Dots recede when the window is mostly empty, which is when
        # the row has nothing to say.
        bw = os.environ.get("TOKENOMICS_BAR_WIDTH") or "14"
        bw = int(bw) if bw.isdigit() and int(bw) > 0 else 14
        fill = max(0, min(bw, up * bw // 100))
        bar = "■" * fill + "·" * (bw - fill)
        c = RED if up >= 85 else (AMB if up >= 70 else GRN)
        row = f"{pad}{DIM}ctx {R} {c}{bar}{R} {c}{up}%{R}"
        if ctxnow > 0 and ctxmax:
            row += f"{DIM}  {human(ctxnow)}/{human(ctxmax)}{R}"
        rows.append(row)

    # ---- the compact nudge ---------------------------------------------------
    # Two separate arguments, deliberately not merged:
    #   COST     — absolute tokens. Rent paid on every call. True at any window size.
    #   CAPACITY — % of window. Room left, and where long context starts costing recall.
    # Saving is quoted from the one compact measured in docs/: 107,585 -> 35,481, ~67%.
    cut = ctxnow * 67 // 100 if ctxnow > 0 else 0
    nudge_at = os.environ.get("TOKENOMICS_NUDGE_AT") or "150000"
    nudge_at = int(nudge_at) if nudge_at.isdigit() else 150000
    upn = up or 0
    tail = (f" · ~{human(cut)} off every later call · long context also makes earlier "
            f"detail easier to lose")
    # The lead is bold and coloured, the explanation stays dim. The cost tier used to be
    # dim end-to-end, which made the one row with something to say the quietest thing on
    # screen -- it read as a footnote and got skipped.
    if upn >= 85:
        rows.append(f"{pad}{B}{RED}⚠ /compact now{R}{DIM} — {up}% of window{tail}{R}")
    elif upn >= 70:
        rows.append(f"{pad}{B}{AMB}◆ /compact soon{R}{DIM} — {up}% of window{tail}{R}")
    elif ctxnow >= nudge_at:
        rows.append(f"{pad}{B}{AMB}◆ /compact{R}{DIM} — would cut ~{human(cut)} from every "
                    f"later call (measured ≈67%){R}")

    sys.stdout.write("\n".join(rows) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # A status line must never be the reason a session looks broken.
        sys.exit(0)
