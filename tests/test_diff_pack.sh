#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGED_REVIEW_FILE_MAX=8192
STAGED_REVIEW_PACK_MAX=4096
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

test_root=$(mktemp -d -t staged-review-diff.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
repo="$test_root/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email staged-review@example.invalid
git -C "$repo" config user.name staged-review-test
printf 'baseline\n' > "$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -qm baseline
baseline_tree=$(git -C "$repo" rev-parse 'HEAD^{tree}')

# Reproduce the first-use failure shape: a large untracked binary plus enough
# ordinary text diffs that a per-file cap cannot enforce the total prompt cap.
dd if=/dev/zero of="$repo/snapshot.png" bs=1024 count=2048 2>/dev/null
for file_index in 1 2 3 4 5 6; do
    awk -v n="$file_index" 'BEGIN { for (i = 0; i < 220; i++) print "text-" n "-" i "-abcdefghijklmnopqrstuvwxyz" }' \
        > "$repo/text-$file_index.txt"
done
triplets="$test_root/triplets.tsv"
printf '%s\t.\t%s\n' "$repo" "$baseline_tree" > "$triplets"

diff_out="$test_root/diff.md"
sr_build_diff_only "$triplets" "$diff_out"
diff_size=$(wc -c < "$diff_out" | tr -d ' ')
[[ "$diff_size" -le "$STAGED_REVIEW_PACK_MAX" ]] || {
    printf 'not ok: diff bundle is %s bytes, cap is %s\n' "$diff_size" "$STAGED_REVIEW_PACK_MAX" >&2
    exit 1
}
grep -Fq '[binary file omitted: snapshot.png' "$diff_out"
if grep -Fq 'GIT binary patch' "$diff_out"; then
    printf 'not ok: binary payload reached the diff bundle\n' >&2
    exit 1
fi
grep -Fq 'bytes truncated' "$diff_out"

printf 'ok: binary payload omitted and complete diff bundle capped at %s bytes\n' \
    "$STAGED_REVIEW_PACK_MAX"
