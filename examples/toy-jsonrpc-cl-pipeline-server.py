#!/usr/bin/env python3
"""
Content-Length-framed twin of examples/toy-jsonrpc-pipeline-server.py
— see that file's docstring for the full rationale (Phase 8, ADR D17):
a dedicated server whose request loop hands each request to its own
thread, so pipelined requests can genuinely resolve out of order, and
whose batch handling replies with responses deliberately reversed from
request order (to prove a client reorders by id, not arrival order).

Framing/read/write mechanics lifted from examples/toy-jsonrpc-cl-
server.py (Content-Length header, \\r\\n\\r\\n separator, byte-counted
body) — same tolerance for a stray leading blank line before headers.

Methods: same three as the NDJSON pipeline server (echo/delay/notify)
— see that file's docstring for what each does.

Run directly: python examples/toy-jsonrpc-cl-pipeline-server.py
"""
import json
import sys
import threading
import time

_write_lock = threading.Lock()


def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if line == b"":
            return None  # EOF
        line = line.rstrip(b"\r\n")
        if line == b"":
            if headers:
                break
            continue
        name, _, value = line.partition(b":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers[b"content-length"])
    body = stream.read(length)
    return json.loads(body.decode("utf-8"))


def write_message(stream, obj):
    with _write_lock:
        body = json.dumps(obj).encode("utf-8")
        stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
        stream.write(body)
        stream.flush()


def _handle_one(stdout, req):
    msg_id = req.get("id")
    method = req.get("method")
    params = req.get("params") or {}

    if method == "echo":
        result = params["text"]
    elif method == "delay":
        time.sleep(params.get("seconds", 0))
        result = params.get("text", "")
    elif method == "initialize":
        result = {"serverInfo": {"name": "pipeline-toy", "version": "0.1.0"},
                   "capabilities": {}}
    elif method == "tools/list":
        result = {"tools": []}
    elif method == "notify":
        write_message(stdout, {"jsonrpc": "2.0", "method": params.get("method", "unsolicited"),
                                "params": params.get("notifyParams", {})})
        result = "sent"
    else:
        if msg_id is not None:
            return {"jsonrpc": "2.0", "id": msg_id,
                    "error": {"code": -32601, "message": "Method not found"}}
        return None

    if msg_id is not None:
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}
    return None


def _handle_request(stdout, req):
    resp = _handle_one(stdout, req)
    if resp is not None:
        write_message(stdout, resp)


def _handle_batch(stdout, batch):
    responses = [None] * len(batch)

    def worker(i, req):
        responses[i] = _handle_one(stdout, req)

    threads = [threading.Thread(target=worker, args=(i, req)) for i, req in enumerate(batch)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    ordered = [r for r in responses if r is not None]
    write_message(stdout, list(reversed(ordered)))


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        msg = read_message(stdin)
        if msg is None:
            return
        if isinstance(msg, list):
            threading.Thread(target=_handle_batch, args=(stdout, msg)).start()
        else:
            threading.Thread(target=_handle_request, args=(stdout, msg)).start()


if __name__ == "__main__":
    main()
