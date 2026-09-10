# mcp-client (Dyalog APL)

An MCP client written in and for Dyalog APL, built in layers over
`⎕SHELL`: a bidirectional stdio process wrapper (`Shell`), a minimal
JSON-RPC 2.0 layer over newline-delimited framing (`JsonRpc`), MCP
protocol semantics (`Mcp`), and a high-level cover for one particular
server (`Fff`, for [`fff-mcp`](https://github.com/dmtrKovalenko/fff)).
A second, self-contained JSON-RPC layer, `JsonRpcCl`, speaks
Content-Length-header framing instead — the framing LSP/DAP and most
other stdio JSON-RPC servers use, verified against a real language
server (`pyright-langserver`) as well as MCP-family ones. `Fff` is the
one deliberately server-specific piece — everything else targets
stdio-based JSON-RPC/MCP servers generally; see
[`CONTEXT.md`](CONTEXT.md) for that Layer/Cover distinction.

- **[docs/manual/](docs/manual/)** — the user manual: a
  [Reference](docs/manual/reference.md) (every public verb, every
  layer, with examples) and a [Tutorial](docs/manual/tutorial.md) (one
  worked walkthrough, start to finish).
- **[PLAN.md](PLAN.md)** — the phased build plan and current status.
- **[docs/adr/0001-architecture-decisions.md](docs/adr/0001-architecture-decisions.md)**
  — the key design decisions and why.
- **[TODO.md](TODO.md)** — what's deliberately deferred past v1.
- **[CONTEXT.md](CONTEXT.md)** — the project's vocabulary (Handle,
  Layer, Cover, Manual, Reference, Tutorial).

## Requirements

- Dyalog APL 20.0+ (for `⎕SHELL`, `⎕TALLOC`, and array notation).

## Loading

```
dyalog +s mcp-client.dyapp
```

Or `⎕FIX` the files under `src/` directly, in order (`Shell`,
`JsonRpc`, `Mcp`, `Fff`, `JsonRpcCl`) — see the Tutorial's bootstrap
step. `JsonRpcCl` is independent of the other four (it doesn't build on
`Shell`) and can be `⎕FIX`ed on its own.

## Testing

Tests are `dyalogscript`-driven `.apls` files under `test/`, run against
the real `fff-mcp.exe` binary with this repo as the working directory
(a plain directory works fine too — fff-mcp doesn't require git, just
indexes slower cold on a large non-git tree):

```powershell
& <path-to-dyalog>\scriptbin\dyalogscript.ps1 test\01-initialize-handshake.apls
```

See `examples/` for a large-tree demo script, the toy JSON-RPC servers
used in the Tutorial, and `sqlite-repl.apls` — `Shell` driving `sqlite3`
instead of a JSON-RPC peer, which is the shortest demonstration that the
bottom layer really is protocol-agnostic (and gives you a SQL database
from APL with no driver, no `⎕NA` and no DLL).

## License

[Unlicense](LICENSE) — public domain.
