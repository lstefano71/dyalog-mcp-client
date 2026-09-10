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

### D14. A mocked/canned-fixture stdio peer for hard-to-provoke misbehaviors

`fff-mcp` is a plain, spec-compliant, well-behaved server (see this
ADR's own "Context" section) — which is exactly why it's useless for
testing what happens when a server *doesn't* behave. It never crashes
mid-response, never sends malformed JSON, never hangs, never floods
unsolicited notifications ahead of a real response. Those paths
(TODO.md's Shell/JSON-RPC layer sections) could only be reasoned about
from reading `Shell`/`JsonRpc`'s source, never actually triggered and
watched. A real server occasionally misbehaving in the wild isn't a
substitute for this either — it's not reproducible, and you can't write
a regression test against "wait for it to happen again."

`examples/toy-jsonrpc-fixture-server.py` solves this the same way the
existing toy servers (D5's NDJSON one, D13's Content-Length one) solve
"is there a well-known non-MCP stdio JSON-RPC server to test against":
by being purpose-built, small, and committed. Its methods let a test
*ask* for a specific misbehavior by name rather than hope one shows up:

- `crash(code)` — exits the process immediately, un-cleanly, instead of
  ever writing a response.
- `garbage()` — writes one line of deliberately invalid JSON instead of
  a real response, then keeps serving later requests normally (proves
  the malformed line itself is the fault, not a wedged process).
- `hang()` — blocks forever and never responds. Deliberately a
  *separate* method from reusing the existing toy servers' `sleep
  (seconds)` idea: `sleep` is built to demonstrate a client timeout
  shorter than a finite sleep, which is still a race between two
  durations, however lopsided. `hang` has no duration at all to race
  against — it removes the "is the client timeout just too generous"
  question entirely.
- `burst(count, text)` — emits `count` unsolicited notifications (no
  `id`) before its real response, to stress-test `h.Notifications`
  queuing under load (5-10+ notifications, not just one or two) without
  disrupting the response that eventually follows.

`test/09-fixture-server-misbehaviors.apls` exercises all four against
`Shell`/`JsonRpc` and records today's *actual* observed behavior — it
deliberately does not fix anything it finds (that's the next phase's
job; TODO.md tracks what to fix). All four behaved as the existing code
already intends: `crash` and `hang` both signal (a process-exit signal
carrying the fixture's real exit code, vs. a plain timeout signal —
confirming these two really are distinguishable, not the same signal
wearing two different messages); `garbage` signals `JsonRpc`'s existing
"malformed JSON from server" path; a `burst` of 8 notifications all
land in `h.Notifications`, in order, without disturbing the real
response. Concretely: this is what confirmed the exact
`Shell.Receive: process exited (reason <r>, code <c>)` message shape
against a real mid-`Receive` crash, resolving that ADR D-adjacent
TODO.md open question, and what caught the `Stop` force-kill gap
actually leaving an orphaned `python.exe` process running forever after
`hang` (closing stdin does nothing to a process blocked in a wait with
no timeout of its own) — both already-known TODO.md items, now backed
by a reproducible trigger instead of just reasoning.

Non-obvious things hit while building it:

- **A crashing method must exit the *interpreter* process, not just
  raise inside the handler** — `sys.exit(code)` inside a Python
  `except`-guarded dispatch loop needs `except SystemExit: raise`
  ahead of the general `except Exception` clause, or the crash gets
  silently swallowed and reported back as an ordinary JSON-RPC error
  instead of actually killing the process — defeating the entire point
  of a `crash` method.
- **`threading.Event().wait()` with no timeout argument blocks
  genuinely forever**, unlike `time.sleep(large-number)` — both look
  similar on paper, but `sleep` is still racing a clock the caller
  could out-wait with a long enough timeout; a bare `.wait()` has no
  clock in it at all. This is what actually makes `hang` a different
  test from a longer `sleep`, not just a renamed one.
- **A file-not-found child process fails exactly like a well-formed but
  buggy one, from `⎕SHELL`'s side** — pointing `Shell.Start`'s `cmd` at
  a script path that doesn't exist doesn't raise anything client-side;
  the child (`python.exe`) starts, immediately prints "can't open
  file" to stderr (silently discarded per D5/D11) and exits with code
  `2`, which `Shell`/`JsonRpc` report as an ordinary process-exit
  signal — indistinguishable, from the client's perspective, from any
  other early crash. Worth remembering when a "the server crashed"
  signal shows up unexpectedly during development: check the command
  path resolves before assuming the server logic is at fault.

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

### D16. `Lsp`: a minimal LSP cover over `JsonRpcCl`

`JsonRpcCl` (D13) proved the Content-Length transport talks to a real
language server, but left the actual LSP protocol semantics — the
handshake shape, hover, clean shutdown — for a cover to build, the
same way `Mcp` builds MCP semantics on top of `JsonRpc`. `Lsp` is that
cover: `Connect`/`Disconnect` (handshake + clean shutdown),
`DidOpen`/`Hover` (`textDocument/didOpen`/`textDocument/hover`).
Deliberately general-purpose, not server-specific (unlike `Fff`) —
nothing in it is pyright-only, it's just the only server it's been
verified against. v1 scope is narrow, same spirit as `Mcp`'s (D8) —
see `TODO.md` for what's out (`didChange`/`didClose`, `completion`,
`definition`, `references`, published diagnostics, workspace folders).

Verified against real `pyright-langserver` (`npx -y -p pyright
pyright-langserver --stdio`, the same invocation D13 used) —
`test/11-lsp-cover.apls`: `initialize`/`initialized` handshake,
`ServerCapabilities` populated, `textDocument/didOpen` on a real
`.py` fixture followed by `textDocument/hover` over a stdlib call
(`os.getcwd()`) returning real hover content (`"(function) def
getcwd() -> str"`), hover over a blank line returning JSON `null`,
`shutdown`/`exit` followed by `Disconnect` actually ending the process
(`Status` reads `'Exited'` afterward).

Empirically-derived specifics, not obvious from the spec text alone
without a real server to check against:

- **LSP's `initialized` is a notification named exactly
  `'initialized'`, with an *empty params object*, not MCP's
  `notifications/initialized`-shaped name and not "no params at
  all."** Skipping it doesn't error outright — pyright's `initialize`
  response comes back fine either way — but requests sent afterward
  (`textDocument/hover` included) got no useful response without it
  having been sent first. This is easy to get wrong by analogy with
  MCP's very similarly-purposed step, which really is what its own
  name plus no-params-needed suggests.
- **Minimal `initialize` params are enough**: `processId:⊂'null'`,
  `rootUri:⊂'null'` (both JSON `null`, no workspace — same convention
  as D13/D11's `⊂'null'`-on-the-way-out), `capabilities:()` (a bare
  empty object). pyright answered with real `ServerCapabilities` and
  gave real hover content off nothing more elaborate than that — no
  need was found for declaring specific client capabilities (e.g.
  `textDocument.hover.contentFormat`) just to get a working `hover`
  reply (it came back as `contents.kind:'plaintext'`, pyright's own
  default, without asking for anything). `TODO.md` notes this may not
  generalize to every server.
- **JSON `null` coming *in* is `⊂'null'`, not an absent field, not
  `⎕NULL`, not `0`/`⍬`.** This wasn't previously documented anywhere
  in this codebase — D11 established `⎕JSON` represents `true`/`false`
  coming in as `⊂'true'`/`⊂'false'`, but `Hover`'s "no info at this
  position" result (a spec-legal `null`) is the first place this
  codebase actually received a `null` value and needed to branch on
  it, and confirmed empirically that the same enclosed-text
  convention extends to `null` too: `(h Lsp.Hover args)≡⊂'null'`, not
  `0=⎕NC` or any check for a missing `.contents`. Get this wrong and a
  legitimate "nothing to say" response looks like a malformed one.
- **`textDocument/didOpen`'s `text` is genuinely authoritative
  regardless of what's on disk at `uri`**, exactly as the spec says —
  confirmed by opening a `uri` naming a path with **no file on disk at
  all** and still getting a correct hover result off `text` alone.
  The committed test/Tutorial example still open a real file (for a
  realistic worked example a reader could open in an editor), but
  nothing in `Lsp.DidOpen` requires `uri` to resolve to a real path.
- **`shutdown` then `exit` is enough to make pyright's own process
  exit on its own** — `Disconnect`'s subsequent
  `JsonRpcCl.Disconnect` (stdin-close/wait) mostly just observes an
  already-finished exit rather than causing one, but is kept
  unconditionally (wrapped in `:Trap` around the `shutdown`/`exit`
  pair) in case a future target server doesn't honor `exit` — falling
  through to the same force-nothing wait `JsonRpcCl.Disconnect`
  already does for every other case.
- **The isError-vs-signal judgment call, applied to LSP**: LSP has no
  literal `isError` field the way MCP tool results do, but the same
  underlying distinction (D6/D11) applies — a JSON-RPC-level `error`
  response (bad params, method not found, a request sent before
  `initialize` completes) means something about the *protocol
  exchange* went wrong and signals; a `result` that is legitimately
  `null` per the LSP spec (hover/definition/etc. all document `null`
  as a valid "nothing found here" result) is the server successfully
  telling the caller there's nothing to report, which is ordinary
  data, not a fault. `Lsp.Hover` implements exactly this split.

### D17. `JsonRpc`/`JsonRpcCl`: pipelining, batch requests, notification dispatch

Phase 8 generalizes both JSON-RPC layers beyond D7's v1 "exactly one
in-flight `Call`" limitation, landed identically in `JsonRpc` and
`JsonRpcCl` (same verb names/semantics; `JsonRpcCl`'s reads come from
its own `h.Messages` queue instead of a fresh `Shell.Receive` line, but
the classification logic is otherwise the same code shape in both).
This does **not** mean multiple APL threads calling `Call` on the same
handle concurrently — `Shell.Receive`/`JsonRpcCl`'s buffer still has
exactly one consumer, and that's staying out of scope (it would mean
redesigning `Shell` itself, which this phase deliberately does not
touch). It means one thread can fire off several requests without
waiting for each one's response immediately, and collect each response
whenever it's ready, in whatever order they actually arrive.

**Pipelining — `Send`/`AwaitResponse`, and the pending table.**
`id←h Send args` sends a request with a fresh id and returns
immediately; `resp←h AwaitResponse id` blocks until that specific id's
response has arrived. The natural shape for "has this id already
arrived while I was waiting for a different one?" is a dyadic-`⍳`
lookup on a plain numeric vector of ids (`h.PendingIds`), paired with a
same-length vector of the matching parsed messages (`h.PendingMsgs`) —
not a loop scanning for a match, and not a namespace keyed by id
(ids are plain integers here, a vector lookup is both the simplest and
the most idiomatic shape). Removing a found entry is a boolean-mask
compress (`keep←pos≠⍳≢h.PendingIds ⋄ h.PendingIds←keep/h.PendingIds`),
again array-oriented rather than a splice-by-loop. `Call` is now
exactly `h AwaitResponse(h Send args)` — every pre-existing test using
`Call` kept passing completely unchanged, which is the whole point of
keeping it as a convenience wrapper rather than reimplementing it
separately.

**Batch requests — `CallBatch`.** `resps←h CallBatch argsVec` builds
one request per element of `argsVec` (via `h∘_Envelope¨argsVec`, the
same operator-bind idiom D15 used for `mode∘_ParseGrep`), assigns each
a fresh id, sends them as a single JSON-RPC 2.0 batch (one JSON array,
one wire message), and then just calls `h AwaitResponse¨ids` — reusing
the exact same pending-table mechanism pipelining already needed, with
no separate code path for "these responses happen to have arrived
together in one array." This is also why `argsVec`'s own order comes
back correctly regardless of the server's reply order: each
`AwaitResponse` in the `¨` only cares about its own id, not position.
The toy pipeline servers (below) deliberately reply to a batch in
**reversed** order specifically to prove this — the naive-but-wrong
implementation ("just return the array elements in the order they
arrived") would have silently passed against a server that happened to
reply in request order, which is exactly the kind of test-passes-for-
the-wrong-reason trap this project's Manual doc standard (only
citing examples that were actually run) is meant to catch elsewhere.

A message that is itself a JSON-RPC batch (an array, not one object)
needed its own detection: `⎕JSON` parses a JSON object to a rank-0
namespace scalar and a JSON array of objects to a rank-1 vector of
namespace refs, so `0<⍴⍴raw` is the array/single-message test — no
special-casing needed beyond that, since a rank-1 result just gets
flattened directly into the same per-message queue a single message
would have landed in one at a time (`JsonRpc.h.Inbox`,
`JsonRpcCl._ExtractMessages` appending straight into `h.Messages`).
`JsonRpc` needed a new `h.Inbox` queue for this (a single incoming
line can now expand into several messages to classify one at a time);
`JsonRpcCl` didn't need an equivalent, since `h.Messages` already
played exactly that role for its per-frame message queue.

**Notification dispatch — the function-values problem, and why a
name-string table won.** The task here is: register a handler for a
method name, discovered only at runtime (the server can send any
`method`), and invoke the right one when a matching notification
arrives — a small dynamic dispatch table. Dyalog has no first-class
traditional-function value (D12 already hit this for `Fff._WithParsed`
and reached for an operator instead), so a plain `h OnNotification
(method SomeHandlerFn)` registration, expecting to store `SomeHandlerFn`
as ordinary data, simply doesn't work — there is nothing to store.
Two real directions were considered:

- **(a) A name-string table**, mirroring the convention `⎕SHELL`'s own
  `Output ('Callback' fn)` already uses throughout this codebase
  (`('_OnOutput' h)`): `OnNotification` takes `(method handlerName)`,
  where `handlerName` is a fully-qualified function-name character
  vector (e.g. `'#.Mcp._OnToolsListChanged'`) chosen by the
  *registering* code. Dispatch looks up `parsed.method` (server text)
  via a dyadic-`⍳` into `h.NotifyMethods` (our own trusted table) to
  find the matching `h.NotifyHandlers` entry, then invokes it by
  building a tiny string, `'h ',handler,' parsed'`, and `⍎`ing it.
- **(b) An operator-based registration API** instead of a runtime
  string-keyed table — the same shape as `Fff._WithParsed`'s
  `(_ParseFindFiles _WithParsed)raw`.

(b) was rejected for the reason the task itself flags: an operator's
operand is bound at the call site, in the *caller's own code*, not
discoverable from a runtime value. `Fff._WithParsed` works precisely
*because* the caller already knows, statically, which parser it wants
(`_ParseFindFiles` vs `_ParseGrep`) — there's exactly one call site per
tool, chosen by the programmer writing `Fff.Find` vs `Fff.Grep`. This
problem is different in kind: the whole point of `OnNotification` is
that a method name arriving over the wire, *at runtime*, must select
the right previously-registered handler out of a set that can grow
after the fact (multiple `OnNotification` calls, one per method,
possibly from different covers built on the same JsonRpc handle — e.g.
future covers besides `Mcp` might want to register their own methods
on a shared connection). An operator can't be handed a runtime string
and asked to "become" the right derived function; it can only be
written once at the call site where its operand is a literal or a
variable already in scope. So (b) doesn't actually solve the stated
problem — it would only work if there were a small, fixed, statically-
known set of methods to dispatch on, chosen by the code that also owns
the `AwaitResponse`/dispatch loop itself, which isn't the case here
(`JsonRpc`/`JsonRpcCl` know nothing about MCP-specific method names;
`Mcp` is just one caller registering into a shared, general mechanism).

(a) does solve it, and is safe *specifically because* of what goes into
each side of the lookup: `parsed.method` (server-supplied, untrusted)
is used **only as a lookup key** — a dyadic-`⍳` position into
`h.NotifyMethods` — never as text that gets executed. What ends up
inside the `⍎`'d string (`handler`) is a value from `h.NotifyHandlers`,
and every entry in that table was put there by a prior `OnNotification`
call made by *this codebase's own code* (`Mcp.Connect`, or any future
caller) — never by anything the server sent. This is exactly the
house rule already stated for numeric parsing (D13's `⎕VFI`-not-`⍎`
note) generalized to dispatch-by-name: the untrusted input selects a
position in a table we built, it never becomes code itself. Re-reading
D12's operator-vs-plain-value writeup while finalizing this confirmed
the boundary: D12's operator case is "the caller knows statically
which function it wants"; this case is "an untrusted runtime value
must select among several `OnNotification`-registered functions",
which is a genuinely different problem an operator can't address.

