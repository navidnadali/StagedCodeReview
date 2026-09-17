# shellcheck shell=bash
# staged-review shared helpers (sr_*). Sourced by staged-review.sh — never executed.

# Resolve the install root from this file's own location so the tree works
# wherever it is checked out or installed (default: ~/.agents/scripts/staged-review).
SR_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SR_STATE_ROOT="${STAGED_REVIEW_STATE_ROOT:-${HOME}/.agents/state/staged-review}"
SR_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# shellcheck source=helpers.sh
source "${SR_HOME}/lib/helpers.sh"   # load_env, discover_git_repos, relpath_under, build_intent_bundle, log_debug, ...
load_env
# shellcheck source=/dev/null
[[ -f "${SR_HOME}/config.env" ]] && source "${SR_HOME}/config.env"

: "${STAGED_REVIEW_SOL_MODEL:=gpt-5.6-sol}"
: "${STAGED_REVIEW_SOL_REASONING:=xhigh}"
: "${STAGED_REVIEW_CODEX_BIN:=codex}"
: "${STAGED_REVIEW_BLOCKING_SEVERITY:=major}" # major = critical+major; critical = critical only
: "${STAGED_REVIEW_PYTHON_BIN:=python3}"
: "${STAGED_REVIEW_TIMEOUT_RUNNER:=${SR_HOME}/run-with-timeout.py}"
: "${STAGED_REVIEW_ATTEMPT_TIMEOUT:=0}"    # 0 waits for natural completion; positive = hard limit
: "${STAGED_REVIEW_TERMINATE_GRACE:=5}"    # TERM-to-KILL grace period (seconds)
: "${STAGED_REVIEW_PROGRESS_INTERVAL:=60}" # visible heartbeat while a model/lock is pending
: "${STAGED_REVIEW_LOCK_TIMEOUT:=30}"      # bounded wait for this session's driver lock
: "${STAGED_REVIEW_FILE_MAX:=122880}"       # per-file byte cap in the diff bundle
: "${STAGED_REVIEW_PACK_MAX:=409600}"       # total diff-bundle byte cap
: "${STAGED_REVIEW_INTENT_MAX:=24576}"      # intent bundle byte cap (middle-truncated)
: "${STAGED_REVIEW_RENDER_MAX:=500}"        # per issue/fix chars in stdout report
: "${STAGED_REVIEW_LIST_MAX:=40}"           # max findings listed in stdout report
: "${ZSTD_BIN:=zstd}"                    # only needed for dsh transcript intent extraction

sr_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- notes ---------------------------------------------------------------
SR_NOTES=()
sr_note() { SR_NOTES+=("$1"); }

# ---- lock ----------------------------------------------------------------
SR_LOCKDIR=""
# shellcheck disable=SC2034  # read by staged-review.sh's lock-failure message
SR_LOCK_OWNER_PID=""
sr_lock() {
    local dir="$1/.lock" pid="" started now elapsed last_notice=-1 pidless_since=-1
    started="$(date +%s)"
    SR_LOCK_OWNER_PID=""
    while :; do
        if mkdir "$dir" 2>/dev/null; then
            printf '%s\n' $$ > "$dir/pid"
            SR_LOCKDIR="$dir"
            return 0
        fi

        pid="$(cat "$dir/pid" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]] && ! ps -p "$pid" >/dev/null 2>&1; then
            rm -f "$dir/pid" 2>/dev/null || true
            rmdir "$dir" 2>/dev/null || true
            continue
        fi

        now="$(date +%s)"
        elapsed=$(( now - started ))
        if [[ -z "$pid" ]]; then
            (( pidless_since < 0 )) && pidless_since=$elapsed
            if (( elapsed - pidless_since >= 2 )); then
                # mkdir and pid-file creation are not atomic. Give a live owner
                # two seconds to publish its pid before reclaiming the lock.
                rmdir "$dir" 2>/dev/null || true
                pidless_since=-1
                continue
            fi
        else
            pidless_since=-1
        fi

        if (( elapsed >= STAGED_REVIEW_LOCK_TIMEOUT )); then
            # shellcheck disable=SC2034  # read by staged-review.sh's lock-failure message
            SR_LOCK_OWNER_PID="${pid:-unknown}"
            return 1
        fi
        if (( last_notice < 0 || elapsed - last_notice >= STAGED_REVIEW_PROGRESS_INTERVAL )); then
            printf 'staged-review: session lock held by pid %s; waiting (%ss/%ss)\n' \
                "${pid:-unknown}" "$elapsed" "$STAGED_REVIEW_LOCK_TIMEOUT" >&2
            last_notice=$elapsed
        fi
        sleep 1
    done
}
sr_unlock() {
    if [[ -n "$SR_LOCKDIR" ]]; then
        rm -f "$SR_LOCKDIR/pid" 2>/dev/null || true
        rmdir "$SR_LOCKDIR" 2>/dev/null || true
    fi
    SR_LOCKDIR=""
}

