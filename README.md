# mcp-client (Dyalog APL)

An MCP client written in and for Dyalog APL, built in three layers over
`⎕SHELL`: a bidirectional stdio process wrapper (`Shell`), a minimal
JSON-RPC 2.0 layer, and MCP protocol semantics on top. Targets stdio-based
MCP servers; developed and tested against
[`fff-mcp`](https://github.com/dmtrKovalenko/fff).

- **[PLAN.md](PLAN.md)** — the phased build plan and current status.
- **[docs/adr/0001-architecture-decisions.md](docs/adr/0001-architecture-decisions.md)**
  — the key design decisions and why.
- **[TODO.md](TODO.md)** — what's deliberately deferred past v1.

## Requirements

- Dyalog APL 20.0+ (for `⎕SHELL`, `⎕TALLOC`, and array notation).

## Loading

```
dyalog +s mcp-client.dyapp
```

## Testing

Tests are `dyalogscript`-driven `.apls` files under `test/`, run against
the real `fff-mcp.exe` binary with this repo as the working directory
(fff-mcp requires a git-indexed directory):

```powershell
& <path-to-dyalog>\scriptbin\dyalogscript.ps1 test\01-initialize-handshake.apls
```
