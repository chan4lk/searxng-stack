#!/usr/bin/env bash
# Run the on-demand music API (ACE-Step 1.5) as a launchd service on this Mac
# and publish it to the tailnet.
#
#   ./music-server.sh install    uv sync, install + start the LaunchAgent, publish via tailscale serve
#   ./music-server.sh uninstall  stop and remove the LaunchAgent and tailnet publish
#   ./music-server.sh start | stop | restart | status | logs
#   ./music-server.sh unload     stop the ACE-Step backend now (it also stops itself when idle)
#   ./music-server.sh test [prompt]   generate a 20-second instrumental and save it to /tmp
#
# The service idles at ~50 MB: the first request starts ACE-Step (~/ace-step,
# see README) and it is stopped again after MUSIC_IDLE_UNLOAD seconds (default 600).
# Env overrides (read at install): MUSIC_PORT (8891), MUSIC_IDLE_UNLOAD (600),
# ACE_STEP_DIR (~/ace-step), ACE_STEP_LM_MODEL (acestep-5Hz-lm-1.7B), TS_SERVE_PROTO.
# stop/restart/install refuse while a job is running or queued; FORCE=1 overrides.
set -euo pipefail

cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(pwd)"
PORT="${MUSIC_PORT:-8891}"
PROTO="${TS_SERVE_PROTO:-http}"
LABEL="com.searxng-stack.music-server"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG="$HOME/Library/Logs/music-server.log"
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
    <key>MUSIC_IDLE_UNLOAD</key><string>${MUSIC_IDLE_UNLOAD:-600}</string>
    <key>ACE_STEP_DIR</key><string>${ACE_STEP_DIR:-$HOME/ace-step}</string>
    <key>ACE_STEP_LM_MODEL</key><string>${ACE_STEP_LM_MODEL:-acestep-5Hz-lm-1.7B}</string>
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
  # The first launch after a dependency change runs uv sync, which can take a while.
  for _ in $(seq 1 180); do curl -fsS -m 2 "$LOCAL_URL/health" >/dev/null 2>&1 && return; sleep 1; done
  tail -30 "$LOG"; die "service did not come up on $LOCAL_URL"
}

# Right after a bootout, launchd can still be tearing the job down and reject a
# new bootstrap; retry briefly instead of exiting silently under set -e.
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
# Refuse to take the service down under a running or queued generation: the
# client's request would be cut off. FORCE=1 overrides.
ensure_idle() {
  [[ ${FORCE:-0} == 1 ]] && return 0
  local h; h="$(curl -s -m 3 "$LOCAL_URL/health" 2>/dev/null)" || return 0
  [[ -z $h ]] && return 0
  if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("busy") or d.get("queued") else 1)' "$h"; then
    die "a generation is running or queued; retry when idle (./music-server.sh status) or use FORCE=1"
  fi
}

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
  unload) curl -s -X POST "$LOCAL_URL/v1/unload"; echo ;;
  test)
    out="/tmp/music-server-test-$(date +%s).mp3"
    log "generating a 20 s instrumental (the first call also starts ACE-Step)"
    body="$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "instrumental": True, "duration": 20, "seed": 7}))' "${2:-upbeat corporate pop, bright synths, punchy drums}")"
    resp="$(curl -fsS -m 1800 "$LOCAL_URL/v1/music/generations" -H 'Content-Type: application/json' -d "$body")"
    url="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["url"])' "$resp")"
    curl -fsS -o "$out" "${url/$(tailnet_url)/$LOCAL_URL}" 2>/dev/null || curl -fsS -o "$out" "$url"
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("startup", d["startup_seconds"], "s | total", d["seconds"], "s | seed", d["seed"], "| metas", d["metas"])' "$resp"
    log "saved $out" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
