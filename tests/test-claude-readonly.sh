#!/usr/bin/env bash
# The claude reviewer runs with read-only built-in tools only (--tools), no MCP
# server (--strict-mcp-config), and a tool set beyond Read/Grep/Glob is refused
# before any model is called.
set -uo pipefail

SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_PARENT="$(dirname "${STAGED_REVIEW_STATE_ROOT:-${HOME}/.agents/state/staged-review}")"
mkdir -p "$STATE_PARENT"
TEST_ROOT="$(mktemp -d "${STATE_PARENT}/staged-review-claude-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
# Run a copy of the driver WITHOUT the installation's config.env: an installed
# config.env may pin the reviewer backend (STAGED_REVIEW_REVIEWER=codex), and it
# is sourced after the environment, so this test could not select claude.
ROOT="${TEST_ROOT}/driver"
mkdir -p "$ROOT"
for item in staged-review.sh run-with-timeout.py lib schemas templates; do
    cp -R "${SRC_ROOT}/${item}" "${ROOT}/${item}"
done
REPO="${TEST_ROOT}/repo"
FAKE="${TEST_ROOT}/fake-claude.sh"
CALLS="${TEST_ROOT}/calls.log"

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email staged-review-test@example.invalid
git -C "$REPO" config user.name staged-review-test
printf 'baseline\n' > "${REPO}/work.txt"
git -C "$REPO" add work.txt
git -C "$REPO" commit -qm 'test baseline'
printf 'changed\n' >> "${REPO}/work.txt"

cat > "$FAKE" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$CALLS"
printf -- '---\n' >> "$CALLS"
printf '%s\n' '{"type":"result","subtype":"success","structured_output":{"findings":[],"resolved":[],"still_open":[],"reraised":[],"summary":"Nothing to report."}}'
FAKE
chmod +x "$FAKE"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_review() {   # $1 = session suffix
    STAGED_REVIEW_REVIEWER=claude STAGED_REVIEW_CLAUDE_BIN="$FAKE" STAGED_REVIEW_STATE_ROOT="${TEST_ROOT}/state" \
        bash "$ROOT/staged-review.sh" --harness=claude --session "claude-$1" --cwd "$REPO" 2>&1
}

: > "$CALLS"
out="$(run_review default)"; rc=$?
(( rc == 0 )) || fail "review returned $rc: $out"
arg_after() { awk -v f="$1" 'prev == f { print; exit } { prev = $0 }' "$CALLS"; }
[[ "$(arg_after --tools)" == "Read,Grep,Glob" ]] || fail "the tool set was not confined: $(cat "$CALLS")"
grep -qx -- '--strict-mcp-config' "$CALLS" || fail "MCP servers were not excluded: $(cat "$CALLS")"
grep -qx -- '--restricted' "$CALLS" || fail "settings-file hooks were not excluded: $(cat "$CALLS")"
[[ "$(arg_after --settings)" == '{"disableAllHooks":true}' ]] || fail "hooks were not disabled: $(cat "$CALLS")"
grep -q 'Bash(' "$CALLS" && fail "a Bash pattern reached the reviewer: $(cat "$CALLS")"

# launched from a subdirectory, the reviewer can still read the whole repository
mkdir -p "${REPO}/sub"
: > "$CALLS"
out="$(STAGED_REVIEW_REVIEWER=claude STAGED_REVIEW_CLAUDE_BIN="$FAKE" STAGED_REVIEW_STATE_ROOT="${TEST_ROOT}/state" \
    bash "$ROOT/staged-review.sh" --harness=claude --session claude-subdir --cwd "${REPO}/sub" 2>&1)"; rc=$?
(( rc == 0 )) || fail "review from a subdirectory returned $rc: $out"
[[ "$(arg_after --add-dir)" == "$(cd "$REPO" && pwd -P)" ]] || fail "the repository root was not granted: $(cat "$CALLS")"

# an explicitly EMPTY tool set (no tools at all) reaches the reviewer unchanged
: > "$CALLS"
out="$(STAGED_REVIEW_CLAUDE_TOOLS='' run_review none)"; rc=$?
(( rc == 0 )) || fail "review with no tools returned $rc: $out"
grep -qx -- '--tools' "$CALLS" || fail "the reviewer was not called: $(cat "$CALLS")"
[[ -z "$(arg_after --tools)" ]] || fail "an empty tool set was replaced with: $(arg_after --tools)"

: > "$CALLS"
out="$(STAGED_REVIEW_CLAUDE_TOOLS='Read,Bash' run_review widened)"; rc=$?
(( rc == 2 )) || fail "a non-read-only tool set was not refused ($rc): $out"
[[ -s "$CALLS" ]] && fail "the reviewer was called with a non-read-only tool set: $(cat "$CALLS")"
[[ "$out" == *"is not read-only"* ]] || fail "the refusal was not explained: $out"

printf 'ok: the claude reviewer is confined to read-only tools\n'
