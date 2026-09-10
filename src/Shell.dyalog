:Namespace Shell
⍝ Bidirectional stdio wrapper around ⎕SHELL for a single long-running
⍝ child process. No knowledge of JSON-RPC/MCP here — just start a
⍝ process, send it a line, get a line back, stop it.
⍝
⍝ See docs/adr/0001-architecture-decisions.md (D1-D3, D5, D6) for the
⍝ reasoning behind the design used here.
⍝
⍝ Handle shape (a plain data namespace — never function refs):
⍝   Cmd          the command as passed to Start
⍝   WorkingDir   working directory used for the child process
⍝   Tok          base of this handle's private ⎕TALLOC token range
⍝   InTok        token number used to feed stdin (Input 'Token')
⍝   SigTok       token number used to signal "stdout queue changed"
⍝   Lines        queue (vector of char vectors) of received stdout lines
⍝   Status       'Running' | 'Exited'
⍝   ExitCode ExitReason Pid   set once the child process has exited
⍝   StopWait     seconds Stop waits for a clean exit before force-killing
⍝                (opts, default 10)
⍝   Killed       1 if Stop had to force-kill this child, else 0 (D18)
⍝   CaptureStderr  1 to collect the child's stderr into StderrLines
⍝                  instead of discarding it (opts, default 0 — D18)
⍝   StderrLines  queue of captured stderr lines (empty unless
⍝                CaptureStderr is set)

    ⎕IO←1 ⋄ ⎕ML←1

    ∇ h←{opts}Start cmd
      ⍝ cmd: a vector of character vectors — the program path followed
      ⍝ by its arguments — as accepted by ⎕SHELL for direct execution.
      ⍝ opts (optional): namespace, may set WorkingDir, StopWait,
      ⍝ CaptureStderr.
      :If 0=⎕NC'opts' ⋄ opts←() ⋄ :EndIf
      tok←⎕TALLOC 1('mcp-client:',⊃cmd)
      h←(
        Cmd:cmd
        WorkingDir:opts ⎕VGET⊂'WorkingDir' ''
        Lines:⍬
        Status:'Running'
        ExitCode:¯1 ⋄ ExitReason:¯1 ⋄ Pid:¯1
        Tok:tok ⋄ InTok:tok+0.1 ⋄ SigTok:tok+0.2
        StopWait:opts ⎕VGET⊂'StopWait' 10
        Killed:0
        CaptureStderr:opts ⎕VGET⊂'CaptureStderr' 0
        StderrLines:⍬
      )
      h.Tid←_Run&h ⍝ needs h to already exist, so can't join the literal above
    ∇

    ∇ {r}←h Send text
      ⍝ Push one line of text to the child's stdin. text must not
      ⍝ contain embedded newlines (NDJSON framing requirement).
      :If h.Status≢'Running'
          ('Shell.Send: process is not running (status: ',h.Status,')')⎕SIGNAL 999
      :EndIf
      ('Array' text 'UTF-8')⎕TPUT h.InTok
      r←⍬
    ∇

    ∇ text←timeout Receive h
      ⍝ Block (up to timeout seconds; 0 = forever) for the next line
      ⍝ of stdout. Signals if the process has exited with nothing left
      ⍝ to read, or if the timeout elapses first.
      :Repeat
          :If 0≠≢h.Lines
              text←⊃h.Lines
              h.Lines←1↓h.Lines
              :Return
          :EndIf
          :If h.Status≡'Exited'
              ('Shell.Receive: process exited (reason ',(⍕h.ExitReason),', code ',(⍕h.ExitCode),')')⎕SIGNAL 999
          :EndIf
          :If 0=≢timeout ⎕TGET h.SigTok
              'Shell.Receive: timed out waiting for output'⎕SIGNAL 999
          :EndIf
      :EndRepeat
    ∇

    ∇ {r}←Stop h
      ⍝ Close stdin, wait (up to h.StopWait seconds) for the child to
      ⍝ exit, force-kill it if that deadline passes, then release the
      ⍝ handle's token range. Safe to call more than once.
      :If h.Status≡'Running'
          ⎕TPUT h.InTok ⍝ a token with no data closes the fed stream
          _AwaitExit h h.StopWait
          :If h.Status≡'Running' ⍝ closing stdin wasn't enough — see _ForceKill
              h.Killed←_ForceKill h
          :EndIf
      :EndIf
      :Trap 0
          h.Tok ⎕TALLOC ¯1
      :Else
          ⍝ already released, or still in use — nothing more we can do
      :EndTrap
      r←⍬
    ∇

    ∇ {r}←_AwaitExit(h seconds)
      ⍝ Wait up to `seconds` (1s at a time, waking early on any queue or
      ⍝ status change) for the child to exit. Note ∧ below does NOT
      ⍝ short-circuit in Dyalog, which is fine here — both operands are
      ⍝ always safe to evaluate.
      n←seconds
      :While (h.Status≡'Running')∧(n>0)
          {}1 ⎕TGET h.SigTok
          n←n-1
      :EndWhile
      r←⍬
    ∇

    ∇ ok←_ForceKill h
      ⍝ Terminate the child process outright, for a server that ignores
      ⍝ its stdin being closed (ADR D18). A server blocked in a wait
      ⍝ with no timeout — test/09's `hang` mode is exactly this — never
      ⍝ notices EOF on stdin, so the graceful path above can only ever
      ⍝ time out and leave the process running forever. Worse, such an
      ⍝ orphan has been observed to block an entirely separate, later
      ⍝ process launch on Windows, so this isn't just housekeeping.
      ⍝
      ⍝ 9(8373⌶)tid: a POSITIVE right argument is an APL THREAD number
      ⍝ whose ⎕SHELL call is still running (a negative one would be a
      ⍝ negated PID, and only for processes ⎕SHELL has already given up
      ⍝ on) — h.Tid is exactly that thread. 9 is the only signal
      ⍝ Microsoft Windows accepts here, where it means TerminateProcess.
      ok←0
      :Trap 0
          ok←9(8373⌶)h.Tid
      :Else
          ⍝ thread already gone, or the OS refused — nothing else to try
      :EndTrap
      :If ok
          ⍝ ⎕SHELL returns on the killed thread shortly after; give _Run
          ⍝ a moment to record ExitCode/ExitReason and flip Status, so a
          ⍝ caller that inspects the handle right after Stop sees the
          ⍝ truth rather than a stale 'Running'.
          _AwaitExit h 5
      :EndIf
    ∇

    ∇ {r}←_Run h
      ⍝ Runs on its own thread (spawned by Start via &). Blocks in
      ⍝ ⎕SHELL for the lifetime of the child process.
      ⍝ Stream 2 (stderr) must NOT be left on its default, which merges
      ⍝ it into stream 1 — a server logging to stderr (perfectly legal;
      ⍝ see ADR D5) would otherwise corrupt the line-oriented protocol
      ⍝ stream our caller reads. Discard it via its own callback rather
      ⍝ than Output ('Null') — that destination, combined with a Token
      ⍝ input on a genuinely interactive child process, reliably
      ⍝ triggers "Invalid value received on token" (see ADR D11);
      ⍝ routing to a callback that just drops the data does not.
      opts←('Input'(0('Token'h.InTok)))('Output'((1('Callback'('_OnOutput'h)))(2('Callback'('_OnStderr'h)))))
      :If 0≠≢h.WorkingDir
          opts,←⊂('WorkingDir'h.WorkingDir)
      :EndIf
      result←⎕SHELL⍠opts⊢h.Cmd
      h.ExitCode←3⊃result
      h.ExitReason←4⊃result
      h.Pid←5⊃result
      h.Status←'Exited'
      h.SigTok ⎕TPUT h.SigTok ⍝ wake anyone still waiting so they see Status
      r←⍬
    ∇

    ∇ {r}←h _OnOutput info
      ⍝ Output ('Callback' ...) target for stream 1. info carries
      ⍝ .Output (new lines, possibly ending in a partial one), .Done,
      ⍝ .PartialLine — see ⎕SHELL's Output/Callback variant docs.
      lines←info.Output
      :If info.PartialLine∧~info.Done
          lines←¯1↓lines ⍝ incomplete last line, kept for next call
      :EndIf
      h.Lines,←lines
      h.SigTok ⎕TPUT h.SigTok
      r←1 ⍝ callback return value must be a Boolean scalar (continue)
    ∇

    ∇ {r}←h _OnStderr info
      ⍝ Output ('Callback' ...) target for stream 2 — discards
      ⍝ everything by default (see ADR D5/D11: a server's stderr
      ⍝ logging is none of our business, and we can't use Output
      ⍝ ('Null') here instead — see the comment in _Run), unless the
      ⍝ caller asked for it via opts.CaptureStderr, in which case the
      ⍝ lines are queued on the handle for debugging (ADR D18). Kept
      ⍝ opt-in because a chatty long-running server would otherwise
      ⍝ grow this queue without bound, with nothing ever draining it.
      ⍝ Deliberately does NOT ⎕TPUT h.SigTok: stderr arriving is not
      ⍝ news for anyone blocked in Receive, which only ever wants
      ⍝ stream 1.
      :If h.CaptureStderr
          lines←info.Output
          :If info.PartialLine∧~info.Done
              lines←¯1↓lines ⍝ incomplete last line, kept for next call
          :EndIf
          h.StderrLines,←lines
      :EndIf
      r←1
    ∇

:EndNamespace
