# Reference

Every public verb, across all layers, with its signature and a working
example. Scoped to public verbs only — no leading-underscore internals
(those would go in a future Internals Guide; see `TODO.md`).

See [`CONTEXT.md`](../../CONTEXT.md) for the vocabulary used here
(**Handle**, **Layer**, **Cover**), and
[`docs/adr/0001-architecture-decisions.md`](../adr/0001-architecture-decisions.md)
for the reasoning behind the design. If you're new to this codebase,
read the [Tutorial](tutorial.md) first — this document is for looking
things up, not for learning the shape of the client.

Every example below is either lifted verbatim from a passing test
script (cited by path) or was written fresh and actually run once
before being included here (per the Manual's own doc standard) — none
of this is speculative.

All layers require Dyalog APL 20.0+ (for `⎕SHELL`, `⎕TALLOC`, and array
notation).

---

## `Shell` — bidirectional stdio wrapper around `⎕SHELL`

The foundation layer: starts a child process, feeds it lines, hands
back lines as they arrive, stops it. Knows nothing about JSON-RPC or
MCP. Source: `src/Shell.dyalog`.

**Handle fields**: `Cmd`, `WorkingDir`, `Lines`, `Status`
(`'Running'`|`'Exited'`), `ExitCode`, `ExitReason`, `Pid`, plus the
token-range bookkeeping (`Tok`/`InTok`/`SigTok`/`Tid`) — see ADR D1 if
you need to know what those are for; you shouldn't need to touch them.

### `h←{opts}Start cmd`

Starts `cmd` (a vector of character vectors: the program path followed
by its arguments) on its own thread and returns a handle. `opts`, if
given, is a namespace that may set `WorkingDir`.

```apl
exe←'C:\Users\stf\AppData\Local\fff-mcp\bin\fff-mcp.exe'
opts←⎕NS''
opts.WorkingDir←'D:\devel\mcp-client'
h←opts Shell.Start,⊂exe
```
(`test/03-lifecycle-edge-cases.apls`)

### `{r}←h Send text`

Pushes one line of text (no embedded newlines) to `h`'s stdin. Signals
if `h.Status` isn't `'Running'`.

```apl
h Shell.Send'{}'
```
(`test/03-lifecycle-edge-cases.apls`, inside a `:Trap` expecting the
not-running signal)

### `text←timeout Receive h`

Blocks up to `timeout` seconds (`0` = forever) for the next line of
output. Signals if the process has already exited with nothing left to
read, or if the timeout elapses first.

```apl
:Trap 999
    2 Shell.Receive h
    ⎕←'FAIL: expected a timeout signal'
:Else
    ⎕←'timeout signaled ok: ',⎕DM
:EndTrap
```
(`test/03-lifecycle-edge-cases.apls`)

### `{r}←Stop h`

Closes stdin, waits (up to ~10s) for the child to exit, releases the
handle's token range. Safe to call more than once.

```apl
Shell.Stop h
⎕←'status after first stop=',h.Status
Shell.Stop h ⍝ must be safe to call twice
⎕←'status after second stop=',h.Status
```
(`test/03-lifecycle-edge-cases.apls`)

---

## `JsonRpc` — minimal JSON-RPC 2.0 over `Shell`

Adds request/response correlation and message shape on top of `Shell`.
v1 allows exactly one in-flight `Call` per handle (ADR D7). Source:
`src/JsonRpc.dyalog`.

**Handle fields** (in addition to the `Shell` handle it wraps, at
`h.Shell`): `NextId`, `Timeout` (seconds; default `10`),
`Notifications` (queue of parsed messages that arrived but weren't the
awaited response — see ADR D7).

### `h←{opts}Connect cmd`

`Shell.Start cmd`, plus JSON-RPC bookkeeping. `opts` may set
`WorkingDir` (forwarded to `Shell.Start`) and `Timeout`.

```apl
exe←'C:\Users\stf\AppData\Local\fff-mcp\bin\fff-mcp.exe'
opts←⎕NS''
opts.WorkingDir←'D:\devel\mcp-client'
h←opts JsonRpc.Connect,⊂exe
```
(`test/04-jsonrpc-roundtrip.apls`)

### `{r}←Disconnect h`

`Shell.Stop h.Shell`.

```apl
JsonRpc.Disconnect h
```
(`test/04-jsonrpc-roundtrip.apls`)

### `resp←h Call args`

`args` is a method name (character vector) or a `(method params)`
pair. Sends a request with a fresh id, blocks (up to `h.Timeout`
seconds) for the matching response, returns it as a parsed namespace.
A JSON-RPC `error` response comes back as ordinary data (ADR D6) — it's
your job to check `resp.error`/`resp.result`, this never signals for a
protocol-legal error response.

```apl
r1←h JsonRpc.Call('initialize'(protocolVersion:'2025-06-18' ⋄ capabilities:() ⋄ clientInfo:(name:'x' ⋄ version:'0')))
⎕←'init ok: ',r1.result.serverInfo.name,' (id=',(⍕r1.id),')'

r2←h JsonRpc.Call'tools/list'
⎕←'tools: ',⍕r2.result.tools.name,' (id=',(⍕r2.id),')'

⍝ Unknown method must come back as an ordinary JSON-RPC error response,
⍝ not a signaled fault (ADR D6).
r4←h JsonRpc.Call'not/a/real/method'
⎕←'unknown method -> has error field: ',⍕0≠⎕NC'r4.error'
⎕←'  error.code=',⍕r4.error.code
```
(`test/04-jsonrpc-roundtrip.apls`)

### `{r}←h Notify args`

Same `args` shape as `Call`, but sends a notification (no id) and
doesn't wait for a response.

```apl
h JsonRpc.Notify'notifications/initialized'
```
(`test/04-jsonrpc-roundtrip.apls`)

---

## `Mcp` — MCP protocol semantics over `JsonRpc`

Performs the `initialize`/`notifications/initialized` handshake and
exposes `tools/list`/`tools/call`. Scope is deliberately narrow (ADR
D8) — resources, prompts, sampling, roots, pagination, and
`list_changed` notifications aren't implemented. Source: `src/Mcp.dyalog`.

**Handle fields** (in addition to the `JsonRpc` handle it wraps, at
`h.JsonRpc`): `ServerInfo` (`{name, version}`), `ServerCapabilities`.

### `h←{opts}Connect cmd`

`JsonRpc.Connect cmd`, then performs the `initialize` handshake with a
fixed `clientInfo` (`name:'dyalog-mcp-client' version:'0.1.0'`) and
empty `capabilities`. Signals if the server rejects `initialize`.

```apl
exe←'C:\Users\stf\AppData\Local\fff-mcp\bin\fff-mcp.exe'
opts←⎕NS''
opts.WorkingDir←'D:\devel\mcp-client'
h←opts Mcp.Connect,⊂exe
⎕←'connected to ',h.ServerInfo.name,' ',h.ServerInfo.version
```
(`test/05-mcp-roundtrip.apls`)

### `{r}←Disconnect h`

`JsonRpc.Disconnect h.JsonRpc`.

```apl
Mcp.Disconnect h
```
(`test/05-mcp-roundtrip.apls`)

### `tools←ListTools h`

Calls `tools/list`, returns `resp.result.tools`. Signals on a
protocol-level error (no pagination support yet — see `TODO.md`).

```apl
tools←Mcp.ListTools h
⎕←'tools: ',⍕tools.name
```
(`test/05-mcp-roundtrip.apls`)

### `result←h CallTool args`

`args` is a tool name (character vector) or a `(name arguments)` pair.
Calls `tools/call`. A **protocol-level** failure (unknown tool name,
missing/invalid arguments) signals; a tool that ran but failed comes
back as ordinary data — check `result.isError` (when the server sets
it at all: it's optional per spec — see ADR D11 — `fff-mcp` always sets
it, but not every server does).

```apl
result←h Mcp.CallTool('find_files'(query:'Mcp'))
⎕←'call ok, isError=',⍕result.isError

⍝ A required argument missing is an invalid-params JSON-RPC error
⍝ (protocol-level), so it must signal too — not come back as data.
:Trap 999
    h Mcp.CallTool'find_files' ⍝ no query given
    ⎕←'FAIL: expected a signal for missing required arguments'
:Else
    ⎕←'missing-args call signaled ok: ',⎕DM
:EndTrap
```
(`test/05-mcp-roundtrip.apls`)

---

## `Fff` — a cover, specific to fff-mcp

Unlike the three layers above, `Fff` only makes sense for one server:
fff-mcp (tested against v0.10.6). It hardcodes its tool names and
parses its particular text output — see ADR D11/D12/D15 for how that
parser was ground-truthed against fff's own source, and `TODO.md` for
what's still open. Source: `src/Fff.dyalog`.

**Handle fields** (in addition to the `Mcp` handle it wraps, at
`h.Mcp`): `Path` (directory searched), `Exe` (fff-mcp.exe path used).

Every `Find`/`Grep`/`MultiGrep` result carries `Raw` (the untouched
`Mcp.CallTool` result) and `Text` (the extracted content string)
**always**, whatever the parser did or didn't recognize — never lossy.

### `h←{opts}Connect path`

`path` need not be a git repo (fff-mcp works either way, just slower
to index a large non-git tree on a cold process). `opts` may set `Exe`
(fff-mcp.exe path override — default resolved from `%LOCALAPPDATA%`),
`WorkingDir` (defaults to `path`), `Timeout`.

```apl
h←Fff.Connect'D:\devel\mcp-client'
⎕←'connected, exe=',h.Exe
```
(`test/06-fff-cover.apls`)

### `{r}←Disconnect h`

```apl
Fff.Disconnect h
```
(`test/06-fff-cover.apls`)

### `result←h Find args`

`args` is a query (character vector) or a `(query opts)` pair — `opts`
may set `cursor`/`maxResults`. Wraps `find_files`. Result fields:
`Shown`, `Total`, `Cursor` (non-empty when there's another page),
`Suggestion` (the `→ Read ...` hint line, if present), `Paths` (vector
of matched paths).

```apl
r1←h Fff.Find'Shell'
⎕←'find shown=',(⍕r1.Shown),' total=',(⍕r1.Total),' paths=',(⍕≢r1.Paths)
⎕←' first path: ',⊃r1.Paths
```
(`test/06-fff-cover.apls`)

Reading the next page (`maxResults` forces pagination here purely to
demonstrate it — the default page size is 20, big enough that a small
repo like this one usually fits on one page with no cursor at all):

```apl
r1←h Fff.Find('Shell'(maxResults:3))
r1.Cursor                                    ⍝ '1'
r2←h Fff.Find('Shell'(maxResults:3 ⋄ cursor:r1.Cursor))
```
(written fresh for this document, run once against `fff-mcp.exe` in
this repo before being included here)

### `result←h Grep args`

`args` is a query (character vector) or a `(query opts)` pair — `opts`
may set `cursor`/`maxResults`/`context`/`output_mode`. Wraps `grep`.
Result fields, always present regardless of `output_mode` (mode-
specific ones are simply empty when they don't apply — see ADR D15):

- `Shown`, `Total` — for the default mode, the "N/Total matches"
  header (or a count of real matches when there's no header to read).
  For `'files_with_matches'`, the number of files (this mode's text
  never carries a header). For `'count'`, the sum of the per-file
  counts.
- `Cursor` — non-empty when there's another page.
- `Suggestion` — the `→ Read ...` hint line, if present.
- `Broadened` — non-empty (naming the broadened query) when fff-mcp's
  own multi-word auto-retry kicked in (`"0 matches for '<q>'.
  Auto-broadened to '<q2>':"`, emitted when the exact query gets 0
  hits) — `Shown`/`Total`/`Files`/`Counts` describe the broadened
  query's real results in that case, not the always-0 exact-match
  count.
- `SuggestedPath` — non-empty when grep found no content match at all
  but a plausibly-related file path (`"0 content matches. But there
  is a relevant file path: <p>"`); `Shown`/`Total` are `0` and
  `Files`/`Counts` are empty in that case.
- `Files` — populated for the default (`'content'`, i.e. `'usage'`)
  and `'files_with_matches'` modes; empty for `'count'`. A vector of
  `(Path Matches)` namespaces (`'files_with_matches'` entries also
  carry `IsDef`, a Boolean — that mode is the only one where a path
  line can genuinely carry a `[def]` tag). Each `Matches` is a vector
  of `(LineNum Text Kind)` namespaces — `Kind` is `'Match'` (a real
  hit, `" N: text"`, or, in `'files_with_matches'`, a `"  N: text"`
  preview line), `'Context'` (an explicit `context:N` line,
  `" N-text"`), or `'DefContext'` (fff auto-expanding a definition's
  body, `"  N| text"` — this can appear even without `context` set,
  whenever a hit is itself a definition).
- `Counts` — populated only for `'count'` mode: a vector of
  `(Path Count)` namespaces, one per file, no per-line `Matches` at
  all (that mode's text never carries individual lines).

```apl
r2←h Fff.Grep('Namespace'(maxResults:5))
⎕←'grep shown=',(⍕r2.Shown),' total=',(⍕r2.Total),' files=',(⍕≢r2.Files)
:If 0≠≢r2.Files
    f←⊃r2.Files
    ⎕←' first file: ',f.Path,' (',(⍕≢f.Matches),' matches)'
    :If 0≠≢f.Matches
        m←⊃f.Matches
        ⎕←'  [',m.Kind,'] line ',(⍕m.LineNum),': ',m.Text
    :EndIf
:EndIf
```
(adapted from `test/06-fff-cover.apls` to also print `Kind`; run once
against `fff-mcp.exe` in this repo before being included here — see
`test/07-fff-parser-groundtruth.apls` for a dedicated `Kind` check)

A zero-hit query parses cleanly to empty results, not a crash:

```apl
r4←h Fff.Grep⌽'zzz_reifitnedi_hcus_on_zzz' ⍝ reversed so the literal
                                             ⍝ word never appears here
⎕←'no-hit grep shown=',(⍕r4.Shown),' total=',(⍕r4.Total),' files=',(⍕≢r4.Files),' text=[',r4.Text,']'
```
(`test/06-fff-cover.apls`)

`output_mode` picks which of `Files`/`Counts` gets populated:

```apl
r5←h Fff.Grep('Namespace'(maxResults:5 ⋄ output_mode:'files_with_matches'))
⎕←'files_with_matches: shown=',(⍕r5.Shown),' files=',⍕≢r5.Files
:If 0≠≢r5.Files
    f←⊃r5.Files
    ⎕←' first file: ',f.Path,' isDef=',⍕f.IsDef
:EndIf

r6←h Fff.Grep('Namespace'(maxResults:5 ⋄ output_mode:'count'))
⎕←'count: shown=',(⍕r6.Shown),' counts=',⍕≢r6.Counts
:If 0≠≢r6.Counts
    c←⊃r6.Counts
    ⎕←' first count: ',c.Path,' = ',⍕c.Count
:EndIf
```
(adapted from `test/10-fff-parser-extended.apls`; run once against
`fff-mcp.exe` in this repo before being included here)

### `result←h MultiGrep args`

`args` is a vector of pattern character vectors, or
`(patterns opts)` — same optional fields as `Grep`. Wraps `multi_grep`
(OR logic across patterns). Same result shape as `Grep`.

```apl
r3←h Fff.MultiGrep(('Namespace' 'Connect')(maxResults:5))
⎕←'multi_grep shown=',(⍕r3.Shown),' total=',(⍕r3.Total),' files=',(⍕≢r3.Files)
```
(`test/06-fff-cover.apls`)

---

## `JsonRpcCl` — JSON-RPC 2.0 over Content-Length framing

A second, self-contained JSON-RPC layer, independent of `Shell` —
speaks the Content-Length-header framing LSP/DAP and most other stdio
JSON-RPC servers use (as opposed to `JsonRpc`'s newline-delimited
framing, which MCP uses). Same verb shape as `JsonRpc`
(`Connect`/`Disconnect`/`Call`/`Notify`), same v1 scope (one in-flight
`Call` per handle — ADR D7's reasoning applies here too), same
error-handling split (ADR D6: a JSON-RPC error response is ordinary
data; transport/protocol faults signal). Source: `src/JsonRpcCl.dyalog`.

**Handle fields**: `Cmd`, `WorkingDir`, `Buffer` (partially-received
data, not yet a complete message), `Messages` (queue of complete
messages received but not yet consumed), `Status`, `ExitCode`,
`ExitReason`, `Pid`, `NextId`, `Timeout` (default `10`),
`Notifications`.

### `h←{opts}Connect cmd`

```apl
h←JsonRpcCl.Connect'python' 'D:\devel\mcp-client\examples\toy-jsonrpc-cl-server.py'
```
(`test/08-jsonrpccl-toy-server.apls`)

### `{r}←Disconnect h`

```apl
JsonRpcCl.Disconnect h
```
(`test/08-jsonrpccl-toy-server.apls`)

### `resp←h Call args`

Same `args` shape and semantics as `JsonRpc.Call`.

```apl
r1←h JsonRpcCl.Call('echo'(text:'hello'))
⎕←'echo -> ',r1.result

r2←h JsonRpcCl.Call('add'(a:3 ⋄ b:4))
⎕←'add -> ',⍕r2.result

⍝ Unknown method -> ordinary JSON-RPC error response, not a signal.
r3←h JsonRpcCl.Call'not/a/real/method'
⎕←'unknown method -> has error field: ',⍕0≠⎕NC'r3.error'
```
(`test/08-jsonrpccl-toy-server.apls`)

A timeout signals, same as `JsonRpc`/`Shell`:

```apl
h.Timeout←2
:Trap 999
    h JsonRpcCl.Call('sleep'(seconds:5))
    ⎕←'FAIL: expected timeout'
:Else
    ⎕←'sleep timeout signaled ok: ',⎕DM
:EndTrap
```
(`test/08-jsonrpccl-toy-server.apls`)

### `{r}←h Notify args`

Same `args` shape as `Call`; sends a notification (no id), doesn't
wait for a response. See `JsonRpc.Notify` — identical semantics.

---

## `Lsp` — a minimal LSP cover over `JsonRpcCl`

A cover, in the `Fff`/`Mcp` sense, but general-purpose rather than
server-specific — it implements LSP semantics, not a particular
language server's quirks, so it should work against any spec-
compliant LSP server, the same way `Mcp` works against any MCP server.
Verified against `pyright-langserver`. v1 scope is deliberately narrow
(same spirit as `Mcp`'s, ADR D8): the `initialize`/`initialized`
handshake, `shutdown`/`exit`, `textDocument/didOpen`,
`textDocument/hover`. See ADR D16 and `TODO.md` for what's not
implemented. Source: `src/Lsp.dyalog`.

**Handle fields** (in addition to the `JsonRpcCl` handle it wraps, at
`h.JsonRpcCl`): `ServerCapabilities`, `ServerInfo` (only present if the
server actually sent one — unlike MCP, LSP doesn't require it, and
`pyright-langserver` doesn't send it).

### `h←{opts}Connect cmd`

Connects via `JsonRpcCl.Connect`, then performs the `initialize`
request (`processId`/`rootUri` sent as JSON `null` — `⊂'null'`,
ADR D11/D13/D16 — `capabilities` an empty object; verified this is
enough for `pyright-langserver` to answer usefully) followed by the
`initialized` notification (LSP's analogue of MCP's
`notifications/initialized`, but named just `'initialized'`, with an
*empty params object*, not no params at all — pyright doesn't respond
usefully to later requests without it). Signals if the server rejects
`initialize`.

```apl
opts←(Timeout:90)
h←opts Lsp.Connect'cmd.exe' '/C' 'npx' '-y' '-p' 'pyright' 'pyright-langserver' '--stdio'
⎕←'connected, capabilities: ',⍕h.ServerCapabilities.⎕NL ¯2
```
(`test/11-lsp-cover.apls`)

### `{r}←Disconnect h`

Performs LSP's clean-shutdown convention — a `shutdown` request, then
an `exit` notification — before falling through to
`JsonRpcCl.Disconnect`'s own stdin-close/wait behavior (kept
unconditionally, in case a server doesn't honor `exit`).

```apl
Lsp.Disconnect h
⎕←'status after disconnect=',h.JsonRpcCl.Status
```
(`test/11-lsp-cover.apls`)

### `{r}←h DidOpen args`

`args` is `(uri text)` or `(uri text languageId)` (`languageId`
defaults to `'python'`). Wraps `textDocument/didOpen` — a notification,
no response. Per spec, `text` is authoritative regardless of what's on
disk at `uri`; confirmed against pyright (`uri` need not name a file
that exists at all for hover to work off `text`), but the committed
test still opens a real file, for a realistic worked example.

```apl
h Lsp.DidOpen(uri text 'python')
```
(`test/11-lsp-cover.apls`)

### `result←h Hover args`

`args` is `(uri line character)` — `line`/`character` are LSP's own
0-based position convention (unrelated to `⎕IO`). Wraps
`textDocument/hover`. A **protocol-level** error signals; a
legitimate "nothing to say about this position" is JSON `null`,
returned as ordinary data — LSP's version of the isError-vs-fault
distinction ADR D6/D11 made for `Mcp.CallTool`. `⎕JSON` represents
JSON `null` coming *in* the same way it represents `true`/`false`
coming in — as `⊂'null'`, an enclosed character vector, confirmed
empirically (ADR D16) — so check for it with `result≡⊂'null'`, not
by looking for an absent field.

```apl
r←h Lsp.Hover(uri 2 4)
⎕←'hover result: ',r.contents.value

r2←h Lsp.Hover(uri 1 0)
⎕←'no-hover-info result is JSON null: ',⍕r2≡⊂'null'
```
(`test/11-lsp-cover.apls`)
