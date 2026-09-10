# mcp-client (Dyalog APL)

An MCP client written in and for Dyalog APL, built in four layers over
`⎕SHELL`: a bidirectional stdio process wrapper (`Shell`), a minimal
JSON-RPC 2.0 layer (`JsonRpc`), MCP protocol semantics (`Mcp`), and a
high-level cover for one particular server (`Fff`, for
[`fff-mcp`](https://github.com/dmtrKovalenko/fff)). Targets stdio-based
MCP servers generally — `Fff` is the exception, deliberately specific
to one server; see [`CONTEXT.md`](CONTEXT.md) for that distinction.

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
`JsonRpc`, `Mcp`, `Fff`) — see the Tutorial's bootstrap step.

## Testing

Tests are `dyalogscript`-driven `.apls` files under `test/`, run against
the real `fff-mcp.exe` binary with this repo as the working directory
(a plain directory works fine too — fff-mcp doesn't require git, just
indexes slower cold on a large non-git tree):

```powershell
& <path-to-dyalog>\scriptbin\dyalogscript.ps1 test\01-initialize-handshake.apls
```

See `examples/` for a large-tree demo script and the toy JSON-RPC
server used in the Tutorial.

## License

[Unlicense](LICENSE) — public domain.
