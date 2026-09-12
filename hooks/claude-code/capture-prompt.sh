#!/usr/bin/env bash
# UserPromptSubmit hook — captures user prompts to per-session intent file.
# Always exits 0 with empty stdout (never blocks).
set -euo pipefail

# shellcheck source=../../lib/helpers.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/lib/helpers.sh"

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT")"
PROMPT="$(jq -r '.prompt // empty' <<<"$INPUT")"

if [[ -z "$SESSION_ID" || -z "$PROMPT" ]]; then
    log_debug "capture-prompt: missing session_id or prompt; skipping"
    exit 0
fi

DIR="$(state_dir "$SESSION_ID")"
INTENT_FILE="${DIR}/intent.md"

if [[ ! -f "$INTENT_FILE" ]]; then
    cleanup_stale_state
    {
        printf '# Original request\n\n'
        printf '%s\n' "$PROMPT"
    } > "$INTENT_FILE"
    log_debug "capture-prompt: wrote initial intent for $SESSION_ID"
else
    {
        printf '\n\n## Follow-up\n\n'
        printf '%s\n' "$PROMPT"
    } >> "$INTENT_FILE"
    log_debug "capture-prompt: appended follow-up for $SESSION_ID"
fi

exit 0
