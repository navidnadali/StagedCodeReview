# shellcheck shell=bash
# Git / intent / hook helpers shared by the driver and the Claude Code capture hooks.
# Sourced, never executed directly. Provides:
#   - load_env
#   - project_opted_in <cwd>
#   - is_git_repo <cwd>
#   - discover_git_repos <cwd>
#   - has_diff <repo>
#   - git_full_diff <repo>
#   - relpath_under <path> <base>
#   - state_dir <session_id>
#   - cleanup_stale_state
#   - extract_transcript_summary <path> [max_bytes]
#   - build_intent_bundle <state_dir> [transcript_path]
#   - emit_hook_json <decision> <reason> [systemMessage]
#   - log_debug <msg>

CODEX_REVIEW_HOME="${HOME}/.claude"
CODEX_REVIEW_STATE_ROOT="${CODEX_REVIEW_HOME}/state/codex-review"
CODEX_REVIEW_LOG="${CODEX_REVIEW_HOME}/state/codex-review/debug.log"

: "${CODEX_REVIEW_MODEL:=gpt-5.6-sol}"
: "${CODEX_REVIEW_REASONING:=xhigh}"
: "${CODEX_REVIEW_MAX_ITER:=5}"

load_env() {
    local env_file="${CODEX_REVIEW_HOME}/.env"
    [[ -f "$env_file" ]] || return 0
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

project_opted_in() {
    local cwd="$1"
    [[ -f "${cwd}/.claude/codex-review.enabled" ]]
}

is_git_repo() {
    local cwd="$1"
    git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Print one or more git repo roots reachable from <cwd>, one per line.
#   - If cwd is inside a git repo, print that repo's toplevel (preserves single-repo behavior, including when cwd is a subdir).
#   - Otherwise, scan immediate child directories (depth 1) for git repos and print each toplevel.
#   - Skips dotted directories (.git, .cache, etc.) and common heavy dirs (node_modules, vendor) to avoid scanning into dependency trees.
discover_git_repos() {
    local cwd="$1"
    local toplevel
    if toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"; then
        printf '%s\n' "$toplevel"
        return 0
    fi
    local d name
    for d in "$cwd"/*/; do
        [[ -d "${d%/}" ]] || continue
        name="$(basename "${d%/}")"
        case "$name" in
            .*|node_modules|vendor) continue ;;
        esac
        toplevel="$(git -C "${d%/}" rev-parse --show-toplevel 2>/dev/null)" || continue
        printf '%s\n' "$toplevel"
    done
}

has_diff() {
    local cwd="$1"
    if ! { git -C "$cwd" diff --quiet && git -C "$cwd" diff --cached --quiet; }; then
        return 0
    fi
    # Also true if there are untracked-not-ignored files.
    [[ -n "$(git -C "$cwd" ls-files --others --exclude-standard 2>/dev/null)" ]]
}

# Print the full diff for a repo: tracked changes (HEAD vs working tree, or working
# tree only on an empty repo) plus synthesized add-only diffs for every
# untracked-not-ignored file. Makes brand-new files visible to the reviewer
# even when Claude hasn't staged them yet.
git_full_diff() {
    local repo="$1"
    git -C "$repo" diff HEAD 2>/dev/null || git -C "$repo" diff
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # --no-index returns exit 1 whenever the files differ (always, here vs /dev/null),
        # so swallow the non-zero exit.
        git -C "$repo" diff --no-index --binary -- /dev/null "$f" 2>/dev/null || true
    done < <(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)
}

# Print a path relative to a base, falling back to the absolute path if not a descendant.
relpath_under() {
    local path="$1" base="$2"
    if [[ "$path" == "$base" ]]; then
        printf '.'
    elif [[ "$path" == "$base"/* ]]; then
        printf '%s' "${path#"$base"/}"
    else
        printf '%s' "$path"
    fi
}

state_dir() {
    local session_id="$1"
    local dir="${CODEX_REVIEW_STATE_ROOT}/${session_id}"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

cleanup_stale_state() {
    [[ -d "$CODEX_REVIEW_STATE_ROOT" ]] || return 0
    find "$CODEX_REVIEW_STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 \
        -exec rm -rf {} + 2>/dev/null || true
}

# Pull a compact user+assistant text summary from a Claude Code session transcript JSONL.
# Skips tool_use / tool_result / thinking / attachment entries (diff is separately included).
# Keeps the tail when the extracted text exceeds max_bytes, since the late exchanges are
# the most relevant to "what did Claude just do" at Stop time.
extract_transcript_summary() {
    local transcript_path="$1"
    local max_bytes="${2:-12000}"

    [[ -n "$transcript_path" && -f "$transcript_path" ]] || return 0

    local extracted
    extracted="$(jq -r '
        select(.type == "user" or .type == "assistant")
        | (.message.role // .type) as $role
        | (.message.content) as $c
        | if ($c | type) == "string" then
              "### " + $role + "\n" + $c
          elif ($c | type) == "array" then
              ($c | map(select(.type == "text") | .text) | join("\n")) as $text
              | if ($text | length) == 0 then empty else "### " + $role + "\n" + $text end
          else empty end
    ' "$transcript_path" 2>/dev/null)"

    [[ -z "$extracted" ]] && return 0

    local size=${#extracted}
    if (( size > max_bytes )); then
        local offset=$(( size - max_bytes ))
        printf '_[earlier %d bytes of transcript truncated]_\n\n%s' "$offset" "${extracted:offset}"
    else
        printf '%s' "$extracted"
    fi
}

build_intent_bundle() {
    local dir="$1"
    local transcript_path="${2:-}"
    local out=""
    if [[ -f "${dir}/intent.md" ]]; then
        out+="${out:+$'\n\n'}$(cat "${dir}/intent.md")"
    fi
    if [[ -f "${dir}/plan.md" ]]; then
        out+="${out:+$'\n\n'}## Approved plan"$'\n\n'"$(cat "${dir}/plan.md")"
    elif [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
        local summary
        summary="$(extract_transcript_summary "$transcript_path")"
        if [[ -n "$summary" ]]; then
            out+="${out:+$'\n\n'}## Session transcript (no plan was captured; user+assistant messages only)"$'\n\n'"$summary"
        fi
    fi
    if [[ -f "${dir}/todos.md" ]]; then
        out+="${out:+$'\n\n'}## Final todo state"$'\n\n'"$(cat "${dir}/todos.md")"
    fi
    printf '%s' "$out"
}

emit_hook_json() {
    local decision="$1"
    local reason="${2:-}"
    local sys_msg="${3:-}"
    if [[ -n "$sys_msg" ]]; then
        jq -nc --arg d "$decision" --arg r "$reason" --arg s "$sys_msg" \
            '{decision: $d, reason: $r, systemMessage: $s} | with_entries(select(.value != ""))'
    elif [[ -n "$reason" ]]; then
        jq -nc --arg d "$decision" --arg r "$reason" '{decision: $d, reason: $r}'
    elif [[ -n "$decision" ]]; then
        jq -nc --arg d "$decision" '{decision: $d}'
    else
        printf '{}'
    fi
}

log_debug() {
    [[ "${CODEX_REVIEW_DEBUG:-0}" == "1" ]] || return 0
    mkdir -p "$(dirname "$CODEX_REVIEW_LOG")"
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$CODEX_REVIEW_LOG"
}
