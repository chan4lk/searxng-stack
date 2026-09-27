# searxng-stack

A keyless web-search API for AI agents, run on a Mac and shared privately over
[Tailscale](https://tailscale.com).

[SearXNG](https://github.com/searxng/searxng) queries many search engines and
returns merged results as JSON, with no API key or account. This repo runs it
with a Valkey cache in Docker, keeps it on loopback, and publishes it to your
tailnet only, so every machine on your tailnet gets one search endpoint.

It suits agent harnesses whose built-in search needs a paid key, such as
DeepSeek Harness (`dsh`) or self-hosted LLM setups.

## What's here

| File | Purpose |
|---|---|
| `docker-compose.yml` | SearXNG + Valkey, bound to `127.0.0.1` only |
| `searxng/settings.yml` | JSON output on, bot limiter off, DuckDuckGo off (see below) |
| `searxng.sh` | Starts the Docker runtime and the stack, publishes it with `tailscale serve`, and runs test searches |
| `clients/dsh/searxng-search.mjs` | `web_search` provider plugin for DeepSeek Harness |
| `clients/dsh/cwd-workspace.mjs` | dsh plugin that opens the web UI in the directory you launched it from |
| `clients/dsh/image-generate.mjs` | dsh `generate_image` and `edit_image` tools: call `image-server`, save PNGs into the session's workspace |
| `clients/dsh/splash.*.tmpl` | dsh settings and overlay: Splash models + SearXNG search |
| `clients/claude-code/splash-settings.json.tmpl` | Claude Code settings for a Splash server |
| `clients/dsh/studio-guard.mjs` | dsh guard: denies agent commands that stop, kill or restart anything on the server |
| `skills/mac-studio/` | Claude Code skill (plus SSH helper) for managing the server from a laptop |
| `image-server/` | On-demand Qwen-Image 2.1 API (mflux/MLX); loads the model per request and unloads when idle |
| `music-server/` | On-demand ACE-Step 1.5 music API (MIT): starts the ACE-Step server per request and stops it when idle |
| `clients/dsh/music-generate.mjs` | dsh `generate_music` tool: calls `music-server`, saves audio into the session's workspace |
| `install.sh`, `install.env.example` | Installs everything under `clients/` and `skills/` on a client machine |

The server side (this stack) and the client side (the laptop running the
agents) are set up separately. [Replicating the full setup](#replicating-the-full-setup)
covers both.

## Requirements

- macOS on Apple silicon (Linux works too; skip the Colima bits)
- A Docker runtime. On a headless Mac, [Colima](https://github.com/abiosoft/colima) is the lightest:
  ```sh
  brew install colima docker docker-compose
  mkdir -p ~/.docker/cli-plugins
  ln -sfn /opt/homebrew/opt/docker-compose/bin/docker-compose ~/.docker/cli-plugins/docker-compose
  brew services start colima   # start at login
  ```
- The Tailscale CLI, logged in (`brew install tailscale` or the Tailscale app)

## Quick start

```sh
git clone https://github.com/chan4lk/searxng-stack.git
cd searxng-stack
./searxng.sh up
```

`up` does the following:

1. Starts Colima if the Docker daemon isn't running. The VM is 2 CPU, 2 GB RAM and 20 GB disk, which leaves room for other workloads such as a local LLM server.
2. Creates `.env` with a random `SEARXNG_SECRET` on the first run. `.env` is git-ignored.
3. Starts the stack and waits until it's healthy.
4. Runs `tailscale serve` so the port is reachable across your tailnet.
5. Runs a test search against both the local and the tailnet URL.

The tailnet URL is `http://<machine>.<tailnet>.ts.net:8889`.

## Commands

```text
./searxng.sh up | down | restart | status | logs
./searxng.sh test [query]      search via local and tailnet URLs
./searxng.sh serve | unserve   publish / unpublish on the tailnet only
```

| Variable | Default | Meaning |
|---|---|---|
| `SEARXNG_PORT` | `8889` | Port on loopback and on the tailnet |
| `TS_SERVE_PROTO` | `http` | `https` needs HTTPS certificates enabled in the Tailscale admin console |

Plain HTTP is usually fine here: traffic between tailnet devices is already
encrypted by WireGuard.

## Using the API

```sh
curl "http://<machine>.<tailnet>.ts.net:8889/search?q=speculative+decoding&format=json"
```

Each item in `results[]` has `url`, `title`, `content` (the snippet) and
sometimes `publishedDate`.

### DeepSeek Harness (`dsh`)

1. Copy `clients/dsh/searxng-search.mjs` to `~/.dsh/plugins/`.
2. Add an overlay, for example `~/.dsh/searxng.patch.yml`:
   ```yaml
   - insert:
       - id: searxng-search
         name: /Users/<you>/.dsh/plugins/searxng-search.mjs   # must be a literal absolute path
         config:
           url: http://<machine>.<tailnet>.ts.net:8889         # or set $SEARXNG_URL
   - id: web
     config:
       searchProvider: searxng
       fetchProvider: http
   ```
3. Run dsh with the overlay:
   ```sh
   dsh --profile web --patch ~/.dsh/searxng.patch.yml
   ```
   The plugin uses `$SEARXNG_URL` if it's set, otherwise `config.url`, otherwise `http://127.0.0.1:8889`.

## Replicating the full setup

The full setup has two machines on one tailnet:

- **Server** (e.g. a Mac Studio): runs [Splash](https://github.com/incoai/splash)
  (`brew install incoai/tap/splash`), which serves a local LLM with OpenAI- and Anthropic-compatible APIs, plus this
  SearXNG stack.
- **Client** (e.g. a laptop): runs Claude Code and DeepSeek Harness against
  that server.

### 1. Server

```sh
brew install colima docker docker-compose tailscale incoai/tap/splash
git clone https://github.com/chan4lk/searxng-stack.git ~/searxng-stack
~/searxng-stack/searxng.sh up

# Splash serves one model at a time. --host must be the machine's tailnet
# name; the default, 127.0.0.1, isn't reachable from other machines.
nohup splash serve --host "$(hostname -s | tr A-Z a-z)" --port 8000 \
  --model incoai/Qwen3.6-35B-A3B-Splash > ~/splash.log 2>&1 &
```

For the client to manage the server, turn on
[Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) on the server
(`tailscale set --ssh`) and allow it in your tailnet policy.

### 2. Client

```sh
git clone https://github.com/chan4lk/searxng-stack.git && cd searxng-stack
cp install.env.example install.env    # fill in; the comments say where each value comes from
./install.sh --dry-run                # preview every file and alias it would write
./install.sh
source ~/.zshrc
```

The installer fills the placeholders in each template with your values. When
it would change an existing file, it saves a timestamped `.bak-*` copy first.
Running it again is safe: files already up to date are left alone. It installs:

| Installed | Purpose |
|---|---|
| `~/.claude/splash-settings.json` + alias `claude-splash` | Claude Code using Splash as its model |
| `~/.claude/skills/<SERVER_NAME>/` | A skill for checking, restarting and deploying things on the server |
| `~/.dsh/splash.settings.yaml`, `~/.dsh/splash.patch.yml` + alias `dsh-splash` | dsh on Splash (both models listed), with search through SearXNG, web fetch, and image generation |
| `~/.dsh/plugins/*.mjs` | The dsh plugins: SearXNG search, launch-folder workspace, and the image tools |

Then check it:

```sh
bash ~/.claude/skills/<SERVER_NAME>/scripts/studio.sh health
dsh-splash --profile headless "Use web_search to find the SearXNG docs. Reply with the URL."
claude-splash
```

The first `studio.sh` call may print a `login.tailscale.com` link. Open it in
the browser profile signed in to your tailnet to approve SSH access.

**Switching models:** restart `splash serve` on the server with the other
`--model`, then pick that model in the dsh UI. For `claude-splash`, set
`SPLASH_MODEL` in `install.env` and re-run `./install.sh`. A request for the
model that isn't loaded fails with `HTTP 404 model_not_found`.

## On-demand image generation (`image-server/`)

An OpenAI-style image API for Qwen-Image 2.1, run with
[mflux](https://github.com/filipstrand/mflux), the MLX-native diffusion
library. The model **isn't kept in memory**: the first request loads it, and it
unloads after 10 idle minutes, so the server holds ~100 MB until you use it.

```sh
cd ~/searxng-stack/image-server
./image-server.sh install     # uv sync, launchd LaunchAgent, tailscale serve on :8890
./image-server.sh test        # one 512x512 image (the first call also loads the model)
```

### Capabilities

| Capability | Endpoint | Key fields |
|---|---|---|
| Text-to-image | `POST /v1/images/generations` | `prompt`, `size` |
| Transparent (RGBA) output | both | `"transparent": true` for stickers, icons and cut-outs |
| Edit one image by instruction | `POST /v1/images/edits` | `images: [one]`, `prompt: "Change the jacket to green, keep the face"` |
| **Combine / merge up to 10 images** | `POST /v1/images/edits` | `images: [a, b, …]`, `prompt: "Place the subject from image 1 in the setting of image 2"` |
| Restyle (keep composition) | `POST /v1/images/edits` | `prompt: "Repaint image 1 as a watercolor painting, keep the composition"` |
| Close variation of an image | `POST /v1/images/generations` | `image` + `strength` (0.05 = barely changed, 0.95 = almost fully redrawn) |

Images are sent as base64 strings or `data:` URLs. In edit prompts, refer to
them as "image 1", "image 2", … in the order given. Without `size`, an edit's
output follows the last image's aspect ratio, and `output_resolution` (default
1024; 512 is faster) sets the pixel budget. Sizes must be multiples of 32.

Common fields: `n` (1–4, consecutive seeds), `steps` (default 40), `seed`,
`guidance` / `negative_prompt` (true CFG runs only with guidance > 1 **and** a
negative prompt), `quantize` (`8` default, `4`, or `0` = bf16), and
`response_format` (`b64_json`, or `url` served from `/images/<name>` and kept 7 days).

Other endpoints: `GET /health`, `GET /v1/models`, `POST /v1/load?variant=edit|img2img`, `POST /v1/unload`.
Requests run one at a time; more than 4 waiting returns `429`.

### Memory guardrails (off by default)

The guard is **disabled by default** (`IMAGE_MEMORY_GUARD=0`). On a Mac shared
with a local LLM it refused too many jobs, so requests now load the
quantization they ask for and run, and macOS swaps if it has to. To turn it on:
`IMAGE_MEMORY_GUARD=1 ./image-server.sh install`. When enabled:

- **Pre-load check:** before loading, the server compares available memory
  with the expected peak for **this job's size**, plus `IMAGE_MEMORY_HEADROOM_GB`
  (default 4). If memory is short, it steps down bf16 → 8-bit → 4-bit
  (`IMAGE_AUTO_DOWNGRADE=1`). If even 4-bit doesn't fit, it answers **503** with
  the numbers, and the response's `quantize` shows what was actually used.
- **Available memory is counted the way macOS counts it:** total minus app
  (anonymous) memory, wired and compressed, plus purgeable. Disk cache, such as
  a local LLM's memory-mapped weights, is **reclaimable**: macOS drops it and
  re-reads from disk. psutil's free+inactive treated recently used cache as
  taken, so jobs were refused right after the LLM had answered.
- **Pre-generation check:** before each image, it confirms there's room for the
  generation's working memory on top of the loaded weights.
- **Size-aware measured peaks:** each response reports `peak_memory_gb`, and
  peaks are saved per variant, quantization and **workload** (output pixels
  plus reference pixels: ≤0.3, ≤0.7, ≤1.2, ≤2.5, ≤5 MP, larger) in
  `~/.image-server-peaks.json`. An unmeasured workload uses the next larger
  measured one, and anything above the largest measured adds 6 GB per step.
  Measured for 8-bit edit: **21 GB at 512², 25 GB at 768², 29.5 GB at 1024²**.
- **MLX limits:** `IMAGE_MEMORY_LIMIT_GB` (default 0 = MLX's own default) and
  `IMAGE_CACHE_LIMIT_GB` (default 2), and the cache is cleared after every job.
  MLX treats the memory limit as a guideline that only fails once RAM and swap
  are exhausted, so the pre-checks above are the real guard.

`GET /health` includes a `memory` section: available GB, limits, and observed peaks.
`image-server.sh stop|restart|install` also refuses to run while a generation
is running or queued (`FORCE=1` overrides), so a restart can't cut off a request.

**Tested at 512×512, 8-bit:** text-to-image took ~20 s, a two-image merge ~47 s,
a watercolor restyle ~12 s, and a transparent sticker ~37 s. Only one model
variant is kept in memory at a time. `edit` handles everything except
strength-based variations, which load `img2img` and swap `edit` out, so mixing
the two adds a reload.

Reference editing, transparent output and prompt caching need an mflux build
newer than 0.20.0. `pyproject.toml` pins the commit that added them
(filipstrand/mflux#741). Switch back to a release once one includes them.

**In dsh:** the installer adds two tools, `generate_image` (text-to-image,
`transparent`, `init_image` + `strength`) and `edit_image` (1–10 workspace
images plus an instruction, `detail` low/medium/high). Just ask the agent,
for example "put the logo from brand.png on the mug in mug.jpg and save it as
assets/mug.png". Results are saved inside the session's workspace (by
default in `generated-images/`), and paths outside it are refused. When the
session's model accepts images (`input: [text, image]` in its settings entry;
the template sets this for `Qwen3.6-35B-A3B-Splash`), the result asks the agent
to open the file with `read_image`. That card is the only one the dsh UI draws
images on.

The first run downloads `Qwen/Qwen-Image-2.1`, about 33 GB, into the Hugging
Face cache. On a 64 GB Mac, don't run bf16 alongside a local LLM server; 8-bit
leaves room for one. The weights are under the
[Qwen Research License](https://huggingface.co/Qwen/Qwen-Image-2.1), so check
its terms before any commercial use.

## On-demand music generation (`music-server/`)

Original music from a text prompt, with optional lyrics, using
[ACE-Step 1.5](https://github.com/ace-step/ACE-Step-1.5). It's **MIT-licensed**
and trained on licensed, royalty-free and synthetic data, so the output can be
used commercially, e.g. soundtracks for short-form video. (YuE2 scores
higher, but it's CC-BY-NC, non-commercial only.)

ACE-Step's own API server keeps its models resident and has no unload, so
`music-server` **supervises** it. The first request starts `acestep-api`
(with the MLX LM backend, as ACE-Step's macOS launcher does) as a child process.
The server submits the job, polls it and saves the audio, and **stops the child
after 10 idle minutes**, which returns all of its memory. When idle the service
uses about 50 MB.

```sh
# one-time: install ACE-Step itself (≈10 GB of models download on first use)
git clone https://github.com/ace-step/ACE-Step-1.5.git ~/ace-step && (cd ~/ace-step && uv sync --python 3.12)
# if the model download crawls, fetch it without Xet:
HF_HUB_DISABLE_XET=1 uvx --from huggingface_hub hf download ACE-Step/Ace-Step1.5 --local-dir ~/ace-step/checkpoints

cd ~/searxng-stack/music-server
./music-server.sh install     # LaunchAgent + tailscale serve on :8891
./music-server.sh test        # a 20 s instrumental
```

```sh
curl http://<machine>.<tailnet>.ts.net:8891/v1/music/generations \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "upbeat corporate pop, bright synths, punchy drums, for a 30s product reel", "instrumental": true, "duration": 30}'
```

| Field | Default | Notes |
|---|---|---|
| `prompt` | — | genre, mood, instruments, use |
| `lyrics` / `instrumental` | none / false | lyrics use `[Verse]`, `[Chorus]`, … tags; no lyrics means instrumental |
| `duration` | 30 | 10–600 seconds |
| `bpm`, `key`, `time_signature`, `language` | model decides / `en` | optional control |
| `seed`, `steps` (8), `thinking` (true, the LM plans the song first) | | |
| `format` | `mp3` | or `wav`, `flac`; served from `/music/<name>`, kept 14 days |

**In dsh:** the installer adds a `generate_music` tool, which saves into
`generated-music/` in the session's workspace. `studio-guard` also stops agents
from restarting or stopping `music-server`.

## Security notes

- **Agents can't take the server down from dsh.** `studio-guard` hooks dsh's
  `tools/pre-execute`. It denies any tool call that reaches the server (ssh, scp
  or tailscale ssh to its IP or name) and contains a stop, kill or restart verb:
  `pkill`, `launchctl bootout`, `docker … down`, `image-server.sh restart`, and
  so on. Read-only checks still run. The image server's 503 message also tells
  agents to report to the user instead of freeing memory themselves.

- The bot limiter is off because agent traffic would trip it. That's only
  acceptable because the service is never exposed publicly: it's bound to
  `127.0.0.1` and reached through `tailscale serve`, never Funnel. Don't
  change the port binding to `0.0.0.0` or enable `tailscale funnel` without
  turning the limiter back on.
- There's no authentication. Anyone on your tailnet can use it, so restrict
  access with Tailscale ACLs if the tailnet is shared.

## Troubleshooting

- **DuckDuckGo returns CAPTCHAs.** It commonly does this for residential and
  self-hosted IPs, which is why it's disabled in `settings.yml`. If another
  engine shows up in `unresponsive_engines` (`./searxng.sh test`), disable it
  the same way.
- **Nothing responds after a reboot.** `brew services` starts Colima only once
  the user logs in. Log in, or run `./searxng.sh up`.
- **`docker compose` isn't found.** Link the plugin into
  `~/.docker/cli-plugins` (see Requirements).

## License

MIT
