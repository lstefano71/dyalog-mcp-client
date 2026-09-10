:Namespace JsonRpcCl
⍝ JSON-RPC 2.0 over stdio, Content-Length-header framed — the framing
⍝ LSP/DAP and most other stdio JSON-RPC servers use ("Content-Length:
⍝ N\r\n\r\n" then exactly N bytes of JSON), as opposed to JsonRpc's
⍝ newline-delimited framing (which MCP uses). See ADR D13.
⍝
⍝ Deliberately self-contained — does NOT build on Shell, because
⍝ Shell's line-oriented Output/Callback mode (built for NDJSON) is the
⍝ wrong tool here: a Content-Length body is read by exact byte count,
⍝ not by scanning for newlines, and could in principle (though rarely
⍝ in practice, since JSON escapes embedded newlines) span what a
⍝ line-splitter would treat as multiple lines. This namespace talks to
⍝ ⎕SHELL directly, in "simple vector mode" (no line splitting) — see
⍝ _Run/_OnOutput.
⍝
⍝ Public verb shape deliberately matches JsonRpc's (Connect/Disconnect/
⍝ Call/Notify) so a future cover could be built on either the same way
⍝ Mcp is built on JsonRpc.
⍝
⍝ Handle shape (a plain data namespace — never function refs):
⍝   Cmd WorkingDir      as given to Connect
⍝   Tok InTok SigTok    this handle's private ⎕TALLOC token range
⍝   Buffer              raw text received but not yet resolved into a
⍝                       complete message (a partial header block or body)
⍝   Messages            queue (vector of parsed namespaces) of complete
⍝                       messages received but not yet consumed — a
⍝                       batch response frame is split into its
⍝                       individual elements here, same as a single one
⍝   Status              'Running' | 'Exited'
⍝   ExitCode ExitReason Pid
⍝   NextId Timeout Notifications   same meaning as in JsonRpc
⍝   PendingIds PendingMsgs         same meaning as in JsonRpc (Phase 8,
⍝                                  ADR D17) — arrived-but-not-yet-
⍝                                  awaited responses, keyed by id
⍝   NotifyMethods NotifyHandlers   same meaning as in JsonRpc (ADR D17)
⍝   StopWait Killed CaptureStderr StderrLines
⍝                       same meaning as on the Shell handle (ADR D18) —
⍝                       Disconnect force-kills a child that ignores its
⍝                       stdin being closed, and stderr is capturable
⍝                       rather than only discardable

    ⎕IO←1 ⋄ ⎕ML←1

    _VECTOR_TYPE←80 ⍝ a scalar (not an encoding name) ⇒ ⎕SHELL runs
                     ⍝ Input/Output in raw "simple vector" mode: no
                     ⍝ forced trailing newline on send, no line
                     ⍝ splitting on receive — see ADR D13.

    ∇ h←{opts}Connect cmd
      :If 0=⎕NC'opts' ⋄ opts←() ⋄ :EndIf
      tok←⎕TALLOC 1('mcp-client-cl:',⊃cmd)
      h←(
        Cmd:cmd
        WorkingDir:opts ⎕VGET⊂'WorkingDir' ''
        Buffer:''
        Messages:⍬
        Status:'Running'
        ExitCode:¯1 ⋄ ExitReason:¯1 ⋄ Pid:¯1
        Tok:tok ⋄ InTok:tok+0.1 ⋄ SigTok:tok+0.2
        NextId:1
        Timeout:opts ⎕VGET⊂'Timeout' 10
        Notifications:⍬
        PendingIds:⍬ ⋄ PendingMsgs:⍬
        NotifyMethods:⍬ ⋄ NotifyHandlers:⍬
        StopWait:opts ⎕VGET⊂'StopWait' 10
        Killed:0
        CaptureStderr:opts ⎕VGET⊂'CaptureStderr' 0
        StderrLines:⍬
      )
      h.Tid←_Run&h ⍝ needs h to already exist, so can't join the literal above
    ∇

    ∇ {r}←Disconnect h
      ⍝ Same shape as Shell.Stop, including its force-kill fallback —
      ⍝ see Shell._ForceKill for the full reasoning (ADR D18); this
      ⍝ namespace is deliberately self-contained (see the header), so
      ⍝ the few lines are duplicated rather than shared.
      :If h.Status≡'Running'
          ⎕TPUT h.InTok ⍝ a token with no data closes the fed stream
          _AwaitExit h h.StopWait
          :If h.Status≡'Running'
              h.Killed←_ForceKill h
          :EndIf
      :EndIf
      :Trap 0
          h.Tok ⎕TALLOC ¯1
      :Else
      :EndTrap
      r←⍬
    ∇

    ∇ {r}←_AwaitExit(h seconds)
      ⍝ See Shell._AwaitExit.
      n←seconds
      :While (h.Status≡'Running')∧(n>0)
          {}1 ⎕TGET h.SigTok
          n←n-1
      :EndWhile
      r←⍬
    ∇

    ∇ ok←_ForceKill h
      ⍝ See Shell._ForceKill — identical, including why the right
      ⍝ argument is h.Tid (an APL thread number, not a PID) and why 9
      ⍝ is the only signal Windows accepts.
      ok←0
      :Trap 0
          ok←9(8373⌶)h.Tid
      :Else
      :EndTrap
      :If ok
          _AwaitExit h 5
      :EndIf
    ∇

    ∇ {r}←h Notify args
      msg←h _Envelope args
      h _Send msg
      r←⍬
    ∇

    ∇ {r}←h OnNotification args
      ⍝ See JsonRpc.OnNotification — identical semantics, same ADR D17
      ⍝ trusted-name-table design.
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
      ⍝ See JsonRpc.Send — sends a request with a fresh id, does NOT
      ⍝ block for the response.
      msg←h _Envelope args
      msg.id←h.NextId
      h.NextId←h.NextId+1
      h _Send msg
      id←msg.id
    ∇

    ∇ resp←h AwaitResponse id
      ⍝ See JsonRpc.AwaitResponse — identical semantics, adapted only
      ⍝ for reading from h.Messages (already a queue of complete
      ⍝ parsed messages, per this transport's framing) instead of
      ⍝ JsonRpc's line-at-a-time h.Inbox.
      :Repeat
          pos←h.PendingIds⍳id
          :If pos≤≢h.PendingIds
              resp←pos⊃h.PendingMsgs
              keep←pos≠⍳≢h.PendingIds
              h.PendingIds←keep/h.PendingIds
              h.PendingMsgs←keep/h.PendingMsgs
              :Return
          :EndIf
          :If 0≠≢h.Messages
              parsed←⊃h.Messages
              h.Messages←1↓h.Messages
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
              :Continue
          :EndIf
          :If h.Status≡'Exited'
              ⎕SIGNAL'JsonRpcCl'_Err('process exited (reason ',(⍕h.ExitReason),', code ',(⍕h.ExitCode),')')
          :EndIf
          :If 0=≢h.Timeout ⎕TGET h.SigTok
              ⎕SIGNAL'JsonRpcCl'_Err'timed out waiting for a response'
          :EndIf
      :EndRepeat
    ∇

    ∇ resp←h Call args
      resp←h AwaitResponse(h Send args)
    ∇

    ∇ resps←h CallBatch argsVec
      ⍝ See JsonRpc.CallBatch — identical semantics.
      n←≢argsVec
      ids←h.NextId+(⍳n)-1
      h.NextId←h.NextId+n
      msgs←h∘_Envelope¨argsVec
      msgs←ids _WithId¨msgs
      h _Send msgs
      resps←h AwaitResponse¨ids
    ∇

    ∇ msg←id _WithId msg
      msg.id←id
    ∇

    ∇ {r}←h _Dispatch parsed
      ⍝ See JsonRpc._Dispatch — identical semantics/reasoning (ADR D17).
      pos←h.NotifyMethods⍳⊂parsed.method
      :If pos≤≢h.NotifyMethods
          handler←pos⊃h.NotifyHandlers
          {}⍎'h ',handler,' parsed'
      :EndIf
      h.Notifications,←⊂parsed
      r←⍬
    ∇

    ∇ {r}←h _Send msg
      :If h.Status≢'Running'
          ⎕SIGNAL'JsonRpcCl.Send'_Err('process is not running (status: ',h.Status,')')
      :EndIf
      body←⎕JSON msg
      crlf←⎕UCS 13 10
      framed←('Content-Length: ',(⍕≢body),crlf,crlf),body
      ('Array' framed _VECTOR_TYPE)⎕TPUT h.InTok
      r←⍬
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

    ∇ spec←label _Err detail
      ⍝ See Shell._Err — same house convention (ADR D19).
      spec←⊂('EN' 999)('EM' label)('Message' detail)
    ∇

    ∇ {r}←_Run h
      ⍝ Stream 1 needs simple-vector mode (_VECTOR_TYPE, raw bytes —
      ⍝ see header comment); stream 2 is discarded, in ordinary
      ⍝ line-mode instead of also being simple-vector mode — two
      ⍝ simple-vector-mode callbacks together with a Token input
      ⍝ reliably raises "DOMAIN ERROR: Invalid use of variant" against
      ⍝ a real interactive child process (ADR D13; the same family of
      ⍝ ⎕SHELL variant-combination gotcha as Shell._Run's stderr note).
      opts←('Input'(0('Token'h.InTok)))('Output'((1('Callback'('_OnOutput'h)_VECTOR_TYPE))(2('Callback'('_OnStderr'h)))))
      :If 0≠≢h.WorkingDir
          opts,←⊂('WorkingDir'h.WorkingDir)
      :EndIf
      result←⎕SHELL⍠opts⊢h.Cmd
      h.ExitCode←3⊃result
      h.ExitReason←4⊃result
      h.Pid←5⊃result
      h.Status←'Exited'
      h.SigTok ⎕TPUT h.SigTok
      r←⍬
    ∇

    ∇ {r}←h _OnOutput info
      ⍝ Simple-vector-mode Callback for stream 1 — info.Output is raw
      ⍝ text, NOT split into lines (⎕SHELL's line mode would be wrong
      ⍝ here — see the header comment). Accumulate and try to peel off
      ⍝ as many complete Content-Length-framed messages as we can.
      h.Buffer,←info.Output
      _ExtractMessages h
      h.SigTok ⎕TPUT h.SigTok
      r←1
    ∇

    ∇ {r}←h _OnStderr info
      ⍝ Discarded unless opts.CaptureStderr asked for it — see
      ⍝ Shell._OnStderr, same reasoning and same ADRs (D5/D11/D18).
      ⍝ This stream is in ordinary line mode (see _Run), so info.Output
      ⍝ is already split into lines here, unlike stream 1's.
      :If h.CaptureStderr
          lines←info.Output
          :If info.PartialLine∧~info.Done
              lines←¯1↓lines
          :EndIf
          h.StderrLines,←lines
      :EndIf
      r←1
    ∇

    ∇ {r}←_ExtractMessages h
      ⍝ Pulls every complete "Content-Length: N\r\n\r\n<N bytes>"
      ⍝ message currently sitting in h.Buffer into h.Messages, leaving
      ⍝ any trailing partial message in the buffer for next time.
      crlfcrlf←⎕UCS 13 10 13 10
      :Repeat
          hits←⍸crlfcrlf⍷h.Buffer
          :If 0=≢hits ⋄ :Return ⋄ :EndIf ⍝ no complete header block yet
          sep←⊃hits
          headerBlock←(sep-1)↑h.Buffer
          bodyStart←sep+4
          len←_ContentLength headerBlock
          ⍝ NOT bodyStart-1+len — APL is right-to-left with no operator
          ⍝ precedence, so that would silently compute bodyStart-(1+len)
          ⍝ instead of the (bodyStart-1)+len intended. Parenthesized
          ⍝ explicitly rather than just reordering to exploit
          ⍝ right-to-left evaluation — this exact bug is why.
          consumed←(bodyStart-1)+len
          :If consumed>≢h.Buffer ⋄ :Return ⋄ :EndIf ⍝ body not fully arrived yet
          body←len↑(bodyStart-1)↓h.Buffer ⍝ drop is a count, not an index — off by one otherwise
          parsed←⎕JSON body
          ⍝ A batch response frame's body parses to a rank-1 vector of
          ⍝ namespaces (a JSON array of objects), not one rank-0
          ⍝ namespace scalar — split it into h.Messages one at a time,
          ⍝ same as JsonRpc._NextMessage does for a batch line (ADR D17).
          :If 0<⍴⍴parsed
              h.Messages,←parsed
          :Else
              h.Messages,←⊂parsed
          :EndIf
          h.Buffer←consumed↓h.Buffer
      :EndRepeat
      r←⍬
    ∇

    ∇ n←_ToInt digits
      ⍝ digits: a character vector already confirmed to hold only
      ⍝ '0123456789'. ⎕VFI, not ⍎ — this text comes from the server,
      ⍝ and ⍎ on unvalidated input is a code-injection risk even when
      ⍝ the caller believes it's clean.
      n←2⊃⎕VFI digits
    ∇

    ∇ len←_ContentLength headerBlock
      ⍝ headerBlock: the header lines (CRLF-separated), body separator
      ⍝ not included. Header names are matched case-insensitively, per
      ⍝ the LSP/DAP convention this framing comes from. nl(≠⊆⊢) only
      ⍝ splits on a single character, so \r is dropped first rather
      ⍝ than trying to split on the 2-character "\r\n" directly.
      nl←⎕UCS 10
      headerBlock←(headerBlock≠⎕UCS 13)/headerBlock
      lines←nl(≠⊆⊢)headerBlock
      len←¯1
      :For ln :In lines
          :If 15≤≢ln ⍝ 'content-length:' is 15 characters, not 16
          :AndIf 'content-length:'≡⎕C 15↑ln
              digits←'0123456789'
              rest←(+/∧\' '=15↓ln)↓15↓ln
              nd←+/∧\rest∊digits
              :If nd>0 ⋄ len←_ToInt nd↑rest ⋄ :EndIf
          :EndIf
      :EndFor
      :If len<0
          ⎕SIGNAL'JsonRpcCl'_Err'message header block has no Content-Length'
      :EndIf
    ∇

:EndNamespace
