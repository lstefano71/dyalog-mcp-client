# Plan — Dyalog APL MCP Client

**Status**: All four phases (`Shell`, `JsonRpc`, `Mcp`, `Fff`) done and
verified against real `fff-mcp.exe` (including a real ~94k-file, non-git
tree — see `examples/fff-search-large-tree.apls`) — see `src/*.dyalog` and
`test/01-*.apls`..`08-*.apls`. v1 scope (ADR D8) is complete; see
`TODO.md` for what's next. A fifth piece, `JsonRpcCl`, adds a second
transport (Content-Length framing) alongside the original four phases'
newline-delimited one. A sixth, `examples/toy-jsonrpc-fixture-server.py`
plus `test/09-*.apls`, adds an on-demand mocked stdio peer for
otherwise hard-to-provoke server misbehaviors — see below. Phase 9
closed out the four previously-open `Fff` parser gaps (auto-broadened
queries, the path-only fallback, `output_mode` variants, and
pagination-scale grouping) — see below and ADR D15.

## Phase 6 — a mocked/canned-fixture stdio peer for hard-to-provoke misbehaviors

All tests up to this point run against the real `fff-mcp.exe`, which
never misbehaves — it doesn't crash mid-response, send malformed JSON,
hang, or flood unsolicited notifications. Those failure paths could
only be reasoned about, not tested on demand. `examples/toy-jsonrpc-
fixture-server.py` is a second toy NDJSON-framed server (twin in style
to `examples/toy-jsonrpc-server.py`) whose methods let a test *ask* for
a specific misbehavior by name: `crash(code)` exits uncleanly instead
of responding, `garbage()` writes deliberately invalid JSON instead of
a real response, `hang()` blocks forever and never responds, and
`burst(count, text)` emits a burst of unsolicited notifications ahead
of its real response. `test/09-fixture-server-misbehaviors.apls`
exercises all four against `Shell`/`JsonRpc` and asserts today's actual
observed behavior for each. See ADR D14.

Verified: all four modes trigger exactly the expected `Shell`/`JsonRpc`
behavior (crash and hang both signal, correctly distinguishing a
process-exit signal with the fixture's own exit code from a plain
timeout signal; malformed JSON signals `JsonRpc`'s "malformed JSON from
server"; a burst of 8 notifications all land in `h.Notifications`, in
order, without disrupting the real response that follows) — see
`TODO.md`'s Shell layer section for what running the `hang` mode
concretely confirmed about the still-open `Stop` force-kill gap. No
bugs were fixed here (out of scope for this phase, deliberately); any
found were recorded in `TODO.md` for the next phase (robustness
hardening) to actually address.

## Phase 9 — `Fff`: closing the remaining parser gaps

Ground-truthed, again, against the fff source (`D:\devel\fff`) — see
ADR D15. Closes all four "Still open" items TODO.md's Fff cover layer
section had left from Phase 4/ADR D12:

- **Auto-broadened queries**: `_ParseGrep` now recognizes `"0 matches
  for '<q>'. Auto-broadened to '<q2>':"`, strips it, and parses the
  rest of the text (which server.rs formats with the *original*
  `output_mode`) exactly as a normal response — `Shown`/`Total`/
  `Files`/`Counts` reflect the broadened result's real counts, and a
  new `Broadened` field carries `<q2>`.
- **Path-only fallback**: `"0 content matches. But there is a
  relevant file path: <p>"` now lands in a new `SuggestedPath` field
  instead of being dropped.
- **`output_mode` variants**: `'files_with_matches'` and `'count'` are
  now parsed (`_ParseFilesWithMatches`/`_ParseCountLines`), dispatched
  from `Fff.Grep`/`MultiGrep` reading `output_mode` out of `opts`.
  `Files` gains an `IsDef` field for `'files_with_matches'`; a new
  `Counts` field (vector of `(Path Count)`) is populated only for
  `'count'` mode.
- **Pagination-scale grouping**: re-verified the file-changes-when-
  path-line-seen grouping logic against real multi-file, large-
  `context` output (both this repo and, by hand, the much larger
  `D:\devel\fff` tree) — no corruption found.

Also fixed two more real, previously-latent bugs this surfaced (see
ADR D15): `_ToInt` returned a 1-element vector from `⎕VFI` rather than
a true scalar (invisible until gathered across several namespace refs
via dot notation, which is exactly what the new `Counts.Count` field
does), and `_NumberBefore` used the syntactically-invalid `¯nd↑seg`
(negating a variable with `¯`, not `-`) — never exercised until this
phase's tests were the first to genuinely trigger grep's fuzzy
"N approximate:" fallback text. See `test/10-fff-parser-extended.apls`.

## Phase 5 — `JsonRpcCl`: Content-Length framing, for non-MCP servers

A second, self-contained JSON-RPC layer (same verb shape as `JsonRpc`:
`Connect`/`Disconnect`/`Call`/`Notify`) speaking Content-Length-header
framing — the framing LSP/DAP and most other stdio JSON-RPC servers
use, as opposed to MCP's newline-delimited one. Verified against a toy
Content-Length server (`test/08-jsonrpccl-toy-server.apls`) and,
manually, against a real language server (`pyright-langserver`). See
ADR D13. No cover is built on top of it yet — see `TODO.md`.

## Phase 4 — `Fff`: a high-level cover for fff-mcp specifically

Built on top of `Mcp`, specific to the fff-mcp server (tested against
v0.10.6): `Fff.Connect`/`Disconnect` keep one instance alive against a
directory; `Fff.Find`/`Grep`/`MultiGrep` wrap `find_files`/`grep`/
`multi_grep`; a best-effort, explicitly version-specific parser turns
fff-mcp's plain-text `content` into structured fields (paths/counts for
`find_files`; per-file → per-line matches for `grep`/`multi_grep`), always
keeping the raw text alongside. See ADR D11 and TODO.md.

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
