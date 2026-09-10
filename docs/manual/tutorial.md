# Tutorial

A single worked walkthrough, run top-to-bottom, building understanding
in order rather than being looked up by topic — that's what the
[Reference](reference.md) is for. Read this once; come back to the
Reference afterward.

We'll go bottom-up through the layers, against several different real
processes, on purpose: it's the only way to actually show which parts of
this client are general-purpose (`Shell`, `JsonRpc`, `Mcp` — see
**Layer** in [`CONTEXT.md`](../../CONTEXT.md)) and which part is
specific to one server (`Fff` — a **Cover**). One of those processes
isn't a server at all, and doesn't speak JSON: step 1b drives `sqlite3`,
which is the shortest way to show that the bottom layer genuinely
doesn't care what the lines mean.

## Prerequisites

- Dyalog APL 20.0+.
- `fff-mcp.exe` installed (see its own docs) — used in the last step.
- Python 3 on your `PATH` — used for a small toy server in step 2.
- Node.js with `npx` on your `PATH` — used for a second real MCP
  server in step 3.
- `sqlite3` on your `PATH` — used in step 1b. Any line-oriented
  interpreter would do; `duckdb` or `python` work the same way.

Bootstrap once, at the start of any session:

```apl
⎕FIX'file://D:/devel/mcp-client/src/Shell.dyalog'
⎕FIX'file://D:/devel/mcp-client/src/JsonRpc.dyalog'
⎕FIX'file://D:/devel/mcp-client/src/Mcp.dyalog'
⎕FIX'file://D:/devel/mcp-client/src/Fff.dyalog'
```

(adjust the path if your checkout isn't at `D:/devel/mcp-client`; order
matters — each layer references the one before it)

## Step 1 — `Shell`: it's just lines in, lines out

`Shell` doesn't know what JSON-RPC or MCP are. It starts a process,
lets you push it a line of text, and lets you read back whatever line
it produces — nothing more. To see that in isolation, let's talk to
`fff-mcp.exe` at the lowest level, by hand-typing one raw protocol
message:

```apl
exe←'C:\Users\stf\AppData\Local\fff-mcp\bin\fff-mcp.exe'
opts←⎕NS''
opts.WorkingDir←'D:\devel\mcp-client'
h←opts Shell.Start,⊂exe

req←(jsonrpc:'2.0' ⋄ id:1 ⋄ method:'initialize' ⋄ params:(
  protocolVersion:'2025-06-18'
  capabilities:()
  clientInfo:(name:'dyalog-mcp-client' ⋄ version:'0.1.0')
))
h Shell.Send ⎕JSON req
resp←10 Shell.Receive h
⎕←resp                    ⍝ one line of raw JSON text, nothing parsed
Shell.Stop h
```

`Shell.Stop` closes the child's stdin and waits for it to exit — and
force-kills it if it doesn't. Almost every server treats EOF on stdin
as "shut down" and goes quietly; one that blocks in a wait with no
timeout never notices, and would otherwise outlive the interpreter as
an orphan. `h.Killed` afterwards tells you which of the two you were
dealing with. You don't normally need to care, which is the point, but
it's worth knowing the handle can tell you (see Reference, and ADR
D18 for the trouble that orphan actually caused).

Notice: `Shell` handed us back *text*. It has no idea it's JSON, let
alone MCP. That's the whole point of this layer — it would work
exactly the same way talking to something that speaks CSV lines, or
plain log output, or anything else line-oriented. Everything from here
on is built *on top of* this, not instead of it.

## Step 1b — still `Shell`: talking SQL to `sqlite3`

That last paragraph is easy to write and easy to disbelieve, so here it
is actually done. `sqlite3 -batch` reads SQL from stdin and writes
result rows to stdout, one row per line, with no prompt and no banner —
which makes it a perfectly ordinary peer for this layer, and gives you
a SQL database from APL with no driver, no `⎕NA`, and no DLL.

```apl
h←(CaptureStderr:1)Shell.Start'sqlite3' '-batch'
h Shell.Send'.mode list'
h Shell.Send'.separator |'
h Shell.Send'create table t(id integer, name text);'
h Shell.Send'insert into t values (1,''alpha''),(2,''beta''),(3,''gamma'');'
```

Now ask it something. One `Send` produces *three* lines back — and
nothing in the stream says so. This is the part JSON-RPC's `id` field
does for you later and nobody does for you here, so you need a
convention of your own; a sentinel row is the simplest one that works:

```apl
h Shell.Send'select id, name from t order by id;'
h Shell.Send'select ''<<end>>'';'
:Repeat
    line←5 Shell.Receive h
    ⎕←line
:Until line≡'<<end>>'
```
```
1|alpha
2|beta
3|gamma
<<end>>
```

