#!/usr/bin/env python3
"""Local pass-through proxy in front of Splash for the claude-splash Qwen3.6 profile.

Claude Code can't set these per model, so for POST /v1/messages the proxy adds:
  - context_management clear_thinking keep:all  -> Splash renders the Qwen chat
    template with preserve_thinking=True. Without it Qwen3.6 drops earlier
    reasoning and starts emitting tool calls with empty {} arguments after a
    few turns.
  - Qwen's "thinking, precise coding" sampling: temperature 0.6, top_p 0.95,
    top_k 20 (Claude Code sends temperature 1).
Everything else, including streaming responses, passes through unchanged.

usage: splash-proxy.py UPSTREAM_URL PORT   (binds 127.0.0.1 only)
"""
import http.client
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = urllib.parse.urlsplit(sys.argv[1])
PORT = int(sys.argv[2])
SAMPLING = {"temperature": 0.6, "top_p": 0.95, "top_k": 20}
PRESERVE = {"edits": [{"type": "clear_thinking_20251015", "keep": "all"}]}
HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "host"}


def rewrite(path, body):
    if not path.startswith("/v1/messages") or path.startswith("/v1/messages/count_tokens"):
        return body
    try:
        data = json.loads(body)
    except ValueError:
        return body
    data.update(SAMPLING)
    data.setdefault("context_management", PRESERVE)
    return json.dumps(data).encode()


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # quiet
        return

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.command == "POST":
            body = rewrite(self.path, body)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Content-Length"] = str(len(body))
        conn = http.client.HTTPConnection(UPSTREAM.hostname or "127.0.0.1", UPSTREAM.port or 80, timeout=900)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except OSError as e:
            msg = json.dumps({"type": "error", "error": {"type": "api_error",
                              "message": f"splash-proxy: upstream unreachable: {e}"}}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
        finally:
            conn.close()

    do_GET = do_POST = do_HEAD = do_DELETE = _forward


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Proxy).serve_forever()
