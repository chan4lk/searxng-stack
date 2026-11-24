#!/usr/bin/env bash
# Run Claude Code on the office DGX Spark's local model (vLLM, Anthropic /v1/messages API).
# Usage: claude-spark.sh [--check] [claude args...]
#   SPARK_URL   server (default http://192.168.1.11:8001, the Spark on the office Wi-Fi)
#   SPARK_MODEL served model name (default ornith)
set -euo pipefail
URL=${SPARK_URL:-http://192.168.1.11:8001}
MODEL=${SPARK_MODEL:-ornith}

command -v claude >/dev/null || { echo "claude-spark: Claude Code is not installed (npm i -g @anthropic-ai/claude-code)" >&2; exit 1; }
served=$(curl -s -m 5 -f "$URL/v1/models") || {
  echo "claude-spark: no answer from $URL. Are you on the office Wi-Fi? Is the Spark's vLLM running?" >&2; exit 1; }
[[ $served == *"\"id\":\"$MODEL\""* ]] || {
  echo "claude-spark: $URL is up but not serving '$MODEL'. It serves: $served" >&2; exit 1; }
echo "claude-spark: $MODEL at $URL" >&2
[[ ${1:-} == --check ]] && exit 0

# Every model slot points at the Spark model; settings JSON is passed inline so the
# user's own ~/.claude/settings.json can't send a request to another server.
settings=$(cat <<EOF
{"env":{"ANTHROPIC_BASE_URL":"$URL","ANTHROPIC_AUTH_TOKEN":"spark-local",
"ANTHROPIC_MODEL":"$MODEL","ANTHROPIC_DEFAULT_OPUS_MODEL":"$MODEL","ANTHROPIC_DEFAULT_SONNET_MODEL":"$MODEL",
"ANTHROPIC_DEFAULT_HAIKU_MODEL":"$MODEL","CLAUDE_CODE_SUBAGENT_MODEL":"$MODEL",
"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","DISABLE_PROMPT_CACHING":"1","API_TIMEOUT_MS":"600000",
"CLAUDE_CODE_MAX_CONTEXT_TOKENS":"131072"},"model":"$MODEL"}
EOF
)
# No MCP servers or claude.ai connectors: they add ~60K prompt tokens and make the first reply take minutes.
exec env ENABLE_CLAUDEAI_MCP_SERVERS=false CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
  CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1 CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
  claude --settings "$settings" --exclude-dynamic-system-prompt-sections \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' "$@"
