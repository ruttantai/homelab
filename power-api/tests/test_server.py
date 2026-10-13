"""Tests for the power API (spec §5.1, §7.4). multipass is never called: a fake runner records argument lists."""
import json
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server  # noqa: E402

TOKEN = "t0ken-for-tests"


class FakeRunner:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.calls = []
        self.result = SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)

    def __call__(self, args):
        self.calls.append(list(args))
        return self.result


@pytest.fixture
def api():
    def start(runner):
        srv = server.make_server("127.0.0.1", 0, TOKEN, runner)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        started.append(srv)
        return f"http://127.0.0.1:{srv.server_address[1]}"

    started = []
    yield start
    for srv in started:
        srv.shutdown()
        srv.server_close()


def call(base, method, path, token=TOKEN):
    req = urllib.request.Request(base + path, method=method, data=b"" if method == "POST" else None)
    if token is not None:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read() or b"{}")


@pytest.mark.parametrize("token", [None, "wrong", ""])
def test_rejects_missing_or_wrong_token(api, token):
    runner = FakeRunner()
    status, _ = call(api(runner), "POST", "/start?node=hpc-node-1", token=token)
    assert status == 401
    assert runner.calls == []


@pytest.mark.parametrize("query", [
    "node=cp-1",
    "node=hpc-node-1%3B%20rm%20-rf%20%2F",   # hpc-node-1; rm -rf /
    "node=",
    "node=hpc-node-1%0A",                    # trailing newline
    "node=hpc-node-%D9%A1",                  # Arabic-Indic digit one
    "node=..%2Fhpc-node-1",
    "node=hpc-head",
    "",                                      # no node at all
    "node=hpc-node-1&node=hpc-node-2",       # ambiguous
])
def test_rejects_bad_node_names(api, query):
    runner = FakeRunner()
    status, body = call(api(runner), "POST", f"/start?{query}")
    assert status == 400
    assert "error" in body
    assert runner.calls == []


@pytest.mark.parametrize("path,action", [("/start", "start"), ("/stop", "stop")])
def test_start_and_stop_run_exact_argument_lists(api, path, action):
    runner = FakeRunner()
    status, body = call(api(runner), "POST", f"{path}?node=hpc-node-2")
    assert status == 200
    assert body == {"node": "hpc-node-2", "action": action}
    assert runner.calls == [[action, "hpc-node-2"]]


def test_ip_reads_multipass_info(api):
    info = {"errors": [], "info": {"hpc-node-1": {"state": "Running", "ipv4": ["192.168.64.21"]}}}
    runner = FakeRunner(stdout=json.dumps(info))
    status, body = call(api(runner), "GET", "/ip?node=hpc-node-1")
    assert status == 200
    assert body == {"node": "hpc-node-1", "ip": "192.168.64.21"}
    assert runner.calls == [["info", "hpc-node-1", "--format", "json"]]


def test_ip_is_null_while_booting(api):
    info = {"errors": [], "info": {"hpc-node-1": {"state": "Starting", "ipv4": []}}}
    status, body = call(api(FakeRunner(stdout=json.dumps(info))), "GET", "/ip?node=hpc-node-1")
    assert status == 200
    assert body["ip"] is None


def test_multipass_failure_is_502_with_its_message(api):
    runner = FakeRunner(returncode=2, stderr="instance \"hpc-node-1\" does not exist")
    status, body = call(api(runner), "POST", "/start?node=hpc-node-1")
    assert status == 502
    assert "does not exist" in body["error"]


@pytest.mark.parametrize("method,path", [("GET", "/start?node=hpc-node-1"), ("POST", "/ip?node=hpc-node-1"),
                                         ("POST", "/reboot?node=hpc-node-1")])
def test_unknown_method_or_path_is_404(api, method, path):
    runner = FakeRunner()
    status, _ = call(api(runner), method, path)
    assert status == 404
    assert runner.calls == []


@pytest.mark.parametrize("bind", ["0.0.0.0", "::", ""])
def test_main_refuses_wildcard_bind(tmp_path, bind):
    token = tmp_path / "token"
    token.write_text("abc\n")
    with pytest.raises(SystemExit):
        server.main(["--bind", bind, "--token-file", str(token)])


def test_main_refuses_empty_token(tmp_path):
    token = tmp_path / "token"
    token.write_text("\n")
    with pytest.raises(SystemExit):
        server.main(["--bind", "127.0.0.1", "--token-file", str(token)])


@pytest.mark.parametrize("name,ok", [("hpc-node-1", True), ("hpc-node-12", True), ("hpc-node-", False),
                                     ("HPC-node-1", False), ("hpc-node-1\n", False)])
def test_valid_node(name, ok):
    assert server.valid_node(name) is ok
