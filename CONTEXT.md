# Glossary

Terms used consistently across this project's code, comments, and docs.
This file is vocabulary only — no implementation detail, no rationale
(that belongs in `docs/adr/`) and no task tracking (that belongs in
`PLAN.md`/`TODO.md`).

**Handle** — the opaque data namespace a layer's `Start`/`Connect`
returns, representing one live resource (a running child process, an
open JSON-RPC session, an initialized MCP session, an `Fff` session).
A handle holds only data fields, never function references — behavior
always lives in the owning namespace's functions, which take the
handle as an argument (conventionally the left argument). See ADR D2/D3.

**Layer** — one of `Shell`, `JsonRpc`, `Mcp`: general-purpose, in the
sense that each would work against *any* conforming peer of the kind
it targets (any child process for `Shell`, any newline-delimited
JSON-RPC 2.0 peer for `JsonRpc`, any stdio MCP server for `Mcp`) — not
just the one this project happens to test against.

**Cover** — a namespace built on top of the layers, specific to one
particular server. `Fff` is a cover: it only makes sense for fff-mcp,
hardcodes its tool names (`find_files`/`grep`/`multi_grep`), and parses
its particular version's text output. A cover is not a layer — it
doesn't generalize, and isn't expected to.

**Manual** — the project's user-facing documentation: how to *use* the
client. Deliberately distinct from `PLAN.md`/`docs/adr/`/`TODO.md`,
which are contributor-facing (why it's built this way, what's next).
Lives under `docs/manual/`, linked from `README.md`.

**Reference** (part of the Manual) — exhaustive, task-agnostic:
every public verb of every layer/cover, its signature, and a working
example. Scoped to public verbs only (no leading underscore) — see the
Internals Guide entry in `TODO.md` for where the rest would go.

**Tutorial** (part of the Manual) — one worked narrative, run
top-to-bottom against real servers, building understanding in order
rather than being looked up by topic.
