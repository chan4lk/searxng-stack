#!/bin/bash
# Start or stop the Mac Studio AI stack, whole or one service at a time
# (e.g. to give ComfyUI all the RAM). Install on the Studio as ~/studio-stack.sh.
#
#   ~/studio-stack.sh stop [service]    # no service: every one below
#   ~/studio-stack.sh start [service]   # no service: all but the LLMs, then $LLMS (default "ornith")
#   ~/studio-stack.sh status [--tsv]    # --tsv: "name<TAB>up|down" per service, then "memory<TAB><free %>", "default<TAB><Pi provider>"
#   ~/studio-stack.sh default [ornith|vllm]   # show or set Pi's default model (~/.pi/agent/settings.json)
#
# Services: ornith lfm sushi mellum splash vllm image music classify ocr asr omniasr openviking searxng ollama
# FORCE=1 stops image/music even while they are generating.
# Never touched: ComfyUI (shown in status only), studio-radar, sinhala-ocr's llama-server (the user's own jobs).
export PATH=/opt/homebrew/bin:$PATH
UID_=$(id -u)
IP=100.101.212.33
LLMS_ALL="ornith lfm sushi mellum splash vllm"
AGENTS_ALL="image music classify ocr asr omniasr openviking"
SERVICES="$LLMS_ALL $AGENTS_ALL searxng ollama"

port_of() { case $1 in splash) echo 8000;; sushi) echo 8084;; mellum) echo 8085;; ornith) echo 8086;; lfm) echo 8087;; vllm) echo 8088;; comfyui) echo 8188;; esac; }
label_of() { case $1 in openviking) echo com.openviking.server;; *) echo com.searxng-stack.$1-server;; esac; }
is_llm() { [[ " $LLMS_ALL " == *" $1 "* ]]; }
is_agent() { [[ " $AGENTS_ALL " == *" $1 "* ]]; }
listener() { lsof -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }
# Is a generation running? (a stop would cut it off)
busy() { curl -s -m 3 "http://127.0.0.1:$1/health" | grep -q '"busy": *true'; }

is_up() {
  if is_llm "$1" || [ "$1" = comfyui ]; then [ -n "$(listener "$(port_of "$1")")" ]
  elif is_agent "$1"; then launchctl print "gui/$UID_/$(label_of "$1")" >/dev/null 2>&1
  elif [ "$1" = searxng ]; then docker ps --format '{{.Names}}' 2>/dev/null | grep -qx searxng
  elif [ "$1" = ollama ]; then pgrep -x ollama >/dev/null
  else return 1; fi
}

start_one() {
  is_up "$1" && { echo "$1 already up"; return; }
  echo "start $1"
  case $1 in
    ornith) nohup ~/ornith-serve.sh > ~/ornith.log 2>&1 & ;;
    lfm)    nohup ~/lfm-serve.sh > ~/lfm.log 2>&1 & ;;
    sushi)  nohup ~/sushi-serve.sh > ~/sushi.log 2>&1 & ;;
    mellum) nohup ~/mellum-serve.sh > ~/mellum.log 2>&1 & ;;
    vllm)   nohup ~/vllm-serve.sh > ~/vllm.log 2>&1 & ;;
    splash) nohup splash serve --host $IP --port 8000 --model incoai/Qwen3.8-27B-Splash --max-cache-disk 40G > ~/splash.log 2>&1 & ;;
    searxng)
      brew services start colima >/dev/null
      # colima status turns OK before the docker socket answers; wait for docker itself.
      for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
      ~/searxng-stack/searxng.sh up ;;
    ollama) open -a Ollama ;;
    *) is_agent "$1" && launchctl bootstrap "gui/$UID_" ~/Library/LaunchAgents/"$(label_of "$1")".plist ;;
  esac
}

stop_one() {
  is_up "$1" || { echo "$1 already down"; return; }
  echo "stop $1"
  case $1 in
    searxng) ~/searxng-stack/searxng.sh down; brew services stop colima >/dev/null 2>&1; colima stop >/dev/null 2>&1 ;;
    # osascript quit doesn't reach the app over SSH, and the app respawns its server: kill both.
    ollama) pkill -x Ollama; sleep 1; pkill -x ollama ;;
    *)
      if is_llm "$1"; then
        pid=$(listener "$(port_of "$1")"); pkill -TERM -P "$pid" 2>/dev/null; kill "$pid"
      else
        launchctl bootout "gui/$UID_/$(label_of "$1")"
      fi ;;
  esac
}

check_name() { [[ " $SERVICES " == *" $1 "* ]] || { echo "unknown service: $1 (one of: $SERVICES)" >&2; exit 2; }; }
check_busy() {
  [ "$FORCE" = 1 ] && return
  for s in "$@"; do
    case $s in image) p=8890;; music) p=8891;; *) continue;; esac
    busy $p && { echo "$s is generating; wait or rerun with FORCE=1" >&2; exit 1; }
  done
}

stop() {
  if [ -n "$1" ]; then check_name "$1"; check_busy "$1"; stop_one "$1"; return; fi
  check_busy image music
  for s in $SERVICES; do stop_one "$s"; done
  sleep 3; memory_pressure | tail -1
}

start() {
  if [ -n "$1" ]; then check_name "$1"; start_one "$1"; return; fi
  for s in ollama searxng $AGENTS_ALL ${LLMS:-ornith}; do start_one "$s"; done
}

status() {
  for s in $SERVICES comfyui; do
    if is_up "$s"; then st=up; else st=down; fi
    if [ "$1" = --tsv ]; then printf '%s\t%s\n' "$s" "$st"; else echo "$s $st"; fi
  done
  free=$(memory_pressure | awk -F': ' '/free percentage/{print $2}')
  if [ "$1" = --tsv ]; then printf 'memory\t%s\n' "$free"; printf 'default\t%s\n' "$(default)"; else echo "memory free $free"; echo "pi default $(default)"; fi
}

PI_SETTINGS=~/.pi/agent/settings.json
# Pi's default provider/model: ornith (Splash on :8086) or vllm (:8088). No arg: print the provider.
default() {
  case $1 in
    '') /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("defaultProvider", "?"))' $PI_SETTINGS; return ;;
    ornith) model=Ornith-1.5-35B-A3B ;;
    vllm) model=Qwen3.6-35B-A3B ;;
    *) echo "default: ornith or vllm" >&2; exit 2 ;;
  esac
  /usr/bin/python3 - "$PI_SETTINGS" "$1" "$model" <<'PY'
import json, sys
path, provider, model = sys.argv[1:]
d = json.load(open(path)); d.update(defaultProvider=provider, defaultModel=model)
json.dump(d, open(path, "w"), indent=2)
PY
  echo "pi default $1 / $model"
}

case $1 in
  stop|start|status|default) "$1" "$2" ;;
  *) echo "usage: $0 stop|start [service] | status [--tsv] | default [ornith|vllm]" >&2; exit 2 ;;
esac
