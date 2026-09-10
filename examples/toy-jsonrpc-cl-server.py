#!/usr/bin/env python3
"""
Minimal JSON-RPC 2.0 server over stdio, Content-Length-header framed —
the same framing LSP/DAP use ("Content-Length: N\r\n\r\n" followed by
exactly N bytes of JSON), NOT the newline-delimited framing
Shell/JsonRpc use (see docs/adr/0001-architecture-decisions.md, ADR
D13). Exists to test JsonRpcCl against something real without needing
a full language server's initialize handshake.

Methods: same four as examples/toy-jsonrpc-server.py (echo/add/sleep/
log) — this is the Content-Length-framed twin of that script,
deliberately kept in sync so the two transports can be compared
directly.

Run directly: python examples/toy-jsonrpc-cl-server.py
"""
import json
import sys
import time

METHODS = {}


def method(name):
    def register(fn):
        METHODS[name] = fn
        return fn
    return register


@method("echo")
def _echo(params):
    return params["text"]


@method("add")
def _add(params):
    return params["a"] + params["b"]


@method("sleep")
def _sleep(params):
    seconds = params["seconds"]
    time.sleep(seconds)
    return f"slept {seconds}s"


@method("log")
def _log(params):
    print(params.get("text", "log line"), file=sys.stderr, flush=True)
    return "logged"


def read_message(stream):
    """Read one Content-Length-framed message, or None at EOF. Tolerates
    a stray blank line before the headers start (some senders leave a
    trailing newline after the previous message's body) — only a blank
    line AFTER at least one real header ends the header block."""
    headers = {}
    while True:
        line = stream.readline()
        if line == b"":
            return None  # EOF
        line = line.rstrip(b"\r\n")
        if line == b"":
            if headers:
                break  # end of header block
            continue  # stray leading blank line — keep waiting for headers
        name, _, value = line.partition(b":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers[b"content-length"])
    body = stream.read(length)
    return json.loads(body.decode("utf-8"))


def write_message(stream, obj):
    body = json.dumps(obj).encode("utf-8")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    stream.write(body)
    stream.flush()


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        msg = read_message(stdin)
        if msg is None:
            return
        msg_id = msg.get("id")
        method_name = msg.get("method")
        params = msg.get("params") or {}

        if method_name not in METHODS:
            if msg_id is not None:
                write_message(stdout, {"jsonrpc": "2.0", "id": msg_id,
                                        "error": {"code": -32601, "message": "Method not found"}})
            continue

        try:
            result = METHODS[method_name](params)
        except Exception as e:
            if msg_id is not None:
                write_message(stdout, {"jsonrpc": "2.0", "id": msg_id,
                                        "error": {"code": -32602, "message": str(e)}})
            continue

        if msg_id is not None:
            write_message(stdout, {"jsonrpc": "2.0", "id": msg_id, "result": result})


if __name__ == "__main__":
    main()
