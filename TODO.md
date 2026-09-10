# TODO — deferred past v1

Things deliberately left out of v1, with the reasoning for *why* they're
deferred (not forgotten) and what would trigger picking them up. See
`docs/adr/0001-architecture-decisions.md` for the decisions these follow
from.

## Transport

- ~~A Content-Length-framed transport~~ — done: `JsonRpcCl` (ADR D13).
  Still open on top of it:
  - ~~No cover built on it yet~~ — done: `Lsp` (ADR D16), a minimal
    LSP cover (`initialize`/`initialized`/`shutdown`/`exit`/
    `textDocument/didOpen`/`textDocument/hover`), verified against
    real `pyright-langserver` — see `src/Lsp.dyalog`,
    `test/11-lsp-cover.apls`. Still open on top of *that*:
    - **Everything else LSP defines** — `textDocument/didChange`/
      `didClose` (so a session can edit past the initial `didOpen`),
      `textDocument/completion`, `textDocument/definition`,
      `textDocument/references`, published diagnostics
      (`textDocument/publishDiagnostics`, a server-initiated
      notification — would need the notification-dispatch item below
      to actually react to one rather than just queue it), workspace
      folders (`workspaceFolders` instead of always sending `rootUri`
      as `null`). None of these were needed to prove the cover works;
      add whichever one an actual use case needs.
    - **`capabilities:()` (empty) may not be enough for every
      server** — it was enough for `pyright-langserver` to answer
      `initialize`/`hover` usefully, but a server that gates specific
      features behind an advertised client capability (e.g.
      `textDocument.hover.contentFormat` for markdown vs. plaintext
      hover content) hasn't been tested; expand `Lsp.Connect`'s
      `capabilities` object if a target server needs it.
  - ~~Same gaps `JsonRpc` has~~ — done: `JsonRpcCl` now has the same
    `Send`/`AwaitResponse`/`CallBatch`/`OnNotification` generalization
    as `JsonRpc` (Phase 8, ADR D17), landed symmetrically in both.
    Still open: no `Stop`/`Disconnect` force-kill fallback (same as
    the `Shell.Stop` TODO below).
  - **The real-LSP verification is now a committed test**
    (`test/11-lsp-cover.apls`), unlike the note below might suggest at
    a glance — but it's the one test in the suite that needs network
    access and an npm install (`npx -y -p pyright pyright-langserver
    --stdio`) on first run, unlike everything else in this repo.
    Worth reconsidering if this project ever gets CI without network
    access.

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

- ~~Concurrent outstanding requests~~ — done (Phase 8, ADR D17):
  `Send`/`AwaitResponse` let a handle pipeline several requests before
  collecting any of their responses, with a `PendingIds`/`PendingMsgs`
  table (array-oriented lookup, not a loop) holding whichever
  responses arrive before they're asked for — including genuinely out
  of send-order. `Call` is now just `AwaitResponse(Send args)`; every
  pre-existing test kept passing unchanged. Landed identically in both
  `JsonRpc` and `JsonRpcCl`. See `test/12-jsonrpc-pipelining.apls`/
  `test/13-jsonrpccl-pipelining.apls`.
- ~~Notification dispatch~~ — done (Phase 8, ADR D17): `OnNotification
  (method handlerName)` registers a handler-name string (looked up by
  method into a trusted table the caller itself populated — never
  `⍎`'d on server-supplied text) invoked as `h HandlerName parsed`
  whenever that method's notification arrives. Backward compatible:
  every notification is still appended to `h.Notifications` regardless
  of whether a handler fired ("as well as", not "instead of" — see ADR
  D17 for why). Still open: no way to *unregister* a handler (only
  replace one by re-registering the same method) — add if a real use
  case needs it.
- ~~Batch requests~~ — done (Phase 8, ADR D17): `CallBatch argsVec`
  sends one JSON-RPC 2.0 batch (one JSON array of request objects,
  fresh id each) and returns the responses in `argsVec`'s own order
  regardless of what order the server replied in, reusing the pending
  mechanism above. `Notify`/`Call` are unaffected — batching only ever
  applies to `CallBatch` itself, there's no batched-notification verb
  (JSON-RPC allows mixing notifications into a batch; not exposed here
  since nothing in this codebase currently needs it — add if it does).

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
- ~~`notifications/tools/list_changed`~~ — done (Phase 8, ADR D17):
  `Mcp.Connect` registers a handler that marks
  `h.JsonRpc.ToolsStale←1`; `Mcp.ListTools` clears it back to `0` after
  the next fetch. Deliberately informational only, not a cache
  invalidation — `Mcp` doesn't cache tool lists at all (`ListTools`
  always calls `tools/list`), so there's no cache to invalidate; adding
  one just for this flag was judged overkill until a real caller
  actually wants cached tool lists. See `test/12-jsonrpc-pipelining.apls`.
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
- ~~A peer that can answer out of order / take batch requests~~ — done
  (Phase 8, ADR D17): `examples/toy-jsonrpc-pipeline-server.py` (NDJSON)
  and `examples/toy-jsonrpc-cl-pipeline-server.py` (Content-Length) —
  dedicated servers whose request loop hands each request to its own
  thread (so a fast request fired after a slow one can genuinely answer
  first) and whose batch replies are deliberately reversed from request
  order. See `test/12-jsonrpc-pipelining.apls`/
  `test/13-jsonrpccl-pipelining.apls`.
- **Test scripts hardcode an absolute `⎕FIX`/working-directory path**
  (`D:/devel/mcp-client/...`, or — for `test/10`, a prior phase's own
  worktree — a now-stale worktree path under `.claude/worktrees/`):
  every test in this suite assumes it's run from (or against) that
  exact location, not wherever the repo/worktree actually is. Harmless
  for a single-machine, single-worktree-at-a-time workflow, but worth
  making path-relative (e.g. deriving the repo root from the script's
  own location) if this project ever runs its tests from more than one
  checkout, or in CI on a different machine.
