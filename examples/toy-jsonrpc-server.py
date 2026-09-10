#!/usr/bin/env python3
"""
Minimal JSON-RPC 2.0 server over stdio, one JSON object per line
(newline-delimited, NOT Content-Length-framed like LSP/DAP) — matching
the framing Shell/JsonRpc assume (see docs/adr/0001-architecture-decisions.md,
ADR D5).

Exists purely as a Tutorial prop: real-world stdio JSON-RPC servers
that AREN'T MCP overwhelmingly use Content-Length framing instead, so
there's no well-known non-MCP server to exercise JsonRpc/Shell against
directly. This one exists to prove those two layers work against any
conforming NDJSON-RPC peer, not just MCP.

Methods:
  echo(text)          -> text
  add(a, b)           -> a + b
  sleep(seconds)       -> "slept <seconds>s" (after actually sleeping —
                          lets a client demonstrate a Receive timeout)

Run directly: python examples/toy-jsonrpc-server.py
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


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            resp = {"jsonrpc": "2.0", "id": None,
                    "error": {"code": -32700, "message": "Parse error"}}
            print(json.dumps(resp), flush=True)
            continue

        msg_id = msg.get("id")
        method_name = msg.get("method")
        params = msg.get("params") or {}

        if method_name not in METHODS:
            if msg_id is not None:
                resp = {"jsonrpc": "2.0", "id": msg_id,
                        "error": {"code": -32601, "message": "Method not found"}}
                print(json.dumps(resp), flush=True)
            continue  # notification with unknown method: silently ignore

        try:
            result = METHODS[method_name](params)
        except Exception as e:
            if msg_id is not None:
                resp = {"jsonrpc": "2.0", "id": msg_id,
                        "error": {"code": -32602, "message": str(e)}}
                print(json.dumps(resp), flush=True)
            continue

        if msg_id is not None:  # only requests get a response, not notifications
            resp = {"jsonrpc": "2.0", "id": msg_id, "result": result}
            print(json.dumps(resp), flush=True)


if __name__ == "__main__":
    main()
