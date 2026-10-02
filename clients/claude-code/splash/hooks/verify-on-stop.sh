#!/usr/bin/env bash
# Stop hook for the claude-splash Qwen3.6 profile: refuse to finish while the
# project's verification command fails. Opt-in per project, so it never guesses
# at (or runs) an expensive test suite:
#   echo 'npm test --silent' > .claude/splash-verify   # in the repo root
#   or: SPLASH_VERIFY_CMD='pytest -q -x' claude-splash 3.6
# Runs only when the working tree has changes, and blocks at most 3 times per
# session so a model that can't fix it isn't trapped in a loop.
input=$(cat)
read -r sid cwd < <(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("session_id","x"), d.get("cwd") or ".")' 2>/dev/null)
cd "${cwd:-.}" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

cmd=${SPLASH_VERIFY_CMD:-}
[[ -z $cmd && -f $root/.claude/splash-verify ]] && cmd=$(grep -v '^\s*#' "$root/.claude/splash-verify" | head -1)
[[ -n $cmd ]] || exit 0
[[ -n $(git -C "$root" status --porcelain 2>/dev/null) ]] || exit 0

count_file=${TMPDIR:-/tmp}/splash-verify-$sid
count=$(cat "$count_file" 2>/dev/null || echo 0)
(( count >= 3 )) && exit 0

out=$(cd "$root" && bash -c "$cmd" 2>&1); rc=$?
if (( rc != 0 )); then
  echo $((count + 1)) > "$count_file"
  printf 'Not done: `%s` fails (exit %d, block %d of 3). Fix it, or explain why it cannot pass. Last output:\n%s\n' \
    "$cmd" "$rc" $((count + 1)) "$(printf '%s' "$out" | tail -40)" >&2
  exit 2
fi
rm -f "$count_file"
exit 0
