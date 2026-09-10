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

### D10. Handle construction: array-notation literals + `⎕NS`/`⎕VGET` for defaults

Handles are built as a single array-notation namespace literal wherever
possible, rather than `h←⎕NS'' ⋄ h.Field←value ⋄ h.Field2←value2 ⋄ ...`
chains — the incremental-assignment style was the original v1 code but is
harder to see the whole shape of at a glance. Two Dyalog 20 features make
this practical for the "optional overrides on top of defaults" cases that
motivated the old chains:

- `⎕NS defaults opts` merges a vector of namespaces left-to-right, later
  namespaces winning on conflicting names — so `defaults` merged with a
  caller-supplied `opts` is a one-liner instead of a field-by-field
  `:If 0≠⎕NC'opts.X' ⋄ h.X←opts.X ⋄ :EndIf` chain.
- `opts ⎕VGET ⊂'Field' fallback` reads one optional field with a fallback
  if it's undefined — used where only a single field needs defaulting
  (e.g. `Timeout`, `WorkingDir`), rather than pulling in a full merge for
  one value.

A field that can only be computed *after* the handle exists (e.g.
`Shell.Start`'s `Tid←_Run&h`, which spawns a thread that needs `h` as its
argument) is necessarily still a separate assignment after the literal —
that's an ordering constraint, not a style regression.

Plain `⎕NS''` used only to mean "an empty namespace" (e.g. a default
`opts`, or empty tool-call `arguments`) is written `()` instead — Dyalog
20 array notation's literal empty-namespace form — since it's shorter and
reads the same as every other namespace literal in the codebase.

(`⎕VGET`'s sibling `⎕VSET` — writing several names into one or more
namespaces at once — isn't needed yet, since nothing here currently
fans one value out to multiple targets. Noted for when it is.)

### D12. `Fff` parser rewritten against fff's own source, not just observation

The fff source is available locally (`D:\devel\fff`). Once that's true,
"best-effort, ground it in whatever the server happens to output" (D11)
stops being an excuse to guess — `crates/fff-mcp/src/{server,output,
cursor}.rs` and `crates/fff-core` are the actual ground truth for every
text shape `Fff._ParseFindFiles`/`_ParseGrep` reads. Re-deriving the
parser against that source (rather than only against observed test
output) surfaced two real bugs no amount of additional *observed*
testing against this small repo would likely have found:

- `find_files`' empty-result text is `"0 results (N indexed)"` — a
  different phrase from grep's `"0 matches."`, not just a variant of
  it — and wasn't recognized, so it was silently misread as one bogus
  path (`Shown=1, Total=1, Paths=(⊂'0 results (N indexed)')`).
- A **definition-context** match line — `"  {n}| {text}"`, two leading
  spaces then a pipe, rendered by `output.rs` whenever a matched line
  happens to itself be a definition, with **no `context` parameter
  needed to trigger it** — was misread as a non-match line, so it
  incorrectly started a new "file" boundary and corrupted every
  subsequent match's file grouping in that response. Given how common
  it is to grep for something that's a definition, this was likely
  the single most-impactful latent bug in the parser.

`Matches` entries now carry a `Kind` (`'Match'` | `'Context'`
(`"{n}-{text}"`, an explicit `context:N` line) | `'DefContext'`) rather
than assuming every annotated line is a real match. TODO.md tracks
what the source confirmed exists but still isn't parsed (the
auto-broadened-query and path-only-fallback header shapes, and
`output_mode` values besides the default).

Two general APL gotchas fell out of writing this, worth keeping in
mind everywhere, not just here:

- **`∧`/`∨` are not short-circuiting** — `(0≠≢text)∧(' '=1⊃text)`
  still evaluates `1⊃text` even when `text` is empty, so it still
  `INDEX ERROR`s. (Monadic `⊃`/`↑` on an empty array are fine —
  `⊃`/`↑` never index, they disclose/pad with a fill element — it's
  specifically an explicit dyadic pick like `1⊃`/`¯1⊃` that needs the
  length check to actually *precede* it, in a separate `:If`, not
  merely appear alongside it in one `∧`.)
- **A multi-character left argument to `≡¨`/`∊` compares
  element-by-element, not as one unit** — `'Match'≡¨kinds` pairs each
  of `'Match'`'s own 5 characters against `kinds` (a `LENGTH ERROR`
  unless `kinds` happens to have exactly 5 elements); the fix is
  `'Match'∘≡¨kinds` (bind `'Match'` as a constant per application) or
  enclosing it first. Same trap for membership: `'Context'∊kinds`
  tests each *character* of `'Context'` for membership, not the whole
  string — needs `(⊂'Context')∊kinds` or `∨/'Context'∘≡¨kinds` instead.

