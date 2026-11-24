---
name: claude-spark
description: Use when someone on the office Wi-Fi wants to run Claude Code on the local DGX Spark model (Ornith), asks about "claude-spark", the Spark, the office LLM, or a free/local model for Claude Code, or gets an error from claude-spark.
---

# claude-spark: Claude Code on the office DGX Spark

The office DGX Spark serves the open model **Ornith-1.5-35B-A3B** (NVFP4, MIT licence) with vLLM.
vLLM speaks the Anthropic Messages API, so Claude Code can use it in place of Anthropic's models.
Requests stay on the office network and cost nothing per token.

- Server: `http://192.168.1.11:8001` (office Wi-Fi only; no API key)
- Model name: `ornith`; context 128K tokens
- Speed: ~80 tokens/s for one user, ~16 tokens/s each when 32 people use it at once

## Setup (once)

1. Install Claude Code if needed: `npm i -g @anthropic-ai/claude-code`.
2. Copy `scripts/claude-spark.sh` from this skill to `~/.local/bin/claude-spark` and make it executable:
   ```bash
   mkdir -p ~/.local/bin
   cp "<this skill's directory>/scripts/claude-spark.sh" ~/.local/bin/claude-spark
   chmod +x ~/.local/bin/claude-spark
   ```
   Make sure `~/.local/bin` is on `PATH`. On Windows, run it from WSL or Git Bash.
3. Check the connection: `claude-spark --check`. It prints `claude-spark: ornith at http://192.168.1.11:8001`.

## Use

```bash
claude-spark                 # interactive Claude Code on Ornith
claude-spark -p "explain src/main.py"   # one-shot; any claude flag works
```

The script points every model slot (main, Opus/Sonnet/Haiku, subagents) at `ornith`. It turns off MCP
servers and claude.ai connectors, because their tool lists add ~60K tokens and make the first reply take
minutes. Normal `claude` is unchanged.

Overrides: `SPARK_URL` (another address, e.g. if the Spark's Wi-Fi address changed) and `SPARK_MODEL`.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| `no answer from http://192.168.1.11:8001` | You are not on the office Wi-Fi, or vLLM on the Spark is stopped. It starts at boot and takes ~2 minutes to be ready; if it stays down, ask the Spark's owner. |
| `is up but not serving 'ornith'` | The Spark runs another model right now (the message lists it). Use `SPARK_MODEL=<that name>` or ask the owner. |
| First reply slow | Normal for a long prompt: the server processes it once, then caches it. |

## Rules

- **Only one model runs on the Spark, shared by everyone.** Don't ask Claude to start, stop or switch it;
  you have no access, and a restart cuts off everyone else.
- **No API key, no login:** anyone on the Wi-Fi can use it. Treat it like a shared office printer:
  don't send passwords, keys or customer data you wouldn't put on the office network.
- Ornith is weaker than Anthropic's Claude models. Use normal `claude` for hard or risky work.
