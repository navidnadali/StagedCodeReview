#!/usr/bin/env bash
# A codex review thread is persisted (never --ephemeral) and archived once the
# attempt ends; STAGED_REVIEW_ARCHIVE_THREADS=0 keeps it in the thread list, and
# a failing `codex archive` never changes the review's result.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# outside every temp dir: the driver refuses to review a repo the reviewer
# sandbox could write to (same placement as test-blocking-severity.sh)
STATE_PARENT="$(dirname "${STAGED_REVIEW_STATE_ROOT:-${HOME}/.agents/state/staged-review}")"
mkdir -p "$STATE_PARENT"
TEST_ROOT="$(mktemp -d "${STATE_PARENT}/staged-review-archive-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
REPO="${TEST_ROOT}/repo"
FAKE="${TEST_ROOT}/fake-codex.sh"
CALLS="${TEST_ROOT}/calls.log"
SID="01a1b21e-9062-7c41-ab2a-63702fe81bc0"

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
printf '%s\n' "\$*" >> "$CALLS"
if [[ "\${1:-}" == archive ]]; then
    if [[ -n "\${FAKE_ARCHIVE_HANG:-}" ]]; then
        printf '%s\n' "\$\$" > "\$FAKE_ARCHIVE_HANG"
        sleep 600 &
        wait
    fi
    exit "\${FAKE_ARCHIVE_RC:-0}"
fi
output=""
while (( \$# )); do
    case "\$1" in
        --output-last-message) output="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'OpenAI Codex v0.166.0\n--------\nsession id: $SID\n--------\n' >&2
printf '%s\n' '{"findings":[],"resolved":[],"still_open":[],"reraised":[],"summary":"Nothing to report."}' > "\$output"
FAKE
chmod +x "$FAKE"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run_review() {   # $1 = session suffix; env passes through
    STAGED_REVIEW_CODEX_BIN="$FAKE" STAGED_REVIEW_STATE_ROOT="${TEST_ROOT}/state" \
        bash "$ROOT/staged-review.sh" --harness=codex --session "archive-$1" --cwd "$REPO" 2>&1
}

: > "$CALLS"
out="$(run_review default)"; rc=$?
(( rc == 0 )) || fail "review returned $rc: $out"
grep -q -- '--ephemeral' "$CALLS" && fail "the review thread was run --ephemeral"
grep -qx "archive $SID" "$CALLS" || fail "the review thread was not archived: $(cat "$CALLS")"

: > "$CALLS"
out="$(STAGED_REVIEW_ARCHIVE_THREADS=0 run_review keep)"; rc=$?
(( rc == 0 )) || fail "review (archive off) returned $rc: $out"
grep -q '^archive ' "$CALLS" && fail "STAGED_REVIEW_ARCHIVE_THREADS=0 still archived"

: > "$CALLS"
out="$(FAKE_ARCHIVE_RC=3 run_review failing)"; rc=$?
(( rc == 0 )) || fail "a failing archive changed the review result ($rc): $out"
[[ "$out" == *"was kept but not archived"* ]] || fail "a failing archive was not noted: $out"

# a signal to the driver during a hung archive ends the run promptly and takes
# the archive process with it (it runs under the driver's cleanup like a review)
: > "$CALLS"
HANG_PID_FILE="${TEST_ROOT}/archive.pid"
FAKE_ARCHIVE_HANG="$HANG_PID_FILE" STAGED_REVIEW_CODEX_BIN="$FAKE" STAGED_REVIEW_STATE_ROOT="${TEST_ROOT}/state" \
    bash "$ROOT/staged-review.sh" --harness=codex --session archive-hang --cwd "$REPO" >/dev/null 2>&1 &
driver=$!
for _ in $(seq 1 100); do [[ -s "$HANG_PID_FILE" ]] && break; sleep 0.1; done
[[ -s "$HANG_PID_FILE" ]] || { kill -KILL "$driver" 2>/dev/null; fail "the archive never started"; }
kill -TERM "$driver"
for _ in $(seq 1 100); do kill -0 "$driver" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$driver" 2>/dev/null; then
    kill -KILL "$driver" 2>/dev/null
    fail "the driver ignored TERM while archiving"
fi
archive_pid="$(cat "$HANG_PID_FILE")"
for _ in $(seq 1 50); do kill -0 "$archive_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$archive_pid" 2>/dev/null; then
    kill -KILL "$archive_pid" 2>/dev/null
    fail "the archive process outlived the driver"
fi

printf 'ok: review threads are persisted and archived\n'
