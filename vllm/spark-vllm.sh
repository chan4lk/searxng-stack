#!/usr/bin/env bash
# Start/stop/check the vLLM server on the DGX Spark from this machine.
#   spark-vllm.sh start [ornith|lightning]   (default ornith; waits until it serves)
#   spark-vllm.sh stop | status | logs [model]
# SPARK_HOST (user@host) is required so no address lands in the repo.
# The Spark side is ~/vllm-moe.sh, which binds 0.0.0.0:8001 (tailnet + Wi-Fi).
set -euo pipefail
HOST=${SPARK_HOST:?set SPARK_HOST, e.g. user@100.x.y.z}
PORT=${PORT:-8001}
CMD=${1:-status}
MODEL=${2:-ornith}
ADDR=${HOST#*@}

remote() { ssh -o ConnectTimeout=15 "$HOST" "$@"; }

urls() {
  local lan
  lan=$(remote "ip -4 -o addr show | awk '\$2 ~ /^wl/ {split(\$4,a,\"/\"); print a[1]; exit}'")
  echo "Tailnet: http://$ADDR:$PORT/v1"
  [ -n "$lan" ] && echo "Wi-Fi:   http://$lan:$PORT/v1"
}

case $CMD in
  start)
    remote "PORT=$PORT ~/vllm-moe.sh $MODEL"
    echo "Waiting for $MODEL (first start takes a few minutes)..."
    for _ in $(seq 1 120); do  # 10 min
      if curl -sf -m 5 "http://$ADDR:$PORT/v1/models" | grep -q "\"$MODEL\""; then
        echo "Ready."; urls; exit 0
      fi
      remote "pgrep -f '[v]llm serve' >/dev/null" || { echo "vllm exited; tail of log:"; remote "tail -20 ~/vllm-$MODEL.log"; exit 1; }
      sleep 5
    done
    echo "Not ready after 10 min; check: $0 logs $MODEL"; exit 1 ;;
  stop)
    remote "pkill -f '[v]llm serve' && while pgrep -f '[v]llm serve' >/dev/null; do sleep 2; done; echo stopped" || echo "not running" ;;
  status)
    remote "pgrep -af '[v]llm serve' | grep -o 'served-model-name [^ ]*' || echo 'vllm not running'"
    curl -sf -m 5 "http://$ADDR:$PORT/v1/models" >/dev/null && { echo "API up"; urls; } || echo "API not answering" ;;
  logs)
    remote "tail -f ~/vllm-$MODEL.log" ;;
  *) echo "usage: $0 start [ornith|lightning] | stop | status | logs [model]"; exit 1 ;;
esac
