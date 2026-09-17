#!/usr/bin/env bash
# Regression test for cross-session intent leakage.
#
# The Claude state root is shared by every session on the machine, across every
# project. sr_claude_intent_dir used to fall back to the most recently modified
# directory there whenever the requested one did not exist -- so a review could be
# briefed with an unrelated project's "Original request" while reviewing the right
# diff. The reviewer then reports honestly about the wrong stated intent, and
# nothing downstream can tell.
#
# Compounding it: the capture hooks name directories by Claude's session_id (a
# UUID) while callers pass a human label via --session, which overrides it. Those
# key spaces do not match, so the miss -- and therefore the fallback -- was the
# normal case, not an edge case. And the staleness warning only fired when the
# chosen directory was over six hours old, i.e. never on a busy machine.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
ok()  { printf 'ok: %s\n' "$1"; }
bad() { printf 'not ok: %s\n' "$1" >&2; fail=1; }

HOME="$(mktemp -d -t staged-review-intent.XXXXXX)"; export HOME
trap 'rm -rf "$HOME"' EXIT
root="${HOME}/.claude/state/codex-review"
mkdir -p "${root}/OTHER-PROJECT" "${root}/MINE"
printf '# Original request\n\nDeploy an unrelated service.\n' > "${root}/OTHER-PROJECT/intent.md"
printf '# Original request\n\nThe change actually under review.\n'  > "${root}/MINE/intent.md"

# Make OTHER-PROJECT unambiguously the most recently modified.
sleep 1; touch "${root}/OTHER-PROJECT"

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

# 1. A named session that resolves is used.
got="$(sr_claude_intent_dir MINE 2>/dev/null)"
[[ "$got" == "${root}/MINE" ]] && ok "named session resolves to its own dir" \
  || bad "named session: expected ${root}/MINE, got '${got}'"

# 2. THE REGRESSION: a named session that does NOT resolve must return empty and
#    must never fall through to another project's directory.
got="$(sr_claude_intent_dir P4-002 2>/dev/null)"
if [[ -z "$got" ]]; then
    ok "unresolved --session returns empty instead of guessing"
elif [[ "$got" == "${root}/OTHER-PROJECT" ]]; then
    bad "REGRESSION: unresolved --session leaked another project's intent dir"
else
    bad "unresolved --session returned unexpected '${got}'"
fi

# 3. No session named, guessing not enabled -> empty.
got="$(STAGED_REVIEW_INTENT_AUTO=0 sr_claude_intent_dir '' 2>/dev/null)"
[[ -z "$got" ]] && ok "no session and auto off returns empty" \
  || bad "no session and auto off returned '${got}'"

# 4. No session, guessing enabled, AMBIGUOUS (two dirs recent) -> empty.
got="$(STAGED_REVIEW_INTENT_AUTO=1 sr_claude_intent_dir '' 2>/dev/null)"
[[ -z "$got" ]] && ok "auto-guess refuses when multiple dirs are recent" \
  || bad "auto-guess picked '${got}' despite ambiguity"

# 5. No session, guessing enabled, UNAMBIGUOUS -> the single recent dir.
rm -rf "${root}/MINE"
got="$(STAGED_REVIEW_INTENT_AUTO=1 sr_claude_intent_dir '' 2>/dev/null)"
[[ "$got" == "${root}/OTHER-PROJECT" ]] && ok "auto-guess picks the sole recent dir" \
  || bad "auto-guess expected the sole dir, got '${got}'"

# 6. An EMPTY directory is a safe fallback target: it yields no intent rather than
#    a foreign one. (Recorded because the opposite was briefly believed.)
mkdir -p "${root}/EMPTY-ONE"
out="$(build_intent_bundle "${root}/EMPTY-ONE" "")"
[[ -z "$out" ]] && ok "an empty state dir yields no intent (safe)" \
  || bad "an empty state dir yielded content: '${out}'"

# 7. Provenance: the built intent names where it came from, so contamination is
#    visible in the artefact the reviewer actually reads.
outfile="${HOME}/intent-out.md"
sr_build_intent claude OTHER-PROJECT "" "$outfile" 2>/dev/null
if grep -q "^Intent source: claude state dir 'OTHER-PROJECT'" "$outfile"; then
    ok "built intent carries its provenance"
else
    bad "built intent has no provenance line: $(head -1 "$outfile")"
fi

exit "$fail"
