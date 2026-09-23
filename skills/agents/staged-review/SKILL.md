---
name: staged-review
description: Iterative GPT-6 Sol review of the current change-set, using the repository's binding severity threshold and preserving a review ledger across passes. Run at the end of coding tasks or invoke on demand (Codex: $staged-review).
---

# Sol review loop (Codex and dsh)

Read the repository's current instructions before the first pass and identify
the severity that blocks another review round. Then run one pass, naming that
threshold explicitly:

    # dsh (DSH_SESSION_ID is set in your shell; intent comes from the transcript)
    bash ~/.agents/scripts/staged-review/staged-review.sh \
      --harness=dsh --blocking-severity major

    # Codex (no session id is exposed to shell commands: pick one stable id per
    # task, e.g. the branch name, and pass a written intent summary every pass)
    bash ~/.agents/scripts/staged-review/staged-review.sh \
      --harness=codex --session <task-id> --intent-file <path> --blocking-severity major

Use the same harness, session and threshold flags on every command below.

Accepted thresholds are `major` (Critical and Major block) and `critical`
(only Critical blocks). Use `major` when no binding repository or user rule
sets a different threshold. The choice is persisted in the review state;
changing an active loop requires another explicit `--blocking-severity` flag
and should happen only because the governing rule changed or was initially
read incorrectly.

The output starts with a `STAGED-REVIEW:` header (pass number, finding counts),
lists findings as `[ID] [severity/kind] file:line - issue` with a suggested
fix, and ends with a `NEXT:` line. The header records `blocking=` and
`open_blocking=`. Follow `NEXT` under that recorded threshold; do not apply a
stale or assumed threshold from memory.

Each model attempt waits for the reviewer to finish naturally by default and
emits a heartbeat every minute. When a bounded run is explicitly required,
`--attempt-timeout <seconds>` supplies a positive hard deadline; only then is a
timed-out reviewer terminated and retried once. The per-session lock wait stays
bounded at 30 seconds. A report is also rejected and retried when its prose
summary says issues remain but its structured finding arrays are empty, or when
any finding is malformed; neither case may advance as a clean pass. Never work
around a review failure by editing review state.

## Protocol

1. Run the driver. Read the header and the findings.
2. If `open_blocking` is nonzero, fix the blocking findings in the working tree
   and address nonblocking findings in the same pass where practical. Re-run
   with the same flags.
3. When a pass reports `ALL CLEAN`, the review-loop stopping condition is met.
   Do not run another pass solely for findings below the selected threshold.
4. Loop completion and permission to land are separate. Apply the repository's
   landing rules to every nonblocking open finding: fix it, or record a
   checkable false-positive dismissal, before committing or pushing.
   After fixing a below-threshold finding, record it and refresh the clean-tree
   receipt without another model pass:

       bash ~/.agents/scripts/staged-review/staged-review.sh \
         --harness=<dsh|codex> [--session <task-id>] \
         --resolve-nonblocking 'SOL-3=tests and exact changed lines'

   This command is accepted only after `ALL CLEAN` and refuses any finding that
   blocks at the recorded threshold.
5. Only then report back.

## Dismissing a finding

Only with a specific, checkable justification (false positive, intended
behavior, out of scope for this change - say why):

    bash ~/.agents/scripts/staged-review/staged-review.sh \
      --harness=<dsh|codex> [--session <task-id>] \
      --dismiss 'SOL-3=false positive: input is validated at src/Auth.php:88'

`--dismiss` is repeatable and may be combined with a normal pass. The reviewer
sees every dismissal and may re-raise only with concrete new evidence.
Use `--dismiss-only` after an `ALL CLEAN` pass when a nonblocking false
positive must be recorded but no further review pass is needed. Use
`--resolve-nonblocking` for a real finding fixed after the clean verdict; do
not mislabel a fix as a dismissal.

## Rules

- Stay in one session (dsh) or keep one `--session` id (Codex) for the whole
  loop; the findings ledger is keyed by it.
- The selected blocking severity is part of the state and every pass receipt.
  Never weaken it merely to make the driver exit successfully.
- Never edit anything under ~/.agents/state/; the driver owns state.
- `--reset` exists only for starting a genuinely NEW task in this same
  session. Never use it to escape findings.
- dsh extracts the intent (prompts, approved plan, todos, goal) from the
  session transcript automatically; add `--intent-file <path>` when that would
  miss context. Codex has no automatic intent capture: always pass one.
- Privacy note: the reviewer is the OpenAI codex CLI (ChatGPT subscription),
  run with a read-only sandbox over the workspace.

## Final report to the user

- Passes run and findings fixed (by severity), including minors fixed after
  the clean verdict.
- The blocking severity used and the repository rule that selected it.
- The commit/push made once the loop ended clean.
- Every dismissal with its justification.
