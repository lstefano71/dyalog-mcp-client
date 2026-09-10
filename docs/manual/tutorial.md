# Tutorial

A single worked walkthrough, run top-to-bottom, building understanding
in order rather than being looked up by topic — that's what the
[Reference](reference.md) is for. Read this once; come back to the
Reference afterward.

We'll go bottom-up through all four layers, against three different
real processes, on purpose: it's the only way to actually show which
parts of this client are general-purpose (`Shell`, `JsonRpc`, `Mcp` —
see **Layer** in [`CONTEXT.md`](../../CONTEXT.md)) and which part is
specific to one server (`Fff` — a **Cover**).

## Prerequisites

- Dyalog APL 20.0+.
- `fff-mcp.exe` installed (see its own docs) — used in the last step.
- Python 3 on your `PATH` — used for a small toy server in step 2.
- Node.js with `npx` on your `PATH` — used for a second real MCP
  server in step 3.

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

Notice: `Shell` handed us back *text*. It has no idea it's JSON, let
alone MCP. That's the whole point of this layer — it would work
exactly the same way talking to something that speaks CSV lines, or
plain log output, or anything else line-oriented. Everything from here
on is built *on top of* this, not instead of it.

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
    ⎕←'sleep timeout signaled ok: ',⎕DM
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

## Where to go next

- [Reference](reference.md) — every verb, looked up by layer.
- `docs/adr/0001-architecture-decisions.md` — why each of these design
  choices was made, including several things this Tutorial glossed
  over (the token-based synchronization inside `Shell`, why `Fff`'s
  parser is deliberately best-effort, the stderr-callback gotcha
  mentioned above, and the `⎕SHELL` variant quirks `JsonRpcCl` hit
  along the way).
- `TODO.md` — what's explicitly not built yet, including a proper
  cover on top of `JsonRpcCl` (Step 5 only proves the transport, the
  way Step 1 does for `Shell` — nothing there turns LSP responses into
  structured data the way `Fff` does for `fff-mcp`).