**Backward compatibility — "as well as", not "instead of".** When a
handler *is* registered for an arriving notification's method, it's
invoked, and the notification is **still** appended to
`h.Notifications` — not replaced by the handler firing. Two reasons:
(1) it's what "backward compatible" has to mean for existing code that
already polls `h.Notifications` — adding a *new* `OnNotification`
registration for some method (e.g. from a library update) must not
silently stop that method's notifications from showing up in a queue
existing code already reads; (2) `h.Notifications` stays a complete,
inspectable log of everything that arrived, useful for debugging a
session regardless of what got dispatched. The cost is that a consumer
using both mechanisms for the same method sees it twice (once via the
handler, once in the queue) — judged the lesser surprise compared to
"registering a handler quietly changes what already-working polling
code sees."

**`Mcp`'s reaction to `notifications/tools/list_changed`.** `Mcp` has
no tool-list caching at all today — `ListTools` always calls
`tools/list` fresh. Building a cache *just* to have something for this
notification to invalidate would be scope creep the task didn't ask
for and no test exercises otherwise, so `Mcp.Connect` registers a
handler that only sets `h.ToolsStale←1` (informational), and
`Mcp.ListTools` clears it back to `0` immediately after it fetches a
fresh list — giving the flag real, checkable meaning (it's genuinely
`1` exactly while the server has said "stale" and the caller hasn't
re-fetched since) without pretending there's a cache underneath it.
One non-obvious wrinkle: the handler is invoked by `JsonRpc`'s dispatch
as `h HandlerName parsed`, where `h` is the *`JsonRpc` handle*
(`jr`), not the `Mcp` handle — `JsonRpc` has no way to know about the
`Mcp` handle wrapping it. So the flag necessarily lives at
`h.JsonRpc.ToolsStale` from `Mcp`'s own callers' point of view, not
`h.ToolsStale` — documented at the top of `Mcp.dyalog` rather than
silently surprising a reader who expects it on the outer handle.

