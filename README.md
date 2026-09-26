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
| `clients/dsh/searxng-search.mjs` | Example `web_search` provider plugin for DeepSeek Harness |

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
