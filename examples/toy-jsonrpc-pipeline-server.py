#!/usr/bin/env python3
"""
NDJSON-framed JSON-RPC 2.0 server built to exercise Phase 8's
pipelining/batch/notification-dispatch generalization of JsonRpc (see
docs/adr/0001-architecture-decisions.md, ADR D17): fire off several
requests without waiting for each one's response, and see genuinely
out-of-order arrival and JSON-RPC batch requests on demand, repeatably.

Neither existing toy server can be made to do this on demand: fff-mcp
never overlaps in-flight requests at all, and examples/toy-jsonrpc-
server.py's stdin loop processes one line fully (including any sleep)
before it even reads the next — so a slow request already blocks the
next line from being read, let alone answered out of order. Getting
genuine out-of-order responses needs the request LOOP itself to hand
each request to its own thread — a structural change, not just an
additional method — which is why this is a new, dedicated server
rather than another method bolted onto the plain toy server (ADR D17).

Methods:
  echo(text)                 -> text, answered immediately.
  delay(seconds, text)       -> answered, from its own thread, after
                                 actually sleeping `seconds` — lets a
                                 short delay fired SECOND resolve
                                 BEFORE a longer delay fired FIRST.
  initialize()                -> a minimal MCP-shaped {serverInfo,
                                 capabilities} result, and tools/list()
                                 -> {"tools": []} — just enough for a
                                 full Mcp.Connect/ListTools round trip,
                                 so test/12 can also drive Mcp's
                                 'notifications/tools/list_changed'
                                 reaction (via notify below) without
                                 needing a real MCP server for it.
  notify(method, notifyParams) -> writes one unsolicited notification
                                 ({"method": method, "params":
                                 notifyParams}, no "id") immediately,
                                 then answers "sent" — lets a test
                                 provoke an arbitrary notification
                                 method name on demand (e.g. to drive
                                 Mcp's 'notifications/tools/list_changed'
                                 reaction, or exercise OnNotification
                                 dispatch for a method it did NOT
                                 register a handler for).

Batch requests: a line that parses to a JSON array is treated as one
JSON-RPC 2.0 batch — every request in it is answered together, in ONE
output line containing a JSON array of the responses, deliberately in
REVERSE of the batch's own request order. This is what actually proves
a client reorders responses by id rather than just trusting arrival
(or send) order.

Run directly: python examples/toy-jsonrpc-pipeline-server.py
"""
import json
import sys
import threading
import time

_write_lock = threading.Lock()


def _write(obj):
    with _write_lock:
        print(json.dumps(obj), flush=True)


def _handle_one(req):
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
        _write({"jsonrpc": "2.0", "method": params.get("method", "unsolicited"),
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


def _handle_request_line(req):
    resp = _handle_one(req)
    if resp is not None:
        _write(resp)


def _handle_batch_line(batch):
    responses = [None] * len(batch)

    def worker(i, req):
        responses[i] = _handle_one(req)

    threads = [threading.Thread(target=worker, args=(i, req)) for i, req in enumerate(batch)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    ordered = [r for r in responses if r is not None]
    with _write_lock:
        print(json.dumps(list(reversed(ordered))), flush=True)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        if isinstance(msg, list):
            threading.Thread(target=_handle_batch_line, args=(msg,)).start()
        else:
            threading.Thread(target=_handle_request_line, args=(msg,)).start()


if __name__ == "__main__":
    main()
