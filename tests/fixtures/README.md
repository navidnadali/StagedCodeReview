These fixtures reproduce two receipt failures observed in a live review:

- `null-summary.json` is the empty/null receipt without changes.
- `foreign-ledger-ids.json` preserves the finding/reference arrays. Its summary
  is reduced to generic parser language so repository-specific context is not
  published. The failure is that its referenced IDs do not exist in the session
  ledger, even though the summary says an issue remains.

The original receipts remain outside this repository. Neither fixture is a
valid clean review, and tests also cover valid empty findings and real ledger
references so the validator cannot succeed by refusing everything.
