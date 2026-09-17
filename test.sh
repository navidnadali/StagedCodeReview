#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

for script in "$ROOT/staged-review.sh" "$ROOT/lib/common.sh" \
    "$ROOT/tests/test_diff_pack.sh" "$ROOT/tests/test_intent_isolation.sh" \
    "$ROOT/tests/test-lock.sh" "$ROOT/tests/test-blocking-severity.sh" \
    "$ROOT/test.sh"; do
    if bash -n "$script"; then
        printf 'ok: bash syntax %s\n' "${script#"$ROOT/"}"
    else
        FAIL=1
    fi
done

if bash "$ROOT/tests/test_diff_pack.sh"; then
    :
else
    FAIL=1
fi

if bash "$ROOT/tests/test_intent_isolation.sh"; then
    :
else
    FAIL=1
fi

if PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py'; then
    printf 'ok: timeout runner tests\n'
else
    FAIL=1
fi

if bash "$ROOT/tests/test-lock.sh"; then
    :
else
    FAIL=1
fi

if bash "$ROOT/tests/test-blocking-severity.sh"; then
    :
else
    FAIL=1
fi

exit "$FAIL"
