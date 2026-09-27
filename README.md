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
| `clients/dsh/image-generate.mjs` | dsh `generate_image` tool: calls `image-server`, saves the PNG into the session's workspace |
| `clients/dsh/splash.*.tmpl` | dsh settings and overlay: Splash models + SearXNG search |
| `clients/claude-code/splash-settings.json.tmpl` | Claude Code settings for a Splash server |
| `skills/mac-studio/` | Claude Code skill (plus SSH helper) for managing the server from a laptop |
| `image-server/` | On-demand Qwen-Image 2.1 API (mflux/MLX); loads the model per request and unloads when idle |
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
   - id: web
     config:
       searchProvider: searxng
       fetchProvider: http
   ```
3. Run dsh with the overlay:
   ```sh
   SEARXNG_URL=http://<machine>.<tailnet>.ts.net:8889 dsh --profile web --patch ~/.dsh/searxng.patch.yml
   ```

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
| `~/.dsh/plugins/*.mjs` | The dsh plugins: SearXNG search, launch-folder workspace, and `generate_image` |

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

```sh
curl http://<machine>.<tailnet>.ts.net:8890/v1/images/generations \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "a red fox in fresh snow, golden hour", "size": "1024x1024", "steps": 40}'
```

| Field | Default | Notes |
|---|---|---|
| `prompt` | — | required |
| `size` | `1024x1024` | multiples of 16, 256–2048 |
| `n` | 1 | up to 4 images, with consecutive seeds |
| `steps` | 40 | the model's recommended default |
| `guidance` / `negative_prompt` | 1.0 / none | true CFG runs only with guidance > 1 **and** a negative prompt |
| `seed` | random | returned per image |
| `quantize` | 8 | `0` = bf16 (best quality, ~46 GB peak), `4`, `8`; switching reloads the model |
| `response_format` | `b64_json` | or `url` (served from `/images/<name>`, kept 7 days) |

Other endpoints: `GET /health`, `GET /v1/models`, `POST /v1/load`, `POST /v1/unload`.

**In dsh:** the installer adds a `generate_image` tool, so you can just ask the
agent ("make a 1024x768 hero image of … and save it as assets/hero.png"). It
saves PNGs inside the session's workspace (by default in `generated-images/`),
refuses paths outside it, and allows 15 minutes per call to cover the first
model load.

To show the image in the chat, the tool's result asks the agent to open the
file with `read_image`, whose card is the only one the dsh UI draws images
on. This happens only when the session's model accepts images, meaning its
settings entry has `input: [text, image]`. The template sets that for
`Qwen3.6-35B-A3B-Splash`, which was checked against a real image.
Requests run one at a time; more than 4 waiting returns `429`.

The first run downloads `Qwen/Qwen-Image-2.1`, about 33 GB, into the Hugging
Face cache. On a 64 GB Mac, don't run bf16 alongside a local LLM server; 8-bit
leaves room for one. The weights are under the
[Qwen Research License](https://huggingface.co/Qwen/Qwen-Image-2.1), so check
its terms before any commercial use.

## Security notes

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
