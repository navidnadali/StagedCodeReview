import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATE = ROOT / "lib" / "validate.jq"


def validate(payload: dict, ledger=None) -> dict:
    completed = subprocess.run(
        ["jq", "--argjson", "ledger", json.dumps(ledger or []), "-f", str(VALIDATE)],
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
            report(summary="One issue remains open.", still_open=["SOL-1"]),
            [{"id": "SOL-1", "status": "open"}],
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

    def test_actual_incomplete_receipts_are_refused(self):
        for name in ("null-summary", "foreign-ledger-ids"):
            with self.subTest(name=name):
                payload = json.loads((ROOT / "tests/fixtures" / (name + ".json")).read_text())
                self.assertFalse(validate(payload)["ok"])

    def test_empty_placeholder_or_missing_summary_is_not_a_review(self):
        for summary in (None, "", " \n\t", "...", "N/A", "OK", "done", "TODO",
                        "No summary provided.", "Placeholder summary", "Review not performed.",
                        "No review was performed.", "No summary has been provided.",
                        "Placeholder", "Pass", "LGTM", "Approved", "Not reviewed yet."):
            with self.subTest(summary=summary):
                self.assertFalse(validate(report(summary=summary))["ok"])
        payload = report(summary="Reviewed the code; no issues found.")
        del payload["summary"]
        self.assertFalse(validate(payload)["ok"])
        self.assertFalse(validate({})["ok"])

    def test_reraise_requires_real_evidence_not_a_placeholder(self):
        ledger = [{"id": "SOL-1", "status": "dismissed"}]
        for evidence in (".", "N/A", "TBD", "No evidence", "Placeholder evidence",
                         "No new evidence was provided.", "No evidence has been given.",
                         "Placeholder", "No evidence found", "New evidence", "No evidence exists."):
            with self.subTest(evidence=evidence):
                payload = report(summary="A dismissed finding is being considered.",
                                 reraised=[{"id": "SOL-1", "evidence": evidence}])
                self.assertFalse(validate(payload, ledger)["ok"])

    def test_malformed_collections_are_not_silently_dropped(self):
        for field, value in (("findings", [None]), ("findings", {}),
                             ("resolved", [None]), ("still_open", [42]),
                             ("reraised", [{"id": "SOL-1", "evidence": " "}])):
            with self.subTest(field=field, value=value):
                payload = report(summary="Reviewed the change; no issues found.")
                payload[field] = value
                self.assertFalse(validate(payload)["ok"])

    def test_references_must_belong_to_the_appropriate_ledger_population(self):
        ledger = [{"id": "SOL-1", "status": "open"},
                  {"id": "SOL-2", "status": "dismissed"},
                  {"id": "SOL-3", "status": "resolved"}]
        for field, accepted in (("resolved", "SOL-1"), ("still_open", "SOL-1"),
                                ("reraised", "SOL-2")):
            for finding_id in ("SOL-1", "SOL-2", "SOL-3", "SOL-39"):
                with self.subTest(field=field, finding_id=finding_id):
                    payload = report(summary="Reviewed the current code and prior ledger.")
                    payload[field] = ([{"id": finding_id, "evidence": "New failing control."}]
                                      if field == "reraised" else [finding_id])
                    self.assertEqual(validate(payload, ledger)["ok"], finding_id == accepted)

    def test_foreign_id_in_findings_is_not_relabelled_as_a_new_finding(self):
        payload = report(summary="One current issue remains.", findings=[{
            "id": "SOL-39", "file": "x.py", "line": 7, "issue": "wrong result",
            "fix": "return expected value", "severity": "major", "kind": "bug",
        }])
        self.assertFalse(validate(payload)["ok"])
        self.assertTrue(validate(payload, [{"id": "SOL-39", "status": "open"}])["ok"])

    def test_refusal_remains_a_valid_nonpass_with_a_reason(self):
        payload = report()
        payload.update(refused=True, refusal_reason="The diff is truncated; I cannot review it.")
        self.assertTrue(validate(payload)["ok"])
        payload["refusal_reason"] = " "
        self.assertFalse(validate(payload)["ok"])


if __name__ == "__main__":
    unittest.main()
