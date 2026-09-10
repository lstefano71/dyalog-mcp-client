# Plan — Dyalog APL MCP Client

**Status**: All three phases (`Shell`, `JsonRpc`, `Mcp`) done and verified
against real `fff-mcp.exe` — see `src/*.dyalog` and `test/01-*.apls`..
`05-*.apls`. v1 scope (ADR D8) is complete; see `TODO.md` for what's next.

Goal: an MCP client, written in and for Dyalog APL, that talks to stdio-based
MCP servers via `⎕SHELL`. Built bottom-up in three phases, each independently
usable and tested against the real `fff-mcp.exe` server before moving on.

## Phase 1 — `Shell`: bidirectional stdio wrapper around `⎕SHELL`

A library namespace `Shell` wrapping a single long-running child process,
exposing synchronous line-in/line-out primitives. No knowledge of JSON-RPC
or MCP at this layer — just "start a process, send it a line, get a line
back, stop it."

- `h ← Shell.Start cmd` (`cmd`: char vector or vector of char vectors, same
  shape `⎕SHELL` accepts for direct execution) — spawns the child process on
  a forked thread, returns a handle namespace.
- `h Shell.Send text` — pushes one line of text to the child's stdin.
- `text ← timeout Shell.Receive h` — blocks (up to `timeout` seconds; `0` =
  forever) for the next line of output, or signals on timeout/process death.
- `Shell.Stop h` — closes stdin, waits for exit, releases resources.

Mechanics: forked `⎕SHELL` thread, `Input ('Token' …)` for stdin,
`Output ('Callback' …)` for stdout, synchronized via a private `⎕TALLOC`
token range and `⎕TPUT`/`⎕TGET`. See ADR 0001.

Smoke test: start `fff-mcp.exe` in this repo, hand-write one raw
`initialize` JSON-RPC line, confirm a line comes back.

## Phase 2 — `JsonRpc`: minimal JSON-RPC 2.0 layer over `Shell`

- Build/parse messages as array-notation namespace literals via `⎕JSON`.
- `h ← JsonRpc.Connect cmd` — wraps `Shell.Start`, adds request-id bookkeeping.
- `resp ← h JsonRpc.Call (method params)` — sends a request, blocks for the
  matching response. v1: exactly one in-flight call at a time (see ADR 0001
  and TODO.md).
- `h JsonRpc.Notify (method params)` — sends a notification (no id, no
  response expected).
- Any received message that isn't the awaited response (no id, or an id
  that doesn't match) is appended to `h.Notifications`, a plain queue the
  caller can drain — never dispatched via callback in v1.
- A JSON-RPC `error` response is returned to the caller as ordinary data;
  only transport/process/protocol-shape faults (dead process, timeout,
  malformed JSON) are raised via `⎕SIGNAL`.

## Phase 3 — `Mcp`: MCP semantics over `JsonRpc`

- `h ← Mcp.Connect cmd` — `JsonRpc.Connect`, then performs the
  `initialize` / `notifications/initialized` handshake with a fixed
  `clientInfo` (`name:'dyalog-mcp-client' version:'0.1.0'`) and empty
  `capabilities`.
- `tools ← Mcp.ListTools h`
- `result ← h Mcp.CallTool (name arguments)`
- Scope for v1 is deliberately narrow: handshake + `tools/list` +
  `tools/call` only. Everything else is TODO.md.

Integration test: full round trip against `fff-mcp.exe` — connect, list
tools, call `fffind`/`ffgrep` against this repo, check shapes.

## Working conventions

- Plain Dyalog source files (`.dyalog`/`.apln`/`.aplf`) loaded by a
  `.dyapp`; no Tatin packaging yet (may be introduced once the API
  stabilizes).
- Tests are `dyalogscript`-driven `.apls` files run against the real
  `fff-mcp.exe` binary, using this repo as the working directory (it's
  already git-indexed, which fff-mcp requires).
- See `docs/adr/0001-architecture-decisions.md` for the reasoning behind
  the above, and `TODO.md` for what's explicitly deferred past v1.
