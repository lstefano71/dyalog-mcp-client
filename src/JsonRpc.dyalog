:Namespace JsonRpc
⍝ Minimal JSON-RPC 2.0 layer over Shell. Messages are built/parsed as
⍝ array-notation namespace literals via ⎕JSON (ADR D4). v1 allows
⍝ exactly one in-flight Call per handle (ADR D7) — see TODO.md for the
⍝ evolution path to concurrent outstanding requests.
⍝
⍝ Handle shape (adds to the Shell handle it wraps):
⍝   Shell           the underlying Shell handle (see Shell.dyalog)
⍝   NextId          next request id to use (monotonic integer)
⍝   Timeout         seconds to wait for a Call's response
⍝   Notifications   queue of parsed messages received that weren't the
⍝                   awaited response (no id, or an id we weren't
⍝                   waiting for) — never dispatched, only queued

    ⎕IO←1 ⋄ ⎕ML←1

    ∇ h←{opts}Connect cmd
      :If 0=⎕NC'opts' ⋄ opts←() ⋄ :EndIf
      h←(
        Shell:opts #.Shell.Start cmd
        Timeout:opts ⎕VGET⊂'Timeout' 10
        NextId:1
        Notifications:⍬
      )
    ∇

    ∇ {r}←Disconnect h
      #.Shell.Stop h.Shell
      r←⍬
    ∇

    ∇ {r}←h Notify args
      ⍝ args: a method name (char vector), or a (method params) pair.
      ⍝ No id is sent, and no response is awaited.
      h.Shell #.Shell.Send ⎕JSON h _Envelope args
      r←⍬
    ∇

    ∇ resp←h Call args
      ⍝ args: a method name (char vector), or a (method params) pair.
      ⍝ Sends a request with a fresh id, blocks (up to h.Timeout
      ⍝ seconds) for the matching response, and returns it as a parsed
      ⍝ namespace — whether it's a {result:...} or {error:...} response
      ⍝ is left for the caller to inspect (ADR D6: a JSON-RPC error
      ⍝ response is ordinary data, not a fault).
      msg←h _Envelope args
      msg.id←h.NextId
      h.NextId←h.NextId+1
      h.Shell #.Shell.Send ⎕JSON msg
      resp←h _AwaitId msg.id
    ∇

    ∇ msg←h _Envelope args
      (method params)←_ParseArgs args
      msg←(jsonrpc:'2.0' ⋄ method:method ⋄ params:params)
    ∇

    ∇ (method params)←_ParseArgs args
      :If 1=≡args
          method←args
          params←()
      :Else
          (method params)←args
      :EndIf
    ∇

    ∇ resp←h _AwaitId id
      :Repeat
          line←h.Timeout #.Shell.Receive h.Shell
          :Trap 0
              parsed←⎕JSON line
          :Else
              ('JsonRpc: malformed JSON from server: ',line)⎕SIGNAL 999
          :EndTrap
          :If (0≠⎕NC'parsed.id')∧(parsed.id≡id)
              resp←parsed
              :Return
          :Else
              h.Notifications,←⊂parsed
          :EndIf
      :EndRepeat
    ∇

:EndNamespace
