#!/usr/bin/env bash
# Run the SearXNG stack on this Mac and expose it to the tailnet.
#
#   ./searxng.sh up        start runtime + stack, then publish via tailscale serve
#   ./searxng.sh down      stop the stack and remove the tailnet publish
#   ./searxng.sh restart   down + up
#   ./searxng.sh status    containers, health, tailscale serve config
#   ./searxng.sh logs      follow searxng logs
#   ./searxng.sh test [q]  run a JSON search against the local and tailnet URLs
#   ./searxng.sh serve | unserve   publish / unpublish on the tailnet only
#
# Env overrides: SEARXNG_PORT (default 8889), TS_SERVE_PROTO (http|https, default http).
# Tailnet traffic is already WireGuard-encrypted; https needs HTTPS certs enabled
# in the Tailscale admin console.
set -euo pipefail

cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PORT="${SEARXNG_PORT:-8889}"
PROTO="${TS_SERVE_PROTO:-http}"
LOCAL_URL="http://127.0.0.1:${PORT}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

tailscale_bin() {
  command -v tailscale 2>/dev/null && return
  local app=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [[ -x $app ]] && { echo "$app"; return; }
  die "tailscale CLI not found"
}

ts_dns() {
  "$(tailscale_bin)" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
}

tailnet_url() { echo "${PROTO}://$(ts_dns):${PORT}"; }

ensure_runtime() {
  command -v docker >/dev/null || die "docker CLI missing (brew install colima docker docker-compose)"
  if ! docker info >/dev/null 2>&1; then
    command -v colima >/dev/null || die "docker daemon not reachable and colima not installed"
    log "starting colima"
    colima start --cpu 2 --memory 2 --disk 20 --vm-type vz
  fi
  docker compose version >/dev/null 2>&1 || die "docker compose plugin missing (link it into ~/.docker/cli-plugins)"
}

ensure_env() {
  if [[ ! -f .env ]] || ! grep -q '^SEARXNG_SECRET=' .env; then
    log "generating .env with a fresh SEARXNG_SECRET"
    umask 077
    printf 'SEARXNG_SECRET=%s\nSEARXNG_PORT=%s\n' "$(openssl rand -hex 32)" "$PORT" > .env
  fi
  local base; base="$(tailnet_url)/"
  if grep -q '^SEARXNG_BASE_URL=' .env; then
    sed -i '' "s|^SEARXNG_BASE_URL=.*|SEARXNG_BASE_URL=${base}|" .env
  else
    echo "SEARXNG_BASE_URL=${base}" >> .env
  fi
}

wait_healthy() {
  log "waiting for searxng to become healthy"
  for _ in $(seq 1 60); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' searxng 2>/dev/null)" == healthy ]] && return
    sleep 2
  done
  docker compose logs --tail 40 searxng
  die "searxng did not become healthy"
}

serve() {
  local ts; ts="$(tailscale_bin)"
  log "publishing ${LOCAL_URL} on the tailnet (${PROTO}:${PORT})"
  "$ts" serve --bg "--${PROTO}=${PORT}" "$LOCAL_URL"
  log "tailnet URL: $(tailnet_url)"
}

unserve() {
  "$(tailscale_bin)" serve "--${PROTO}=${PORT}" off 2>/dev/null || true
}

search_test() {
  local q="${1:-searxng}" url
  for url in "$LOCAL_URL" "$(tailnet_url)"; do
    printf '%-50s ' "$url"
    curl -fsS -m 20 "${url}/search?q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$q")&format=json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["results"]), "results; unresponsive:", [e[0] for e in d.get("unresponsive_engines", [])])' \
      || echo "FAILED"
  done
}

case "${1:-}" in
  up)
    ensure_runtime; ensure_env
    log "starting stack"; docker compose up -d --pull missing
    wait_healthy; serve; search_test ;;
  down)
    unserve; ensure_runtime; docker compose down ;;
  restart)
    "$0" down; "$0" up ;;
  status)
    ensure_runtime; docker compose ps
    echo; "$(tailscale_bin)" serve status ;;
  logs)
    docker compose logs -f --tail 100 searxng ;;
  test)
    search_test "${2:-}" ;;
  serve) serve ;;
  unserve) unserve ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
