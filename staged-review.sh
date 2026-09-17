#!/usr/bin/env bash
# staged-review.sh — iterative single-model code-review driver.
#   Reviewer: GPT-5.6 Sol @ xhigh (codex exec, ChatGPT sub, read-only sandbox).
#   Loop: one Sol pass per invocation until no findings remain at the selected
#   blocking severity. The compatibility default is major (critical+major);
#   repositories may select critical when their binding review rule does.
#   See README.md and skills/*/SKILL.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: staged-review.sh [options]
  --harness auto|claude|codex|dsh
                              harness (default auto: DSH_SESSION_ID -> dsh, CLAUDE_CODE_SESSION_ID -> claude, else local)
  --session <id>              override the session component of the state key
  --cwd <dir>                 workspace root to scan for git repos (default: $PWD)
  --intent-file <path>        extra intent addendum written by the calling agent
  --baseline <rev>            (re)record every repo's baseline at <rev> instead of HEAD
  --stage sol                 force the stage pointer (re-check a tree already marked done)
  --blocking-severity <level> loop gate: critical or major (default major; persisted in state)
  --dismiss ID="reason"       dismiss a finding with a justification (repeatable)
  --dismiss-only              record dismissals and exit (no review pass)
  --resolve-nonblocking ID="evidence"
                              after ALL CLEAN, record a fixed below-threshold finding (repeatable)
  --attempt-timeout <seconds> hard limit for each model attempt (default 0: wait indefinitely)
  --lock-timeout <seconds>    maximum wait for this session's lock (default 30)
  --status                    print state + findings ledger and exit
  --reset                     wipe this session's review state (next call re-baselines)
  --dry-run                   build the prompt bundle but call no model
Exit codes: 0 clean/all-clean/skipped, 1 findings to fix, 2 error.
USAGE
}

# ---- args -----------------------------------------------------------------
HARNESS=auto SESSION="" WCWD="$PWD" INTENT_FILE="" BASELINE_REV="" FORCE_STAGE=""
BLOCKING_SEVERITY="$STAGED_REVIEW_BLOCKING_SEVERITY" BLOCKING_SEVERITY_EXPLICIT=0
DISMISSALS=() RESOLUTIONS=()
DO_STATUS=0 DO_RESET=0 DRY_RUN=0 DISMISS_ONLY=0
while (( $# )); do
    case "$1" in
        --harness)      HARNESS="$2"; shift 2 ;;
        --harness=*)    HARNESS="${1#*=}"; shift ;;
        --session)      SESSION="$2"; shift 2 ;;
        --session=*)    SESSION="${1#*=}"; shift ;;
        --cwd)          WCWD="$2"; shift 2 ;;
        --cwd=*)        WCWD="${1#*=}"; shift ;;
        --intent-file)  INTENT_FILE="$2"; shift 2 ;;
        --intent-file=*) INTENT_FILE="${1#*=}"; shift ;;
        --baseline)     BASELINE_REV="$2"; shift 2 ;;
        --baseline=*)   BASELINE_REV="${1#*=}"; shift ;;
        --stage)        FORCE_STAGE="$2"; shift 2 ;;
        --stage=*)      FORCE_STAGE="${1#*=}"; shift ;;
        --blocking-severity) BLOCKING_SEVERITY="$2"; BLOCKING_SEVERITY_EXPLICIT=1; shift 2 ;;
        --blocking-severity=*) BLOCKING_SEVERITY="${1#*=}"; BLOCKING_SEVERITY_EXPLICIT=1; shift ;;
        --dismiss)      DISMISSALS+=("$2"); shift 2 ;;
        --dismiss=*)    DISMISSALS+=("${1#*=}"); shift ;;
        --dismiss-only) DISMISS_ONLY=1; shift ;;
        --resolve-nonblocking) RESOLUTIONS+=("$2"); shift 2 ;;
        --resolve-nonblocking=*) RESOLUTIONS+=("${1#*=}"); shift ;;
        --attempt-timeout) STAGED_REVIEW_ATTEMPT_TIMEOUT="$2"; shift 2 ;;
        --attempt-timeout=*) STAGED_REVIEW_ATTEMPT_TIMEOUT="${1#*=}"; shift ;;
        --lock-timeout) STAGED_REVIEW_LOCK_TIMEOUT="$2"; shift 2 ;;
        --lock-timeout=*) STAGED_REVIEW_LOCK_TIMEOUT="${1#*=}"; shift ;;
        --status)       DO_STATUS=1; shift ;;
        --reset)        DO_RESET=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) printf 'staged-review: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ ! "$STAGED_REVIEW_ATTEMPT_TIMEOUT" =~ ^[0-9]+$ ]]; then
    printf 'staged-review: STAGED_REVIEW_ATTEMPT_TIMEOUT must be zero or a positive integer (got %s)\n' \
        "$STAGED_REVIEW_ATTEMPT_TIMEOUT" >&2
    exit 2
fi
for timeout_setting in STAGED_REVIEW_LOCK_TIMEOUT STAGED_REVIEW_PROGRESS_INTERVAL; do
    timeout_value="${!timeout_setting}"
    if [[ ! "$timeout_value" =~ ^[1-9][0-9]*$ ]]; then
        printf 'staged-review: %s must be a positive integer (got %s)\n' \
            "$timeout_setting" "$timeout_value" >&2
        exit 2
    fi
