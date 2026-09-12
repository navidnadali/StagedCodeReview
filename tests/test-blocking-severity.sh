#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_ROOT="${STAGED_REVIEW_STATE_ROOT:-${HOME}/.agents/state/staged-review}"
mkdir -p "$(dirname "$STATE_ROOT")"
TEST_ROOT="$(mktemp -d "$(dirname "$STATE_ROOT")/staged-review-threshold-test.XXXXXX")"
REPO="${TEST_ROOT}/repo"
FAKE_CODEX="${TEST_ROOT}/fake-codex.sh"
CRITICAL_SESSION="threshold-critical-$$"
MAJOR_SESSION="threshold-major-$$"

cleanup() {
    rm -rf "$TEST_ROOT" \
        "${STATE_ROOT}/dsh-${CRITICAL_SESSION}" \
        "${STATE_ROOT}/dsh-${MAJOR_SESSION}"
}
trap cleanup EXIT

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email staged-review-test@example.invalid
git -C "$REPO" config user.name staged-review-test
printf 'baseline\n' > "${REPO}/work.txt"
git -C "$REPO" add work.txt
git -C "$REPO" commit -qm 'test baseline'
printf 'changed\n' >> "${REPO}/work.txt"

cat > "$FAKE_CODEX" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
output=""
while (( $# )); do
    case "$1" in
        --output-last-message) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ -z "$output" ]]; then
    printf 'fake-codex: missing --output-last-message\n' >&2
    exit 2
fi
printf '%s\n' '{"findings":[{"id":null,"file":"work.txt","line":1,"issue":"test major remains","fix":"fix the test issue","severity":"major","kind":"bug"}],"resolved":[],"still_open":[],"reraised":[],"summary":"One major finding remains."}' > "$output"
FAKE
chmod +x "$FAKE_CODEX"

run_review() {
    local session="$1" threshold="$2"
    STAGED_REVIEW_CODEX_BIN="$FAKE_CODEX" \
        bash "$ROOT/staged-review.sh" --harness=dsh --session "$session" \
        --cwd "$REPO" --blocking-severity "$threshold" 2>&1
}

critical_output="$(run_review "$CRITICAL_SESSION" critical)"
critical_rc=$?
if (( critical_rc != 0 )); then
    printf 'FAIL: critical threshold returned %s\n%s\n' "$critical_rc" "$critical_output" >&2
    exit 1
fi
for expected in 'status=all-clean blocking=critical open_blocking=0' 'open_major=1' 'ALL CLEAN'; do
    if [[ "$critical_output" != *"$expected"* ]]; then
        printf 'FAIL: critical-threshold output missed %s\n%s\n' "$expected" "$critical_output" >&2
        exit 1
    fi
done
clean_hash_before="$(cat "${STATE_ROOT}/dsh-${CRITICAL_SESSION}/staged_clean.hash")"
printf 'post-clean fix\n' >> "${REPO}/work.txt"
resolved_output="$(STAGED_REVIEW_CODEX_BIN="$FAKE_CODEX" \
    bash "$ROOT/staged-review.sh" --harness=dsh --session "$CRITICAL_SESSION" \
    --cwd "$REPO" --resolve-nonblocking 'SOL-1=fixture fix verified after clean' 2>&1)"
resolved_rc=$?
if (( resolved_rc != 0 )) || [[ "$resolved_output" != *'RESOLVED-NONBLOCKING: SOL-1'* ]]; then
    printf 'FAIL: below-threshold post-clean resolution failed\n%s\n' "$resolved_output" >&2
    exit 1
fi
clean_hash_after="$(cat "${STATE_ROOT}/dsh-${CRITICAL_SESSION}/staged_clean.hash")"
if [[ "$clean_hash_before" == "$clean_hash_after" ]]; then
    printf 'FAIL: post-clean resolution did not refresh the clean-tree hash\n' >&2
    exit 1
fi
critical_status="$(STAGED_REVIEW_CODEX_BIN="$FAKE_CODEX" \
    bash "$ROOT/staged-review.sh" --harness=dsh --session "$CRITICAL_SESSION" \
    --cwd "$REPO" --status 2>&1)"
if [[ "$critical_status" != *'Blocking severity: critical'* ]] || \
    [[ "$critical_status" != *'[resolved] SOL-1'* ]] || \
    [[ "$critical_status" != *'resolved after clean: fixture fix verified after clean'* ]]; then
    printf 'FAIL: critical threshold did not persist in state\n%s\n' "$critical_status" >&2
    exit 1
fi

major_output="$(run_review "$MAJOR_SESSION" major)"
major_rc=$?
if (( major_rc != 1 )); then
    printf 'FAIL: major threshold returned %s\n%s\n' "$major_rc" "$major_output" >&2
    exit 1
fi
for expected in 'status=findings blocking=major open_blocking=1' 'open_major=1' 'next=sol'; do
    if [[ "$major_output" != *"$expected"* ]]; then
        printf 'FAIL: major-threshold output missed %s\n%s\n' "$expected" "$major_output" >&2
        exit 1
    fi
done

set +e
invalid_output="$(bash "$ROOT/staged-review.sh" --blocking-severity invalid --status 2>&1)"
invalid_rc=$?
set -e
if (( invalid_rc != 2 )) || [[ "$invalid_output" != *'invalid --blocking-severity invalid'* ]]; then
    printf 'FAIL: invalid threshold was not refused\n%s\n' "$invalid_output" >&2
    exit 1
fi

printf 'ok: blocking severity is explicit, persisted, and changes loop exit semantics\n'
