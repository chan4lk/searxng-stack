#!/bin/bash
# Serve DavidAU's Qwen3.8-27B-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored NEO-CODER-MAX (Apache-2.0,
# uncensored merge) on the tailnet (100.101.212.33:8089) with llama.cpp llama-server (Homebrew, Metal).
# GGUF only, so not Splash/vLLM/mlx. MTP-Q5_K_M (21.2 GB) + mmproj-F16 (vision) in ~/models/qwen38-fcf.
# MTP self-speculation: 2 draft tokens (card: acceptance <50% means the non-MTP quant is faster).
# Sampling = card's coding settings; rep pen off (it hurts MTP). Same API key as ~/sushi-serve.sh.
# Start: nohup ~/fcf-serve.sh > ~/fcf.log 2>&1 &
export PATH=/opt/homebrew/bin:$PATH
D=~/models/qwen38-fcf
exec llama-server --host 100.101.212.33 --port 8089 \
  -m "$D/Qwen3.8-27B-TurboFCFusion-735-882-Here-Uncen-NEO-CODER-MAX-MTP-Q5_K_M.gguf" --mmproj "$D/mmproj-F16.gguf" \
  --alias Qwen3.8-27B-FCF --api-key "$(cat ~/.sushi/api-key)" \
  -c "${FCF_CTX:-131072}" -np 1 -ngl 999 -fa on --jinja --reasoning-format deepseek \
  --spec-type draft-mtp --spec-draft-n-max "${FCF_DRAFT:-2}" \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0 --repeat-penalty 1.0 "$@"
