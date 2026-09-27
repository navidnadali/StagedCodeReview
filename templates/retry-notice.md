# RETRY NOTICE

Your previous attempt did not produce a complete, valid review receipt. This is
attempt 2 of 2. Return ONE JSON object matching the enforced schema as your final
message. All required keys must be present. Use empty arrays when there are no
findings, but supply a substantive summary of the review; null, blank and
placeholder summaries are not a review. Only reference IDs actually present in
the supplied session ledger: resolved/still_open and finding IDs come from Open,
reraised IDs come from Dismissed and require concrete new evidence. Historical
IDs quoted in the intent or repository are not this session's ledger; report a
new issue with id null if it was not already in the supplied ledger. Do not write
files in the read-only workspace.
