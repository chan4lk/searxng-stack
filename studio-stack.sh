#!/bin/bash
# Start or stop the Mac Studio AI stack, whole or one service at a time
# (e.g. to give ComfyUI all the RAM). Install on the Studio as ~/studio-stack.sh.
#
#   ~/studio-stack.sh stop [service]    # no service: every one below
#   ~/studio-stack.sh start [service]   # no service: all but $OFF_BY_DEFAULT, then loads the llama-swap models in $LLMS (default none)
#   ~/studio-stack.sh status [--tsv]    # --tsv: "name<TAB>up|starting|down" per service, then "memory<TAB><free %>", "default<TAB><Pi provider>"
#   ~/studio-stack.sh default [ornith|vllm [MODEL]]   # show or set Pi's default model (~/.pi/agent/settings.json)
#   ~/studio-stack.sh load|unload [MODEL]       # llama-swap (:8100) models: load one now, unload one or (no MODEL) all
#
# Every LLM (Splash, Ornith, vLLM, Sushi, FCF, 3D Coder, LFM, Mellum: llama-swap/config.yaml) runs behind llama-swap,
# starts on request and unloads when idle; `swap` is llama-swap itself. status --tsv adds "llm<TAB>id<TAB>loaded|starting|unloaded<TAB>description" per model.
#
# Services: swap image music classify ocr asr omniasr openviking searxng ollama
# FORCE=1 stops image/music even while they are generating.
# ComfyUI: only by name (~/ComfyUI/run_comfyui.sh / stop_comfyui.sh), never by stop/start all.
# Never touched: studio-radar, sinhala-ocr's llama-server (the user's own jobs).
export PATH=/opt/homebrew/bin:$PATH
UID_=$(id -u)
IP=100.101.212.33
AGENTS_ALL="swap image music classify ocr asr omniasr openviking"
SERVICES="$AGENTS_ALL searxng ollama"
# Started only by name; stopping one also disables its LaunchAgent so it stays off after a reboot.
OFF_BY_DEFAULT="classify asr omniasr"

port_of() { case $1 in comfyui) echo 8188;; esac; }
label_of() { case $1 in openviking) echo com.openviking.server;; swap) echo com.searxng-stack.llama-swap;; *) echo com.searxng-stack.$1-server;; esac; }
is_agent() { [[ " $AGENTS_ALL " == *" $1 "* ]]; }
is_off_by_default() { [[ " $OFF_BY_DEFAULT " == *" $1 "* ]]; }
# ComfyUI's process, to see it still loading (no listener yet).
proc_of() { case $1 in comfyui) echo 'Python main.py';; esac; }
listener() { lsof -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }
# Is a generation running? (a stop would cut it off)
busy() { curl -s -m 3 "http://127.0.0.1:$1/health" | grep -q '"busy": *true'; }

is_up() {
  if [ "$1" = comfyui ]; then [ -n "$(listener "$(port_of "$1")")" ]
  elif is_agent "$1"; then launchctl print "gui/$UID_/$(label_of "$1")" >/dev/null 2>&1
  elif [ "$1" = searxng ]; then docker ps --format '{{.Names}}' 2>/dev/null | grep -qx searxng
  elif [ "$1" = ollama ]; then pgrep -x ollama >/dev/null
  else return 1; fi
}

is_starting() { [ "$1" = comfyui ] && ! is_up "$1" && pgrep -f "$(proc_of "$1")" >/dev/null; }

start_one() {
  is_up "$1" && { echo "$1 already up"; return; }
  is_starting "$1" && { echo "$1 already starting"; return; }
  echo "start $1"
  case $1 in
    comfyui) nohup ~/ComfyUI/run_comfyui.sh > ~/comfyui.log 2>&1 & ;;
    searxng)
      brew services start colima >/dev/null
      # colima status turns OK before the docker socket answers; wait for docker itself.
      for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
      ~/searxng-stack/searxng.sh up ;;
    ollama) open -a Ollama ;;
    *) is_agent "$1" || return
       launchctl enable "gui/$UID_/$(label_of "$1")"  # undo a stop_one disable
       launchctl bootstrap "gui/$UID_" ~/Library/LaunchAgents/"$(label_of "$1")".plist ;;
  esac
}

