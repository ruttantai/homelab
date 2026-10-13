#!/usr/bin/env python3
"""Power API for the lab's elastic Slurm nodes (spec §5.1).

Slurm's resume/suspend hooks on hpc-head call this on the Mac. It only ever runs
`multipass start|stop|info` as an argument list, for names matching hpc-node-<digits>,
and only for callers presenting the bearer token. It binds one address (the Multipass
network), never a wildcard, so nothing else on the LAN can reach it.
"""
import argparse
import hmac
import json
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

NODE_RE = re.compile(r"hpc-node-[0-9]+", re.ASCII)
ROUTES = {("POST", "/start"): "start", ("POST", "/stop"): "stop", ("GET", "/ip"): "ip"}
WILDCARD_BINDS = {"", "0.0.0.0", "::"}


def valid_node(name):
    return NODE_RE.fullmatch(name) is not None


def run_multipass(args):
    return subprocess.run(["multipass", *args], capture_output=True, text=True, timeout=180, check=False)


def make_handler(token, runner):
    expected = f"Bearer {token}".encode()

    class Handler(BaseHTTPRequestHandler):
        def _reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _handle(self, method):
            url = urlparse(self.path)
            action = ROUTES.get((method, url.path))
            if action is None:
                return self._reply(404, {"error": "not found"})
            # Auth before validating input, so unauthenticated callers learn nothing about the rules.
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected):
                return self._reply(401, {"error": "unauthorized"})
            nodes = parse_qs(url.query, keep_blank_values=True).get("node", [])
            if len(nodes) != 1 or not valid_node(nodes[0]):
                return self._reply(400, {"error": "node must be exactly one hpc-node-<number>"})
            node = nodes[0]
            args = ["info", node, "--format", "json"] if action == "ip" else [action, node]
            result = runner(args)
            if result.returncode != 0:
                return self._reply(502, {"error": (result.stderr or result.stdout).strip()})
            if action == "ip":
                ipv4 = json.loads(result.stdout).get("info", {}).get(node, {}).get("ipv4") or []
                return self._reply(200, {"node": node, "ip": ipv4[0] if ipv4 else None})
            return self._reply(200, {"node": node, "action": action})

        def do_GET(self):  # noqa: N802 (http.server naming)
            self._handle("GET")

        def do_POST(self):  # noqa: N802
            self._handle("POST")

    return Handler


def make_server(bind, port, token, runner=run_multipass):
    return ThreadingHTTPServer((bind, port), make_handler(token, runner))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bind", required=True, help="the Mac's address on the Multipass network")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token-file", required=True)
    args = parser.parse_args(argv)
    if args.bind in WILDCARD_BINDS:
        sys.exit(f"refusing to bind {args.bind!r}: pass the Multipass network address")
    with open(args.token_file, encoding="utf-8") as fh:
        token = fh.read().strip()
    if not token:
        sys.exit(f"empty token in {args.token_file}")
    srv = make_server(args.bind, args.port, token)
    print(f"power-api listening on {args.bind}:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
