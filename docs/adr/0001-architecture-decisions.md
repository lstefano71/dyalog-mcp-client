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
  length check to actually *precede* it.) `:If`'s `:AndIf`/`:OrIf`
  clauses genuinely short-circuit (the later condition isn't evaluated
  at all when the earlier one already decides the branch) and read
  better than nesting a separate `:If` inside the first — that's what
  the code does now, e.g. `:If 0≠≢text ⋄ :AndIf ' '=1⊃text`. (Don't mix
  `:AndIf` and `:OrIf` in the same chain, and avoid code between an
  `:If`/`:AndIf` and the next `:AndIf` where it can be helped — both
  are legal but read about as unclearly as nested `:If`s once you do.)
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

### D13. `JsonRpcCl`: a second, self-contained JSON-RPC layer for Content-Length framing

`Shell`/`JsonRpc` assume newline-delimited JSON-RPC framing throughout
(ADR D5) — correct for MCP, but genuinely unusual in the wider stdio
JSON-RPC world, where Content-Length-header framing (LSP, DAP, and
most other stdio JSON-RPC servers) dominates (see the Manual's
Tutorial, and the TODO.md entry this ADR resolves). `JsonRpcCl` adds
that framing as a **separate, self-contained namespace** — deliberately
*not* built on `Shell`, because `Shell`'s line-splitting `Output`
callback mode is the wrong tool for a transport where a message body
is read by exact byte count, not by scanning for newlines. `JsonRpcCl`
talks to `⎕SHELL` directly, in *simple vector mode* (see below), and
does its own header/body buffering. Its public verb shape
(`Connect`/`Disconnect`/`Call`/`Notify`) deliberately matches
`JsonRpc`'s, so a future cover could be built on either the same way
`Mcp` is built on `JsonRpc`.

Verified two ways: a purpose-built toy Content-Length server
(`examples/toy-jsonrpc-cl-server.py`, the twin of the NDJSON toy server
— `test/08-jsonrpccl-toy-server.apls` is the committed, network-free
test), and manually against a real, substantial language server,
`pyright-langserver` (installed ad hoc via `npx -y -p pyright
pyright-langserver --stdio` — note the `-p` flag: `pyright-langserver`
is a bin *inside* the `pyright` npm package, not a package of its own,
so a bare `npx -y pyright-langserver` 404s). The real-server run
completed a full `initialize` handshake, correctly interleaving
unsolicited `window/logMessage` notifications with the awaited
response — not committed as an automated test since it needs network
access and an npm install on first run, unlike everything else in this
repo.

Implementation notes from building and debugging it — several are
general APL gotchas, not specific to this transport:

- **`Output ('Callback' fn type)` with a scalar-integer `type`** (here,
  `80` — the same value the docs note is what `('Array' Data)`'s
  shorthand means for character data) puts the callback in *simple
  vector mode*: raw accumulated text, no line splitting. This is
  exactly what a byte-counted framing needs, and — as a bonus — an
  `Input ('Token' n)` fed the same way (`('Array' Data 80)`, not
  `('Array' Data Encoding)`) sends the data as-is, with **no forced
  trailing newline** (unlike `Shell.Send`'s `('Array' text 'UTF-8')`,
  where the auto-appended newline is desirable for NDJSON but would be
  one stray extra byte here).
- **Two simple-vector-mode (`type`-based) `Output` callbacks together,
  combined with an `Input ('Token' …)`, reliably raise `DOMAIN ERROR:
  Invalid use of variant`** against a real interactive child process —
  a distinct `⎕SHELL` variant-combination limitation from `Shell`'s
  `Output ('Null')`-plus-token one (ADR D11), but the same *family* of
  issue. The fix is the same shape: give the discarded stream (2) an
  *ordinary line-mode* callback instead (no explicit `type`), keeping
  simple-vector mode only where it's actually needed (stream 1).
- **`bodyStart-1+len` does not mean `(bodyStart-1)+len`** — APL
  evaluates strictly right-to-left with no operator precedence, so
  that expression is `bodyStart-(1+len)`, silently wrong (and, since it
  can come out negative, an "already have enough bytes" length check
  built on it can be *always* false, masking the bug as a downstream
  JSON-parse failure instead of the arithmetic error it actually is).
  Parenthesize; don't rely on reading intent into bare `+`/`-` chains.
- **`N↓X` where `N` is a *count*, not an index** — `bodyStart↓h.Buffer`
  drops `bodyStart` elements, landing one *past* the position named
  `bodyStart`; extracting a slice starting *at* index `bodyStart` needs
  `(bodyStart-1)↓h.Buffer`.
