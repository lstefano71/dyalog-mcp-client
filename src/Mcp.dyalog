:Namespace Mcp
⍝ MCP protocol semantics over JsonRpc. v1 scope is deliberately narrow
⍝ (ADR D8): the initialize/initialized handshake, tools/list, and
⍝ tools/call, plus a reaction to notifications/tools/list_changed
⍝ (added in Phase 8 — see the ToolsStale note below). Resources,
⍝ prompts, sampling, roots and pagination are not implemented — see
⍝ TODO.md.
⍝
⍝ Handle shape (adds to the JsonRpc handle it wraps):
⍝   JsonRpc              the underlying JsonRpc handle (see JsonRpc.dyalog)
⍝   ServerInfo            {name, version} from the initialize response
⍝   ServerCapabilities    the capabilities object the server advertised
⍝   LastError             the whole JSON-RPC error object (code, message,
⍝                         and data if the server sent one) from the most
⍝                         recent protocol-level failure ListTools/CallTool
⍝                         signalled on — ⍬ until one happens (ADR D18)
⍝
⍝ ToolsStale (Phase 8, ADR D17): Connect registers _OnToolsListChanged
⍝ against 'notifications/tools/list_changed' on the underlying JsonRpc
⍝ handle — since that's the handle the dispatcher actually invokes the
⍝ handler with, the flag lives at h.JsonRpc.ToolsStale, not h.ToolsStale.
⍝ Mcp does no tool-list caching (no cache to invalidate), so this is
⍝ purely informational: it's set 1 when the server announces its tool
⍝ list changed, and cleared back to 0 the next time ListTools actually
⍝ fetches a fresh list.

    ⎕IO←1 ⋄ ⎕ML←1

    _PROTOCOL_VERSION←'2025-06-18'
    _CLIENT_INFO←(name:'dyalog-mcp-client' ⋄ version:'0.1.0')

    ∇ h←{opts}Connect cmd
      jr←opts #.JsonRpc.Connect cmd
      params←(protocolVersion:_PROTOCOL_VERSION ⋄ capabilities:() ⋄ clientInfo:_CLIENT_INFO)
      resp←jr #.JsonRpc.Call('initialize' params)
      :If 0≠⎕NC'resp.error'
          ⍝ No handle to stash LastError on — Connect is failing, so the
          ⍝ caller never receives one; the code/data are in the message.
          ⎕SIGNAL'Mcp.Connect'_Err('server rejected initialize: ',_RpcErrorDetail resp.error)
      :EndIf
      jr #.JsonRpc.Notify'notifications/initialized'
      jr.ToolsStale←0
      jr #.JsonRpc.OnNotification('notifications/tools/list_changed' '#.Mcp._OnToolsListChanged')
      h←(
        JsonRpc:jr
        ServerInfo:resp.result.serverInfo
        ServerCapabilities:resp.result.capabilities
        LastError:⍬
      )
    ∇

    ∇ spec←label _Err detail
      ⍝ See Shell._Err — same house convention (ADR D19).
      spec←⊂('EN' 999)('EM' label)('Message' detail)
    ∇

    ∇ msg←_RpcErrorDetail err
      ⍝ err: a JSON-RPC error object. Builds the Message half of the
      ⍝ signal for a protocol-level failure. The error's `code` (and
      ⍝ `data`, when the server sent one) used to be dropped on the
      ⍝ floor here, leaving only `message` — see ADR D18. Both are
      ⍝ folded into the text so a human reading the signal sees them; a
      ⍝ caller that needs to BRANCH on the code reads h.LastError
      ⍝ instead, since even the structured ⎕SIGNAL form can only set
      ⍝ names ⎕DMX already defines and so has nowhere to carry a
      ⍝ payload of our own (ADR D19).
      ⍝
      ⍝ Everything this returns is server-supplied and unbounded —
      ⍝ `message` is whatever the server wrote, and `data` can be an
      ⍝ arbitrarily large JSON value — which is precisely why it goes
      ⍝ into Message rather than into EM.
      msg←err.message
      code←err ⎕VGET⊂'code' ⍬
      :If 0≠≢code
          msg,←' (JSON-RPC code ',(⍕code),')'
      :EndIf
      :If 0≠err.⎕NC⊂'data'
          :Trap 0
              msg,←', data: ',⎕JSON err.data
          :Else
              ⍝ data is legal JSON by construction (it arrived as JSON),
              ⍝ but never let rendering it turn into the reported error.
          :EndTrap
      :EndIf
    ∇

    ∇ {r}←h _OnToolsListChanged notif
      ⍝ Registered (via Connect) against 'notifications/tools/list_changed'.
      ⍝ h here is the JsonRpc handle the dispatcher calls this with —
      ⍝ see the ToolsStale note above. Just marks staleness; no cache to
      ⍝ invalidate (Mcp doesn't cache tool lists — see ADR D17 for why
      ⍝ adding that here would be overkill for what this needs to do).
      h.ToolsStale←1
      r←⍬
    ∇

    ∇ {r}←Disconnect h
      #.JsonRpc.Disconnect h.JsonRpc
      r←⍬
    ∇

    ∇ tools←ListTools h
      ⍝ TODO: no pagination (cursor/nextCursor) support yet — returns
      ⍝ whatever the server hands back in one tools/list response.
      resp←h.JsonRpc #.JsonRpc.Call'tools/list'
      :If 0≠⎕NC'resp.error'
          h.LastError←resp.error
          ⎕SIGNAL'Mcp.ListTools'_Err _RpcErrorDetail resp.error
      :EndIf
      tools←resp.result.tools
      h.JsonRpc.ToolsStale←0 ⍝ a fresh list was just fetched — see the ToolsStale note above
    ∇

    ∇ result←h CallTool args
      ⍝ args: a tool name (char vector), or a (name arguments) pair.
      ⍝ A protocol-level failure (e.g. unknown tool name) signals; a
      ⍝ tool that ran but failed comes back as ordinary data — check
      ⍝ result.isError, per the MCP spec's own distinction.
      :If 1=≡args
          name←args ⋄ arguments←()
      :Else
          (name arguments)←args
      :EndIf
      resp←h.JsonRpc #.JsonRpc.Call('tools/call'(name:name ⋄ arguments:arguments))
      :If 0≠⎕NC'resp.error'
          h.LastError←resp.error
          ⎕SIGNAL'Mcp.CallTool'_Err _RpcErrorDetail resp.error
      :EndIf
      result←resp.result
    ∇

:EndNamespace
