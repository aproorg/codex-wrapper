#!/usr/bin/env python3
"""Localhost HTTP/1.1 -> LiteLLM HTTPS shim for Codex CLI.

Codex's bundled reqwest/native-tls stack can't complete requests to the
LiteLLM edge (curl works, Codex gets "error sending request"). This shim lets
Codex talk plaintext HTTP/1.1 to 127.0.0.1 while we forward to the real proxy
over Python's OpenSSL TLS (the same stack curl uses), and inject the
proxy-required x-github-repo header.

Run:  python3 ~/.codex/litellm_shim.py
Env:  SHIM_PORT (default 8787)
      SHIM_UPSTREAM (default https://litellm.ai.apro.is)
      SHIM_GITHUB_REPO (default aproorg/code)
"""
import http.client
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT = int(os.environ.get("SHIM_PORT", "8787"))
UPSTREAM = os.environ.get("SHIM_UPSTREAM", "https://litellm.ai.apro.is")
GITHUB_REPO = os.environ.get("SHIM_GITHUB_REPO", "aproorg/code")

_up = urlsplit(UPSTREAM)
UP_HOST = _up.hostname
UP_PORT = _up.port or (443 if _up.scheme == "https" else 80)
_SSL = ssl.create_default_context() if _up.scheme == "https" else None

# Headers we must not copy verbatim from client->upstream or upstream->client.
HOP_BY_HOP = {
    "host", "content-length", "connection", "keep-alive", "proxy-authenticate",
    "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade",
    "accept-encoding", "content-encoding",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter logs
        sys.stderr.write("[shim] " + (fmt % args) + "\n")

    def _proxy(self, method):
        body = b""
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n:
            body = self.rfile.read(n)

        out_headers = {}
        for k, v in self.headers.items():
            if k.lower() in HOP_BY_HOP:
                continue
            out_headers[k] = v
        # Forward the client's x-github-repo if present (set per-invocation by the
        # codex wrapper via env_http_headers); otherwise stamp the default.
        if not any(k.lower() == "x-github-repo" for k in out_headers):
            out_headers["x-github-repo"] = GITHUB_REPO
        out_headers["Accept-Encoding"] = "identity"  # avoid gzip so we can stream raw
        _repo = next((v for k, v in out_headers.items() if k.lower() == "x-github-repo"), "?")
        self.log_message("%s %s  x-github-repo=%s", method, self.path, _repo)

        try:
            if _up.scheme == "https":
                conn = http.client.HTTPSConnection(
                    UP_HOST, UP_PORT, timeout=600, context=_SSL
                )
            else:
                conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=600)
            conn.request(method, self.path, body=body, headers=out_headers)
            resp = conn.getresponse()
        except Exception as e:  # upstream/connection failure
            msg = f"shim upstream error: {e}".encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(msg)
            self.close_connection = True
            return

        # Stream response back; use Connection: close so the client reads to EOF
        # (works for both SSE streams and plain JSON).
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in HOP_BY_HOP:
                continue
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                chunk = resp.read(2048)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except Exception as e:
            self.log_message("stream error: %s", e)
        finally:
            conn.close()
            self.close_connection = True

    def do_POST(self):
        self._proxy("POST")

    def do_GET(self):
        self._proxy("GET")

    def do_DELETE(self):
        self._proxy("DELETE")


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[shim] listening on http://127.0.0.1:{PORT} -> {UPSTREAM} "
          f"(x-github-repo: {GITHUB_REPO})", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
