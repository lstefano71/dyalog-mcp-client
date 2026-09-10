# ADR 0001: Architecture decisions for the Dyalog APL MCP client

Status: Accepted (v1)

## Context

We're building an MCP client in Dyalog APL (v20.0), for use from Dyalog APL,
targeting stdio-based MCP servers. It's built in three layers: a `⎕SHELL`
process wrapper, a JSON-RPC 2.0 layer, and MCP semantics on top. This ADR
records the decisions made while designing that stack, and why, so later
changes can be evaluated against the original reasoning rather than
rediscovered from scratch.

Test target: `fff-mcp.exe` (the MCP server for the
[`fff`](https://github.com/dmtrKovalenko/fff) file-search engine) — a
plain, spec-compliant, tools-only MCP server with no quirks to design
around.

Reference: MCP spec version `2025-06-18`
(modelcontextprotocol.io/specification/2025-06-18).

## Decisions

### D1. Concurrency model: forked `⎕SHELL` thread + `⎕TALLOC`/`⎕TPUT`/`⎕TGET`

`⎕SHELL` blocks its calling thread until the child process exits, so a
persistent stdio session requires running it on its own forked thread, with:

- `Input ('Token' n)` on stream 0, so stdin can be fed dynamically via
  `⎕TPUT`, after the process has already started.
- `Output ('Callback' fn)` on stream 1, so stdout lines are delivered to a
  callback as they arrive, without waiting for the process to exit.

The caller-facing API (`Shell.Send`/`Shell.Receive`) is **synchronous
blocking with a timeout**, because JSON-RPC request/response is inherently
call-and-wait, and that's the natural shape for the scripting use this
client targets. This requires a way for the caller's thread to block until
the callback (running on the `⎕SHELL` thread) has something for it.
`⎕TGET` provides exactly that — it blocks (with an optional timeout) until
a matching token appears in the pool. So:

- Each handle allocates a **private token range** via
  `⎕TALLOC 1 'mcp-client:<cmd>'` on `Start`, to avoid collisions between
  concurrent client instances in the same interpreter.
- The `Output ('Callback' …)` function appends each received line to a
  queue on the handle, then does `⎕TPUT` on the handle's "data available"
  token to unblock any waiting `Receive`.
- `Receive` does a timed `⎕TGET` on that token, then drains the queue.
- `Stop` closes stdin with a monadic (no-data) `⎕TPUT` on the input token
  — the documented way to close a token-fed stream — then waits for exit
  and releases the range with `⎕TALLOC ¯1`.

Alternative considered: polling with `⎕DL` instead of `⎕TGET`. Rejected —
`⎕TGET`'s built-in timeout/blocking is a closer match to what's needed and
avoids a busy-wait.

### D2. Handle shape: plain data namespace, not a class

State lives in a namespace created by `Start` (e.g. via array-notation
`⎕NS`), holding only data fields (queues, token range, thread id, status)
— **never function references**. All behavior lives in library namespaces
(`Shell`, `JsonRpc`, `Mcp`) as ordinary functions that take the handle as
an argument.

This was a deliberate choice against Dyalog's `:Class`/`⎕NEW` syntax:
classes are the more "instinctive" OO fit, but this client is meant to be
usable comfortably by people who'd rather not opt into class syntax, and
plain namespaces-as-records are an established idiom in the Dyalog
ecosystem (e.g. Conga) for exactly this "opaque handle + free functions"
shape.

### D3. Argument order: handle is the left argument

`h Shell.Send text`, `h JsonRpc.Call (method params)`, etc. — the handle is
always the **left** argument. Chosen over the alternative (handle on the
right) because it reads left-to-right as "handle, verb, payload," and
keeps the handle visually anchored at the start of every call site, which
matters more here than matching any single existing library's convention
(Dyalog's own libraries are inconsistent on this point).

### D4. Message construction: array notation + `⎕JSON`

Dyalog 20's array notation lets a namespace be written as a parenthesised
list of name-value pairs, e.g. `(jsonrpc:'2.0' ⋄ id:n ⋄ method:'tools/call'
⋄ params:(name:'ffgrep' ⋄ arguments:(path:'.')))`. This maps directly onto
`⎕JSON`'s namespace-to-JSON-object conversion, so JSON-RPC/MCP messages are
built and read as ordinary APL namespace literals rather than through any
hand-rolled JSON construction. Parsed responses are namespaces, dotted
into directly (`resp.result.tools`).

### D5. Wire framing: newline-delimited JSON, no envelope

Confirmed against the MCP spec: stdio messages are one JSON value per line,
newline-delimited, **must not** contain embedded newlines; no
Content-Length header framing (unlike LSP). stdout carries only JSON-RPC
messages; a server may log freely to stderr, which we don't need to
capture. This maps directly onto `⎕SHELL`'s line-oriented `Output 'Array'`
behavior — no custom framing/decoding needed at the `Shell` layer.

### D6. Error handling split: signal vs. return value

- **Faults** — dead/crashed process, `Receive` timeout, malformed JSON,
  anything that means the transport or protocol contract was broken — are
  raised via `⎕SIGNAL`, catchable with `:Trap`. These are programmer/
  environment errors, not data the caller should have to check for on
  every call.
- **JSON-RPC error responses** (`{jsonrpc, id, error:{code,message,data}}`)
  are valid protocol data, not faults, and are returned to the caller as
  an ordinary successful result — mirroring how `⎕SHELL` itself separates
  `ExitReason`/`ExitCode` (inspectable data) from the `ExitCheck` variant
  (opt-in trappable error).

This was the one place the two design instincts in play (idiomatic APL
signaling vs. a "no hidden control flow, check the result" functional
style) genuinely disagreed; the split above was chosen as the one that
keeps genuine faults loud while treating protocol-legal error responses as
just another shape of successful data.

### D7. JSON-RPC id correlation: single in-flight request (v1)

`JsonRpc.Call` allows exactly **one outstanding request at a time** per
handle. `fff-mcp` never sends out-of-band (unsolicited/notification)
messages in practice, and MCP clients in general only need pipelined
concurrent requests for advanced use cases this client doesn't target yet.
This keeps response correlation trivial (the next id-bearing line in is
*the* response) at the cost of not supporting concurrent outstanding
calls. See TODO.md for the evolution path.

### D8. MCP scope: handshake + tools only (v1)

Phase 3 implements exactly: `initialize` request/response,
`notifications/initialized`, `tools/list`, `tools/call`. Resources,
prompts, sampling, roots, pagination (`cursor`/`nextCursor`), and
`notifications/tools/list_changed` are explicitly out of scope for v1 —
`fff-mcp` only implements tools, and there's no value in building against
untested surface. See TODO.md.

### D9. Repo/tooling conventions

- Plain `.dyalog`/`.apln`/`.aplf` source files loaded by a `.dyapp`; no
  Tatin package structure yet — deferred until the API stabilizes.
- Tests are `dyalogscript`-driven `.apls` files that exercise the real
  `fff-mcp.exe` binary (this repo as working directory, since it's already
  git-indexed, which `fff-mcp` requires) rather than a mocked stdio peer.
  A canned-fixture mock may be added later if the real binary proves too
  slow/flaky for routine test runs.

## Implementation notes (discovered while building, not in the docs)

- **`Input ('Token' n)` data shape**: the value passed to `⎕TPUT` is not
  raw data — it must itself be shaped like one of the `('Array' ...)`
  input sources, e.g. `('Array' text 'UTF-8')`. That form also handles
  newline-termination for free, matching the NDJSON framing requirement
  (D5) without `Shell.Send` having to append `\n` itself.
- **`Output ('Callback' fn)` return value**: the callback function must
  return a Boolean scalar (continue/stop), or `⎕SHELL` raises a
  `RANK ERROR`. Not called out in the variant's documented callback
  contract.
- **Namespace-script cross-references need `#.` qualification**: a
  `:Namespace ... :EndNamespace` script fixed at the root gets lexical
  scoping from `⎕FIX`, so a sibling top-level namespace (e.g. `JsonRpc`
  calling into `Shell`) is *not* visible under its bare name the way it
  would be from an unscripted/dynamically-scoped namespace — it must be
  written `#.Shell.Start`, not `Shell.Start`.
