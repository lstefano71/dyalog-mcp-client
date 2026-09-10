:Namespace Fff
⍝ High-level cover over Mcp, specific to the fff-mcp server (tested
⍝ against v0.10.6) — find_files/grep/multi_grep, ergonomic argument
⍝ shapes, and a best-effort parser turning fff-mcp's plain-text
⍝ "content" into structured APL results. Version-specific by design
⍝ (see docs/adr/0001-architecture-decisions.md, ADR D11) — the raw
⍝ text is always kept alongside whatever got parsed, so a caller can
⍝ fall back by hand when the parser doesn't recognize a shape.
⍝
⍝ Handle shape (adds to the Mcp handle it wraps):
⍝   Mcp     the underlying Mcp handle (see Mcp.dyalog)
⍝   Path    the directory this instance searches
⍝   Exe     the fff-mcp.exe path actually used

    ⎕IO←1 ⋄ ⎕ML←1

    ∇ exe←_DefaultExe
      ⍝ ⎕NQ'.' 'GetEnvironment' returned empty for every variable tried
      ⍝ under dyalogscript (see ADR D11) — read it via a trivial child
      ⍝ process instead. R is ⎕SHELL's 5-element result; ⊃⊃⊃R unwraps
      ⍝ (StreamData → its one stream's lines → the first line).
      R←⎕SHELL⍠('Shell'('cmd.exe' '/C'))⊢'echo %LOCALAPPDATA%'
      exe←(⊃⊃⊃R),'\fff-mcp\bin\fff-mcp.exe'
    ∇

    ∇ h←{opts}Connect path
      ⍝ path: directory to search (need not be a git repo — fff-mcp
      ⍝ works either way, just slower to index a large non-git tree
      ⍝ on a cold process).
      ⍝ opts (optional): may set Exe (fff-mcp.exe path override),
      ⍝ WorkingDir (defaults to path), Timeout — forwarded down to
      ⍝ Mcp.Connect/JsonRpc.Connect/Shell.Start.
      :If 0=⎕NC'opts' ⋄ opts←() ⋄ :EndIf
      exe←opts ⎕VGET⊂'Exe' _DefaultExe
      mcpOpts←⎕NS(WorkingDir:path)opts
      h←(
        Mcp:mcpOpts #.Mcp.Connect,⊂exe
        Path:path
        Exe:exe
      )
    ∇

    ∇ {r}←Disconnect h
      #.Mcp.Disconnect h.Mcp
      r←⍬
    ∇

    ∇ result←h Find args
      ⍝ args: a query (char vector), or a (query opts) pair — opts
      ⍝ may set cursor/maxResults, per find_files' inputSchema.
      (query opts)←_SplitArgs args
      arguments←⎕NS(query:query)opts
      raw←h.Mcp #.Mcp.CallTool('find_files' arguments)
      result←(_ParseFindFiles _WithParsed)raw
    ∇

    ∇ result←h Grep args
      ⍝ args: a query (char vector), or a (query opts) pair — opts
      ⍝ may set cursor/maxResults/context/output_mode, per grep's
      ⍝ inputSchema.
      (query opts)←_SplitArgs args
      arguments←⎕NS(query:query)opts
      raw←h.Mcp #.Mcp.CallTool('grep' arguments)
      result←(_ParseGrep _WithParsed)raw
    ∇

    ∇ result←h MultiGrep args
      ⍝ args: a vector of pattern char vectors, or (patterns opts) —
      ⍝ opts may set constraints/cursor/maxResults/context/
      ⍝ output_mode, per multi_grep's inputSchema.
      (patterns opts)←_SplitArgs args
      arguments←⎕NS(patterns:patterns)opts
      raw←h.Mcp #.Mcp.CallTool('multi_grep' arguments)
      result←(_ParseGrep _WithParsed)raw ⍝ same per-file/per-line shape as grep
    ∇

    ∇ (primary opts)←_SplitArgs args
      :If 1=≡args
          primary←args ⋄ opts←()
      :Else
          (primary opts)←args
      :EndIf
    ∇

    ∇ result←(parser _WithParsed)raw
      ⍝ parser: a monadic function operand (_ParseFindFiles or
      ⍝ _ParseGrep) run on the tool's text content. Always keeps
      ⍝ Raw/Text; only attempts to parse when the tool didn't itself
      ⍝ report an error (fff-mcp's error text has no documented shape,
      ⍝ so we don't guess at it).
      text←''
      :If 0≠≢raw.content ⋄ text←(⊃raw.content).text ⋄ :EndIf
      parsed←()
      ⍝ ⎕JSON represents JSON true/false as ⊂'true'/⊂'false' (ADR D11),
      ⍝ not 0/1 — disclose before testing.
      :If ~(⊃raw.isError)≡'true'
          :Trap 0
              parsed←parser text
          :Else
              ⍝ text didn't match the shape this parser recognizes —
              ⍝ Raw/Text are still there for the caller to fall back on.
          :EndTrap
      :EndIf
      result←⎕NS(Raw:raw ⋄ Text:text)parsed
    ∇

    ∇ (shown total)←_ParseCount header
      ⍝ "20/617 matches" -> 20 617 ; "3/49 matches shown" -> 3 49 ;
      ⍝ "0 matches." -> 0 0
      digits←'0123456789'
      shown←0 ⋄ total←0
      n1←+/∧\header∊digits
      :If n1>0
          shown←⍎n1↑header
          total←shown
          rest←n1↓header
          :If 0≠≢rest ⍝ ∧ isn't short-circuiting — see _ParseMatchLine
              :If '/'=1⊃rest
                  rest←1↓rest
                  n2←+/∧\rest∊digits
                  :If n2>0 ⋄ total←⍎n2↑rest ⋄ :EndIf
              :EndIf
          :EndIf
      :EndIf
    ∇

    ∇ (kind num text)←_ParseMatchLine line
      ⍝ Three annotated-line shapes fff-mcp emits (ground-truthed
      ⍝ against crates/fff-mcp/src/output.rs in the fff source):
      ⍝   " 59: ⎕SHADOW'mdiSofia_def'"   -> 'Match'      59 "⎕SHADOW'mdiSofia_def'"
      ⍝   " 59-some context line"        -> 'Context'    59 "some context line"
      ⍝   "  59| def MyFunction ..."     -> 'DefContext' 59 "def MyFunction ..."
      ⍝ kind is '' (not one of these — a new file boundary) otherwise.
      digits←'0123456789'
      kind←'' ⋄ num←0 ⋄ text←''
      t←(+/∧\' '=line)↓line
      :If 0=≢t ⋄ :Return ⋄ :EndIf
      nd←+/∧\t∊digits
      :If (nd>0)∧(nd<≢t)
          sep←(nd+1)⊃t
          :If sep∊':|-'
              :Select sep
              :Case ':' ⋄ kind←'Match'
              :Case '|' ⋄ kind←'DefContext'
              :Case '-' ⋄ kind←'Context'
              :EndSelect
              num←⍎nd↑t
              text←(nd+1)↓t
              ⍝ ∧ isn't short-circuiting in APL — 1⊃text on an empty
              ⍝ text would INDEX ERROR if these were combined in one :If.
              :If 0≠≢text
                  :If ' '=1⊃text ⋄ text←1↓text ⋄ :EndIf
              :EndIf
          :EndIf
      :EndIf
    ∇

    ∇ n←text _NumberBefore word
      ⍝ The integer immediately preceding the first occurrence of word
      ⍝ in text (e.g. "0 exact matches. 1 approximate:" 'approximate'
      ⍝ -> 1), or 0 if word doesn't occur or nothing digit-like
      ⍝ precedes it.
      digits←'0123456789'
      n←0
      hits←⍸word⍷text
      :If 0≠≢hits
          seg←(¯1+⊃hits)↑text
          :While (0≠≢seg)∧(' '=¯1↑seg) ⋄ seg←¯1↓seg ⋄ :EndWhile
          nd←+/∧\digits∊⍨⌽seg
          :If nd>0 ⋄ n←⍎¯nd↑seg ⋄ :EndIf
      :EndIf
    ∇

    ∇ parsed←_ParseFindFiles text
      ⍝ "N/Total matches\n<path>\n...\n{cursor: <token>}" — or, for no
      ⍝ matches at all, the single line "0 results (N indexed)"
      ⍝ (ground-truthed against fff's server.rs — note this is a
      ⍝ different phrase from grep's "0 matches.").
      nl←⎕UCS 10
      text←(text≠⎕UCS 13)/text ⍝ tolerate \r\n as well as bare \n
      lines←nl(≠⊆⊢)text
      :If (1=≢lines)∧(11≤≢⊃lines)∧('0 results ('≡11↑⊃lines)
          parsed←(Shown:0 ⋄ Total:0 ⋄ Cursor:'' ⋄ Suggestion:'' ⋄ Paths:⍬)
          :Return
      :EndIf
      suggestion←''
      :If (0≠≢lines)∧(2≤≢⊃lines)∧('→ '≡2↑⊃lines)
          suggestion←⊃lines
          lines←1↓lines
      :EndIf
      cursor←''
      :If (0≠≢lines)∧(8≤≢⊃¯1↑lines)∧('cursor: '≡8↑⊃¯1↑lines)
          cursor←8↓⊃¯1↑lines
          lines←¯1↓lines
      :EndIf
      ⍝ The "N/Total matches" header line is only present when the
      ⍝ result was actually paginated/counted — a find_files response
      ⍝ that fits in one page with nothing truncated is just the bare
      ⍝ list of paths, no header, no cursor.
      :If (0≠≢lines)∧(∨/'matches'⍷⊃lines)
          (shown total)←_ParseCount⊃lines
          lines←1↓lines
      :Else
          shown←≢lines ⋄ total←shown
      :EndIf
      parsed←(Shown:shown ⋄ Total:total ⋄ Cursor:cursor ⋄ Suggestion:suggestion ⋄ Paths:lines)
    ∇

    ∇ parsed←_ParseGrep text
      ⍝ "{→ Read <path> (only match|[def]|(best match))\n}
      ⍝  {N/Total matches shown\n}
      ⍝  <path>\n <num>: <line>\n <num>-<context line>\n
      ⍝   <num>| <definition context line>\n...\n{\ncursor: <token>}"
      ⍝ Ground-truthed against fff's output.rs. Two header shapes are
      ⍝ recognized but only degrade gracefully, not fully parsed —
      ⍝ still yields Files correctly, Shown/Total stay 0 (see TODO.md):
      ⍝   "0 matches for '<q>'. Auto-broadened to '<q2>':" (results for
      ⍝   the broadened query follow, on subsequent lines)
      ⍝   "0 content matches. But there is a relevant file path: <p>"
      ⍝   (a bare suggestion, no Files at all)
      nl←⎕UCS 10
      text←(text≠⎕UCS 13)/text ⍝ tolerate \r\n as well as bare \n
      lines←nl(≠⊆⊢)text
      ⍝ Unlike find_files, grep/multi_grep's cursor line is preceded
      ⍝ by a blank line (harmless: the per-file loop below skips blank
      ⍝ lines anyway) rather than following directly.
      cursor←''
      :If (0≠≢lines)∧(8≤≢⊃¯1↑lines)∧('cursor: '≡8↑⊃¯1↑lines)
          cursor←8↓⊃¯1↑lines
          lines←¯1↓lines
      :EndIf
      suggestion←''
      :If (0≠≢lines)∧(2≤≢⊃lines)∧('→ '≡2↑⊃lines)
          suggestion←⊃lines
          lines←1↓lines
      :EndIf
      shown←0 ⋄ total←0 ⋄ files←⍬
      hadHeader←0
      :If 0≠≢lines
          ⍝ The count header is also omitted for a single "only match"
          ⍝ result (the → Read suggestion line already says as much) —
          ⍝ same "no header when redundant" pattern as find_files.
          :If ∨/'matches'⍷⊃lines
              :If ∨/'approximate'⍷⊃lines
                  ⍝ "0 exact matches. N approximate:" — the meaningful
                  ⍝ count is N (approximate), not the leading 0 (exact).
                  shown←total←(⊃lines)_NumberBefore'approximate'
              :Else
                  (shown total)←_ParseCount⊃lines
              :EndIf
              lines←1↓lines
              hadHeader←1
          :EndIf
          curPath←'' ⋄ curMatches←⍬
          :For ln :In lines
              :If (0=≢ln)∨(ln≡'--') ⋄ :Continue ⋄ :EndIf ⍝ blank/ripgrep-style separator
              (kind num mtext)←_ParseMatchLine ln
              :If 0≠≢kind
                  curMatches,←⊂(LineNum:num ⋄ Text:mtext ⋄ Kind:kind)
              :Else
                  :If 0≠≢curPath ⋄ files,←⊂(Path:curPath ⋄ Matches:curMatches) ⋄ :EndIf
                  curPath←ln ⋄ curMatches←⍬
              :EndIf
          :EndFor
          :If 0≠≢curPath ⋄ files,←⊂(Path:curPath ⋄ Matches:curMatches) ⋄ :EndIf
      :EndIf
      :If (~hadHeader)∧(0≠≢files)
          ⍝ Only count real matches, not context/definition-context
          ⍝ lines riding along with them.
          n←+/'Match'∘≡¨(∊files.Matches).Kind
          shown←total←n
      :EndIf
      parsed←(Shown:shown ⋄ Total:total ⋄ Cursor:cursor ⋄ Suggestion:suggestion ⋄ Files:files)
    ∇

:EndNamespace
