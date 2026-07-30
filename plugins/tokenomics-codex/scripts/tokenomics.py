#!/usr/bin/env python3
"""Read Codex session token events and render a local, deterministic dashboard."""

from __future__ import annotations

import argparse
import html
import json
import threading
import time
from dataclasses import dataclass
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


CODEX_HOME = Path.home() / ".codex"


@dataclass
class Session:
    path: Path
    session_id: str
    cwd: str | None
    updated_at: str | None
    events: list[dict[str, Any]]


def token_event(record: dict[str, Any]) -> dict[str, Any] | None:
    payload = record.get("payload", {})
    if record.get("type") != "event_msg" or payload.get("type") != "token_count":
        return None
    info = payload.get("info")
    return info if isinstance(info, dict) else None


def read_session(path: Path) -> Session | None:
    session_id = path.stem.removeprefix("rollout-")
    cwd = None
    updated_at = None
    events: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("type") == "session_meta":
                    meta = record.get("payload", {})
                    session_id = str(meta.get("id") or meta.get("session_id") or session_id)
                    cwd = meta.get("cwd") or cwd
                info = token_event(record)
                if info:
                    events.append({"timestamp": record.get("timestamp"), "info": info})
                    updated_at = record.get("timestamp") or updated_at
    except OSError:
        return None
    return Session(path, session_id, cwd, updated_at, events)


def discover_sessions(roots: list[Path]) -> list[Path]:
    found: set[Path] = set()
    for root in roots:
        if root.is_file() and root.suffix == ".jsonl":
            found.add(root)
        elif root.exists():
            found.update(root.rglob("rollout-*.jsonl"))
    return sorted(found, key=lambda path: path.stat().st_mtime, reverse=True)


def default_roots() -> list[Path]:
    return [CODEX_HOME / "sessions", CODEX_HOME / "archived_sessions"]


def usage_number(usage: dict[str, Any], name: str) -> int:
    value = usage.get(name, 0)
    return int(value) if isinstance(value, (int, float)) else 0


def analyze(session: Session) -> dict[str, Any]:
    if not session.events:
        raise ValueError(f"No token-count events found in {session.path}")
    history = [usage_number(event["info"].get("last_token_usage", {}), "input_tokens") for event in session.events]
    latest = session.events[-1]["info"]
    last = latest.get("last_token_usage", {})
    total = latest.get("total_token_usage", {})
    current = usage_number(last, "input_tokens")
    window = usage_number(latest, "model_context_window")
    compactions = [
        {"before": before, "after": after, "reduction": before - after}
        for before, after in zip(history, history[1:])
        if before > 0 and after < before * 0.8
    ]
    cached = usage_number(last, "cached_input_tokens")
    fresh = max(0, current - cached)
    output = usage_number(last, "output_tokens")
    reasoning = usage_number(last, "reasoning_output_tokens")
    return {
        "session": {"id": session.session_id, "cwd": session.cwd, "path": str(session.path), "updated_at": session.updated_at},
        "context": {"current": current, "window": window, "percent": round((current / window) * 100, 1) if window else None},
        "observed_compactions": compactions,
        "last_turn": {"fresh_input": fresh, "cached_input": cached, "output": output, "reasoning_output": reasoning},
        "session_total": {key: usage_number(total, key) for key in ("input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens")},
        "history": history[-20:],
    }


def number(value: int) -> str:
    return f"{value / 1_000_000:.2f}M" if value >= 1_000_000 else (f"{value / 1_000:.1f}k" if value >= 1_000 else str(value))


def chart_points(values: list[int], positions: list[int], total_points: int, ceiling: int, width: int = 740, height: int = 245) -> str:
    if not values:
        return ""
    step = (width - 64) / max(1, total_points - 1)
    return " ".join(f"{32 + index * step:.1f},{height - 34 - value / ceiling * (height - 68):.1f}" for value, index in zip(values, positions))


