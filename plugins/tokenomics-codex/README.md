# Tokenomics Codex

Tokenomics Codex is a local, read-only dashboard for Codex session context.
It parses the token-count events already written to Codex session transcripts and produces:

- current context-window pressure;
- an observed context runway;
- the biggest contributors to context growth; and
- observed prior compaction events.

The dashboard does not call a model. It does not change Codex settings or session files.

## Run locally

```bash
python3 scripts/tokenomics.py --output /tmp/tokenomics.html
python3 scripts/tokenomics.py --watch 5 --serve 8899
```

The live mode refreshes the report every five seconds and serves it on localhost.

## Install for development

The repository marketplace is at `.agents/plugins/marketplace.json`. Add it with:

```bash
codex plugin marketplace add .
```

Then install `tokenomics-codex` from the Plugins browser and begin a new Codex task.