done
if [[ ! "$STAGED_REVIEW_TERMINATE_GRACE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'staged-review: STAGED_REVIEW_TERMINATE_GRACE must be a non-negative number (got %s)\n' \
        "$STAGED_REVIEW_TERMINATE_GRACE" >&2
    exit 2
fi
case "$HARNESS" in auto|claude|codex|dsh) ;; *) printf 'staged-review: invalid --harness %s\n' "$HARNESS" >&2; exit 2 ;; esac
case "$BLOCKING_SEVERITY" in
    critical|major) ;;
    *) printf 'staged-review: invalid --blocking-severity %s (expected critical or major)\n' "$BLOCKING_SEVERITY" >&2; exit 2 ;;
esac
if [[ -n "$FORCE_STAGE" ]]; then
    case "$FORCE_STAGE" in sol) ;; *) printf 'staged-review: invalid --stage %s (only sol exists)\n' "$FORCE_STAGE" >&2; exit 2 ;; esac
fi
WCWD="$(cd "$WCWD" 2>/dev/null && pwd)" || { printf 'staged-review: bad --cwd\n' >&2; exit 2; }

# ---- harness / state key --------------------------------------------------
if [[ "$HARNESS" == "auto" ]]; then
    if [[ -n "${DSH_SESSION_ID:-}" ]]; then HARNESS=dsh
    elif [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then HARNESS=claude
    else HARNESS=local; fi
fi
case "$HARNESS" in
    dsh)    SID="${SESSION:-${DSH_SESSION_ID:-}}" ;;
    claude) SID="${SESSION:-${CLAUDE_CODE_SESSION_ID:-}}" ;;
    codex)  SID="${SESSION:-}" ;;   # Codex exposes no session id to shell commands: pass --session
    *)      SID="${SESSION:-}" ;;
esac
if [[ -z "$SID" ]]; then
    SID="cwd-$(printf '%s' "$WCWD" | shasum -a 256 | cut -c1-12)"
    sr_note "no session id available - state keyed by cwd hash ($SID); findings will not correlate across sessions"
fi
KEY="${HARNESS}-${SID}"
KEYDIR="${SR_STATE_ROOT}/${KEY}"
STATE="${KEYDIR}/state.json"

if (( DO_RESET )); then
    rm -rf "$KEYDIR"
    printf 'STAGED-REVIEW: stage=none pass=0 status=reset\nNEXT: State for %s wiped. The next invocation re-baselines and starts a fresh sol review loop.\n' "$KEY"
    exit 0
fi

mkdir -p "$KEYDIR"
sr_cleanup_stale
if ! sr_lock "$KEYDIR"; then
    printf 'STAGED-REVIEW: stage=unknown pass=0 status=error\nNEXT: session %s stayed locked by pid %s for %ss; inspect that process, then retry.\n' \
        "$KEY" "${SR_LOCK_OWNER_PID:-unknown}" "$STAGED_REVIEW_LOCK_TIMEOUT" >&2
    exit 2
fi
TRIPLETS=""
SR_ACTIVE_PID=""
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
sr_driver_cleanup() {
    if [[ -n "$SR_ACTIVE_PID" ]] && kill -0 "$SR_ACTIVE_PID" 2>/dev/null; then
        kill -TERM "$SR_ACTIVE_PID" 2>/dev/null || true
        wait "$SR_ACTIVE_PID" 2>/dev/null || true
    fi
    [[ -n "$TRIPLETS" ]] && rm -f "$TRIPLETS"
    sr_unlock
}
trap sr_driver_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

sr_save_state() {  # $1 = json on stdin -> atomic write
    local tmp="${STATE}.tmp.$$"
    cat > "$tmp" && mv "$tmp" "$STATE"
}

