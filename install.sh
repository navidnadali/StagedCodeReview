#!/usr/bin/env bash
# Install the staged-review driver and the skill for one or more harnesses.
#   ./install.sh [--claude] [--codex] [--dsh] [--all] [--prefix DIR]
# Driver  -> $PREFIX (default ~/.agents/scripts/staged-review)
# Skills  -> ~/.claude/skills/codex-review   (Claude Code, invoked as /codex-review)
#            ~/.agents/skills/staged-review   (Codex, invoked as $staged-review; and dsh -
#                                              both read this shared user skill directory)
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${HOME}/.agents/scripts/staged-review"
CLAUDE=0 CODEX=0 DSH=0
while (( $# )); do
    case "$1" in
        --claude) CLAUDE=1; shift ;;
        --codex)  CODEX=1; shift ;;
        --dsh)    DSH=1; shift ;;
        --all)    CLAUDE=1; CODEX=1; DSH=1; shift ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) printf 'install: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done
if (( CLAUDE + CODEX + DSH == 0 )); then
    printf 'install: pick at least one of --claude, --codex, --dsh (or --all)\n' >&2
    exit 2
fi

missing=0
for tool in git jq python3 codex; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'install: missing required tool: %s\n' "$tool" >&2; missing=1; }
done
(( missing )) && exit 2
(( DSH )) && ! command -v zstd >/dev/null 2>&1 && \
    printf 'install: warning: zstd not found - dsh transcript intent extraction will be skipped\n' >&2

mkdir -p "$PREFIX"
for item in staged-review.sh run-with-timeout.py test.sh lib schemas templates tests hooks; do
    rm -rf "${PREFIX:?}/${item}"
    cp -R "${SRC}/${item}" "${PREFIX}/${item}"
done
# Keep an existing config.env; seed the commented default otherwise.
[[ -f "${PREFIX}/config.env" ]] || cp "${SRC}/config.env" "${PREFIX}/config.env"
chmod +x "${PREFIX}/staged-review.sh" "${PREFIX}/test.sh" "${PREFIX}/hooks/claude-code/"*.sh "${PREFIX}/tests/"*.sh
printf 'driver installed: %s\n' "$PREFIX"

install_skill() {  # <src dir> <dest dir>
    mkdir -p "$(dirname "$2")"
    rm -rf "$2"
    cp -R "$1" "$2"
    printf 'skill installed: %s\n' "$2"
}
(( CLAUDE )) && install_skill "${SRC}/skills/claude-code/codex-review" "${HOME}/.claude/skills/codex-review"
(( CODEX ))  && install_skill "${SRC}/skills/agents/staged-review"    "${HOME}/.agents/skills/staged-review"
if (( DSH )); then
    DSH_SKILLS="${DSH_AGENTS_HOME:-${HOME}/.agents}/skills/staged-review"
    if (( CODEX )) && [[ "$DSH_SKILLS" == "${HOME}/.agents/skills/staged-review" ]]; then
        printf 'skill shared with Codex: %s\n' "$DSH_SKILLS"
    else
        install_skill "${SRC}/skills/agents/staged-review" "$DSH_SKILLS"
    fi
fi

if (( CLAUDE )); then
    printf '\nOptional (Claude Code): capture prompt/plan/todos as review intent by merging\n  %s\ninto ~/.claude/settings.json.\n' "${PREFIX}/hooks/claude-code/settings.snippet.json"
fi
