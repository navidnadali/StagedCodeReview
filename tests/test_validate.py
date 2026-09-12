import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATE = ROOT / "lib" / "validate.jq"


def validate(payload: dict) -> dict:
    completed = subprocess.run(
        ["jq", "-f", str(VALIDATE)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(completed.stdout)


def report(*, findings=None, summary=None, still_open=None, reraised=None):
    return {
        "findings": findings or [],
        "resolved": [],
        "still_open": still_open or [],
        "reraised": reraised or [],
        "summary": summary,
    }


class ValidateReviewOutputTests(unittest.TestCase):
    def test_affirmative_remaining_issues_cannot_hide_behind_empty_arrays(self):
        result = validate(
            report(
                summary=(
                    "Mechanical alignment holds. Three documentation issues "
                    "remain, including a blocker."
                )
            )
        )
        self.assertFalse(result["ok"])
        self.assertIn("summary says issues remain", " ".join(result["notes"]))

    def test_negated_clean_summary_is_accepted(self):
        result = validate(report(summary="No issues remain; the change is clean."))
        self.assertTrue(result["ok"])

    def test_negated_modified_issue_phrases_are_accepted(self):
        summaries = (
            "No new actionable issues found.",
            "No new actionable issues were found.",
            "No other critical or major findings remain.",
            (
                "Both open findings are fixed: the probe now guards cases by "
                "identity. No new actionable issues found."
            ),
        )
        for summary in summaries:
            with self.subTest(summary=summary):
                self.assertTrue(validate(report(summary=summary))["ok"])

    def test_unrelated_no_does_not_negate_actionable_issues(self):
        result = validate(
            report(summary="No fix was applied. Actionable issues remain open.")
        )
        self.assertFalse(result["ok"])

    def test_open_findings_that_are_not_fixed_still_fail(self):
        result = validate(report(summary="Open findings are not fixed."))
        self.assertFalse(result["ok"])

    def test_an_open_id_represents_the_summary_issue(self):
        result = validate(
            report(summary="One issue remains open.", still_open=["SOL-1"])
        )
        self.assertTrue(result["ok"])

    def test_malformed_findings_fail_instead_of_being_dropped(self):
        result = validate(
            report(
                findings=[
                    {
                        "id": None,
                        "file": "x.py",
                        "line": 1,
                        "issue": "missing severity",
                        "fix": "add it",
                        "severity": "urgent",
                        "kind": "bug",
                    }
                ],
                summary="A finding was reported.",
            )
        )
        self.assertFalse(result["ok"])
        self.assertIn("refusing to drop", " ".join(result["notes"]))

    def test_valid_finding_is_accepted(self):
        finding = {
            "id": None,
            "file": "x.py",
            "line": 7,
            "issue": "wrong result",
            "fix": "return the expected value",
            "severity": "major",
            "kind": "bug",
        }
        result = validate(report(findings=[finding], summary="One issue remains."))
        self.assertTrue(result["ok"])
        self.assertEqual(result["out"]["findings"], [finding])


if __name__ == "__main__":
    unittest.main()