**Testing — a new, dedicated toy server pair, not an extension of the
existing ones.** Provoking genuine out-of-order responses needs the
server's *request loop itself* to hand every request to its own
thread — a structural change, not an additional method — because
`examples/toy-jsonrpc-server.py`'s stdin loop processes one line fully
(including any `sleep`) before it even reads the next, so a slow
request already blocks the next line from being read, let alone
answered first. `examples/toy-jsonrpc-pipeline-server.py` (NDJSON) and
its Content-Length-framed twin `examples/toy-jsonrpc-cl-pipeline-
server.py` are purpose-built for this: `echo`/`delay(seconds,text)`
answered from per-request threads, a `notify(method,notifyParams)`
method to provoke an arbitrary unsolicited notification on demand
(used to drive `Mcp`'s `list_changed` reaction without needing a real
MCP server that actually sends one), and batch requests answered with
their responses deliberately **reversed** from request order (see
"Batch requests" above for why that specific choice matters, not just
"any order"). Both also implement bare-minimum `initialize`/
`tools/list` methods so `test/12` can drive a full `Mcp.Connect`/
`ListTools` round trip without a real MCP server.
`test/12-jsonrpc-pipelining.apls`/`test/13-jsonrpccl-pipelining.apls`
exercise pipelined out-of-order `AwaitResponse`, `CallBatch`,
registered-vs-unregistered notification dispatch, and (test/12 only,
since `Mcp` is built on `JsonRpc`, not `JsonRpcCl`) the `ToolsStale`
reaction — against both layers where applicable. The full existing
suite (`test/01` through `test/11`) was re-run afterward and passed
with zero regressions.

Non-obvious mistake made and fixed while building this, worth
recording since it's an easy trap: a tradfn header of the shape
`∇ parsed←h _NextMessage` does **not** define a dyadic function with
`h` as its left argument — APL has no "monadic function with its
argument on the left" form, so Dyalog instead parses the *first*
identifier as the function name and the second as its (monadic,
right-hand) argument: this line actually defined a function called
`h` taking an argument named `_NextMessage`, silently shadowing the
handle variable `h` used everywhere else. A monadic helper that takes
only the handle must follow the existing convention already visible in
`Mcp.ListTools`/`Disconnect` (`h` on the **right**, since there's no
second argument to justify the left-argument-is-the-handle convention
at all) — fixed to `∇ parsed←_NextMessage h`. `⎕NL 3 4` on the fixed
namespace is what actually surfaced this (an unexpected niladic-
looking `h` function appeared in the listing, and the intended
`_NextMessage` was simply absent) — worth remembering as a diagnostic
technique if a newly-added function seems to silently not exist after
`⎕FIX`.
