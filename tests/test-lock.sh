#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

TEST_DIR="$(mktemp -d -t sr-lock-test.XXXXXX)"
OWNER_PID=""
cleanup() {
    sr_unlock
    if [[ -n "$OWNER_PID" ]]; then
        kill "$OWNER_PID" 2>/dev/null || true
        wait "$OWNER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

STAGED_REVIEW_LOCK_TIMEOUT=1
STAGED_REVIEW_PROGRESS_INTERVAL=1
mkdir "$TEST_DIR/.lock"
sleep 30 &
OWNER_PID=$!
printf '%s\n' "$OWNER_PID" > "$TEST_DIR/.lock/pid"
if sr_lock "$TEST_DIR"; then
    printf 'FAIL: acquired a live owner lock\n' >&2
    exit 1
fi
if [[ "$SR_LOCK_OWNER_PID" != "$OWNER_PID" ]]; then
    printf 'FAIL: lock owner pid was not reported\n' >&2
    exit 1
fi

kill "$OWNER_PID"
wait "$OWNER_PID" 2>/dev/null || true
OWNER_PID=""
if ! sr_lock "$TEST_DIR"; then
    printf 'FAIL: did not reclaim a stale lock\n' >&2
    exit 1
fi
sr_unlock

mkdir "$TEST_DIR/.lock"
STAGED_REVIEW_LOCK_TIMEOUT=4
if ! sr_lock "$TEST_DIR"; then
    printf 'FAIL: did not reclaim a pidless partial lock\n' >&2
    exit 1
fi
sr_unlock
printf 'ok: lock waits are bounded and stale locks are reclaimed\n'
