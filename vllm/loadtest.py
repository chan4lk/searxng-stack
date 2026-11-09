#!/usr/bin/env python3
"""Multi-user load test for an OpenAI-compatible chat endpoint (stdlib only).

N simulated users send streaming chat requests at the same time; for each concurrency level it
reports time to first token (TTFT), per-user decode speed and total throughput.

  python3 loadtest.py --url http://100.101.212.33:8088/v1 --model MODEL --users 1,2,4,8,16
  API key: --key or $OPENAI_API_KEY (Splash/Ornith needs ~/.sushi/api-key; vLLM none).
"""
import argparse, json, os, statistics, threading, time, urllib.request

PROMPTS = [
    "Explain how a hash map handles collisions, with a short Python example.",
    "Write a bash script that finds the 10 largest files under a directory.",
    "Summarise the trade-offs between REST and gRPC for internal services.",
    "What is the difference between a process and a thread? Give two examples.",
    "Write a SQL query that returns the top 3 customers by revenue per month.",
    "Explain the CAP theorem to a junior developer in plain words.",
    "Refactor this into a list comprehension: out=[]\nfor x in xs:\n  if x%2: out.append(x*x)",
    "List five common causes of memory leaks in Node.js services and how to find them.",
]


def one_request(args, i, out):
    body = {
        "model": args.model,
        "messages": [{"role": "user", "content": PROMPTS[i % len(PROMPTS)] + f" (request {i})"}],
        "max_tokens": args.max_tokens,
        "temperature": 0.7,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if args.no_think:
        body["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(
        args.url.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json", **({"authorization": f"Bearer {args.key}"} if args.key else {})},
    )
    start = time.perf_counter()
    first = None
    chunks = 0
    usage_tokens = None
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:") or line == "data: [DONE]":
                    continue
                msg = json.loads(line[5:])
                if msg.get("usage"):
                    usage_tokens = msg["usage"].get("completion_tokens")
                for ch in msg.get("choices") or []:
                    d = ch.get("delta") or {}
                    if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                        chunks += 1
                        if first is None:
                            first = time.perf_counter()
        end = time.perf_counter()
        tokens = usage_tokens or chunks
        out[i] = {"ok": True, "ttft": (first or end) - start, "total": end - start, "tokens": tokens,
                  "decode_tps": tokens / max(end - (first or start), 1e-6)}
    except Exception as e:  # report and keep going: one failed user shouldn't stop the level
        out[i] = {"ok": False, "error": str(e)[:200], "total": time.perf_counter() - start}


def run_level(args, n):
    out = [None] * n
    threads = [threading.Thread(target=one_request, args=(args, i, out)) for i in range(n)]
    t0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0
    ok = [r for r in out if r and r["ok"]]
    if not ok:
        return {"users": n, "ok": 0, "errors": [r.get("error") for r in out if r]}
    ttft = sorted(r["ttft"] for r in ok)
    return {
        "users": n,
        "ok": len(ok),
        "failed": n - len(ok),
        "ttft_p50": statistics.median(ttft),
        "ttft_max": ttft[-1],
        "user_tps_p50": statistics.median(r["decode_tps"] for r in ok),
        "total_tps": sum(r["tokens"] for r in ok) / wall,
        "wall": wall,
        "errors": [r.get("error") for r in out if r and not r["ok"]][:3],
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--key", default=os.environ.get("OPENAI_API_KEY", ""))
    p.add_argument("--users", default="1,2,4,8")
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--timeout", type=float, default=600)
    p.add_argument("--no-think", action="store_true", help="send chat_template_kwargs enable_thinking=false")
    args = p.parse_args()
    print(f"{args.url}  {args.model}  max_tokens={args.max_tokens}")
    print(f"{'users':>5} {'ok':>3} {'TTFT p50':>9} {'TTFT max':>9} {'tok/s/user':>11} {'tok/s total':>12} {'wall s':>7}")
    for n in [int(x) for x in args.users.split(",")]:
        r = run_level(args, n)
        if not r["ok"]:
            print(f"{n:>5}   0  all failed: {r['errors'][:1]}")
            continue
        print(f"{n:>5} {r['ok']:>3} {r['ttft_p50']:>8.2f}s {r['ttft_max']:>8.2f}s {r['user_tps_p50']:>11.1f} {r['total_tps']:>12.1f} {r['wall']:>7.1f}"
              + (f"  failed {r['failed']}: {r['errors'][:1]}" if r["failed"] else ""))


if __name__ == "__main__":
    main()
