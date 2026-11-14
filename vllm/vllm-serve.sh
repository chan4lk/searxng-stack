#!/bin/bash
# Serve the Qwen3.5-9B heretic fine-tune (BF16, Pi's default since 2026-11-11) with vLLM on Apple Silicon (vllm-metal, Homebrew tap
# vllm-project/vllm-metal) on the tailnet, for multi-user tests. Same API key as ~/sushi-serve.sh.
# Install on the Studio as ~/vllm-serve.sh.  Start: nohup ~/vllm-serve.sh > ~/vllm.log 2>&1 &
# VLLM_MEM: share of RAM vLLM reserves up front (weights + fixed KV cache); 0.5 = ~32 GB.
# VLLM_MODEL / VLLM_NAME pick another model, e.g. Qwen3.6-35B-A3B (MLX 4-bit):
#   VLLM_MODEL=mlx-community/Qwen3.6-35B-A3B-4bit VLLM_NAME=Qwen3.6-35B-A3B
export PATH=/opt/homebrew/bin:$PATH HF_HUB_OFFLINE=1
exec vllm serve "${VLLM_MODEL:-xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic}" \
  --host 100.101.212.33 --port 8088 --served-model-name "${VLLM_NAME:-Qwen3.5-9B-heretic}" \
  --api-key "$(cat ~/.sushi/api-key)" \
  --gpu-memory-utilization "${VLLM_MEM:-0.5}" --max-model-len "${VLLM_CTX:-131072}" \
  --enable-prefix-caching --reasoning-parser qwen3 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder "$@"
