import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# The single sentence in the dashboard that is allowed to say "forecast", because its job
# is to deny forecasting. Kept in sync with the footer in scripts/tokenomics.py.
FOOTER_DISCLAIMER = "It does not forecast future turns or compact outcomes."

SPEC = importlib.util.spec_from_file_location("tokenomics", ROOT / "scripts" / "tokenomics.py")
tokenomics = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = tokenomics
SPEC.loader.exec_module(tokenomics)


class TokenomicsTests(unittest.TestCase):
    def test_fixture_analysis_uses_latest_call_context(self):
        session = tokenomics.read_session(ROOT / "tests" / "fixture.jsonl")
        self.assertIsNotNone(session)
        result = tokenomics.analyze(session)

        self.assertEqual(result["session"]["id"], "fixture-session")
        self.assertEqual(result["context"]["current"], 30000)
        self.assertEqual(result["context"]["percent"], 30.0)
        self.assertEqual(result["last_turn"]["fresh_input"], 7000)
        self.assertEqual(result["observed_compactions"], [])

    def test_dashboard_contains_observed_context_only(self):
        result = tokenomics.analyze(tokenomics.read_session(ROOT / "tests" / "fixture.jsonl"))
        page = tokenomics.dashboard(result)

        self.assertIn("observed turns only", page)
        self.assertIn("Observed compactions", page)

    def test_dashboard_never_forecasts(self):
        """V1 is read-only and reports only what the session already did.

        This guards the whole vocabulary rather than one class name. The assertion it
        replaces checked a single literal and passed while the removed forecast overlay's
        stylesheet was still shipping, which left the presentation in place for anyone who
        re-added the markup.
        """
        result = tokenomics.analyze(tokenomics.read_session(ROOT / "tests" / "fixture.jsonl"))
        # The footer disclaims forecasting by name, so that one sentence is the only place
        # the word is allowed. Drop it before checking the rest of the page.
        body = tokenomics.dashboard(result).lower().replace(FOOTER_DISCLAIMER.lower(), "")

        for term in ("forecast", "would cut", "would save", "projected", "projection",
                     "estimate", "predict", "after compact", "if you compact"):
            self.assertNotIn(term, body, f"forward-looking language in dashboard: {term!r}")

    def test_source_stays_local_and_read_only(self):
        """No outbound call, no model call, no shelling out. --serve is local by design."""
        src = (ROOT / "scripts" / "tokenomics.py").read_text(encoding="utf-8")
        for term in ("urllib", "requests", "httpx", "http.client",
                     "socket.create_connection", "anthropic", "openai", "subprocess"):
            self.assertNotIn(term, src, f"dashboard must stay local: {term!r}")


if __name__ == "__main__":
    unittest.main()
