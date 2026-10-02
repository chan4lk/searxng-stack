#!/usr/bin/env bash
# PostToolUse hook (Edit|Write|MultiEdit) for the claude-splash Qwen3.6 profile.
# Runs a fast syntax/lint check on the file just edited. On failure it exits 2,
# which hands the error text back to the model so it fixes it now instead of
# carrying a broken file forward. Checks only what is installed; never blocks
# on a missing tool.
input=$(cat)
file=$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("tool_input") or {}).get("file_path",""))' 2>/dev/null)
[[ -n $file && -f $file ]] || exit 0

root=$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null || dirname "$file")
have() { command -v "$1" >/dev/null 2>&1; }
out=

case "$file" in
  *.py)
    out=$(python3 -m py_compile "$file" 2>&1) || true
    if [[ -z $out ]] && have ruff; then out=$(ruff check --quiet --select E9,F63,F7,F82,F401,F811,F821 "$file" 2>&1) || true; fi ;;
  *.js|*.mjs|*.cjs)
    out=$(node --check "$file" 2>&1) || true
    if [[ -z $out && -x $root/node_modules/.bin/eslint ]]; then out=$(cd "$root" && node_modules/.bin/eslint --quiet "$file" 2>&1) || true; fi ;;
  *.ts|*.tsx|*.jsx)
    if [[ -x $root/node_modules/.bin/eslint ]]; then out=$(cd "$root" && node_modules/.bin/eslint --quiet "$file" 2>&1) || true; fi ;;
  *.sh|*.bash)  out=$(bash -n "$file" 2>&1) || true ;;
  *.zsh)        out=$(zsh -n "$file" 2>&1) || true ;;
  *.json)       out=$(python3 -m json.tool "$file" 2>&1 >/dev/null) || true ;;
  *.go)         have gofmt && out=$(gofmt -e -l "$file" 2>&1 >/dev/null) || true ;;
  *.rs)         : ;;  # cargo check is too slow per edit; rely on the Stop gate
esac

if [[ -n $out ]]; then
  printf 'Check failed for %s — fix this before continuing:\n%s\n' "$file" "$(printf '%s' "$out" | head -40)" >&2
  exit 2
fi
exit 0
