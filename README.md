# tokenomics

Measure where an agent session's **tokens and context** actually go.

Not a billing tool — it reports token counts and never asserts a price.

Whether those tokens are *money* depends on how you are authenticated. On a subscription
they spend your **rate-limit budget**, the thing that decides whether you hit a cap
mid-afternoon. On per-token API billing they spend cash. The mechanism is identical either
way, and so is the advice — only the unit of pain changes. If you have never thought about
tokens, the useful frame is that these tools show you why you hit a limit sooner than you
expected.

## Two packages, one per host

| Package | Host | Manifest |
|---|---|---|
| [plugins/tokenomics](plugins/tokenomics) | Claude Code | `.claude-plugin/plugin.json` |
| [plugins/tokenomics-codex](plugins/tokenomics-codex) | Codex | `.codex-plugin/plugin.json` |

Each manifest is the only place its version lives — this file deliberately does not repeat
them, so it cannot fall out of date with a release.

They share the idea and nothing else. The two hosts expose different APIs and write
different session formats, so scripts, hooks, transcript parsers, commands, tests and
manifests are deliberately kept separate rather than abstracted over. Each package has its
own manifest, its own marketplace catalog, its own version, and its own README with the
real detail.

**Claude Code** — measure a session and render an HTML report, a live status line with
per-call and per-session counts, a compact nudge that fires everywhere including the
desktop app, and a skill the model reaches for on its own.

**Codex** — a local, read-only dashboard of observed context usage, token classes, context
history, and prior compaction events.

The Codex package is deliberately the narrower of the two: it reports what a session
already did and never forecasts. The Claude package does estimate what a `/compact` would
save, which is right there and out of scope for Codex.

## Install

### Claude Code

```bash
claude plugin marketplace add Priyadarshiswain/tokenomics
claude plugin install tokenomics@pd-claude-plugins
```

Or load it for a single session without installing anything:

```bash
claude --plugin-dir ./plugins/tokenomics
```

Full detail, including the status-line setup and the uninstall ordering that matters:
[plugins/tokenomics/README.md](plugins/tokenomics/README.md).

### Codex

The Codex catalog is local, so add this repository as the marketplace:

```bash
codex plugin marketplace add .
```

Then install `tokenomics-codex` from the Plugins browser and start a new Codex task. The
dashboard also runs standalone:

```bash
python3 plugins/tokenomics-codex/scripts/tokenomics.py --output /tmp/tokenomics.html
```

Detail: [plugins/tokenomics-codex/README.md](plugins/tokenomics-codex/README.md).

Both packages need **`python3`** and nothing else — no `jq`, no npm, no network. The local
dashboards bind to localhost only. Developed and tested on macOS and Linux; **Windows is
untested**.

## Repository layout

```
.claude-plugin/marketplace.json      Claude Code catalog — "pd-claude-plugins"
.agents/plugins/marketplace.json     Codex catalog — "tokenomics"
plugins/tokenomics/                  the Claude Code package
plugins/tokenomics-codex/            the Codex package
```

The repository root is two marketplace catalogs and nothing else. Only the contents of a
package directory ship when that package is installed.

## Working on this repo

**Identify the host before editing.** A change belongs to one package; do not touch the
sibling unless that is the point of the change. Keep pull requests host-scoped and verify
only the package you touched.

```bash
bash plugins/tokenomics/tests/run.sh                          # Claude — 43 tests
python3 -m unittest discover -s plugins/tokenomics-codex/tests  # Codex
```

Each package carries its own semver in its own manifest, and a host-only change bumps only
that host's version. Releases are tagged per host:

```
claude-vX.Y.Z
codex-vX.Y.Z
```

Shared documentation changes — this file included — need no version bump unless
user-facing behaviour changed with them.
