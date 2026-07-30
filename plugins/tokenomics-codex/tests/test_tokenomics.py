import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
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
        self.assertNotIn("forecast keep", page)


if __name__ == "__main__":
    unittest.main()
