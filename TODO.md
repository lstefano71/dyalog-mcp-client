# TODO — deferred past v1

Things deliberately left out of v1, with the reasoning for *why* they're
deferred (not forgotten) and what would trigger picking them up. See
`docs/adr/0001-architecture-decisions.md` for the decisions these follow
from.

## Shell layer

- **Stderr handling**: v1 relies on `⎕SHELL`'s default of merging stream 2
  into stream 1. MCP servers may log to stderr; if a server's stderr
  chatter ever needs to be inspected (debugging a misbehaving server), add
  a separate `Output` redirection + callback for stream 2, kept apart from
  the stdout line queue.
- **Multiple concurrent child processes per interpreter**: works today
  (each `Start` gets its own `⎕TALLOC` range), but untested beyond one at
  a time — verify once there's an actual multi-server use case.
- **Process crash mid-`Receive`**: needs a defined behavior (currently:
  should signal, but the exact signal/message shape hasn't been nailed
  down against a real crash yet).
- **`Stop` force-kill**: currently waits up to ~10s for the child to exit
  after closing stdin, then gives up (still releases the token range
  regardless). Should force-kill via `8373⌶` (see `⎕SHELL`'s docs on
  abandoned child processes) if the deadline passes without a clean exit.

## JSON-RPC layer

- **Concurrent outstanding requests**: v1 allows exactly one in-flight
  `Call` per handle (ADR D7). Generalizing to a request-id → response
  table (so multiple calls can be pipelined) is the natural next step if a
  server ever needs it — `fff-mcp` doesn't. Would need: a dictionary
  keyed by id on the handle, and `Receive`'s dispatch loop routing by id
  instead of assuming "next line = the answer."
- **Notification dispatch**: v1 only queues unmatched/no-id messages
  (`h.Notifications`) for the caller to poll. A callback-based dispatch
  (matching MCP notification methods, e.g. `notifications/tools/list_changed`)
  is only worth building once phase 3 actually needs to react to one.
- **Batch requests**: JSON-RPC 2.0 batching is not implemented; MCP
  2025-06-18 doesn't require it either.

## MCP layer

- **`resources/*`** — not implemented; add when a target server exposes
  resources.
- **`prompts/*`** — not implemented; same trigger as resources.
- **`sampling/*`, `elicitation/*`, `roots/*`** — client-side capabilities
  we don't declare or implement; only relevant once a server actually
  requests them.
- **Pagination** (`cursor`/`nextCursor` on `tools/list`): `fff-mcp` returns
  its whole tool list in one page. Implement once a target server actually
  paginates.
- **`notifications/tools/list_changed`**: no dispatch/re-fetch logic yet;
  depends on the notification-dispatch item above.
- **Protocol version negotiation edge cases**: v1 sends one fixed
  `protocolVersion` and doesn't handle the server proposing a different,
  unsupported one (spec says the client SHOULD disconnect) — add explicit
  handling once tested against a server that actually negotiates down.

- **Preserve JSON-RPC error detail on Mcp-layer signals**: `Mcp.ListTools`/
  `Mcp.CallTool` currently signal with only `resp.error.message` when the
  server returns a protocol-level JSON-RPC error (e.g. invalid params,
  unknown tool). The error's `code` and `data` are discarded. Worth
  carrying them through (e.g. via `⎕SIGNAL`'s name/value form) once
  something downstream needs to branch on the error code rather than just
  report it.

## Packaging / distribution

- **Tatin package**: repo is plain source + `.dyapp` for now (ADR D9).
  Package it once the API is stable enough to version.

## Testing

- **Mocked stdio peer**: all tests currently run against the real
  `fff-mcp.exe`. Add a canned-fixture/mock MCP server if the real binary
  turns out too slow or flaky for routine runs, or to test error paths
  `fff-mcp` won't naturally trigger (malformed responses, slow/hanging
  server, mid-stream crash).