sr_cleanup_stale() {
    [[ -d "$SR_STATE_ROOT" ]] || return 0
    find "$SR_STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
}

# ---- text utils ----------------------------------------------------------
# Cap a file's content at $2 bytes keeping the first $3 bytes + the tail.
sr_cap_middle() {
    local file="$1" max="$2" keep="$3" size omitted notice notice_len tail_keep
    size=$(wc -c < "$file" | tr -d ' ')
    if (( size <= max )); then cat "$file"; return 0; fi
    omitted=$(( size - max ))
    notice=$(printf '\n\n_[... %d bytes truncated ...]_\n\n' "$omitted")
    notice_len=${#notice}
    if (( keep + notice_len > max )); then
        keep=$(( (max - notice_len) / 2 ))
    fi
    (( keep < 0 )) && keep=0
    tail_keep=$(( max - keep - notice_len ))
    (( tail_keep < 0 )) && tail_keep=0
    head -c "$keep" "$file"
    printf '%s' "$notice"
    (( tail_keep > 0 )) && tail -c "$tail_keep" "$file"
}

# Cap an already-built bundle in place. The model input ceiling applies to the
# complete diff bundle, not independently to each file. Per-file truncation
# alone therefore does not protect a change-set containing many medium-sized
# files.
sr_cap_bundle() {  # <file> <label>
    local file="$1" label="$2" size tmp keep
    size=$(wc -c < "$file" | tr -d ' ')
    (( size <= STAGED_REVIEW_PACK_MAX )) && return 0
    tmp=$(mktemp -t sr-cap.XXXXXX)
    keep=$(( STAGED_REVIEW_PACK_MAX * 2 / 3 ))
    sr_cap_middle "$file" "$STAGED_REVIEW_PACK_MAX" "$keep" > "$tmp"
    mv "$tmp" "$file"
    sr_note "$label: capped complete bundle from ${size} to ${STAGED_REVIEW_PACK_MAX} bytes"
}

# ---- git -----------------------------------------------------------------
# Canonical working-tree hash across repos: git diff HEAD + untracked file hashes.
# The optional Claude Code Stop hook compares its own copy of this hash against
# the ALL CLEAN marker — keep the two implementations identical.
sr_worktree_hash() {
    local r f
    {
        for r in $(printf '%s\n' "$@" | sort); do
            git -C "$r" diff HEAD 2>/dev/null
            git -C "$r" ls-files --others --exclude-standard 2>/dev/null | sort | while IFS= read -r f; do
                [[ -f "$r/$f" ]] && shasum -a 256 "$r/$f" 2>/dev/null
            done
        done
    } | shasum -a 256 | cut -d' ' -f1
}

# One file's diff, exclusion- and size-capped. $3 = tracked|untracked.
sr_emit_file_diff() {
    local repo="$1" tree="$2" f="$3" kind="$4" d sz sha
    if sr_pack_excluded "$f"; then
        printf '# [diff omitted: %s (excluded path/lockfile)]\n' "$f"
        sr_note "diff: omitted $f (excluded path/lockfile)"
        return 0
    fi
    if [[ "$kind" == "tracked" ]]; then
        d="$(git -C "$repo" diff "$tree" -- "$f" 2>/dev/null)"
    else
        # Never inline a binary patch for an untracked file. A PNG rename is
        # represented as delete+untracked until staged; --binary expanded sixty
        # byte-identical baseline renames into a 2.34M-character prompt and the
        # Sol API refused it before review began. The hash keeps the file's exact
        # identity reviewable while the model can inspect it from the read-only
        # repository when visual content matters.
        if [[ -f "$repo/$f" ]] && ! LC_ALL=C grep -qI . "$repo/$f" 2>/dev/null; then
            sz=$(wc -c < "$repo/$f" | tr -d ' ')
            sha=$(shasum -a 256 "$repo/$f" | awk '{print $1}')
            printf '# [binary file omitted: %s (%s bytes; sha256 %s)]\n' "$f" "$sz" "$sha"
            sr_note "diff: omitted binary payload $f (${sz} bytes; sha256 $sha)"
            return 0
        fi
        d="$(git -C "$repo" diff --no-index -- /dev/null "$repo/$f" 2>/dev/null || true)"
    fi
    sz=${#d}
    if (( sz > STAGED_REVIEW_FILE_MAX )); then
        printf '%s\n' "${d:0:2000}"
        printf '# [diff truncated: %s (%d bytes)]\n' "$f" "$sz"
        sr_note "diff: truncated $f (${sz} bytes > per-file cap)"
    elif (( sz > 0 )); then
        printf '%s\n' "$d"
    fi
}

# Full diff of a repo vs a baseline tree hash (tracked + untracked),
# per-file, with exclusion and size caps applied.
sr_repo_diff() {
    local repo="$1" tree="$2" f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        sr_emit_file_diff "$repo" "$tree" "$f" tracked
    done < <(git -C "$repo" diff --name-only "$tree" 2>/dev/null)
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        sr_emit_file_diff "$repo" "$tree" "$f" untracked
    done < <(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)
}

# 0 when the repo has changes vs the baseline tree (or untracked files).
sr_repo_changed() {
    local repo="$1" tree="$2"
    if ! git -C "$repo" diff --quiet "$tree" 2>/dev/null; then return 0; fi
    [[ -n "$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)" ]]
}

sr_tree_of() {  # rev -> tree sha (empty output on failure)
    local repo="$1" rev="$2"
    git -C "$repo" rev-parse "${rev}^{tree}" 2>/dev/null
}

sr_head_tree() {
    local repo="$1" t
    t="$(git -C "$repo" rev-parse 'HEAD^{tree}' 2>/dev/null)" || t=""
    [[ -z "$t" ]] && t="$SR_EMPTY_TREE"   # unborn HEAD
    printf '%s' "$t"
}

# ---- intent --------------------------------------------------------------
sr_extract_dsh_intent() {   # uses $DSH_SESSION_JSONL
    local jsonl="${DSH_SESSION_JSONL:-}"
    [[ -n "$jsonl" && -f "$jsonl" ]] || return 0
    "$ZSTD_BIN" -dc "$jsonl" 2>/dev/null | jq -rs '
        map(select(type == "object")) as $all
        | ($all | map(select(.type == "user/message" and .data.source.kind == "user")
            | [.data.content[]? | select(.type == "text") | .text] | join("\n"))
            | map(select(length > 0))) as $prompts
        | ($all | map(select(.type == "tool/call" and .data.name == "exit_plan_mode")
            | (.data.arguments | fromjson? | .plan) // empty) | if length > 0 then last else null end) as $plan
        | ($all | map(select(.type == "todo/write") | .data.todos) | if length > 0 then last else null end) as $todos
        | ($all | map(select(.type == "goal/change") | .data.goal.objective // empty)
            | map(select(length > 0)) | if length > 0 then last else null end) as $goal
        | (if ($prompts | length) > 0 then "# Original request\n\n\($prompts[0])\n" else "" end)
        + (if ($prompts | length) > 1 then "\n## Follow-ups\n\n"
            + ([$prompts[1:][] | "### Follow-up\n\n\(.)"] | join("\n\n")) + "\n" else "" end)
        + (if $goal  != null then "\n## Current goal\n\n\($goal)\n" else "" end)
        + (if $plan  != null then "\n## Approved plan\n\n\($plan)\n" else "" end)
        + (if $todos != null then "\n## Latest todos\n\n"
            + ([$todos[] | "- [\(.status)] \(.content)"] | join("\n")) + "\n" else "" end)
    ' 2>/dev/null
}

# Resolve the Claude state directory holding this session's captured intent.
#
# The root is SHARED BY EVERY SESSION ON THE MACHINE, across every project. Picking
# the wrong directory briefs the reviewer with another project's purpose, and the
# resulting review is indistinguishable from a real one: it reviews the right diff
# against the wrong stated intent. So this never guesses unless told it may.
#
# Note the capture hooks name directories by Claude's session_id (a UUID) while
# callers typically pass a human label via --session, which overrides it. Those key
# spaces do not match, so a miss here is the NORMAL case for a labelled session --
# which is exactly why the old fallback fired so often and so quietly.
#
# Precedence:
#   1. --session <sid> is authoritative. If it does not resolve, emit NOTHING.
#   2. No session named: guessing is opt-in via STAGED_REVIEW_INTENT_AUTO=1.
#   3. Even when opted in, refuse when the choice is ambiguous.
sr_claude_intent_dir() {   # -> state dir path, or empty
    local root="${HOME}/.claude/state/codex-review" sid="${1:-}" d recent n

    # (1) An explicit session is a statement of fact by the caller. Honour it or
    #     return nothing. Falling through to a guess here is what allowed reviews
    #     to be briefed with unrelated projects' requests.
    if [[ -n "$sid" ]]; then
        if [[ -d "${root}/${sid}" ]]; then
            printf '%s' "${root}/${sid}"
        else
            sr_note "claude intent: --session '${sid}' has no state dir under ${root}; capturing NO intent (refusing to guess). Pass --intent-file to supply it."
        fi
        return 0
    fi

    # (2) No session named. Guessing is off by default.
    if [[ "${STAGED_REVIEW_INTENT_AUTO:-0}" != "1" ]]; then
        sr_note "claude intent: no --session given; capturing NO intent (set STAGED_REVIEW_INTENT_AUTO=1 to allow most-recent-dir guessing)."
        return 0
    fi

    # (3) Opted in. Refuse when more than one session was active recently: on a
    #     multi-lane host "most recent" is a coin toss, and the old code warned
    #     only when the pick was STALE -- silent in exactly the case where it was
    #     most likely to be wrong.
    recent="$(find "$root" -mindepth 1 -maxdepth 1 -type d -newermt '-6 hours' 2>/dev/null)"
    n="$(printf '%s' "$recent" | grep -c . || true)"
    if (( n > 1 )); then
        sr_note "claude intent: ${n} state dirs modified in the last 6h -- ambiguous; capturing NO intent. Pass --session or --intent-file."
        return 0
    fi

    d="$(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | xargs -0 ls -td 2>/dev/null | head -1)"
    [[ -n "$d" ]] || return 0
    sr_note "claude intent: GUESSED most-recent state dir $(basename "$d") -- verify it matches this session."
    printf '%s' "$d"
}

# sr_build_intent <harness> <session-id> <intent-addendum-file> <outfile>
sr_build_intent() {
    local harness="$1" sid="$2" addendum="$3" out="$4" tmp dir src
    tmp="$(mktemp -t sr-intent.XXXXXX)"
    src="none"
    case "$harness" in
        dsh)    src="dsh session transcript"; sr_extract_dsh_intent > "$tmp" ;;
        claude) dir="$(sr_claude_intent_dir "$sid")"
                if [[ -n "$dir" ]]; then
                    src="claude state dir '$(basename "$dir")'"
                    build_intent_bundle "$dir" "" > "$tmp"
                fi ;;
        *)      : ;;
    esac
    # Provenance, in the artefact the reviewer actually reads. Contamination is then
    # visible in intent.md itself rather than needing an out-of-band check.
    if [[ -s "$tmp" ]]; then
        { printf 'Intent source: %s\n\n---\n\n' "$src"; cat "$tmp"; } > "${tmp}.prov"
        mv "${tmp}.prov" "$tmp"
    fi
    if [[ -n "$addendum" && -f "$addendum" ]]; then
        { printf '\n\n## Agent addendum\n\n'; cat "$addendum"; } >> "$tmp"
    fi
    if [[ ! -s "$tmp" ]]; then
        printf '(No captured intent. Review on the merits of the changes alone.)\n' > "$out"
    else
        sr_cap_middle "$tmp" "$STAGED_REVIEW_INTENT_MAX" 8192 > "$out"
    fi
    rm -f "$tmp"
}

# ---- diff bundle ---------------------------------------------------------
sr_pack_excluded() {   # 0 = excluded
    local f="$1" base
    base="${f##*/}"
    case "$base" in
        package-lock.json|pnpm-lock.yaml|yarn.lock|composer.lock|Cargo.lock|Gemfile.lock|poetry.lock|uv.lock|go.sum) return 0 ;;
        *.min.js|*.min.css|*.map) return 0 ;;
    esac
    case "/$f/" in
        */vendor/*|*/node_modules/*|*/dist/*|*/build/*|*/.git/*) return 0 ;;
    esac
    return 1
}

# sr_build_diff_only <triplets-file: repo\trel\ttree per line> <outfile>
sr_build_diff_only() {
    local triplets="$1" out="$2" repo rel tree
    : > "$out"
    while IFS=$'\t' read -r repo rel tree; do
        [[ -z "$repo" ]] && continue
        sr_repo_changed "$repo" "$tree" || continue
        {
            printf '### Repo: %s\n' "$rel"
            printf '``````diff\n'
            sr_repo_diff "$repo" "$tree"
            printf '``````\n\n'
        } >> "$out"
    done < "$triplets"
    sr_cap_bundle "$out" "diff"
}

# ---- ledger rendering ----------------------------------------------------
sr_render_ledger() {   # state.json -> markdown on stdout
    jq -r '
        (.findings // []) as $f
        | ([$f[] | select(.status == "open")]) as $open
        | ([$f[] | select(.status == "dismissed")]) as $dis
        | ([$f[] | select(.status == "resolved")]) as $res
        | if ($open | length) == 0 and ($dis | length) == 0 and ($res | length) == 0
          then "(First pass - no prior findings.)"
          else
            (if ($open | length) > 0 then
                "## Open - for EACH id below decide: fixed now -> its id goes in \"resolved\"; not fixed -> \"still_open\"\n\n"
                + ([$open[] | "- \(.id) [\(.severity)/\(.kind)] \(.file):\(.line) - \(.issue) (raised: \(.stage) pass \(.pass))\n  Suggested fix was: \(.fix)"] | join("\n")) + "\n"
             else "" end)
            + (if ($dis | length) > 0 then
                "\n## Dismissed - do NOT re-raise without concrete NEW evidence (then use \"reraised\")\n\n"
                + ([$dis[] | "- \(.id) [\(.severity)/\(.kind)] \(.file):\(.line) - \(.issue) - engineer: \"\(.dismiss_reason // "no reason recorded")\""] | join("\n")) + "\n"
             else "" end)
            + (if ($res | length) > 0 then
                "\n## Resolved earlier (context only - do not re-report)\n\n"
                + ([$res[] | "- \(.id) \(.file):\(.line) - \(.issue)"] | join("\n")) + "\n"
             else "" end)
          end
    ' "$1"
}

# ---- output parsing ------------------------------------------------------
# Extract the LAST ```json fenced block from a file to stdout (empty if none).
sr_extract_last_json_fence() {
    awk '
        /^```json[[:space:]]*$/ { collecting = 1; buf = ""; next }
        /^```[[:space:]]*$/     { if (collecting) { collecting = 0; last = buf } ; next }
        collecting              { buf = buf $0 "\n" }
        END                     { printf "%s", last }
    ' "$1" 2>/dev/null
}