stop_one() {
  [ "$1" = comfyui ] && { ~/ComfyUI/stop_comfyui.sh; return; }
  if is_starting "$1"; then
    echo "stop $1 (still loading)"
    for pid in $(pgrep -f "$(proc_of "$1")"); do pkill -TERM -P "$pid" 2>/dev/null; kill "$pid"; done
    return
  fi
  is_up "$1" || { echo "$1 already down"; return; }
  echo "stop $1"
  case $1 in
    searxng) ~/searxng-stack/searxng.sh down; brew services stop colima >/dev/null 2>&1; colima stop >/dev/null 2>&1 ;;
    # osascript quit doesn't reach the app over SSH, and the app respawns its server: kill both.
    ollama) pkill -x Ollama; sleep 1; pkill -x ollama ;;
    *)
      launchctl bootout "gui/$UID_/$(label_of "$1")"
      is_off_by_default "$1" && launchctl disable "gui/$UID_/$(label_of "$1")" ;;
  esac
}

check_name() { [[ " $SERVICES comfyui " == *" $1 "* ]] || { echo "unknown service: $1 (one of: $SERVICES)" >&2; exit 2; }; }
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
  for s in ollama searxng $AGENTS_ALL; do is_off_by_default "$s" || start_one "$s"; done
  for m in $LLMS; do sleep 2; load "$m"; done
}

status() {
  for s in $SERVICES comfyui; do
    if is_up "$s"; then st=up; elif is_starting "$s"; then st=starting; else st=down; fi
    if [ "$1" = --tsv ]; then printf '%s\t%s\n' "$s" "$st"; else echo "$s $st"; fi
  done
  swap_models | while IFS=$'\t' read -r id st desc; do
    if [ "$1" = --tsv ]; then printf 'llm\t%s\t%s\t%s\n' "$id" "$st" "$desc"; else echo "llm $id $st ($desc)"; fi
  done
  free=$(memory_pressure | awk -F': ' '/free percentage/{print $2}')
  if [ "$1" = --tsv ]; then printf 'memory\t%s\n' "$free"; printf 'default\t%s\n' "$(default)"; else echo "memory free $free"; echo "pi default $(default)"; fi
}

PI_SETTINGS=~/.pi/agent/settings.json
# Pi's default provider/model: ornith or vllm [MODEL] (both through llama-swap). No arg: print the provider.
default() {
  case $1 in
    '') /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("defaultProvider", "?"))' $PI_SETTINGS; return ;;
    ornith) model=Ornith-1.5-35B-A3B ;;
    vllm) model=${2:-Qwen3.5-9B-heretic} ;;
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

SWAP=http://$IP:8100
swap_api() { curl -s -m "${2:-10}" -H "Authorization: Bearer $(cat ~/.sushi/api-key)" "${@:3}" "$SWAP$1"; }
# "id<TAB>loaded|starting|unloaded<TAB>description" per llama-swap model (nothing while llama-swap is down)
swap_models() {
  swap_api /v1/models 5 | /usr/bin/python3 -c '
import json, sys
try: data = json.load(sys.stdin)["data"]
except Exception: sys.exit(0)
for m in data:
    st = (m.get("status") or {}).get("value", "?")
    st = {"ready": "loaded", "starting": "starting"}.get(st, st)
    print(m["id"], st, m.get("description", ""), sep="\t")'
}
# Load a llama-swap model now (any request to it starts it; waits until it answers).
load() {
  [ -n "$1" ] || { echo "load: MODEL (one of: $(swap_models | cut -f1 | tr '\n' ' '))" >&2; exit 2; }
  is_up swap || { echo "swap (llama-swap) is down: start swap first" >&2; exit 1; }
  echo "load $1"; swap_api "/upstream/$1/v1/models" 600 -o /dev/null -w '%{http_code}\n'
}
# Unload one llama-swap model, or all of them.
unload() { echo "unload ${1:-all}"; swap_api "/api/models/unload${1:+/$1}" 60 -X POST -o /dev/null -w '%{http_code}\n'; }

case $1 in
  stop|start|status) "$1" "$2" ;;
  default) default "$2" "$3" ;;
  load|unload) "$1" "$2" ;;
  *) echo "usage: $0 stop|start [service] | status [--tsv] | default [ornith|vllm [MODEL]] | load|unload [MODEL]" >&2; exit 2 ;;
esac