Worth sitting with for a second: `Shell.Receive` gave you exactly what
you asked for and not one line more. Knowing that an answer has *ended*
is not a transport problem, it's a protocol problem — and inventing a
sentinel here is precisely the itch that `JsonRpc` scratches in the next
step. Everything after this point in the Tutorial exists because
`<<end>>` is a bad answer to a real question.

Now break something on purpose:

```apl
h Shell.Send'select * from no_such_table;'
h Shell.Send'select ''<<end>>'';'
:Repeat ⋄ line←5 Shell.Receive h ⋄ :Until line≡'<<end>>'
⎕←h.StderrLines
```
```
 Parse error near line 7: no such table: no_such_table
```

The result stream stayed clean — the only thing on stdout was the
sentinel — because `sqlite3` writes its errors to **stderr**, exactly as
ADR D5 assumed a well-behaved child process would. `Shell` discards that
stream by default, which is right for keeping the protocol stream
uncorrupted and *wrong* the moment you actually want to know why a query
returned nothing: without `CaptureStderr:1`, a failed query and an empty
result look identical from up here. This is what that option is for.

The session also survives the error — the connection is still good:

```apl
h Shell.Send'select count(*), max(name) from t;'
⎕←5 Shell.Receive h     ⍝ 3|gamma
Shell.Stop h
```

(`sqlite3` isn't special here. `duckdb -noheader -list` behaves
identically, and so does `python -u -i -q` — Python puts its `>>>`
prompts on stderr too, so `print(2+2)` comes back as a bare `4`. The
`-u` matters: without it Python block-buffers stdout once it isn't a
terminal and you'd wait forever. See `examples/sqlite-repl.apls`, and
`test/15-shell-sqlite-repl.apls` for the same thing with assertions.)

## Step 2 — `JsonRpc`: request/response, against something that isn't MCP

Here's an uncomfortable fact that came up researching this Tutorial:
outside of MCP, essentially nothing well-known speaks JSON-RPC over
stdio the way `Shell`/`JsonRpc` expect — one JSON object per line,
newline-delimited. The rest of the stdio-JSON-RPC world (language
servers, debug adapters, ...) uses Content-Length-header framing
instead (see `TODO.md`'s Transport section — a sibling layer for that
framing is a plausible future addition, not built yet). So to prove
`JsonRpc` is genuinely protocol-generic and not secretly MCP-shaped,
we're using a tiny purpose-built toy server:
[`examples/toy-jsonrpc-server.py`](../../examples/toy-jsonrpc-server.py)
— a few dozen lines, three methods (`echo`, `add`, `sleep`), no MCP
concepts anywhere in it.

```apl
h←JsonRpc.Connect'python' 'D:\devel\mcp-client\examples\toy-jsonrpc-server.py'

r1←h JsonRpc.Call('echo'(text:'hello'))
⎕←'echo -> ',r1.result

r2←h JsonRpc.Call('add'(a:3 ⋄ b:4))
⎕←'add -> ',⍕r2.result
```
```
echo -> hello
add -> 7
```

Now let's deliberately break it, to see `JsonRpc.Call`'s timeout
signal — `sleep` really sleeps server-side, longer than we're willing
to wait:

```apl
h.Timeout←2
:Trap 999
    h JsonRpc.Call('sleep'(seconds:5))
    ⎕←'FAIL: expected timeout'
:Else
    ⎕←'sleep timeout signaled ok: ',⎕DMX.(EM,': ',Message)
:EndTrap

JsonRpc.Disconnect h
```
```
sleep timeout signaled ok:  Shell.Receive: timed out waiting for output ...
```

Two things worth noticing:
- `Call`'s response is a parsed *namespace* (`r1.result`, not raw
  text) — `JsonRpc` did the JSON round trip for us, `Shell` still has
  no idea any of this happened.
- The timeout signal actually comes from `Shell.Receive`, one layer
  down — `JsonRpc` doesn't reimplement timeout handling, it just
  passes `h.Timeout` through to the layer that already has it (ADR D1).

## Step 3 — `Mcp`: the handshake, against a second real MCP server

Time to add MCP semantics, and to prove `Mcp` isn't secretly
`fff-mcp`-shaped either. `@modelcontextprotocol/server-memory` is an
official, zero-setup MCP server — no accounts, no network, just a
little knowledge-graph store it persists to a local file:

```apl
opts←(Timeout:60)
h←opts Mcp.Connect'cmd.exe' '/C' 'npx' '-y' '@modelcontextprotocol/server-memory'
⎕←'connected to ',h.ServerInfo.name,' ',h.ServerInfo.version
```
```
connected to memory-server 0.6.3
```

(`cmd.exe /C` is there because `npx` on Windows is a `.cmd` shim —
`⎕SHELL`'s direct-execution mode can't launch one on its own, so we
route through `cmd.exe` as the direct-executed program instead. See
`docs/adr/0001-architecture-decisions.md` D11's comment in
`Shell._Run` for the related stderr-handling gotcha this same server
surfaced.)

