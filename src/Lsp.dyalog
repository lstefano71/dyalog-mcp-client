:Namespace Lsp
⍝ Minimal LSP (Language Server Protocol) semantics over JsonRpcCl — the
⍝ Content-Length-framed transport (ADR D13), mirroring what Mcp does
⍝ for JsonRpc/MCP (see Mcp.dyalog). v1 scope is deliberately narrow,
⍝ same spirit as Mcp's (ADR D8): the initialize/initialized handshake,
⍝ shutdown/exit, textDocument/didOpen, textDocument/hover. Everything
⍝ else LSP defines (diagnostics push, completion, definition, ...) is
⍝ out of scope until a real use case needs it — see TODO.md.
⍝
⍝ Handle shape (adds to the JsonRpcCl handle it wraps):
⍝   JsonRpcCl             the underlying JsonRpcCl handle (see JsonRpcCl.dyalog)
⍝   ServerCapabilities    the capabilities object the server advertised
⍝                         in its initialize response
⍝   ServerInfo            {name, version} — only present if 0≠⎕NC'.',
⍝                         since unlike MCP this is optional in LSP and
⍝                         pyright-langserver doesn't always send it

    ⎕IO←1 ⋄ ⎕ML←1

    ∇ h←{opts}Connect cmd
      jr←opts #.JsonRpcCl.Connect cmd
      ⍝ Minimal params that work against pyright-langserver, verified
      ⍝ empirically (see docs/adr/0001-architecture-decisions.md D16):
      ⍝ processId/rootUri as JSON null (⊂'null' — this is the OUT
      ⍝ direction, ADR D11/D13), capabilities an empty object. pyright
      ⍝ answers usefully (real ServerCapabilities, hover works) with
      ⍝ nothing more elaborate than this.
      params←(processId:⊂'null' ⋄ rootUri:⊂'null' ⋄ capabilities:())
      resp←jr #.JsonRpcCl.Call('initialize' params)
      :If 0≠⎕NC'resp.error'
          ('Lsp.Connect: server rejected initialize: ',resp.error.message)⎕SIGNAL 999
      :EndIf
      ⍝ Unlike MCP's notifications/initialized, LSP's equivalent is
      ⍝ literally named 'initialized', with an (empty) params object,
      ⍝ not no params at all — both confirmed against the spec and
      ⍝ against pyright (which otherwise never responds usefully to
      ⍝ later requests — see ADR D16).
      jr #.JsonRpcCl.Notify('initialized' ())
      h←(
        JsonRpcCl:jr
        ServerCapabilities:resp.result.capabilities
      )
      :If 0≠⎕NC'resp.result.serverInfo'
          h.ServerInfo←resp.result.serverInfo
      :EndIf
    ∇

    ∇ {r}←Disconnect h
      ⍝ LSP's clean-shutdown convention: a 'shutdown' request (server
      ⍝ must respond with a null result and do no more work), then an
      ⍝ 'exit' notification (no response — the server is expected to
      ⍝ actually terminate itself on receipt). Confirmed against
      ⍝ pyright-langserver: after 'exit', its process exits on its own,
      ⍝ so JsonRpcCl.Disconnect's stdin-close/wait fallback below
      ⍝ mostly just observes the exit rather than causing it — but it
      ⍝ still runs unconditionally, in case a server ignores 'exit'.
      :Trap 999
          {}h.JsonRpcCl #.JsonRpcCl.Call'shutdown'
          h.JsonRpcCl #.JsonRpcCl.Notify'exit'
      :Else
      :EndTrap
      #.JsonRpcCl.Disconnect h.JsonRpcCl
      r←⍬
    ∇

    ∇ {r}←h DidOpen args
      ⍝ args: (uri text) or (uri text languageId) — languageId defaults
      ⍝ to 'python' (the only language server this is verified against
      ⍝ so far; pass it explicitly for anything else). A notification —
      ⍝ no response. Per spec, textDocument/didOpen's text field is
      ⍝ authoritative regardless of what's on disk — confirmed against
      ⍝ pyright: hovering over content that only exists in `text`
      ⍝ (never written to the file at `uri`) still resolves correctly,
      ⍝ so `uri` need not name a file that actually exists on disk.
      :If 2=≢args
          (uri text)←args ⋄ languageId←'python'
      :Else
          (uri text languageId)←args
      :EndIf
      textDocument←(uri:uri ⋄ languageId:languageId ⋄ version:1 ⋄ text:text)
      h.JsonRpcCl #.JsonRpcCl.Notify('textDocument/didOpen'(textDocument:textDocument))
      r←⍬
    ∇

    ∇ result←h Hover args
      ⍝ args: (uri line character), both zero-based per LSP's own
      ⍝ convention (not this codebase's usual ⎕IO←1 — this is the
      ⍝ wire protocol's own indexing, unrelated to ⎕IO). A protocol-
      ⍝ level error (e.g. the document was never opened) signals; a
      ⍝ legitimate "no hover info at this position" is a null `result`
      ⍝ per spec, not an error — that's ordinary returned data here,
      ⍝ same reasoning as Mcp.CallTool's isError distinction (ADR D6/
      ⍝ D11): a request that completes but has nothing to report is not
      ⍝ a fault. Confirmed empirically against pyright (ADR D16): JSON
      ⍝ `null` coming IN is represented the same way ⎕JSON represents
      ⍝ true/false coming in — as ⊂'null' (an enclosed character
      ⍝ vector), not an absent field or ⎕NULL — so callers check for
      ⍝ "no hover info" with `result≡⊂'null'`, not `0≠⎕NC'result.contents'`.
      (uri line character)←args
      params←(textDocument:(uri:uri) ⋄ position:(line:line ⋄ character:character))
      resp←h.JsonRpcCl #.JsonRpcCl.Call('textDocument/hover' params)
      :If 0≠⎕NC'resp.error'
          ('Lsp.Hover: ',resp.error.message)⎕SIGNAL 999
      :EndIf
      result←resp.result
    ∇

:EndNamespace