# One-time migration (2026-08-28): the glm and grok stages were removed - the
# review is now a single sol loop. Old GLM-n/GROK-n/KIMI-n finding ids stay
# as-is in the ledger; only live stage keys move.
if jq -e '((.passes // {}) | (has("glm") or has("grok") or has("kimi"))) or (.stage == "glm" or .stage == "grok" or .stage == "kimi")' "$STATE" >/dev/null 2>&1; then
    jq '
        .stage = (if .stage == "sol" or .stage == "done" then .stage else "sol" end)
        | .passes = {sol: (.passes.sol // 0)}
        | .next_finding_seq = {sol: (.next_finding_seq.sol // 1)}
    ' "$STATE" | sr_save_state
    sr_note "state migrated: the glm and grok stages were removed - single sol loop"
fi

# The gate is part of the review receipt, not an ambient assumption. Preserve
# the historical critical+major behavior when migrating old state; changing an
# active loop requires an explicit CLI option so an environment drift cannot
# silently weaken an in-progress review.
if [[ -f "$STATE" ]]; then
    RECORDED_BLOCKING_SEVERITY="$(jq -r '.blocking_severity // "major"' "$STATE")"
    if (( BLOCKING_SEVERITY_EXPLICIT )) && [[ "$BLOCKING_SEVERITY" != "$RECORDED_BLOCKING_SEVERITY" ]]; then
        jq --arg severity "$BLOCKING_SEVERITY" --arg now "$(sr_now)" \
            '.blocking_severity = $severity | .updated_at = $now' "$STATE" | sr_save_state
        sr_note "blocking severity changed explicitly: ${RECORDED_BLOCKING_SEVERITY} -> ${BLOCKING_SEVERITY}"
    else
        BLOCKING_SEVERITY="$RECORDED_BLOCKING_SEVERITY"
        if ! jq -e 'has("blocking_severity")' "$STATE" >/dev/null; then
            jq --arg severity "$BLOCKING_SEVERITY" --arg now "$(sr_now)" \
                '.blocking_severity = $severity | .updated_at = $now' "$STATE" | sr_save_state
            sr_note "state migrated: blocking severity recorded as $BLOCKING_SEVERITY"
        fi
    fi
fi

# ---- init / baselines -----------------------------------------------------
mapfile -t ALL_REPOS < <(discover_git_repos "$WCWD")
if (( ${#ALL_REPOS[@]} == 0 )); then
    printf 'STAGED-REVIEW: stage=none pass=0 status=skipped\nNEXT: no git repository found at or below %s - nothing to review.\n' "$WCWD"
    exit 0
fi
# Confinement precondition: repos must not live in a reviewer-writable area.
TMPD="${TMPDIR:-/nonexistent}"
for r in "${ALL_REPOS[@]}"; do
    case "$r" in
        /tmp/*|/private/tmp/*|"${TMPD%/}"/*)
            printf 'STAGED-REVIEW: stage=none pass=0 status=error\nNEXT: repo %s lives under a temp dir the reviewer sandbox can write to - move it or review it manually.\n' "$r" >&2
            exit 2 ;;
    esac
done

NOW="$(sr_now)"
if [[ ! -f "$STATE" ]]; then
    BASE_JSON="[]"
    for r in "${ALL_REPOS[@]}"; do
        rel="$(relpath_under "$r" "$WCWD")"
        if [[ -n "$BASELINE_REV" ]]; then
            tree="$(sr_tree_of "$r" "$BASELINE_REV")"
            if [[ -z "$tree" ]]; then
                printf 'STAGED-REVIEW: stage=none pass=0 status=error\nNEXT: --baseline %s does not resolve in %s.\n' "$BASELINE_REV" "$r" >&2
                exit 2
            fi
        else
            tree="$(sr_head_tree "$r")"
        fi
        commit="$(git -C "$r" rev-parse HEAD 2>/dev/null || printf '%s' "$SR_EMPTY_TREE")"
        BASE_JSON="$(jq -c --arg repo "$r" --arg rel "$rel" --arg tree "$tree" --arg commit "$commit" --arg now "$NOW" \
            '. + [{repo:$repo, rel:$rel, tree:$tree, commit:$commit, recorded_at:$now, note:null}]' <<< "$BASE_JSON")"
    done
    jq -n --arg h "$HARNESS" --arg sid "$SID" --arg cwd "$WCWD" --arg now "$NOW" --arg blocking "$BLOCKING_SEVERITY" --argjson epoch "$(date +%s)" --argjson baselines "$BASE_JSON" '
        {version: 1, harness: $h, session_id: $sid, cwd: $cwd,
         created_at: $now, created_epoch: $epoch, updated_at: $now,
         stage: "sol", blocking_severity: $blocking, passes: {sol: 0},
         next_finding_seq: {sol: 1}, run_seq: 0,
         baselines: $baselines, findings: [], runs: []}' | sr_save_state
elif [[ -n "$BASELINE_REV" ]]; then
    BASE_JSON="[]"
    for r in "${ALL_REPOS[@]}"; do
        rel="$(relpath_under "$r" "$WCWD")"
        tree="$(sr_tree_of "$r" "$BASELINE_REV")"
        if [[ -z "$tree" ]]; then
            printf 'STAGED-REVIEW: stage=none pass=0 status=error\nNEXT: --baseline %s does not resolve in %s.\n' "$BASELINE_REV" "$r" >&2
            exit 2
        fi
        commit="$(git -C "$r" rev-parse "$BASELINE_REV" 2>/dev/null || printf '%s' "$SR_EMPTY_TREE")"
        BASE_JSON="$(jq -c --arg repo "$r" --arg rel "$rel" --arg tree "$tree" --arg commit "$commit" --arg now "$NOW" \
            '. + [{repo:$repo, rel:$rel, tree:$tree, commit:$commit, recorded_at:$now, note:"explicit --baseline"}]' <<< "$BASE_JSON")"
    done
    jq --argjson baselines "$BASE_JSON" --arg now "$NOW" '.baselines = $baselines | .updated_at = $now' "$STATE" | sr_save_state
    sr_note "baselines re-recorded at --baseline $BASELINE_REV (ledger kept)"
fi

# New repos discovered mid-run: baseline on sight.
CREATED_EPOCH="$(jq -r '.created_epoch // 0' "$STATE")"
for r in "${ALL_REPOS[@]}"; do
    known="$(jq -r --arg repo "$r" '[.baselines[] | select(.repo == $repo)] | length' "$STATE")"
    if [[ "$known" == "0" ]]; then
        rel="$(relpath_under "$r" "$WCWD")"
        first_ts="$(git -C "$r" log --format=%ct 2>/dev/null | tail -1)"
        if [[ -n "$first_ts" && "$first_ts" -gt "$CREATED_EPOCH" ]]; then
            tree="$SR_EMPTY_TREE"   # repo authored during this session: review it whole
        else
            tree="$(sr_head_tree "$r")"
        fi
        commit="$(git -C "$r" rev-parse HEAD 2>/dev/null || printf '%s' "$SR_EMPTY_TREE")"
        jq --arg repo "$r" --arg rel "$rel" --arg tree "$tree" --arg commit "$commit" --arg now "$(sr_now)" \
            '.baselines += [{repo:$repo, rel:$rel, tree:$tree, commit:$commit, recorded_at:$now, note:"discovered mid-run"}]' \
            "$STATE" | sr_save_state
        sr_note "new repo discovered and baselined: $rel"
    fi
done
# Baseline trees lost to history rewrites: re-baseline loudly.
while IFS=$'\t' read -r r tree; do
    [[ -z "$r" ]] && continue
    if ! git -C "$r" cat-file -e "$tree" 2>/dev/null; then
        newtree="$(sr_head_tree "$r")"
        jq --arg repo "$r" --arg tree "$newtree" --arg now "$(sr_now)" \
            '.baselines |= map(if .repo == $repo then . + {tree: $tree, note: "re-baselined: original tree lost to a history rewrite", recorded_at: $now} else . end)' \
            "$STATE" | sr_save_state
        sr_note "BASELINE LOST for $r (history rewrite?) - re-baselined at current HEAD; earlier committed changes are now out of review scope (use --baseline to widen)"
    fi
done < <(jq -r '.baselines[] | [.repo, .tree] | @tsv' "$STATE")

# ---- dismissals -----------------------------------------------------------
for d in ${DISMISSALS[@]+"${DISMISSALS[@]}"}; do
    id="${d%%=*}"; reason="${d#*=}"
    if [[ -z "$id" || "$id" == "$d" ]]; then sr_note "dismissal ignored (use --dismiss ID=\"reason\"): $d"; continue; fi
    st="$(jq -r --arg id "$id" '(.findings[] | select(.id == $id) | .status) // "missing"' "$STATE")"
    case "$st" in
        open)      jq --arg id "$id" --arg r "$reason" --arg s "$(jq -r .stage "$STATE")" \
                      '.findings |= map(if .id == $id then . + {status: "dismissed", dismiss_reason: $r, status_stage: $s} else . end)' \
                      "$STATE" | sr_save_state ;;
        dismissed) sr_note "dismissal: $id was already dismissed" ;;
        resolved)  sr_note "dismissal ignored: $id is already resolved" ;;
        *)         sr_note "dismissal ignored: no finding with id $id" ;;
    esac
done

STAGE="$(jq -r .stage "$STATE")"
if [[ -n "$FORCE_STAGE" ]]; then
    jq --arg s "$FORCE_STAGE" '.stage = $s' "$STATE" | sr_save_state
    STAGE="$FORCE_STAGE"
    sr_note "stage forced to $FORCE_STAGE"
fi

# A clean loop may deliberately leave findings below its selected threshold.
# Repository landing rules can still require those findings to be fixed. Let
# the engineer record that post-clean fix without manufacturing another model
# round, but only for an already-clean loop and never for a blocking severity.
if (( ${#RESOLUTIONS[@]} )); then
    if [[ "$STAGE" != "done" ]]; then
        printf 'staged-review: --resolve-nonblocking requires an ALL CLEAN review state\n' >&2
        exit 2
    fi
    for resolution in "${RESOLUTIONS[@]}"; do
        id="${resolution%%=*}"
        reason="${resolution#*=}"
        if [[ -z "$id" || "$id" == "$resolution" || -z "$reason" ]]; then
            printf 'staged-review: invalid --resolve-nonblocking value (use ID="evidence"): %s\n' "$resolution" >&2
            exit 2
        fi
        finding="$(jq -c --arg id "$id" '.findings[]? | select(.id == $id)' "$STATE")"
        if [[ -z "$finding" ]]; then
            printf 'staged-review: cannot resolve %s: finding does not exist\n' "$id" >&2
            exit 2
        fi
        finding_status="$(jq -r '.status' <<<"$finding")"
        finding_severity="$(jq -r '.severity' <<<"$finding")"
        if [[ "$finding_status" != "open" ]]; then
            printf 'staged-review: cannot resolve %s: status is %s, not open\n' "$id" "$finding_status" >&2
            exit 2
        fi
        if [[ "$finding_severity" == "critical" ]] || \
            [[ "$BLOCKING_SEVERITY" == "major" && "$finding_severity" == "major" ]]; then
            printf 'staged-review: cannot resolve %s without review: %s blocks at the %s threshold\n' \
                "$id" "$finding_severity" "$BLOCKING_SEVERITY" >&2
            exit 2
        fi
    done
    for resolution in "${RESOLUTIONS[@]}"; do
        id="${resolution%%=*}"
        reason="${resolution#*=}"
        jq --arg id "$id" --arg reason "$reason" --arg now "$(sr_now)" '
            (.passes.sol // 0) as $pass
            | .findings |= map(if .id == $id then . + {
                status: "resolved", status_stage: "post-clean",
                status_pass: $pass, resolution_reason: $reason,
                resolved_at: $now
            } else . end)
            | .updated_at = $now
        ' "$STATE" | sr_save_state
        printf 'RESOLVED-NONBLOCKING: %s — %s\n' "$id" "$reason"
    done

    # Post-clean fixes intentionally move the tree after the review verdict.
    # Refresh the hook receipt only after every requested ledger update passed.
    mapfile -t HASH_REPOS < <(jq -r '.baselines[].repo' "$STATE")
    WT_HASH="$(sr_worktree_hash "${HASH_REPOS[@]}")"
    printf '%s\n' "$WT_HASH" > "${KEYDIR}/staged_clean.hash"
    if [[ "$HARNESS" == "claude" ]]; then
        mkdir -p "${HOME}/.claude/state/codex-review/${SID}"
        printf '%s\n' "$WT_HASH" > "${HOME}/.claude/state/codex-review/${SID}/staged_clean.hash"
    fi
fi

sr_print_status() {
    local st="$1"
    jq -r --argjson rmax "$STAGED_REVIEW_RENDER_MAX" '
        "STAGED-REVIEW: stage=\(.stage) pass=\(.passes[.stage] // 0) status=status-report",
        "Session key: \(.harness)-\(.session_id)  cwd: \(.cwd)  created: \(.created_at)",
        "Blocking severity: \(.blocking_severity // "major")",
        "Passes: sol=\(.passes.sol // 0)",
        "Baselines:", (.baselines[] | "  \(.rel): tree \(.tree[0:12]) (\(.note // "session start"))"),
        "Findings:",
        (if (.findings | length) == 0 then "  (none)" else
            (.findings[] | "  [\(.status)] \(.id) [\(.severity)/\(.kind)] \(.file):\(.line) - \(.issue[0:$rmax])\(if .status == "dismissed" then " (dismissed: \(.dismiss_reason // ""))" elif .status == "resolved" and .resolution_reason != null then " (resolved after clean: \(.resolution_reason))" else "" end)")
         end)
    ' "$st"
}

if (( DO_STATUS )); then sr_print_status "$STATE"; exit 0; fi
if (( DISMISS_ONLY )); then sr_print_status "$STATE"; exit 0; fi

if [[ "$STAGE" == "done" ]]; then
    printf 'STAGED-REVIEW: stage=done pass=%s status=all-clean blocking=%s\nALL CLEAN\nNEXT: Review round already complete at the recorded %s threshold. Use --reset for a new round, or --stage sol to re-check the current tree.\n' \
        "$(jq -r '.passes.sol' "$STATE")" "$BLOCKING_SEVERITY" "$BLOCKING_SEVERITY"
    exit 0
fi

# ---- anything to review? --------------------------------------------------
TRIPLETS="$(mktemp -t sr-triplets.XXXXXX)"
jq -r '.baselines[] | [.repo, .rel, .tree] | @tsv' "$STATE" > "$TRIPLETS"
CHANGED=0
while IFS=$'\t' read -r r rel tree; do
    [[ -z "$r" ]] && continue
    if sr_repo_changed "$r" "$tree"; then CHANGED=1; fi
done < "$TRIPLETS"
if (( ! CHANGED )); then
    printf 'STAGED-REVIEW: stage=%s pass=%s status=skipped\nNEXT: no changes vs the recorded baselines - make changes first, or --reset to re-baseline.\n' \
        "$STAGE" "$(jq -r --arg s "$STAGE" '.passes[$s] // 0' "$STATE")"
    exit 0
fi

# ---- run dir + bundle -----------------------------------------------------
RUN_SEQ="$(( $(jq -r .run_seq "$STATE") + 1 ))"
RUN_DIR="${KEYDIR}/runs/$(printf '%03d' "$RUN_SEQ")-${STAGE}"
SCRATCH="${RUN_DIR}/scratch"
mkdir -p "$SCRATCH"
PASS="$(( $(jq -r --arg s "$STAGE" '.passes[$s] // 0' "$STATE") + 1 ))"

sr_build_intent "$HARNESS" "$SID" "$INTENT_FILE" "${RUN_DIR}/intent.md"
sr_render_ledger "$STATE" > "${RUN_DIR}/ledger.md"

REPO_LIST=""
while IFS=$'\t' read -r r rel tree; do
    [[ -z "$r" ]] && continue
    sr_repo_changed "$r" "$tree" && REPO_LIST+="- ${rel} -> ${r}"$'\n'
done < "$TRIPLETS"

sr_build_diff_only "$TRIPLETS" "${RUN_DIR}/diff.md"
PROMPT="${RUN_DIR}/prompt.md"
{
    printf 'You are the reviewer (pass %s) of an iterative code-review loop.\n' "$PASS"
    printf "The driver records \`%s\` as this loop's blocking severity. Classify findings by actual impact; do not promote or demote them to influence the loop.\n" "$BLOCKING_SEVERITY"
    printf 'Repositories under review (read-only):\n%s\n' "$REPO_LIST"
    cat "${SCRIPT_DIR}/templates/preamble-sol.md"
    printf '\n# Stated intent\n\n'; cat "${RUN_DIR}/intent.md"
    printf '\n# Prior findings ledger\n\n'; cat "${RUN_DIR}/ledger.md"
    printf '\n# Diffs under review\n\n'; cat "${RUN_DIR}/diff.md"
    printf '\n# Output discipline\n\nReturn one JSON object matching the enforced schema. Every id listed under "Open" above MUST appear in exactly one of "resolved" or "still_open" (verify each in the code first). "findings" is ONLY for NEW issues. A dismissed id may only appear in "reraised", with concrete new evidence. Use empty arrays when there is nothing.\n\nIf you CANNOT review this change-set, set "refused": true with a "refusal_reason" and return no findings. Refuse when the stated intent describes a different change than the diff, when the diff is truncated or internally inconsistent, or when the bundle is otherwise unusable. Refusing is correct and costs nothing: it records the run without advancing the pass counter. Reviewing the wrong thing costs a round and leaves a ledger entry asserting work nobody did.\n'
} > "$PROMPT"

if (( DRY_RUN )); then
    printf 'STAGED-REVIEW: stage=%s pass=%s status=skipped\nNEXT: dry run - no model was called and no state advanced. Inspect:\n  %s\n' \
        "$STAGE" "$PASS" "$RUN_DIR"
    for n in ${SR_NOTES[@]+"${SR_NOTES[@]}"}; do printf '  note: %s\n' "$n"; done
    exit 0
fi

# ---- invoke ---------------------------------------------------------------
sr_run_bounded() {       # args are passed to run-with-timeout.py
    "$STAGED_REVIEW_PYTHON_BIN" "$STAGED_REVIEW_TIMEOUT_RUNNER" "$@" &
    SR_ACTIVE_PID=$!
    wait "$SR_ACTIVE_PID"
    local rc=$?
    SR_ACTIVE_PID=""
    return "$rc"
}

sr_invoke_sol() {        # $1 = attempt number
    local n="$1"
    sr_run_bounded \
        --timeout "$STAGED_REVIEW_ATTEMPT_TIMEOUT" \
        --progress-interval "$STAGED_REVIEW_PROGRESS_INTERVAL" \
        --grace "$STAGED_REVIEW_TERMINATE_GRACE" \
        --label "$STAGE attempt $n" \
        --cwd "$WCWD" \
        --stdin "$PROMPT" \
        --stdout "${RUN_DIR}/codex-events.attempt${n}.log" \
        --stderr "${RUN_DIR}/stderr.attempt${n}.log" \
        -- "$STAGED_REVIEW_CODEX_BIN" exec --skip-git-repo-check --ephemeral -C "$WCWD" \
        --model "$STAGED_REVIEW_SOL_MODEL" \
        -c "model_reasoning_effort=\"${STAGED_REVIEW_SOL_REASONING}\"" \
        --sandbox read-only \
        --output-schema "${SCRIPT_DIR}/schemas/review-output.schema.json" \
        --output-last-message "${RUN_DIR}/sol-output.attempt${n}.json" \
        -
}

sr_get_validated() {     # $1 = attempt -> prints validated JSON, rc 0 when ok
    local n="$1" raw="" v
    [[ -s "${RUN_DIR}/sol-output.attempt${n}.json" ]] && raw="$(cat "${RUN_DIR}/sol-output.attempt${n}.json")"
    if [[ -z "$raw" ]] || ! jq -e . >/dev/null 2>&1 <<< "$raw"; then
        raw="$(sr_extract_last_json_fence "${RUN_DIR}/sol-output.attempt${n}.json" 2>/dev/null)"
    fi
    [[ -z "$raw" ]] && return 1
    jq -e . >/dev/null 2>&1 <<< "$raw" || return 1
    v="$(jq -f "${SCRIPT_DIR}/lib/validate.jq" <<< "$raw")" || return 1
    [[ "$(jq -r .ok <<< "$v")" == "true" ]] || return 1
    printf '%s' "$v"
}

VALIDATED=""
ATTEMPT_RESULTS=""
for attempt in 1 2; do
    if (( attempt == 2 )); then
        sr_note "attempt 1 produced no valid output - retrying with a stricter notice"
        { printf '\n'; cat "${SCRIPT_DIR}/templates/retry-notice.md"; } >> "$PROMPT"
    fi
    sr_invoke_sol "$attempt"
    RC=$?
    ATTEMPT_RESULTS+="${attempt}=${RC} "
    if (( RC == 0 )) && VALIDATED="$(sr_get_validated "$attempt")"; then break; fi
    VALIDATED=""
    if (( RC == 124 )); then
        sr_note "attempt ${attempt}: reviewer exceeded the ${STAGED_REVIEW_ATTEMPT_TIMEOUT}s hard limit"
    elif (( RC != 0 )); then
        sr_note "attempt ${attempt}: reviewer process exited rc=${RC}"
    fi
    (( attempt == 1 )) && log_debug "staged-review: $STAGE attempt 1 failed (rc=$RC)"
done

if [[ -z "$VALIDATED" ]]; then
    ERR_TAIL="$(tail -n 3 "${RUN_DIR}"/stderr.attempt*.log 2>/dev/null | tr '\n' ' ' | head -c 400)"
    jq --arg s "$STAGE" --argjson seq "$RUN_SEQ" --argjson pass "$PASS" --arg dir "runs/$(printf '%03d' "$RUN_SEQ")-${STAGE}" --arg now "$(sr_now)" \
        '.run_seq = $seq | .runs += [{seq: $seq, stage: $s, pass: $pass, dir: $dir, ended: $now, result: "error"}] | .updated_at = $now' \
        "$STATE" | sr_save_state
    printf 'STAGED-REVIEW: stage=%s pass=%s status=error attempt_rcs="%s"\nSTDERR-TAIL: %s\nNEXT: the %s reviewer did not exit successfully with parsable output after 2 bounded attempts. Inspect %s, then re-run this command to retry.\n' \
        "$STAGE" "$PASS" "${ATTEMPT_RESULTS% }" "${ERR_TAIL:-no stderr}" "$STAGE" "$RUN_DIR" >&2
    exit 2
fi

# ---- merge + transition ---------------------------------------------------
PREFIX=SOL
VNOTES="$(jq -c .notes <<< "$VALIDATED")"
OUT="$(jq -c .out <<< "$VALIDATED")"

# A REFUSAL IS NOT A PASS.
#
# A reviewer handed an unusable bundle -- a stated intent describing a different
# change, a truncated diff -- should decline rather than review the wrong thing.
# That is a valid, parsable answer, and it must not advance the pass counter:
# otherwise the exit code, the events file and .passes all read as success on a
# review that examined nothing, and the ledger records work nobody did.
#
# Mirrors the "error" path above (unparsable output), which likewise records the
# run without advancing .passes.
if [[ "$(jq -r '.refused // false' <<< "$OUT")" == "true" ]]; then
    REFUSAL_REASON="$(jq -r '.refusal_reason // "no reason given"' <<< "$OUT")"
    jq --arg s "$STAGE" --argjson seq "$RUN_SEQ" --argjson pass "$PASS" \
       --arg dir "runs/$(printf '%03d' "$RUN_SEQ")-${STAGE}" --arg now "$(sr_now)" \
       --arg reason "$REFUSAL_REASON" '
        .run_seq = $seq
        | .runs += [{seq: $seq, stage: $s, pass: $pass, dir: $dir, ended: $now,
                     result: "refused", refusal_reason: $reason}]
        | .updated_at = $now' "$STATE" | sr_save_state
    printf 'STAGED-REVIEW: stage=%s pass=%s status=refused\nREASON: %s\nNEXT: the reviewer declined to review this bundle; the pass counter was NOT advanced. Fix the cause (check %s/intent.md first) and re-run.\n' \
        "$STAGE" "$PASS" "$REFUSAL_REASON" "$RUN_DIR" >&2
    exit 2
fi

MERGED="$(jq -f "${SCRIPT_DIR}/lib/merge.jq" \
    --argjson out "$OUT" --argjson vnotes "$VNOTES" \
    --arg stage "$STAGE" --argjson pass "$PASS" --arg now "$(sr_now)" --arg prefix "$PREFIX" \
    "$STATE")" || { printf 'STAGED-REVIEW: stage=%s pass=%s status=error\nNEXT: internal merge failure - inspect %s.\n' "$STAGE" "$PASS" "$RUN_DIR" >&2; exit 2; }

case "$BLOCKING_SEVERITY" in
    critical) OPEN_BLOCKING="$(jq -r '.summary.counts.open_critical' <<< "$MERGED")" ;;
    major)    OPEN_BLOCKING="$(jq -r '.summary.counts.open_critical + .summary.counts.open_major' <<< "$MERGED")" ;;
esac
OPEN_TOTAL="$(jq -r '[.state.findings[] | select(.status == "open")] | length' <<< "$MERGED")"
if (( OPEN_BLOCKING == 0 )); then NEXT_STAGE="done"; else NEXT_STAGE=sol; fi
if [[ "$NEXT_STAGE" == "done" ]]; then STATUS=all-clean; EXIT=0
elif (( OPEN_TOTAL > 0 )); then STATUS=findings; EXIT=1
else STATUS=clean; EXIT=0; fi

RUN_DIR_REL="runs/$(printf '%03d' "$RUN_SEQ")-${STAGE}"
jq -c .state <<< "$MERGED" | jq \
    --arg s "$STAGE" --arg next "$NEXT_STAGE" --argjson seq "$RUN_SEQ" --argjson pass "$PASS" \
    --arg dir "$RUN_DIR_REL" --arg now "$(sr_now)" --arg result "$STATUS" --argjson exit "$EXIT" '
    .stage = $next | .passes[$s] = $pass | .run_seq = $seq
    | .runs += [{seq: $seq, stage: $s, pass: $pass, dir: $dir, ended: $now, result: $result, exit: $exit}]
    | .updated_at = $now' | sr_save_state

SUMMARY_FILE="${RUN_DIR}/summary.json"
if (( ${#SR_NOTES[@]} )); then
    NOTES_JSON="$(printf '%s\n' "${SR_NOTES[@]}" | jq -R . | jq -sc .)"
else
    NOTES_JSON="[]"
fi
jq -c .summary <<< "$MERGED" | jq --arg status "$STATUS" --arg next "$NEXT_STAGE" --arg blocking "$BLOCKING_SEVERITY" --argjson open_blocking "$OPEN_BLOCKING" --argjson exitc "$EXIT" \
    --arg dir "$RUN_DIR" --argjson notes "$NOTES_JSON" \
    '. + {status: $status, next_stage: $next, blocking_severity: $blocking,
          open_blocking: $open_blocking, exit: $exitc, run_dir: $dir,
          notes: (.validation_notes + $notes)}' > "$SUMMARY_FILE"

# ALL CLEAN marker for the Claude Stop hook.
if [[ "$STATUS" == "all-clean" ]]; then
    mapfile -t HASH_REPOS < <(jq -r '.baselines[].repo' "$STATE")
    WT_HASH="$(sr_worktree_hash "${HASH_REPOS[@]}")"
    printf '%s\n' "$WT_HASH" > "${KEYDIR}/staged_clean.hash"
    if [[ "$HARNESS" == "claude" ]]; then
        mkdir -p "${HOME}/.claude/state/codex-review/${SID}"
        printf '%s\n' "$WT_HASH" > "${HOME}/.claude/state/codex-review/${SID}/staged_clean.hash"
    fi
fi

# ---- report ---------------------------------------------------------------
C="$(jq -r '[.counts.new, .counts.resolved, .counts.still_open, .counts.unconfirmed, .counts.open_critical, .counts.open_major, .counts.open_minor] | @tsv' "$SUMMARY_FILE")"
IFS=$'\t' read -r N_NEW N_RES N_STILL N_UNCONF N_CRIT N_MAJ N_MIN <<< "$C"

printf 'STAGED-REVIEW: stage=%s pass=%s status=%s blocking=%s open_blocking=%s new=%s resolved=%s still_open=%s unconfirmed=%s open_critical=%s open_major=%s open_minor=%s next=%s\n' \
    "$STAGE" "$PASS" "$STATUS" "$BLOCKING_SEVERITY" "$OPEN_BLOCKING" "$N_NEW" "$N_RES" "$N_STILL" "$N_UNCONF" "$N_CRIT" "$N_MAJ" "$N_MIN" "$NEXT_STAGE"
printf 'SUMMARY-FILE: %s\n' "$SUMMARY_FILE"
case "$STATUS" in
    all-clean)
        printf 'ALL CLEAN\nNEXT: No open findings at the %s blocking threshold - the review loop is complete. Address every nonblocking finding as required by the repository\x27s landing rules, without another review pass unless those rules require one.\n' "$BLOCKING_SEVERITY" ;;
    clean)
        printf 'NEXT: sol pass was clean but open items remain - re-run this command.\n' ;;
    findings)
        printf 'NEXT: fix findings blocking at the %s threshold (fix nonblocking findings in the same pass too), dismiss false positives with --dismiss ID="reason", then re-run this exact command with the same --blocking-severity.\n' "$BLOCKING_SEVERITY" ;;
esac

jq -r --argjson rmax "$STAGED_REVIEW_RENDER_MAX" --argjson lmax "$STAGED_REVIEW_LIST_MAX" '
    def cap: .[0:$rmax];
    def fmt: "- [\(.id)] [\(.severity)/\(.kind)] \(.file):\(.line) - \(.issue | cap)\n  Fix: \(.fix | cap)";
    (if (.new | length) > 0 then
        "\n## New findings (stage \(.stage), pass \(.pass))",
        (["critical", "major", "minor"][] as $sev
         | ([.new[] | select(.severity == $sev)]) as $g
         | if ($g | length) > 0 then "### \($sev)", ($g[:$lmax][] | fmt),
             (if ($g | length) > $lmax then "  (+\(($g | length) - $lmax) more - see SUMMARY-FILE)" else empty end)
           else empty end)
     else "\n(no new findings this pass)" end),
    (.still_open + .unconfirmed) as $carry
    | (if ($carry | length) > 0 then
        "\n## Still open from earlier passes\(if (.unconfirmed | length) > 0 then " (unconfirmed: \(.unconfirmed | join(", ")))" else "" end)",
        (.open[] | select(.id as $i | $carry | index($i) != null) | fmt)
       else empty end),
    (if (.resolved | length) > 0 then "\n## Resolved this pass", "- \(.resolved | join(", "))" else empty end),
    (if (.reraised | length) > 0 then "\n## Re-raised (dismissed items with new evidence)",
        (.reraised[] | "- \(.id): \(.evidence | cap)") else empty end),
    (if (.reviewer_summary // "") != "" then "\n## Reviewer summary", (.reviewer_summary | cap) else empty end),
    (if (.notes | length) > 0 then "\n## Notes", (.notes[] | "- \(.)") else empty end)
' "$SUMMARY_FILE"

# Dismissed section from the ledger (reasons live in state, not the summary).
jq -r --argjson rmax "$STAGED_REVIEW_RENDER_MAX" '
    ([.findings[] | select(.status == "dismissed")]) as $d
    | if ($d | length) > 0 then
        "\n## Dismissed (reviewers may re-raise only with new evidence)",
        ($d[] | "- [\(.id)] \(.file):\(.line) - \(.issue[0:$rmax]) - reason: \(.dismiss_reason // "n/a")")
      else empty end
' "$STATE"

exit "$EXIT"
