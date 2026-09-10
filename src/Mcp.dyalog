:Namespace Mcp
⍝ MCP protocol semantics over JsonRpc. v1 scope is deliberately narrow
⍝ (ADR D8): the initialize/initialized handshake, tools/list, and
⍝ tools/call. Resources, prompts, sampling, roots, pagination and
⍝ list_changed notifications are not implemented — see TODO.md.
⍝
⍝ Handle shape (adds to the JsonRpc handle it wraps):
⍝   JsonRpc              the underlying JsonRpc handle (see JsonRpc.dyalog)
⍝   ServerInfo            {name, version} from the initialize response
⍝   ServerCapabilities    the capabilities object the server advertised

    ⎕IO←1 ⋄ ⎕ML←1

    _PROTOCOL_VERSION←'2025-06-18'
    _CLIENT_INFO←(name:'dyalog-mcp-client' ⋄ version:'0.1.0')

    ∇ h←{opts}Connect cmd
      jr←opts #.JsonRpc.Connect cmd
      params←(protocolVersion:_PROTOCOL_VERSION ⋄ capabilities:() ⋄ clientInfo:_CLIENT_INFO)
      resp←jr #.JsonRpc.Call('initialize' params)
      :If 0≠⎕NC'resp.error'
          ('Mcp.Connect: server rejected initialize: ',resp.error.message)⎕SIGNAL 999
      :EndIf
      jr #.JsonRpc.Notify'notifications/initialized'
      h←(
        JsonRpc:jr
        ServerInfo:resp.result.serverInfo
        ServerCapabilities:resp.result.capabilities
      )
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
          ('Mcp.ListTools: ',resp.error.message)⎕SIGNAL 999
      :EndIf
      tools←resp.result.tools
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
          ('Mcp.CallTool: ',resp.error.message)⎕SIGNAL 999
      :EndIf
      result←resp.result
    ∇

:EndNamespace