`Mcp.Connect` already did the `initialize`/`notifications/initialized`
handshake for us — by the time we get a handle back, the server's
ready. Let's list its tools and use a couple:

```apl
tools←Mcp.ListTools h
⎕←'tools: ',⍕tools.name

entities←,⊂(name:'APL' ⋄ entityType:'language' ⋄ observations:(,⊂'Iverson notation descendant'))
r←h Mcp.CallTool('create_entities'(entities:entities))

r2←h Mcp.CallTool('search_nodes'(query:'APL'))
⎕←(⊃r2.content).text
```
```
tools:  create_entities  create_relations  add_observations  delete_entities  delete_observations  delete_relations  read_graph  search_nodes  open_nodes 
{
  "entities": [
    {
      "name": "APL",
      "entityType": "language",
      "observations": [
        "Iverson notation descendant"
      ]
    }
  ],
  "relations": []
}
```

That's real cross-call state: `create_entities` wrote something,
`search_nodes` found it back, and the server would still remember it
if we disconnected and reconnected (it's on disk).

One nuance this server exposes that `fff-mcp` doesn't: try
`r.isError` after `create_entities` above, and you'll get a
`VALUE ERROR` — this server simply omits `isError` on success, rather
than setting it `false`. That's spec-legal (`isError` is optional,
only required when true); code driving `Mcp` directly against an
arbitrary server should check `0≠⎕NC'result.isError'` before reading
it. (`Fff`, next, gets away without that check only because it's
scoped to one server that does always set it.)

```apl
Mcp.Disconnect h
```

## Step 4 — `Fff`: what a cover buys you

Everything above is protocol-generic — the same three layers work
against a toy script and an official reference server without change.
`Fff` is the opposite: it exists *only* because `fff-mcp` exists, and
it hardcodes exactly what that one server needs. Here's the same kind
of thing we did by hand in Step 1 and Step 3 — connect, call a tool —
but with the text response actually turned into data:

```apl
h←Fff.Connect'D:\devel\mcp-client'

r←h Fff.Grep'*.dyalog Namespace' ⍝ *.dyalog: only source, not docs —
                                  ⍝ keeps this example's numbers stable
                                  ⍝ regardless of how much prose exists
⎕←'shown=',(⍕r.Shown),' total=',(⍕r.Total),' files=',(⍕≢r.Files)
f←⊃r.Files
⎕←f.Path,' — ',(⍕≢f.Matches),' matches'
m←⊃f.Matches
⎕←'  line ',(⍕m.LineNum),': ',m.Text
```
```
shown=8 total=8 files=4
src/Fff.dyalog — 2 matches
  line 1: :Namespace Fff
```

Compare that to Step 1: there, `resp` was one opaque line of JSON text
you'd have had to pick apart by hand. Here, `r.Files[1].Matches[1].LineNum`
is just a number. That's the entire value proposition of a cover —
`Mcp`/`JsonRpc`/`Shell` gave us a working *connection*; `Fff` gives us
working *data*, at the cost of only working for this one server.

```apl
Fff.Disconnect h
```

## Step 5 — `JsonRpcCl`: the other transport, against a real language server

