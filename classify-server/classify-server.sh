#!/usr/bin/env bash
# Run the GLiNER2.5-Decide classification API as a launchd service on this Mac
# and publish it to the tailnet.
#
#   ./classify-server.sh install    uv sync, install + start the LaunchAgent, publish via tailscale serve
#   ./classify-server.sh uninstall  stop and remove the LaunchAgent and tailnet publish
#   ./classify-server.sh start | stop | restart | status | logs
#   ./classify-server.sh test       classify two sample texts
#
# The model (~1.5 GB) stays loaded and runs on Apple's GPU (MPS): ~40 ms a call.
# Env overrides (read at install): CLASSIFY_PORT (8892), CLASSIFY_DEVICE (mps|cpu),
# CLASSIFY_MODEL (fastino/GLiNER2.5-Decide), TS_SERVE_PROTO (http|https).
# stop/restart/install refuse while a request is running; FORCE=1 overrides.
set -euo pipefail

cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(pwd)"
PORT="${CLASSIFY_PORT:-8892}"
PROTO="${TS_SERVE_PROTO:-http}"
LABEL="com.searxng-stack.classify-server"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$HOME/Library/Logs/classify-server.log"
LOCAL_URL="http://127.0.0.1:${PORT}"
DOMAIN="gui/$(id -u)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

tailscale_bin() {
  command -v tailscale 2>/dev/null && return
  local app=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [[ -x $app ]] && { echo "$app"; return; }
  die "tailscale CLI not found"
}
tailnet_url() {
  echo "${PROTO}://$("$(tailscale_bin)" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'):${PORT}"
}

write_plist() {
  local uv; uv="$(command -v uv)" || die "uv not found (brew install uv)"
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${uv}</string><string>run</string><string>--project</string><string>${DIR}</string>
    <string>uvicorn</string><string>server:app</string>
    <string>--app-dir</string><string>${DIR}</string>
    <string>--host</string><string>127.0.0.1</string><string>--port</string><string>${PORT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>CLASSIFY_MODEL</key><string>${CLASSIFY_MODEL:-fastino/GLiNER2.5-Decide}</string>
    <key>CLASSIFY_DEVICE</key><string>${CLASSIFY_DEVICE:-}</string>
    <key>TOKENIZERS_PARALLELISM</key><string>false</string>
  </dict>
  <key>WorkingDirectory</key><string>${DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
EOF
}

# /health answers while the model is still loading; wait for "ok".
wait_up() {
  for _ in $(seq 1 300); do
    curl -fsS -m 2 "$LOCAL_URL/health" 2>/dev/null | grep -q '"status":"ok"' && return
    sleep 1
  done
  tail -30 "$LOG"; die "service did not come up on $LOCAL_URL"
}

start() {
  for _ in $(seq 1 15); do
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
      wait_up; return
    fi
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && { wait_up; return; }
    sleep 1
  done
  die "launchd would not load $LABEL (launchctl bootstrap $DOMAIN $PLIST)"
}
ensure_idle() {
  [[ ${FORCE:-0} == 1 ]] && return 0
  local h; h="$(curl -s -m 3 "$LOCAL_URL/health" 2>/dev/null)" || return 0
  [[ -z $h ]] && return 0
  if python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("busy") else 1)' "$h"; then
    die "a request is running; retry when idle (./classify-server.sh status) or use FORCE=1"
  fi
}
stop() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  for _ in $(seq 1 60); do
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || return 0
    sleep 1
  done
  die "old server still listening on :$PORT after 60s"
}
serve()  { "$(tailscale_bin)" serve --bg "--${PROTO}=${PORT}" "$LOCAL_URL" >/dev/null; log "tailnet URL: $(tailnet_url)"; }
unserve(){ "$(tailscale_bin)" serve "--${PROTO}=${PORT}" off 2>/dev/null || true; }

case "${1:-}" in
  install)
    log "installing dependencies (uv sync)"; uv sync --quiet
    log "installing LaunchAgent $LABEL"; ensure_idle; stop; write_plist; start
    serve; curl -s "$LOCAL_URL/health"; echo ;;
  uninstall)
    ensure_idle; unserve; stop; rm -f "$PLIST"; log "removed $LABEL" ;;
  start) start; curl -s "$LOCAL_URL/health"; echo ;;
  stop) ensure_idle; stop ;;
  restart) ensure_idle; stop; start ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid|last exit code) =' || echo "not running"
    curl -s -m 3 "$LOCAL_URL/health" && echo
    "$(tailscale_bin)" serve status 2>/dev/null | grep -A1 ":${PORT}" || echo "not published" ;;
  logs) tail -f "$LOG" ;;
  test)
    curl -fsS -m 60 "$LOCAL_URL/v1/classify" -H 'Content-Type: application/json' -d '{
      "texts": ["My subscription renewed after the service was already down. Can I get that charge refunded?",
                "URGENT: production database is refusing connections since 09:00"],
      "tasks": {"intent": ["refund_request", "bug_report", "outage_report", "question", "other"],
                "urgency": ["low", "normal", "high", "critical"],
                "route": {"labels": ["billing", "support", "engineering", "security"], "multi_label": true, "cls_threshold": 0.4}},
      "include_confidence": true}'; echo ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
