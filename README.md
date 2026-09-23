# StagedCodeReview

Iterative, ledger-backed code review for AI coding agents. Each invocation runs
one review pass by GPT-6 Sol (through the OpenAI `codex` CLI, read-only
sandbox) over everything changed since a recorded baseline, merges the result
into a per-session findings ledger, and tells the agent exactly what to do next.
The loop stops at the first pass with no open finding at the blocking severity.

Works as a skill for **Claude Code**, **Codex** and **dsh**.

## How it works

1. First run records a baseline (HEAD tree) for every git repo under the cwd.
2. Each pass bundles the diff vs baseline (tracked + untracked, lockfiles and
   binaries excluded, size-capped), the captured intent and the prior ledger.
3. `codex exec` reviews it with a JSON output schema; malformed or
   self-contradicting reports are rejected and retried once.
4. Findings get stable ids (`SOL-1`, `SOL-2`, ...) and a status: open,
   resolved, dismissed. The reviewer must account for every open id each pass.
5. Exit code: `0` all clean or nothing to review, `1` findings to fix, `2` error.

Blocking severity is `major` (critical + major block) or `critical`; minor
findings never force another pass but can be recorded after the clean verdict.

## Requirements

`bash` 4+, `git`, `jq`, `python3` 3.9+, and the [`codex` CLI](https://github.com/openai/codex)
logged in (ChatGPT subscription or API key). `zstd` is needed for dsh only.

## Install

```bash
git clone https://github.com/navidnadali/StagedCodeReview
cd StagedCodeReview
./install.sh --all        # or any of: --claude  --codex  --dsh
```

The driver lands in `~/.agents/scripts/staged-review`; skills go where each
harness reads them. Re-run `install.sh` to update. `bash test.sh` runs the
regression suite.

### Claude Code

```bash
./install.sh --claude     # -> ~/.claude/skills/codex-review
```

- In a session, run `/codex-review` (or ask Claude to "run the review loop").
  State is keyed by `CLAUDE_CODE_SESSION_ID`.
- Optional intent capture: merge `hooks/claude-code/settings.snippet.json`
  into `~/.claude/settings.json`. The hooks save your prompts, approved plan
  and todos so the reviewer can check the change against them.
- The reviewer needs network access. If Claude's Bash sandbox blocks it, run
  the command outside the sandbox.

### Codex

```bash
./install.sh --codex      # -> ~/.agents/skills/staged-review
```

- In Codex, invoke `$staged-review`. Codex reads user skills from
  `~/.agents/skills` and follows symlinks.
- Codex exposes no session id to shell commands, so the skill passes
  `--session <task-id>` (one stable id per task) and `--intent-file <path>`
  with a written summary of the task.
- The reviewer is a nested `codex exec` using the same login.

### dsh

```bash
./install.sh --dsh        # -> ~/.agents/skills/staged-review (or $DSH_AGENTS_HOME/skills)
```

- dsh exports `DSH_SESSION_ID` and `DSH_SESSION_JSONL`; the driver keys state
  by session and extracts intent (prompts, plan, todos, goal) from the
  transcript. Codex and dsh share this skill directory.
- To make it a definition of done, add to your `AGENTS.md`: "At the end of
  every coding task run the staged-review skill until it prints ALL CLEAN."

## Usage

```bash
S=~/.agents/scripts/staged-review/staged-review.sh
$S --harness=claude                                 # one pass (auto-detects dsh/claude)
$S --harness=codex --session my-task --intent-file intent.md
$S --status                                         # ledger and baselines
$S --dismiss 'SOL-2=false positive: input is validated at src/auth.rs:88'
$S --resolve-nonblocking 'SOL-3=fixed; test added'  # after ALL CLEAN only
$S --blocking-severity critical                     # persisted for the loop
$S --reset                                          # new task in the same session
```

A pass prints a header, the findings, and an authoritative `NEXT:` line:

```
STAGED-REVIEW: stage=sol pass=2 status=findings blocking=major open_blocking=1 new=1 resolved=2 ...
NEXT: fix findings blocking at the major threshold ..., then re-run this exact command.

## New findings (stage sol, pass 2)
### major
- [SOL-4] [major/bug] src/api/token.rs:42 - refresh token is compared with ==, not constant-time
  Fix: use subtle::ConstantTimeEq
```

## Configuration and state

- `~/.agents/scripts/staged-review/config.env`: model, reasoning effort,
  default blocking severity, timeouts, diff and intent size caps.
- `~/.claude/.env` is sourced if present (e.g. `CODEX_REVIEW_DEBUG=1`).
- State lives in `~/.agents/state/staged-review/<harness>-<session>/`
  (`state.json` plus one `runs/NNN-sol/` directory per pass with the prompt,
  diff, intent and raw reviewer output). Entries older than 7 days are pruned.
  Never edit state by hand.

## Privacy

The diff bundle and captured intent are sent to OpenAI through `codex`. The
reviewer runs with a read-only sandbox; repositories under a temp directory are
refused because that sandbox can write there.
