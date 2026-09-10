# TODO — deferred past v1

Things deliberately left out of v1, with the reasoning for *why* they're
deferred (not forgotten) and what would trigger picking them up. See
`docs/adr/0001-architecture-decisions.md` for the decisions these follow
from.

## Transport

- **A Content-Length-framed transport, alongside `Shell`'s newline-
  delimited one**: `Shell`/`JsonRpc` currently assume NDJSON framing
  (ADR D5) — correct for MCP, but that's actually the *unusual* choice
  in the wider stdio-JSON-RPC world; Content-Length-header framing
  (LSP, DAP, and most other stdio JSON-RPC servers) is far more common.
  A sibling transport layer (e.g. `ShellLsp`, or a framing option on
  `Shell` itself) would open this client up to language servers and
  similar tools, not just MCP-family servers. Not needed for anything
  in scope today — recorded here because the idea came up while
  researching what else `JsonRpc` could plausibly talk to (see the
  Manual's Tutorial, which uses a purpose-built NDJSON toy server
  instead, precisely because no well-known *non*-MCP stdio server
  actually uses this client's framing).

## Shell layer

- **Inspecting stderr**: stream 2 is discarded (`Shell._OnStderr`, ADR
  D11) rather than merged into stream 1 or captured — correct for
  keeping the protocol stream clean, but there's currently no way to
  see what a server logged there if you need to debug it. Add an
  optional second queue (`h.StderrLines`, say) if that's ever needed.
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

## Fff cover layer

Ground-truthed against the fff source itself (`D:\devel\fff`,
`crates/fff-mcp/src/{server,output,cursor}.rs`, `crates/fff-core`) as
of the commit checked out there — not just observed empirically. Fixed
two real bugs this surfaced: `find_files`' own `"0 results (N indexed)"`
empty-result phrasing wasn't recognized (a different phrase from
grep's `"0 matches."`, and used to be misread as one bogus path); and
a definition-context match line (`"  N| text"`, two spaces + pipe —
extremely common, since it's rendered whenever a matched line happens
to be a definition, with no `context` param needed) was misparsed as a
spurious new file boundary, corrupting file/match grouping from that
point on. `Matches` entries now carry a `Kind` (`'Match'`|`'Context'`|
`'DefContext'`) rather than being assumed all real matches — see
`docs/manual/reference.md`.

Still open:
- **`"0 matches for '<q>'. Auto-broadened to '<q2>':"`** (grep retries
  a multi-word query with the first word dropped when the exact query
  gets 0 hits) — the broadened results that follow parse fine as
  `Files`, but `Shown`/`Total` stay `0` (read off the leading, always-0
  count in that header) rather than reflecting the broadened count.
- **`"0 content matches. But there is a relevant file path: <p>"`**
  (grep's path-only fallback) — parses to an empty result; the
  suggested path itself isn't extracted into a structured field.
- **`output_mode` values other than the default (`'content'`, which
  the source shows is actually identical to `'usage'`)** —
  `'files_with_matches'` and `'count'` produce structurally different
  text (confirmed in `output.rs`: e.g. `'files_with_matches'` is the
  *only* mode with a genuine per-file `[def]` tag) that `_ParseGrep`
  doesn't attempt to read at all.
- **Multi-file blocks under real pagination load** (many files, a
  `context` far larger than tested) — the file-changes-when-path-line-
  seen grouping logic is confirmed correct in principle from the
  source, but only exercised here against small, few-file results.

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

## Documentation

- **An Internals Guide**, as a third Manual document alongside
  Reference and Tutorial: covers the underscore-prefixed helpers each
  layer keeps private (`_ParseGrep`, `_Envelope`, `_AwaitId`, `_Run`,
  `_OnOutput`, ...) — for a reader extending a layer or writing a new
  cover, not for a reader who just wants to use one. Reference
  deliberately stays scoped to public verbs only (see
  `docs/manual/reference.md`); this would be where the rest goes.

## Packaging / distribution

- **Tatin package**: repo is plain source + `.dyapp` for now (ADR D9).
  Package it once the API is stable enough to version.

## Testing

- **Mocked stdio peer**: all tests currently run against the real
  `fff-mcp.exe`. Add a canned-fixture/mock MCP server if the real binary
  turns out too slow or flaky for routine runs, or to test error paths
  `fff-mcp` won't naturally trigger (malformed responses, slow/hanging
  server, mid-stream crash).