- **A single-character split idiom (`sep(≠⊆⊢)text`) cannot split on a
  multi-character delimiter** (`"\r\n"`) — `≠` would try to compare a
  2-element left argument against `text` elementwise. Strip the `\r`
  first (as `Fff`'s CRLF-tolerance already does) and split on the
  remaining `\n` alone; reserve `⍷` (which does handle multi-character
  needles correctly) for finding the 4-character `"\r\n\r\n"` header/body
  boundary itself.
- **`'content-length:'` is 15 characters, not 16** — worth calling out
  only because miscounting it silently produces a *shape* mismatch
  (`≡` between a 16-element slice and a 15-element literal is just
  `0`, no error at all), not a loud one — this is the same class of
  silent-wrongness as the arithmetic precedence gotcha above, not a
  new lesson, but a second data point for it.
- **Never use `⍎` to parse numbers out of untrusted (server-supplied)
  text**, even text already filtered down to plain digits by the
  caller — `⍎` executes arbitrary APL, and relying on an upstream
  filter's correctness to make that safe is fragile. `⎕VFI` is the
  actual tool for "turn this digit string into a number" and never
  executes anything. (This applies equally to the digit-parsing added
  for `Fff` in D12, fixed alongside this.)

### D15. `Fff` parser: closing the remaining fff-source-confirmed gaps

Phase 9 (see `PLAN.md`/`TODO.md`) closed the four items D12/TODO.md
had left open, re-verified against the current `D:\devel\fff` checkout
(`crates/fff-mcp/src/{server,output}.rs`) rather than trusting D12's
line-range citations blindly — they had moved somewhat, so every shape
below was re-confirmed directly.

**Auto-broadened queries** (`server.rs`' `perform_grep`): when the
exact query gets 0 matches and is multi-word, fff-mcp retries with the
first word dropped (skipped if that word looks like a constraint —
starts with `!`/`*` or ends with `/`). If the retry finds 1-10
matches, the response is `"0 matches for '<q>'. Auto-broadened to
'<q2>':\n{text}"`, where `{text}` is a **normal, mode-formatted**
`GrepFormatter::format` result for the retry — `output_mode` is
whatever was originally requested, not always `'content'`. This means
the embedded text can itself contain a `→ Read` suggestion line, a
`"N/Total matches shown"` header, or (for `'files_with_matches'`/
`'count'` modes) their own mode-specific shapes. `_ParseGrep` now
strips just the leading `"0 matches for '<q>'. Auto-broadened to
'<q2>':"` line, records `<q2>` as `Broadened`, and falls through to
parse the remaining lines exactly as if they were the whole response
(same `mode` — no separate code path needed). Decision: `Broadened`
defaults to `''` (empty means "no broadening happened"), matching the
existing `Suggestion`/`Cursor` convention of "empty string means
absent" rather than a separate Boolean flag field.

**Path-only fallback** (`server.rs`, same function, later branch):
reached only when the exact query, the auto-broaden retry, *and* a
fuzzy content-similarity retry all come up empty, and the query
contains `/` and scores well against fff's filename fuzzy matcher.
Text is `"0 content matches. But there is a relevant file path:
{path}"` — always exactly this one line, mode-independent (built
directly in `server.rs`, never routed through `GrepFormatter`, so it's
identical no matter what `output_mode` was requested). `<p>` now lands
in a new `SuggestedPath` field (`''` when absent, same convention).

**The fuzzy-approximate fallback is also mode-independent**: the `"0
exact matches. N approximate:\n{...}"` text a few lines above the
path-only fallback in `server.rs` is likewise built directly (not
through `GrepFormatter`), and always uses the *default/content* line
shape (`" N: text"`) regardless of the requested `output_mode`. So is
the bare `"0 matches."` (both empty-result branches in `perform_grep`
use this exact string). `_ParseGrep` checks for these two shapes
*before* branching on `mode`, so a `'count'`/`'files_with_matches'`
request that happens to fall into one of these fallbacks still parses
correctly instead of being fed to the wrong per-line parser.

**`output_mode` variants** (`output.rs`' `GrepFormatter::format`):
confirmed `OutputMode::Usage` and `OutputMode::Content` are the same
code path (the `_ => Self::Content` catch-all in `OutputMode::new`
means an unset/unrecognized `output_mode` and an explicit `"usage"`
produce identical text) — no separate handling needed beyond the
existing default parser. `FilesWithMatches` and `Count` are genuinely
different text shapes, each with its own formatting function
(`format_files_with_matches`/`format_count`) that **never** produces
the `"N/Total matches"` header the default mode does — `Shown`/`Total`
are defined instead as the file count (`'files_with_matches'`) or the
sum of per-file counts (`'count'`), the closest each mode's own text
actually carries. `'files_with_matches'` is confirmed the only mode
whose path line can carry a trailing `" [def]"` tag (and, for large
files, a `"({N}KB - use offset to read relevant section)"` size tag) —
both are stripped out into a new `IsDef` field per `Files` entry
rather than left riding along in `Path`. `'count'` produces one
`"{path}: {count}"` line per file with no header and no per-line
detail at all — modeled as a new `Counts` field (vector of
`(Path Count)`), left empty when the mode isn't `'count'`; `Files`
stays empty when it is. Decision: rather than varying `Fff.Grep`'s
result *shape* by mode (which would make every caller `:Select` on
`output_mode` before touching the result), it keeps one consistent
field set (`Shown`/`Total`/`Cursor`/`Suggestion`/`Broadened`/
`SuggestedPath`/`Files`/`Counts`) across all modes, with the
mode-inapplicable fields simply empty — same "always present, may be
empty" convention `Raw`/`Text`/`Suggestion`/`Cursor` already
established. `output_mode` is threaded through as a left argument to
a now-dyadic `_ParseGrep` (`mode _ParseGrep text`, defaulting to
`'content'` when omitted monadically, so the existing direct
`Fff._ParseGrep sample` call in `test/07` keeps working unchanged);
`Fff.Grep`/`MultiGrep` bind it via `mode∘_ParseGrep` (Dyalog 18+'s
bind form of `∘`, mentioned in D12) before handing it to `_WithParsed`
as the parser operand.

**Multi-file/pagination-scale grouping**: re-ran the existing
file-changes-when-path-line-seen grouping logic (unchanged from D12)
against real heavy output — `context:4`/`context:5` grep queries with
many hits across several files, both in this repo and, by hand,
against the much larger `D:\devel\fff` source tree (a `multi_grep`
there returned 11 files, up to 13 matches in one, 67 total match+
context lines in one page; a plain `grep 'fn '` with `context:5`
returned exactly 60 Context-kind entries for 6 Match-kind entries — 6
matches × (5 before + 5 after) = 60, confirming context-line counting
is exact even at this scale). No grouping corruption found — the
logic holds up under real pagination load, not just the small,
few-file cases it had only been exercised against before. Cursor
pagination itself (multiple pages via the returned `Cursor`) was also
exercised this way and round-tripped correctly.

**Two more real, previously-latent bugs surfaced by actually exercising
these paths for the first time** (not introduced by this phase's
changes — both pre-existing, just never triggered before):

- `_ToInt` (`n←2⊃⎕VFI digits`) returns a **1-element vector**, not a
  true scalar — `⍴` on the result is `1`, not `⍬`. This was invisible
  everywhere it had been used before (it prints and does arithmetic
  identically to a scalar as long as nothing gathers several of them
  across an array of namespace refs via dot notation). The new
  `Counts` field's `Path`/`Count` per-file entries are exactly that:
  `r.Counts.Count` (dot notation over several refs, per D12's own
  "distributes like `¨`" note) wraps each non-scalar `Count` leaf in
  its own enclosure to build the combined array, so the result comes
  out **nested** (`≡` reports depth 2, not the expected 1) even though
  its shape and printed value look perfectly ordinary. That nesting
  then propagated through ordinary-looking arithmetic/comparisons
  (`r.Shown≠+/r.Counts.Count`, `∨` combining that with other
  conditions) into a `:If` condition that was no longer a simple
  Boolean, which Dyalog rejects with `DOMAIN ERROR: Boolean singleton
  value required` — a genuinely confusing error to debug backward
  from, since every intermediate value *displays* and *shapes* like an
  ordinary scalar; only `≡` (depth) exposes the nesting. Fixed by
  disclosing: `n←⊃2⊃⎕VFI digits`. General lesson: when a `:If`
  condition DOMAIN ERRORs with "Boolean singleton value required" on
  what looks like an ordinary scalar comparison, check `≡` on the
  operands, not just `⍴` — a nested (nesting depth > 1) simple-looking
  scalar is invisible to `⍴`/`⍕`/direct display alike.
- `_NumberBefore` used `n←_ToInt ¯nd↑seg` — `¯` (high minus) is valid
  **only as part of a numeric literal** (`¯1`, `¯nd` is not one token,
  it's `¯` followed by the variable `nd`, which is a `SYNTAX ERROR`);
  negating a variable to build a left argument for `↑` needs monadic
  `-`, i.e. `(-nd)↑seg`. This line implements grep's `"0 exact
  matches. N approximate:"` fuzzy-fallback count, a shape that had
  apparently never actually been hit by any test or example run
  against this repo before Phase 9's queries were the first to
  reliably trigger it (a query with no exact hits but a strong fuzzy
  match). Fixed alongside the `output_mode`/broadening work; a good
  reminder that "the code has never errored" is not the same claim as
  "the code has been exercised" — a `:Trap`-swallowed or simply
  never-reached branch can carry a `SYNTAX ERROR` indefinitely.
