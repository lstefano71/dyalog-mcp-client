#!/usr/bin/env python3
"""
Misbehavior-on-demand JSON-RPC 2.0 server over stdio, NDJSON-framed (one
JSON object per line — same framing as examples/toy-jsonrpc-server.py,
NOT Content-Length; see docs/adr/0001-architecture-decisions.md, ADR D5).

Built for Phase 6 (see PLAN.md, ADR D14): a real MCP server never
reliably misbehaves on demand, so the hard-to-provoke failure paths in
Shell/JsonRpc (dead process mid-Receive, malformed JSON, a hung
request, a burst of unsolicited notifications ahead of a real response)
can't be tested deterministically against one. This fixture lets a test
*ask* for each misbehavior, by method name, so the failure is
reproducible instead of hoped-for.

Methods:
  echo(text)              -> text, same as the plain toy server — a
                             sanity-check baseline that ordinary
                             request/response still works here.
  crash(code)             -> exits the process immediately with the
                             given code (default 1) instead of ever
                             writing a response line. `code` optional.
  garbage(size)           -> writes one line of deliberately invalid
                             JSON (not parseable at all) instead of a
                             real response, then continues serving
                             later requests normally. `size` optional:
                             pads the bad line out to roughly that many
                             characters, so a client can be tested
                             against a LONG unparseable line as well as
                             a short one.
  hang()                  -> never responds, ever — blocks forever
                             (⎕TGET on the client side must time out).
                             Deliberately a DEDICATED method rather than
                             reusing the existing toy server's
                             `sleep(seconds)` idea: `sleep` always
                             eventually answers (it's meant to
                             demonstrate a client-side timeout that's
                             shorter than the sleep, not a server that
                             truly never comes back), which leaves a
                             race between the timeout and a slow-but-
                             finite sleep. `hang` removes that race
                             entirely by never producing a response no
                             matter how long the client waits.
  burst(count, text)      -> emits `count` (default 8) unsolicited
                             notifications first (no "id" field, method
                             "burst/notice", params {n, text}), THEN a
                             normal response — to stress-test a
                             client's notification queue under load
                             without disrupting the real response that
                             eventually follows.

Run directly: python examples/toy-jsonrpc-fixture-server.py
"""
import json
import sys
import threading

METHODS = {}


def method(name):
    def register(fn):
        METHODS[name] = fn
        return fn
    return register


def _write(obj):
    print(json.dumps(obj), flush=True)


@method("echo")
def _echo(params):
    return params["text"]


@method("crash")
def _crash(params):
    code = params.get("code", 1)
    sys.exit(code)


@method("garbage")
def _garbage(params):
    # Not valid JSON by construction — an unterminated object. `size`
    # (optional) pads it out to roughly that many characters, so a client
    # can check how it handles a *long* unparseable line — the whole line
    # ends up inside the signalled error, and how much of it survives is
    # exactly the question ADR D19 is about.
    line = '{"jsonrpc": "2.0", "id": totally not json'
    size = params.get("size", 0)
    if size > len(line):
        line += " " + "q" * (size - len(line) - 1)
    print(line, flush=True)
    return _NO_RESPONSE


@method("hang")
def _hang(params):
    threading.Event().wait()  # blocks forever; no timeout, ever returns
    return _NO_RESPONSE  # unreachable


@method("burst")
def _burst(params):
    count = params.get("count", 8)
    text = params.get("text", "notice")
    for n in range(count):
        _write({"jsonrpc": "2.0", "method": "burst/notice",
                "params": {"n": n, "text": text}})
    return f"burst of {count} sent"


_NO_RESPONSE = object()  # sentinel: method already wrote its own output


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
            _write(resp)
            continue

        msg_id = msg.get("id")
        method_name = msg.get("method")
        params = msg.get("params") or {}

        if method_name not in METHODS:
            if msg_id is not None:
                _write({"jsonrpc": "2.0", "id": msg_id,
                        "error": {"code": -32601, "message": "Method not found"}})
            continue  # notification with unknown method: silently ignore

        try:
            result = METHODS[method_name](params)
        except SystemExit:
            raise
        except Exception as e:
            if msg_id is not None:
                _write({"jsonrpc": "2.0", "id": msg_id,
                        "error": {"code": -32602, "message": str(e)}})
            continue

        if result is _NO_RESPONSE:
            continue  # method already handled (or deliberately skipped) output

        if msg_id is not None:  # only requests get a response, not notifications
            _write({"jsonrpc": "2.0", "id": msg_id, "result": result})


if __name__ == "__main__":
    main()
