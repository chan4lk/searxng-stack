#!/usr/bin/env bash
# Run the on-demand image API (Qwen-Image 2.1 via mflux) as a launchd service
# on this Mac and publish it to the tailnet.
#
#   ./image-server.sh install    uv sync, install + start the LaunchAgent, publish via tailscale serve
#   ./image-server.sh uninstall  stop and remove the LaunchAgent and tailnet publish
#   ./image-server.sh start | stop | restart | status | logs
#   ./image-server.sh unload     free the model's memory now (it also unloads itself when idle)
#   ./image-server.sh test [prompt]   generate one small image and save it to /tmp
#
# The service idles at ~100 MB: the model loads on the first request and
# unloads after IMAGE_IDLE_UNLOAD seconds (default 600) without work.
# Env overrides (read at install): IMAGE_PORT (8890), IMAGE_QUANTIZE (8; 0 = bf16),
# IMAGE_IDLE_UNLOAD (600), TS_SERVE_PROTO (http|https).
set -euo pipefail

cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(pwd)"
PORT="${IMAGE_PORT:-8890}"
PROTO="${TS_SERVE_PROTO:-http}"
LABEL="com.searxng-stack.image-server"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$HOME/Library/Logs/image-server.log"
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
    <key>IMAGE_QUANTIZE</key><string>${IMAGE_QUANTIZE:-8}</string>
    <key>IMAGE_IDLE_UNLOAD</key><string>${IMAGE_IDLE_UNLOAD:-600}</string>
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

wait_up() {
  for _ in $(seq 1 60); do curl -fsS -m 2 "$LOCAL_URL/health" >/dev/null 2>&1 && return; sleep 1; done
  tail -30 "$LOG"; die "service did not come up on $LOCAL_URL"
}

start()  { launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl kickstart -k "$DOMAIN/$LABEL"; wait_up; }
# bootout returns before the process exits; wait until the port is free so a
# following start can't be fooled by the old server still answering /health.
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
    log "installing LaunchAgent $LABEL"; stop; write_plist; start
    serve; curl -s "$LOCAL_URL/health"; echo ;;
  uninstall)
    unserve; stop; rm -f "$PLIST"; log "removed $LABEL" ;;
  start) start; curl -s "$LOCAL_URL/health"; echo ;;
  stop) stop ;;
  restart) stop; start ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E '^\s+(state|pid|last exit code) =' || echo "not running"
    curl -s -m 3 "$LOCAL_URL/health" && echo
    "$(tailscale_bin)" serve status 2>/dev/null | grep -A1 ":${PORT}" || echo "not published" ;;
  logs) tail -f "$LOG" ;;
  unload) curl -s -X POST "$LOCAL_URL/v1/unload"; echo ;;
  test)
    out="/tmp/image-server-test-$(date +%s).png"
    log "generating 512x512, 20 steps (first call also loads the model)"
    curl -fsS -m 1800 "$LOCAL_URL/v1/images/generations" -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "size": "512x512", "steps": 20, "seed": 7}))' "${2:-a red fox in fresh snow, golden hour, photo}")" \
      | python3 -c 'import base64,json,sys; d=json.load(sys.stdin); open(sys.argv[1],"wb").write(base64.b64decode(d["data"][0]["b64_json"])); print("load", d["load_seconds"], "s | generate", d["generate_seconds"], "s | quantize", d["quantize"], "->", sys.argv[1])' "$out" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
