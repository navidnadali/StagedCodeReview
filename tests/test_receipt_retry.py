"""Drive the real shell/ledger boundary with deterministic model receipts."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures"
CLEAN = {"findings": [], "resolved": [], "still_open": [], "reraised": [],
         "summary": "Reviewed the complete change; no correctness or design issues found."}
FINDING = {"id": None, "file": "work.txt", "line": 1, "issue": "A boundary is missing.",
           "fix": "Validate the boundary.", "severity": "major", "kind": "bug"}


class ReceiptRetryTests(unittest.TestCase):
    def setUp(self):
        # The driver's real read-only sandbox excludes OS temp paths. Keep the
        # disposable fixture beside the checkout and isolate all runtime state.
        self.temp = tempfile.TemporaryDirectory(prefix="receipt-test-", dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.repo = self.directory / "repo"
        self.repo.mkdir()
        for args in (("init", "-q"), ("config", "user.name", "receipt-test"),
                     ("config", "user.email", "receipt-test@example.invalid")):
            self.git(*args)
        (self.repo / "work.txt").write_text("baseline\n")
        self.git("add", "work.txt")
        self.git("commit", "-qm", "test baseline")
        (self.repo / "work.txt").write_text("changed\n")
        self.fake = self.directory / "reviewer.py"
        self.fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
queue = pathlib.Path(os.environ["RECEIPT_QUEUE"])
receipts = json.loads(queue.read_text())
receipt = receipts.pop(0)
queue.write_text(json.dumps(receipts))
if isinstance(receipt, dict) and "__process_exit__" in receipt:
    sys.exit(receipt["__process_exit__"])
output = pathlib.Path(sys.argv[sys.argv.index("--output-last-message") + 1])
output.write_text(receipt if isinstance(receipt, str) else json.dumps(receipt))
''')
        self.fake.chmod(0o755)
        self.queue = self.directory / "queue.json"
        self.state_root = self.directory / "state"
        self.keydir = self.state_root / "codex-receipt-test"

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True)

    def run_receipts(self, receipts, *extra):
        self.queue.write_text(json.dumps(receipts))
        env = dict(os.environ, STAGED_REVIEW_CODEX_BIN=str(self.fake),
                   STAGED_REVIEW_STATE_ROOT=str(self.state_root), RECEIPT_QUEUE=str(self.queue))
        result = subprocess.run([shutil.which("bash"), str(ROOT / "staged-review.sh"),
                                 "--harness=codex", "--session", "receipt-test", "--cwd", str(self.repo),
                                 "--blocking-severity", "major", *extra],
                                env=env, text=True, capture_output=True, timeout=30)
        self.assertEqual(json.loads(self.queue.read_text()), [], result.stdout + result.stderr)
        return result

    def state(self):
        return json.loads((self.keydir / "state.json").read_text())

    def test_both_actual_bad_receipts_retry_without_advancing_then_valid_recovers(self):
        bad = [json.loads((FIXTURES / (name + ".json")).read_text())
               for name in ("null-summary", "foreign-ledger-ids")]
        result = self.run_receipts(bad)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        state = self.state()
        self.assertEqual(state["passes"]["sol"], 0)
        self.assertEqual(state["findings"], [])
        self.assertEqual(state["next_finding_seq"]["sol"], 1)
        self.assertEqual(state["stage"], "sol")
        self.assertEqual(state["runs"][-1]["result"], "error")
        self.assertFalse((self.keydir / "staged_clean.hash").exists())
        run = self.keydir / "runs/001-sol"
        for attempt in (1, 2):
            validation = json.loads((run / f"validation.attempt{attempt}.json").read_text())
            self.assertFalse(validation["ok"])
            self.assertTrue(validation["notes"])
        result = self.run_receipts([CLEAN])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state()["passes"]["sol"], 1)
        self.assertEqual(self.state()["run_seq"], 2)
        self.assertTrue((self.keydir / "staged_clean.hash").exists())

    def test_invalid_first_attempt_then_valid_finding_gets_first_id_once(self):
        bad = json.loads((FIXTURES / "null-summary.json").read_text())
        valid = dict(CLEAN, findings=[FINDING], summary="The change misses a boundary check.")
        result = self.run_receipts([bad, valid])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.state()["passes"]["sol"], 1)
        self.assertEqual([f["id"] for f in self.state()["findings"]], ["SOL-1"])
        self.assertEqual(self.state()["next_finding_seq"]["sol"], 2)
        before = self.state()
        invalid = dict(CLEAN, resolved=["SOL-39"], still_open=["SOL-1"])
        result = self.run_receipts([invalid, invalid])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        after = self.state()
        for key in ("findings", "passes", "next_finding_seq", "stage"):
            self.assertEqual(after[key], before[key])
        result = self.run_receipts([dict(CLEAN, resolved=["SOL-1"])])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state()["findings"][0]["status"], "resolved")

    def test_invalid_receipt_cannot_refresh_existing_clean_marker(self):
        self.assertEqual(self.run_receipts([CLEAN]).returncode, 0)
        marker = self.keydir / "staged_clean.hash"
        before = (marker.read_bytes(), marker.stat().st_mtime_ns)
        (self.repo / "work.txt").write_text("another change\n")
        bad = json.loads((FIXTURES / "null-summary.json").read_text())
        result = self.run_receipts([bad, bad], "--stage", "sol")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.state()["passes"]["sol"], 1)
        self.assertEqual((marker.read_bytes(), marker.stat().st_mtime_ns), before)

    def test_valid_carry_and_dismissed_reraise_preserve_the_ledger_id(self):
        valid = dict(CLEAN, findings=[FINDING], summary="The boundary check is missing.")
        self.assertEqual(self.run_receipts([valid]).returncode, 1)
        carried = dict(CLEAN, still_open=["SOL-1"], summary="The boundary issue remains open.")
        self.assertEqual(self.run_receipts([carried]).returncode, 1)
        reraised = dict(CLEAN, reraised=[{"id": "SOL-1", "evidence": "A new input still fails."}],
                        summary="The dismissed boundary issue is reproducible with a new input.")
        result = self.run_receipts([reraised], "--dismiss", "SOL-1=Original input was out of scope.")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual([f["id"] for f in self.state()["findings"]], ["SOL-1"])
        self.assertEqual(self.state()["findings"][0]["status"], "open")
        self.assertEqual(self.state()["findings"][0]["reraised"][0]["evidence"],
                         "A new input still fails.")
        self.assertEqual(self.state()["next_finding_seq"]["sol"], 2)

    def test_explicit_refusal_is_recorded_without_pass_or_retry(self):
        refused = dict(CLEAN, summary=None, refused=True,
                       refusal_reason="The diff is truncated; the complete change cannot be reviewed.")
        result = self.run_receipts([refused])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.state()["passes"]["sol"], 0)
        self.assertEqual(self.state()["runs"][-1]["result"], "refused")
        self.assertFalse((self.keydir / "staged_clean.hash").exists())

    def test_placeholder_summary_and_evidence_cannot_advance_a_pass(self):
        valid = dict(CLEAN, findings=[FINDING], summary="The boundary check is missing.")
        self.assertEqual(self.run_receipts([valid]).returncode, 1)
        invalid = dict(CLEAN, reraised=[{"id": "SOL-1", "evidence": "No evidence found"}])
        result = self.run_receipts([invalid, invalid], "--dismiss", "SOL-1=Input is out of scope.")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.state()["findings"][0]["status"], "dismissed")
        self.assertEqual(self.state()["passes"]["sol"], 1)
        placeholders = [dict(CLEAN, summary=s) for s in ("Placeholder", "Pass")]
        result = self.run_receipts(placeholders)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.state()["passes"]["sol"], 1)
        self.assertFalse((self.keydir / "staged_clean.hash").exists())

    def test_empty_and_unparsable_attempts_keep_diagnostic_receipts(self):
        result = self.run_receipts(["", "not JSON"])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        run = self.keydir / "runs/001-sol"
        for attempt in (1, 2):
            validation = json.loads((run / f"validation.attempt{attempt}.json").read_text())
            self.assertFalse(validation["ok"])
            self.assertTrue(validation["notes"])
        self.assertIn("Validation refusal: reviewer output", (run / "prompt.md").read_text())
        self.assertEqual(self.state()["passes"]["sol"], 0)

    def test_process_failure_has_a_diagnostic_for_the_retry(self):
        result = self.run_receipts([{"__process_exit__": 7}, CLEAN])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        run = self.keydir / "runs/001-sol"
        diagnostic = json.loads((run / "validation.attempt1.json").read_text())
        self.assertFalse(diagnostic["ok"])
        self.assertIn("rc=7", " ".join(diagnostic["notes"]))
        self.assertIn("reviewer process exited rc=7", (run / "prompt.md").read_text())
        self.assertEqual(self.state()["passes"]["sol"], 1)


if __name__ == "__main__":
    unittest.main()