def dashboard(data: dict[str, Any]) -> str:
    context = data["context"]
    current = context["current"]
    window = context["window"] or max(current, 1)
    history = data["history"]
    actual_points = chart_points(history, list(range(len(history))), len(history), max(history + [1]))
    percent = context["percent"] or 0
    contributors = data["last_turn"]
    rows = [("Cached input", contributors["cached_input"], "cached"), ("Fresh input", contributors["fresh_input"], "fresh"), ("Output + reasoning", contributors["output"] + contributors["reasoning_output"], "output")]
    escaped_cwd = html.escape(data["session"]["cwd"] or "Unknown project")
    row_html = "".join(f'<div class="contributor {kind}"><span>{label}</span><strong>{number(value)}</strong></div>' for label, value, kind in rows)
    current_width = min(100, current / window * 100)
    compaction_note = "No context drops that match a prior compaction were observed." if not data["observed_compactions"] else "; ".join(f"{number(item['before'])} to {number(item['after'])} (-{number(item['reduction'])})" for item in data["observed_compactions"][-3:])
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Tokenomics Codex</title>
<style>
:root {{ --bg:#101113; --surface:#181a1d; --text:#f2f2ef; --muted:#a8a9ad; --line:#303237; --context:#6dc3ae; --compact:#e3a65b; --cached:#77a6e8; --fresh:#d987b8; }}
* {{ box-sizing:border-box }} body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.45 ui-sans-serif,system-ui,sans-serif }} main {{ max-width:940px; margin:auto; padding:44px 28px 64px }} header, .section-head {{ display:flex; justify-content:space-between; gap:20px; align-items:baseline; flex-wrap:wrap }} h1,h2,p {{ margin:0 }} h1 {{ font-size:28px; letter-spacing:-.04em }} h2 {{ font-size:16px }} .muted {{ color:var(--muted) }} .metrics {{ display:grid; grid-template-columns:repeat(3,1fr); gap:28px; margin:36px 0 }} .metric-label {{ color:var(--muted); font-size:13px }} .metric-value {{ margin-top:4px; font-size:25px; letter-spacing:-.04em }} .bar-row {{ display:grid; grid-template-columns:124px 1fr 105px; gap:16px; align-items:center; margin:13px 0 }} .bar {{ height:12px; background:#26282c; border-radius:99px; overflow:hidden }} .bar span {{ display:block; height:100%; border-radius:inherit; background:var(--context) }} .bar.compact span {{ background:var(--compact) }} section {{ margin-top:46px }} svg {{ width:100%; height:auto; margin-top:12px }} .grid {{ stroke:var(--line); stroke-width:1 }} .actual {{ fill:none; stroke:var(--context); stroke-width:3; stroke-linecap:round; stroke-linejoin:round }} .forecast {{ fill:none; stroke-width:2.5; stroke-dasharray:7 7; stroke-linecap:round; stroke-linejoin:round }} .forecast.keep {{ stroke:var(--context) }} .forecast.compact {{ stroke:var(--compact) }} .axis-label {{ fill:var(--muted); font-size:12px }} .callout {{ display:grid; grid-template-columns:10px 1fr; gap:14px; padding:18px; margin-top:36px; background:var(--surface); border-left:3px solid var(--compact) }} .dot {{ width:10px; height:10px; border-radius:50%; background:var(--compact); margin-top:6px }} .contributors {{ display:grid; grid-template-columns:repeat(3,1fr); gap:22px; margin-top:20px }} .contributor {{ border-top:3px solid var(--line); padding-top:12px }} .contributor.cached {{ border-color:var(--cached) }} .contributor.fresh {{ border-color:var(--fresh) }} .contributor.output {{ border-color:var(--context) }} .contributor span {{ display:block; color:var(--muted); font-size:13px }} .contributor strong {{ display:block; margin-top:3px; font-size:19px }} footer {{ color:var(--muted); font-size:12px; margin-top:44px }} @media(max-width:620px) {{ main{{padding:30px 18px}} .metrics,.contributors{{grid-template-columns:1fr;gap:16px}} .bar-row{{grid-template-columns:1fr;gap:5px}} }}
</style></head><body><main>
<header><div><h1>Session health</h1><p class="muted">{escaped_cwd}</p></div><p class="muted">Updated {html.escape(data["session"]["updated_at"] or "now")}</p></header>
<div class="metrics"><div><div class="metric-label">Context used</div><div class="metric-value">{percent:.0f}% <span class="muted">of {number(window)}</span></div></div><div><div class="metric-label">Session tokens</div><div class="metric-value">{number(data["session_total"]["total_tokens"])}</div></div><div><div class="metric-label">Cached input</div><div class="metric-value">{(contributors["cached_input"] / current * 100) if current else 0:.0f}%</div></div></div>
<section><div class="bar-row"><span>Context window</span><div class="bar"><span style="width:{current_width:.1f}%"></span></div><strong>{number(current)} / {number(window)}</strong></div></section>
<section><div class="section-head"><h2>Context runway</h2><span class="muted">observed turns only</span></div><svg viewBox="0 0 740 245" role="img" aria-label="Observed context runway for this session"><line class="grid" x1="32" y1="211" x2="718" y2="211"/><line class="grid" x1="32" y1="130" x2="718" y2="130"/><line class="grid" x1="32" y1="49" x2="718" y2="49"/><polyline class="actual" points="{actual_points}"/><text class="axis-label" x="32" y="235">start</text><text class="axis-label" x="678" y="235">now</text></svg></section>
<div class="callout"><span class="dot"></span><div><strong>Observed compactions</strong><p class="muted">{html.escape(compaction_note)}</p></div></div>
<section><div class="section-head"><h2>Latest-turn usage</h2><span class="muted">token classes, not billing</span></div><div class="contributors">{row_html}</div></section>
<footer>Tokenomics reads local Codex session events only. It does not forecast future turns or compact outcomes.</footer>
</main></body></html>"""


def select_session(paths: list[Path], query: str | None) -> Session:
    if query:
        candidate = Path(query).expanduser()
        if candidate.is_file():
            session = read_session(candidate)
            if session:
                return session
        matches = [path for path in paths if query in path.name]
        if not matches:
            raise ValueError(f"No session matches {query!r}")
        session = read_session(matches[0])
    else:
        session = read_session(paths[0]) if paths else None
    if not session:
        raise ValueError("No readable Codex sessions found")
    return session


def list_sessions(paths: list[Path]) -> list[dict[str, str | int | None]]:
    result = []
    for path in paths[:30]:
        session = read_session(path)
        if session:
            result.append({"id": session.session_id, "cwd": session.cwd, "updated_at": session.updated_at, "events": len(session.events), "path": str(path)})
    return result


def serve(directory: Path, port: int) -> ThreadingHTTPServer:
    handler = lambda *args, **kwargs: SimpleHTTPRequestHandler(*args, directory=str(directory), **kwargs)
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", help="session id fragment or transcript path")
    parser.add_argument("--sessions-root", action="append", type=Path, help="override a transcript root; repeatable")
    parser.add_argument("--list", action="store_true", help="list recent sessions")
    parser.add_argument("--json", action="store_true", help="print the compact analysis JSON")
    parser.add_argument("--output", type=Path, help="write a standalone dashboard HTML file")
    parser.add_argument("--watch", type=float, metavar="SECONDS", help="refresh the dashboard at this interval")
    parser.add_argument("--serve", type=int, metavar="PORT", help="serve the output directory on localhost")
    args = parser.parse_args()
    roots = args.sessions_root or default_roots()
    paths = discover_sessions(roots)
    if args.list:
        print(json.dumps(list_sessions(paths), indent=2))
        return 0
    output = args.output or (CODEX_HOME / "tokenomics" / "dashboard.html")
    if args.watch and args.watch <= 0:
        parser.error("--watch must be greater than zero")
    if args.serve and not args.watch:
        args.watch = 5
    server = serve(output.parent, args.serve) if args.serve else None
    try:
        while True:
            session = select_session(discover_sessions(roots), args.session)
            result = analyze(session)
            if args.json:
                print(json.dumps(result, indent=2))
                return 0
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(dashboard(result), encoding="utf-8")
            if not args.watch:
                print(output)
                return 0
            print(f"Updated {output}" + (f" · http://127.0.0.1:{args.serve}/" if server else ""), flush=True)
            time.sleep(args.watch)
    except KeyboardInterrupt:
        return 0
    finally:
        if server:
            server.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
