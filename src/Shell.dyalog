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

    ⎕IO←1 ⋄ ⎕ML←1

    ∇ h←{opts}Start cmd
      ⍝ cmd: a vector of character vectors — the program path followed
      ⍝ by its arguments — as accepted by ⎕SHELL for direct execution.
      ⍝ opts (optional): namespace, may set WorkingDir.
      :If 0=⎕NC'opts' ⋄ opts←() ⋄ :EndIf
      tok←⎕TALLOC 1('mcp-client:',⊃cmd)
      h←(
        Cmd:cmd
        WorkingDir:opts ⎕VGET⊂'WorkingDir' ''
        Lines:⍬
        Status:'Running'
        ExitCode:¯1 ⋄ ExitReason:¯1 ⋄ Pid:¯1
        Tok:tok ⋄ InTok:tok+0.1 ⋄ SigTok:tok+0.2
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
      ⍝ Close stdin, wait (up to ~10s) for the child to exit, release
      ⍝ the handle's token range. Safe to call more than once.
      ⍝ TODO: if the process hasn't exited by the deadline, force-kill
      ⍝ it via 8373⌶ instead of just giving up (see TODO.md).
      :If h.Status≡'Running'
          ⎕TPUT h.InTok ⍝ a token with no data closes the fed stream
          n←10
          :While (h.Status≡'Running')∧(n>0)
              {}1 ⎕TGET h.SigTok ⍝ wake on every queue/status change, 1s max
              n←n-1
          :EndWhile
      :EndIf
      :Trap 0
          h.Tok ⎕TALLOC ¯1
      :Else
          ⍝ already released, or still in use — nothing more we can do
      :EndTrap
      r←⍬
    ∇

    ∇ {r}←_Run h
      ⍝ Runs on its own thread (spawned by Start via &). Blocks in
      ⍝ ⎕SHELL for the lifetime of the child process.
      opts←('Input'(0('Token'h.InTok)))('Output'(1('Callback'('_OnOutput'h))))
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

:EndNamespace