Also: dot notation distributes over an array of namespace references
directly — `files.Matches` *is* `{⍵.Matches}¨files`, no explicit `¨`
needed. Used throughout the rewritten parser (e.g.
`(∊files.Matches).Kind`), and worth defaulting to over the `{⍵.Field}¨`
spelling wherever the left side is already a plain array of refs.

### D11. `Fff`: a version-specific cover over fff-mcp, plus its parser

`Fff` is a high-level cover over `Mcp`, specific to fff-mcp (tested
against v0.10.6): `Connect`/`Disconnect` keep one fff-mcp instance alive
against a directory (need not be a git repo — confirmed working, just
slower to index a large non-git tree on a cold process), and
`Find`/`Grep`/`MultiGrep` wrap `find_files`/`grep`/`multi_grep` with the
established `(value)`/`(value opts)` argument shape. A parser turns the
plain-text `content` fff-mcp returns into structured fields — deliberately
version-specific (per the user), best-effort, and never lossy: `Raw`
(the full `Mcp.CallTool` result) and `Text` (the extracted content
string) are always present on the result, whatever the parser did or
didn't recognize. One page per call (no auto-pagination); the `cursor`
`find_files` returns is exposed for the caller to feed back in, not
followed automatically — this avoids an unbounded-cost surprise on a
call against a huge tree. See TODO.md for the text-format variants
(`[def]` markers, `|` context lines, the fuzzy-fallback header, non-
`content` `output_mode`) the parser doesn't yet handle.

Further implementation notes discovered while building it:

- **`⎕JSON` represents JSON `true`/`false` as `⊂'true'`/`⊂'false'`**,
  not `1`/`0` (this is documented behavior, just easy to forget) — code
  that branches on a parsed boolean field must disclose and compare
  against the text, e.g. `(⊃ns.isError)≡'true'`, not `~ns.isError`
  (which is a `DOMAIN ERROR`: negating a character vector).
- **`⎕NQ'.' 'GetEnvironment' name` returned empty for every variable
  tried (`DYALOG`, `USERPROFILE`, `LOCALAPPDATA`, `PATH`) under
  `dyalogscript`** — it may only work against a full interactive/GUI
  session object, not this headless runtime. `Fff._DefaultExe` reads
  `%LOCALAPPDATA%` via a trivial child process
  (`⎕SHELL⍠('Shell'('cmd.exe' '/C'))⊢'echo %LOCALAPPDATA%'`) instead.
- **The `A(≠⊆⊢)B` line-split idiom needs its separator as the train's
  *left argument*, not embedded inside the train** — `sep(≠⊆⊢)text`,
  not `(sep≠⊆⊢)text` (the latter is a monadic application of a 3-train
  missing its left argument entirely, a `SYNTAX ERROR`).
- **`Output ('Null')` on stream 2, combined with an `Input ('Token' …)`
  on stream 0 talking to a genuinely interactive child process,
  reliably raises `DOMAIN ERROR: Invalid value received on token`** —
  discovered wiring up `@modelcontextprotocol/server-memory` as a
  second MCP server for the Tutorial (`fff-mcp` never logs to stderr,
  so this went unnoticed through phases 1–4; `server-memory` does, on
  every request). `Shell`'s default `Output` previously left stream 2
  on its own default (merge into stream 1 — see main `Output` docs),
  which corrupts the line-oriented protocol stream once a server
  writes anything to stderr. The fix is **not** `Output (2 'Null')`
  (that's what triggers the token error above) but a second `Callback`
  on stream 2 that just discards its data (`Shell._OnStderr`) — same
  destination *kind* as stream 1, just an inert sink.
- **A tool result's `isError` field is optional, not guaranteed
  present** — `fff-mcp` always includes it, but `server-memory` omits
  it entirely on success (matching the spec, which only requires it
  when true). Code reading `result.isError` directly from `Mcp.CallTool`
  against an arbitrary server needs `0≠⎕NC'result.isError'` first;
  `Fff._WithParsed` gets away with assuming it's present only because
  `Fff` is deliberately scoped to `fff-mcp` alone (ADR D11's whole
  premise), which does always set it.
- **A named traditional function can't be passed as a plain value**
  in an ordinary expression (there's no first-class function value to
  hand to another function as data) — but it *can* be passed as an
  **operand to an operator**, which is exactly the mechanism APL gives
  for this. `Fff._WithParsed` is a traditional operator taking the
  parser (`_ParseFindFiles`/`_ParseGrep`) as its operand:
  `(_ParseFindFiles _WithParsed)raw` — no string-selector dispatch
  needed. (An initial version used a `'FindFiles'`/`'Grep'` selector
  string with `:Select` instead, before noticing operators were the
  actual tool for the job.)