Every server so far — the toy script, `server-memory`, `fff-mcp` —
speaks the same wire format: one JSON object per line. That's MCP's
framing, and it's what `Shell`/`JsonRpc`/`Mcp`/`Fff` are all built on
(ADR D5). It is, however, the *unusual* choice outside MCP —
Content-Length-header framing (a `"Content-Length: N\r\n\r\n"` prefix,
then exactly `N` bytes of JSON) is what LSP, DAP, and most other stdio
JSON-RPC servers actually use. `JsonRpcCl` speaks that framing instead,
and is otherwise independent of everything above — it doesn't build on
`Shell` at all (see ADR D13 for why: a byte-counted body needs raw
bytes, not `Shell`'s line-split text).

To see it against something with real substance, not just a toy
script, this step drives `pyright`'s language server directly — no
project to open, just enough of LSP's `initialize` handshake to prove
the transport:

```apl
⎕FIX'file://D:/devel/mcp-client/src/JsonRpcCl.dyalog'

opts←(Timeout:60)
h←opts JsonRpcCl.Connect'cmd.exe' '/C' 'npx' '-y' '-p' 'pyright' 'pyright-langserver' '--stdio'
```

(`cmd.exe /C` again, for the same reason as `server-memory` in Step 3
— `npx` is a `.cmd` shim on Windows. The `-p pyright` matters too:
`pyright-langserver` is a bin *inside* the `pyright` npm package, not
a package of its own — a bare `npx -y pyright-langserver` 404s.)

```apl
params←(processId:⊂'null' ⋄ rootUri:⊂'null' ⋄ capabilities:())
r←h JsonRpcCl.Call('initialize' params)
⎕←'server capabilities: ',⍕r.result.capabilities.⎕NL ¯2
```
```
server capabilities:  callHierarchyProvider  textDocumentSync 
```

(`⊂'null'` is how a JSON `null` is written on the way *out*, same as
`⎕JSON` gives you `⊂'true'`/`⊂'false'` coming *in* — see ADR D11.)

A real language server, unlike our three MCP-family test servers,
talks back before you ask it anything — startup log messages arrive as
unsolicited notifications, interleaved with the response to
`initialize`. `JsonRpcCl` handles that exactly like `JsonRpc` does:
anything that isn't the awaited response lands in `h.Notifications`
rather than derailing the call.

```apl
h JsonRpcCl.Notify'initialized'
⎕←'queued notifications so far: ',⍕≢h.Notifications
:For n :In h.Notifications
    ⎕←' ',n.method
:EndFor
```
```
queued notifications so far: 2
 window/logMessage
 window/logMessage
```

```apl
JsonRpcCl.Disconnect h
```

That's the point of Step 5: nothing about `JsonRpcCl`'s API differs
from `JsonRpc`'s (`Connect`/`Call`/`Notify`/`Disconnect`, the same
`Notifications` queue, the same error/signal split), only the framing
underneath — and a real, unrelated piece of tooling (a Python language
server, nothing to do with MCP or fff) just worked against it.

## Step 6 — `Lsp`: a minimal cover, actually asking pyright something

Step 5 only proved `JsonRpcCl` could talk to `pyright-langserver` at
all — a hand-rolled `initialize` call, nothing turned into a real
answer. `Lsp` (ADR D16) is a small cover on top, the same shape as
`Mcp` is on top of `JsonRpc`, that does the full handshake and can
actually ask pyright about some code:

```apl
⎕FIX'file://D:/devel/mcp-client/src/Lsp.dyalog'

opts←(Timeout:90)
h←opts Lsp.Connect'cmd.exe' '/C' 'npx' '-y' '-p' 'pyright' 'pyright-langserver' '--stdio'
⎕←'capabilities: ',⍕h.ServerCapabilities.⎕NL ¯2
```
```
capabilities:  callHierarchyProvider  textDocumentSync 
```

`Lsp.Connect` does the handshake `JsonRpcCl.Call` alone can't: besides
`initialize`, LSP also requires an `initialized` *notification*
(empty params, not no params) before a server will do anything useful
with later requests — easy to miss, since nothing in the `initialize`
response itself says so.

With a handle in hand, open a real file's text — the file at `uri`
need not even exist on disk; LSP's `text` is authoritative — and ask
for hover info at a position (0-based, LSP's own convention):

```apl
uri←'file:///D:/devel/mcp-client/examples/hover-fixture.py'
text←'import os',(⎕UCS 10),(⎕UCS 10),'os.getcwd()',(⎕UCS 10)
h Lsp.DidOpen(uri text 'python')

r←h Lsp.Hover(uri 2 4)
⎕←'hover: ',r.contents.value
```
```
hover: (function) def getcwd() -> str
```

A position with nothing to say comes back as JSON `null` — ordinary
data, not a fault, same reasoning as `Mcp.CallTool`'s `isError` split
(ADR D6/D11):

```apl
r2←h Lsp.Hover(uri 1 0)
⎕←'no info here -> null: ',⍕r2≡⊂'null'
```
```
no info here -> null: 1
```

```apl
Lsp.Disconnect h
```

That's the whole of `Lsp`'s v1 scope — see `docs/adr/0001-architecture-
decisions.md`'s D16 and `TODO.md` for what it deliberately doesn't do
yet (diagnostics, completion, definition, and everything else LSP
defines beyond hover).

## Where to go next

- [Reference](reference.md) — every verb, looked up by layer.
- `docs/adr/0001-architecture-decisions.md` — why each of these design
  choices was made, including several things this Tutorial glossed
  over (the token-based synchronization inside `Shell`, why `Fff`'s
  parser is deliberately best-effort, the stderr-callback gotcha
  mentioned above, the `⎕SHELL` variant quirks `JsonRpcCl` hit along
  the way, and the LSP handshake/`null`-result specifics `Lsp` hit).
- `TODO.md` — what's explicitly not built yet, including the rest of
  LSP beyond `Lsp`'s narrow v1 scope.
- `examples/sqlite-repl.apls` — step 1b written out in full, with a
  couple of substitutions (`duckdb`, `python -u -i -q`) if you want to
  point `Shell` at something else line-oriented. ADR D20 records which
  interpreters were tried and why two of them didn't make the cut,
  which is the more useful half of that exercise.
