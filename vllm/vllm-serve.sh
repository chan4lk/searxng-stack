#!/bin/bash
# Serve Qwen3.6-35B-A3B (MLX 4-bit) with vLLM on Apple Silicon (vllm-metal, Homebrew tap
# vllm-project/vllm-metal) on the tailnet, for multi-user tests. Same API key as ~/sushi-serve.sh.
# Install on the Studio as ~/vllm-serve.sh.  Start: nohup ~/vllm-serve.sh > ~/vllm.log 2>&1 &
# VLLM_MEM: share of RAM vLLM reserves up front (weights + fixed KV cache); 0.5 = ~32 GB.
export PATH=/opt/homebrew/bin:$PATH HF_HUB_OFFLINE=1
exec vllm serve mlx-community/Qwen3.6-35B-A3B-4bit \
  --host 100.101.212.33 --port 8088 --served-model-name Qwen3.6-35B-A3B \
  --api-key "$(cat ~/.sushi/api-key)" \
  --gpu-memory-utilization "${VLLM_MEM:-0.5}" --max-model-len "${VLLM_CTX:-65536}" \
  --enable-prefix-caching --reasoning-parser qwen3 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder "$@"
