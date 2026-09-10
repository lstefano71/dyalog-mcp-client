# TODO — deferred past v1

Things deliberately left out of v1, with the reasoning for *why* they're
deferred (not forgotten) and what would trigger picking them up. See
`docs/adr/0001-architecture-decisions.md` for the decisions these follow
from.

## Transport

- ~~A Content-Length-framed transport~~ — done: `JsonRpcCl` (ADR D13).
  Still open on top of it:
  - **No cover built on it yet** — `JsonRpcCl` was verified directly
    (a toy server, and manually against real `pyright-langserver`),
    but nothing like `Mcp`/`Fff` exists on top of it. A minimal LSP
    cover (`initialize`/`textDocument/didOpen`/`textDocument/hover`,
    say) would be the natural next step if there's ever a reason to
    actually use a language server from this client, not just prove
    the transport talks to one.
  - **Same gaps `JsonRpc` has, largely un-re-litigated**: single
    in-flight `Call` only (ADR D7's reasoning applies equally here),
    no `Stop`/`Disconnect` force-kill fallback (same as the `Shell.Stop`
    TODO below), batch requests not implemented.
  - **The real-LSP verification isn't a committed automated test** —
    it needs network access and an npm install (`npx -y -p pyright
    pyright-langserver --stdio`) on first run, unlike everything else
    in this repo. Worth reconsidering if this project ever gets CI.

## Shell layer

- **Inspecting stderr**: stream 2 is discarded (`Shell._OnStderr`, ADR
  D11) rather than merged into stream 1 or captured — correct for
  keeping the protocol stream clean, but there's currently no way to
  see what a server logged there if you need to debug it. Add an
  optional second queue (`h.StderrLines`, say) if that's ever needed.
- **Multiple concurrent child processes per interpreter**: works today
  (each `Start` gets its own `⎕TALLOC` range), but untested beyond one at
  a time — verify once there's an actual multi-server use case.
- ~~Process crash mid-`Receive`~~ — confirmed via
  `test/09-fixture-server-misbehaviors.apls`'s `crash` mode (ADR D14):
  `Shell.Receive`/`JsonRpc.Call` signal with `'Shell.Receive: process
  exited (reason <r>, code <c>)'`, `<c>` matching the exit code the
  fixture server was told to exit with. No fix needed — this was
  already the intended behavior, just previously unverified against an
  actual mid-`Receive` crash.
- **`Stop` force-kill**: currently waits up to ~10s for the child to exit
  after closing stdin, then gives up (still releases the token range
  regardless). Should force-kill via `8373⌶` (see `⎕SHELL`'s docs on
  abandoned child processes) if the deadline passes without a clean exit.
  Concretely demonstrated (not just reasoned about) by `test/09`'s
  `hang` mode: `Shell.Stop` waits the full ~10s and returns, but the
  child process itself is left running forever afterward (confirmed via
  `Get-Process python` still showing it) — closing stdin does nothing
  for a server blocked in a wait with no timeout, and there's currently
  no way to reap it short of an external kill.

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

All four previously-open items below are now done (Phase 9, ADR D15):
- ~~`"0 matches for '<q>'. Auto-broadened to '<q2>':"`~~ — done.
  `Shown`/`Total`/`Files`/`Counts` now reflect the broadened result's
  real counts (server.rs re-invokes `GrepFormatter` with the
  *original* `output_mode` for the retry, so the embedded text is
  parsed exactly as if it were the whole response), and a new
  `Broadened` field carries the query it broadened to (empty when no
  broadening happened).
- ~~`"0 content matches. But there is a relevant file path: <p>"`~~ —
  done. `<p>` is extracted into a new `SuggestedPath` field.
- ~~`output_mode` values other than the default~~ — done.
  `'files_with_matches'` and `'count'` are now parsed
  (`_ParseFilesWithMatches`/`_ParseCountLines`); `Fff.Grep`/
  `MultiGrep` read `output_mode` from `opts` and dispatch accordingly.
  `Files` gains an `IsDef` field for `'files_with_matches'` (the only
  mode with a genuine per-file `[def]` tag); a new `Counts` field
  (vector of `(Path Count)`) is populated only for `'count'` mode. A
  handful of fallback text shapes (`"0 matches."`, the fuzzy
  `"N approximate:"` text, and the auto-broadened header above) are
  mode-independent in the source itself and are recognized before any
  mode-specific dispatch, regardless of the requested `output_mode`.
- ~~Multi-file blocks under real pagination load~~ — done. Re-verified
  against a `context:4`/`context:5` grep with many hits across
  multiple files, both in this repo and by hand against the much
  larger `D:\devel\fff` source tree (11+ files, 60+ matches in one
  page) — no grouping corruption found. See `test/10-fff-parser-
  extended.apls`.

Also surfaced and fixed while doing this pass (see ADR D15):
- `_ToInt` returned a 1-element *vector* from `⎕VFI`, not a true
  scalar — invisible until `Counts.Count`, gathered via dot notation
  across several namespace refs, became the first field to expose it:
  the nested result made a later `:If` DOMAIN ERROR ("Boolean
  singleton value required"). Fixed by disclosing (`⊃`) the `⎕VFI`
  result.
- `_NumberBefore` used `¯nd↑seg` — `¯` is only valid as part of a
  numeric literal, not as negation of a variable; this is a
  `SYNTAX ERROR`, and it had never actually been exercised until this
  pass's tests genuinely triggered grep's "0 exact matches. N
  approximate:" fuzzy-fallback text for the first time. Fixed to
  `(-nd)↑seg`.

Still open:
- **`Broadened`/`SuggestedPath`/`output_mode`'s size-tag stripping are
  best-effort text matching**, same spirit as the rest of this parser
  (D11/D12) — e.g. `_StripDefTag`'s large-file size-tag stripping
  assumes the exact `output.rs` wording (`"NNKB - use offset to read
  relevant section)"`) and would silently leave it in `Path` if that
  wording ever changes upstream. Not a known bug, just the same
  version-specific fragility every other shape here already has.

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

- ~~Mocked stdio peer~~ — done: `examples/toy-jsonrpc-fixture-server.py`
  (NDJSON-framed, `crash`/`garbage`/`hang`/`burst` methods) plus
  `test/09-fixture-server-misbehaviors.apls` (ADR D14). Covers the four
  misbehavior modes the real `fff-mcp.exe` never naturally triggers —
  see the Shell layer/JSON-RPC layer sections below for what running it
  surfaced.
