#!/bin/bash
# Sushi (Qwen3.8-Flash-Next-Sushi-3bpw) for llama-swap: same settings as the old ~/sushi-serve.sh, but on loopback
# port $1 with no key of its own (llama-swap checks the key). Experts stream from the SSD: 44 GiB resident with
# `sudo sysctl iogpu.wired_limit_mb=59000` (resets at reboot), else 36 GiB. SUSHI_SSD_BUDGET overrides.
export PATH=/opt/homebrew/bin:$PATH
budget=36; [ "$(sysctl -n iogpu.wired_limit_mb)" -ge 59000 ] && budget=44
exec sushi serve --model ~/.sushi/models/Qwen3.8-Flash-Next-Sushi-3bpw --host 127.0.0.1 --port "$1" \
  --kv-quant 4 --prefill-chunk 2048 --ctx-size 262144 --max-tokens 32000 \
  --prefix-cache-disk 20GB --prefix-cache-entries 8 --no-prefix-cache-ram --ssm-checkpoint-max 8 \
  --gpu-warm-secs 300 --metrics --preserve-thinking on --temp 1 \
  --vision --ssd-budget-gb "${SUSHI_SSD_BUDGET:-$budget}"
