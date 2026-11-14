#!/bin/bash
# Start or stop the Mac Studio AI stack, whole or one service at a time
# (e.g. to give ComfyUI all the RAM). Install on the Studio as ~/studio-stack.sh.
#
#   ~/studio-stack.sh stop [service]    # no service: every one below
#   ~/studio-stack.sh start [service]   # no service: all but the LLMs and $OFF_BY_DEFAULT, then $LLMS (default "ornith")
#   ~/studio-stack.sh status [--tsv]    # --tsv: "name<TAB>up|starting|down" per service, then "memory<TAB><free %>", "default<TAB><Pi provider>"
#   ~/studio-stack.sh default [ornith|vllm]   # show or set Pi's default model (~/.pi/agent/settings.json)
#   ~/studio-stack.sh model vllm|splash [MODEL] # show or switch the engine's model (restarts it if up; kept in ~/.studio-models/)
#
# Services: ornith lfm sushi mellum splash vllm image music classify ocr asr omniasr openviking searxng ollama
# FORCE=1 stops image/music even while they are generating.
# ComfyUI: only by name (~/ComfyUI/run_comfyui.sh / stop_comfyui.sh), never by stop/start all.
# Never touched: studio-radar, sinhala-ocr's llama-server (the user's own jobs).
export PATH=/opt/homebrew/bin:$PATH
UID_=$(id -u)
IP=100.101.212.33
LLMS_ALL="ornith lfm sushi mellum splash vllm"
AGENTS_ALL="image music classify ocr asr omniasr openviking"
SERVICES="$LLMS_ALL $AGENTS_ALL searxng ollama"
# Started only by name; stopping one also disables its LaunchAgent so it stays off after a reboot.
OFF_BY_DEFAULT="classify asr omniasr"

port_of() { case $1 in splash) echo 8000;; sushi) echo 8084;; mellum) echo 8085;; ornith) echo 8086;; lfm) echo 8087;; vllm) echo 8088;; comfyui) echo 8188;; esac; }
label_of() { case $1 in openviking) echo com.openviking.server;; *) echo com.searxng-stack.$1-server;; esac; }
is_llm() { [[ " $LLMS_ALL " == *" $1 "* ]]; }
is_agent() { [[ " $AGENTS_ALL " == *" $1 "* ]]; }
is_off_by_default() { [[ " $OFF_BY_DEFAULT " == *" $1 "* ]]; }
# Process of each LLM server, to see one that is still loading (no listener yet).
proc_of() { case $1 in splash) echo 'splash serve.*--port 8000';; ornith) echo 'splash serve.*--port 8086';; sushi) echo 'sushi serve';;
  mellum) echo 'mlx_lm.server --model randmaru';; lfm) echo 'mlx_lm.server --model LiquidAI';; vllm) echo 'vllm serve';; comfyui) echo 'Python main.py';; esac; }
# Engines that serve one model at a time from a choice of several (served names; first = default).
models_of() { case $1 in vllm) echo Qwen3.5-9B-heretic Qwen3.6-35B-A3B;; splash) echo Qwen3.8-27B-Splash Qwen3.6-35B-A3B-Splash;; esac; }
model_choice() { local m; m=$(cat ~/.studio-models/"$1" 2>/dev/null); [[ " $(models_of "$1") " == *" $m "* ]] || m=$(models_of "$1" | cut -d' ' -f1); echo "$m"; }
vllm_repo() { case $1 in Qwen3.5-9B-heretic) echo xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic;; Qwen3.6-35B-A3B) echo mlx-community/Qwen3.6-35B-A3B-4bit;; esac; }
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

is_starting() { { is_llm "$1" || [ "$1" = comfyui ]; } && ! is_up "$1" && pgrep -f "$(proc_of "$1")" >/dev/null; }

start_one() {
  is_up "$1" && { echo "$1 already up"; return; }
  is_starting "$1" && { echo "$1 already starting"; return; }
  echo "start $1"
  case $1 in
    ornith) nohup ~/ornith-serve.sh > ~/ornith.log 2>&1 & ;;
    lfm)    nohup ~/lfm-serve.sh > ~/lfm.log 2>&1 & ;;
    sushi)  nohup ~/sushi-serve.sh > ~/sushi.log 2>&1 & ;;
    mellum) nohup ~/mellum-serve.sh > ~/mellum.log 2>&1 & ;;
    vllm)   m=$(model_choice vllm); VLLM_MODEL=$(vllm_repo "$m") VLLM_NAME=$m nohup ~/vllm-serve.sh > ~/vllm.log 2>&1 & ;;
    comfyui) nohup ~/ComfyUI/run_comfyui.sh > ~/comfyui.log 2>&1 & ;;
    splash) nohup splash serve --host $IP --port 8000 --model incoai/$(model_choice splash) --max-cache-disk 40G > ~/splash.log 2>&1 & ;;
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
      if is_llm "$1"; then
        pid=$(listener "$(port_of "$1")"); pkill -TERM -P "$pid" 2>/dev/null; kill "$pid"
      else
        launchctl bootout "gui/$UID_/$(label_of "$1")"
        is_off_by_default "$1" && launchctl disable "gui/$UID_/$(label_of "$1")"
      fi ;;
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
  for s in ollama searxng $AGENTS_ALL ${LLMS:-ornith}; do is_off_by_default "$s" || start_one "$s"; done
}

status() {
  for s in $SERVICES comfyui; do
    if is_up "$s"; then st=up; elif is_starting "$s"; then st=starting; else st=down; fi
    if [ "$1" = --tsv ]; then printf '%s\t%s\n' "$s" "$st"; else echo "$s $st"; fi
  done
  for e in vllm splash; do  # "model.<engine>  <current>  <choices>"
    if [ "$1" = --tsv ]; then printf 'model.%s\t%s\t%s\n' "$e" "$(model_choice $e)" "$(models_of $e)"; else echo "$e model $(model_choice $e) (of: $(models_of $e))"; fi
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
    # whatever vLLM serves now (VLLM_MODEL/VLLM_NAME in vllm-serve.sh); the stored choice while it is down or loading
    vllm) model=$(curl -s -m 3 -H "Authorization: Bearer $(cat ~/.sushi/api-key)" http://100.101.212.33:8088/v1/models |
            /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null) || model=$(model_choice vllm) ;;
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

# Show or switch an engine's model. A running engine restarts with it; Pi's default follows a vLLM switch.
model() {
  [ -n "$(models_of "$1")" ] || { echo "model: vllm or splash" >&2; exit 2; }
  [ -z "$2" ] && { model_choice "$1"; return; }
  [[ " $(models_of "$1") " == *" $2 "* ]] || { echo "$1 models: $(models_of "$1")" >&2; exit 2; }
  mkdir -p ~/.studio-models && echo "$2" > ~/.studio-models/"$1"
  echo "$1 model $2"
  if is_up "$1" || is_starting "$1"; then
    stop_one "$1"
    for i in $(seq 1 30); do [ -z "$(listener "$(port_of "$1")")" ] && ! pgrep -f "$(proc_of "$1")" >/dev/null && break; sleep 1; done
    start_one "$1"
  fi
  # Pi names the served model: point it at the new one now (default() falls back to the choice while vLLM loads).
  [ "$1" = vllm ] && [ "$(default)" = vllm ] && default vllm
  return 0
}

case $1 in
  stop|start|status|default) "$1" "$2" ;;
  model) model "$2" "$3" ;;
  *) echo "usage: $0 stop|start [service] | status [--tsv] | default [ornith|vllm] | model vllm|splash [MODEL]" >&2; exit 2 ;;
esac
