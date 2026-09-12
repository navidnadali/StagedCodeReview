#!/usr/bin/env bash
# Captures Claude's stated intent at two points:
#   - PreToolUse:ExitPlanMode  -> writes plan.md from .tool_input.plan
#   - PostToolUse:TodoWrite    -> rewrites todos.md from .tool_input.todos
# Always exits 0 (never blocks).
set -euo pipefail

# shellcheck source=../../lib/helpers.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/helpers.sh"

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT")"
TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT")"

if [[ -z "$SESSION_ID" || -z "$TOOL_NAME" ]]; then
    log_debug "capture-plan: missing session_id or tool_name; skipping"
    exit 0
fi

DIR="$(state_dir "$SESSION_ID")"

case "$TOOL_NAME" in
    ExitPlanMode)
        PLAN="$(jq -r '.tool_input.plan // empty' <<<"$INPUT")"
        if [[ -n "$PLAN" ]]; then
            printf '%s\n' "$PLAN" > "${DIR}/plan.md"
            log_debug "capture-plan: wrote plan.md for $SESSION_ID"
        fi
        ;;
    TodoWrite)
        TODOS_JSON="$(jq -c '.tool_input.todos // []' <<<"$INPUT")"
        if [[ "$TODOS_JSON" != "[]" ]]; then
            jq -r '.tool_input.todos
                | map("- [" + (.status // "pending") + "] " + (.content // ""))
                | join("\n")' <<<"$INPUT" > "${DIR}/todos.md"
            log_debug "capture-plan: wrote todos.md for $SESSION_ID"
        fi
        ;;
    *)
        log_debug "capture-plan: unhandled tool $TOOL_NAME; skipping"
        ;;
esac

exit 0
