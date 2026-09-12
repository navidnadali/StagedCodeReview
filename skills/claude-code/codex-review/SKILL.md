---
name: codex-review
description: Iterative code review of the current change-set via the staged-review driver - a GPT-5.6 Sol (codex, xhigh) pass looped until no NEW critical or major findings remain. Minor findings do not gate the loop - fix them after the clean verdict, then commit and push.
---

# Sol review loop (Claude Code)

Run one review pass using the Bash tool:

    bash ~/.agents/scripts/staged-review/staged-review.sh --harness=claude

The output starts with a `STAGED-REVIEW:` header (pass number, finding counts),
lists findings as `[ID] [severity/kind] file:line - issue` with a suggested
fix, and ends with a `NEXT:` line. The `NEXT:` line is authoritative: follow
it exactly.

## Protocol

The loop is gated on critical/major findings ONLY:

1. Run the driver. Read the header and the findings.
2. If there are open critical or major findings: fix them in the working tree
   (fix any minors in the same pass while you are there), then re-run the same
   driver command for another pass. Repeat.
3. The loop is COMPLETE at the first pass that raises no NEW critical or major
   finding and leaves none open (the driver prints `ALL CLEAN` for that pass) -
   even if minor findings were reported. Never run another pass to chase
   minors: fix any open minor findings now, record each with
   `--resolve-nonblocking 'SOL-n=evidence'`, count the review as complete,
   then commit and push.
4. Only then report back.

## Dismissing a finding

Only with a specific, checkable justification:

    bash ~/.agents/scripts/staged-review/staged-review.sh \
      --harness=claude --dismiss 'SOL-2=intended: cache bypass is the documented flag behavior'

`--dismiss` is repeatable and may be combined with a normal pass.

## Rules

- Review state is keyed by `CLAUDE_CODE_SESSION_ID` (already in your Bash
  environment). Stay in this session for the whole loop.
- Never edit anything under ~/.agents/state/; the driver owns state.
- `--reset` exists only for starting a genuinely NEW task in this same
  session. Never use it to escape findings.
- Intent (original prompt, approved plan, todos) is picked up automatically
  from ~/.claude/state/codex-review/$CLAUDE_CODE_SESSION_ID when the capture
  hooks are installed; add --intent-file <path> for anything they would miss.
- If your Bash tool runs in a network sandbox, the reviewer cannot reach the
  model and dies with no output. Run this command outside the sandbox.
- Privacy note: the reviewer is the OpenAI codex CLI (ChatGPT subscription),
  run with a read-only sandbox over the workspace.

## Final report to the user

- Passes run and findings fixed (by severity), including minors fixed after
  the clean verdict.
- The commit/push made once the loop ended clean.
- Every dismissal with its justification.
