:Namespace JsonRpc
⍝ Minimal JSON-RPC 2.0 layer over Shell. Messages are built/parsed as
⍝ array-notation namespace literals via ⎕JSON (ADR D4). v1 (ADR D7)
⍝ allowed exactly one in-flight Call per handle; Phase 8 (ADR D17)
⍝ generalizes this to pipelined Send/AwaitResponse, JSON-RPC batch
⍝ requests, and notification dispatch — see below.
⍝
⍝ Handle shape (adds to the Shell handle it wraps):
⍝   Shell           the underlying Shell handle (see Shell.dyalog)
⍝   NextId          next request id to use (monotonic integer)
⍝   Timeout         seconds to wait for a response
⍝   Notifications   queue of parsed no-id messages received — always
⍝                   populated (backward compatible with v1), whether
⍝                   or not a handler was also dispatched (ADR D17)
⍝   PendingIds      ids of responses that have arrived but weren't
⍝                   the one an earlier AwaitResponse was waiting for
⍝   PendingMsgs     the matching parsed responses, same order as
⍝                   PendingIds
⍝   Inbox           single parsed messages not yet classified — holds
⍝                   the leftover elements of a JSON-RPC batch response
⍝                   line (an array of messages) one at a time
⍝   NotifyMethods   registered notification methods (ADR D17)
⍝   NotifyHandlers  the matching handler-name strings (OnNotification)

    ⎕IO←1 ⋄ ⎕ML←1

    ∇ h←{opts}Connect cmd
      :If 0=⎕NC'opts' ⋄ opts←() ⋄ :EndIf
      h←(
        Shell:opts #.Shell.Start cmd
        Timeout:opts ⎕VGET⊂'Timeout' 10
        NextId:1
        Notifications:⍬
        PendingIds:⍬ ⋄ PendingMsgs:⍬
        Inbox:⍬
        NotifyMethods:⍬ ⋄ NotifyHandlers:⍬
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

    ∇ {r}←h OnNotification args
      ⍝ args: (method handlerName) — registers handlerName (a fully
      ⍝ qualified function name, e.g. '#.Mcp._OnToolsListChanged') to
      ⍝ be invoked, as `h HandlerName parsed`, whenever a notification
      ⍝ with this method name arrives. See ADR D17 for why this is a
      ⍝ name-string table (looked up array-style, never ⍎'d on
      ⍝ server-supplied text) rather than an operator-based API.
      ⍝ Registering the same method again replaces the old handler.
      (method handler)←args
      pos←h.NotifyMethods⍳⊂method
      :If pos≤≢h.NotifyMethods
          h.NotifyHandlers[pos]←⊂handler
      :Else
          h.NotifyMethods,←⊂method
          h.NotifyHandlers,←⊂handler
      :EndIf
      r←⍬
    ∇

    ∇ id←h Send args
      ⍝ args: a method name (char vector), or a (method params) pair.
      ⍝ Sends a request with a fresh id and returns that id immediately
      ⍝ — does NOT block for the response. Pair with AwaitResponse to
      ⍝ pipeline several requests before collecting any of their
      ⍝ answers (ADR D17).
      msg←h _Envelope args
      msg.id←h.NextId
      h.NextId←h.NextId+1
      h.Shell #.Shell.Send ⎕JSON msg
      id←msg.id
    ∇

    ∇ resp←h AwaitResponse id
      ⍝ Blocks (up to h.Timeout seconds per message read) until the
      ⍝ response with this specific id has arrived. Returns instantly
      ⍝ if it already showed up while waiting on a different id
      ⍝ (stashed in h.PendingIds/PendingMsgs by an earlier
      ⍝ AwaitResponse) — otherwise reads and classifies incoming
      ⍝ messages until it sees this one. Any OTHER id-bearing message
      ⍝ seen along the way is stashed for a later AwaitResponse on
      ⍝ THAT id, array-style (a dyadic ⍳ lookup, not a loop with an
      ⍝ early return); any message with no id goes through
      ⍝ notification dispatch instead.
      :Repeat
          pos←h.PendingIds⍳id
          :If pos≤≢h.PendingIds
              resp←pos⊃h.PendingMsgs
              keep←pos≠⍳≢h.PendingIds
              h.PendingIds←keep/h.PendingIds
              h.PendingMsgs←keep/h.PendingMsgs
              :Return
          :EndIf
          parsed←_NextMessage h
          hasId←0≠⎕NC'parsed.id'
          :If hasId
          :AndIf parsed.id≡id
              resp←parsed
              :Return
          :ElseIf hasId
              h.PendingIds,←parsed.id
              h.PendingMsgs,←⊂parsed
          :Else
              h _Dispatch parsed
          :EndIf
      :EndRepeat
    ∇

    ∇ resp←h Call args
      ⍝ Convenience wrapper: Send then immediately AwaitResponse on
      ⍝ that id. A JSON-RPC error response comes back as ordinary data
      ⍝ (ADR D6) — it's your job to check resp.error/resp.result, this
      ⍝ never signals for a protocol-legal error response.
      resp←h AwaitResponse(h Send args)
    ∇

    ∇ resps←h CallBatch argsVec
      ⍝ argsVec: a vector of args, each in the same shape Send/Call
      ⍝ accept. Sends one JSON-RPC 2.0 batch request (a JSON array of
      ⍝ request objects, one fresh id each) and returns the responses
      ⍝ in argsVec's OWN order — regardless of what order the server
      ⍝ replies in — by reusing AwaitResponse's pending-table mechanism
      ⍝ for every id in turn.
      n←≢argsVec
      ids←h.NextId+(⍳n)-1
      h.NextId←h.NextId+n
      msgs←h∘_Envelope¨argsVec
      msgs←ids _WithId¨msgs
      h.Shell #.Shell.Send ⎕JSON msgs
      resps←h AwaitResponse¨ids
    ∇

    ∇ msg←id _WithId msg
      msg.id←id
    ∇

    ∇ {r}←h _Dispatch parsed
      ⍝ parsed: a no-id message (a notification). If a handler is
      ⍝ registered for parsed.method (found via a dyadic-⍳ lookup into
      ⍝ our OWN trusted NotifyMethods table — parsed.method, server
      ⍝ text, is used only as the lookup KEY, never as code), it's
      ⍝ invoked as `h HandlerName parsed`. Backward compatible either
      ⍝ way (ADR D17): parsed is ALWAYS also appended to h.Notifications,
      ⍝ whether or not a handler fired — "as well as", not "instead of".
      pos←h.NotifyMethods⍳⊂parsed.method
      :If pos≤≢h.NotifyMethods
          handler←pos⊃h.NotifyHandlers
          ⍝ handler is a name WE (trusted, registering) code chose via
          ⍝ OnNotification — never text that came from the server; the
          ⍝ server's own parsed.method only ever selected a position in
          ⍝ our own table above. Safe to ⍎, per ADR D17/the house rule
          ⍝ against ⍎ing server-supplied text.
          {}⍎'h ',handler,' parsed'
      :EndIf
      h.Notifications,←⊂parsed
      r←⍬
    ∇

    ∇ parsed←_NextMessage h
      ⍝ Returns the next single parsed message, blocking on Shell for
      ⍝ a new line only when h.Inbox is empty. A line that is itself a
      ⍝ JSON-RPC batch parses (via ⎕JSON) to a VECTOR of namespaces
      ⍝ (rank 1) rather than one namespace scalar (rank 0) — that's
      ⍝ what distinguishes it from an ordinary single message, and it's
      ⍝ split into h.Inbox so each element is classified on its own,
      ⍝ same as if it had arrived on its own line.
      :If 0=≢h.Inbox
          line←h.Timeout #.Shell.Receive h.Shell
          :Trap 0
              raw←⎕JSON line
          :Else
              ⍝ `line` is server-supplied and can be arbitrarily long,
              ⍝ which is exactly why it belongs in Message rather than
              ⍝ EM — see Shell._Err and ADR D19.
              ⎕SIGNAL'JsonRpc'_Err('malformed JSON from server: ',line)
          :EndTrap
          :If 0<⍴⍴raw ⍝ a batch (JSON array of objects) is rank 1, not a scalar ref
              h.Inbox←,raw
          :Else
              h.Inbox←,⊂raw
          :EndIf
      :EndIf
      parsed←⊃h.Inbox
      h.Inbox←1↓h.Inbox
    ∇

    ∇ msg←h _Envelope args
      (method params)←_ParseArgs args
      msg←(jsonrpc:'2.0' ⋄ method:method ⋄ params:params)
    ∇

    ∇ spec←label _Err detail
      ⍝ See Shell._Err — same house convention (ADR D19), duplicated
      ⍝ rather than shared so each layer stays ⎕FIX-able on its own.
      spec←⊂('EN' 999)('EM' label)('Message' detail)
    ∇

    ∇ (method params)←_ParseArgs args
      :If 1=≡args
          method←args
          params←()
      :Else
          (method params)←args
      :EndIf
    ∇

:EndNamespace
