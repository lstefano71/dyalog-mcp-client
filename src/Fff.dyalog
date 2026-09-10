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

    ∇ n←_ToInt digits
      ⍝ digits: a character vector already confirmed to hold only
      ⍝ '0123456789' (every call site here pre-filters with that exact
      ⍝ digit set before slicing — never a '-', so ⎕VFI's high-minus
      ⍝ requirement for negatives never applies). ⎕VFI, not ⍎ — this
      ⍝ text comes from the server, and ⍎ on unvalidated input is a
      ⍝ code-injection risk even when the caller believes it's clean.
      ⍝ ⎕VFI's second result is a 1-element VECTOR, not a true scalar
      ⍝ (⍴ shows 1, not ⍬) — ⊃ discloses it down to a genuine scalar.
      ⍝ Never visibly wrong before (it prints and does arithmetic
      ⍝ exactly like a scalar as long as nothing gathers several of
      ⍝ them across an array of namespace refs via dot notation) —
      ⍝ surfaced only once _ParseCountLines' Counts.Count did exactly
      ⍝ that: dot-distribution over several refs wraps each non-scalar
      ⍝ leaf in its own enclosure to build the combined array, and the
      ⍝ resulting nested (mixed) value made a later :If's condition
      ⍝ come out nested instead of a plain boolean, DOMAIN ERRORing
      ⍝ with "Boolean singleton value required". See ADR D15.
      n←⊃2⊃⎕VFI digits
    ∇

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
      ⍝ inputSchema. output_mode drives which _ParseGrep shape is
      ⍝ attempted (see ADR D15) — 'content' (the default, and also
      ⍝ what fff-mcp calls 'usage') if unset.
      (query opts)←_SplitArgs args
      arguments←⎕NS(query:query)opts
      mode←opts ⎕VGET⊂'output_mode' 'content'
      raw←h.Mcp #.Mcp.CallTool('grep' arguments)
      result←((mode∘_ParseGrep) _WithParsed)raw
    ∇

    ∇ result←h MultiGrep args
      ⍝ args: a vector of pattern char vectors, or (patterns opts) —
      ⍝ opts may set constraints/cursor/maxResults/context/
      ⍝ output_mode, per multi_grep's inputSchema.
      (patterns opts)←_SplitArgs args
      arguments←⎕NS(patterns:patterns)opts
      mode←opts ⎕VGET⊂'output_mode' 'content'
      raw←h.Mcp #.Mcp.CallTool('multi_grep' arguments)
      result←((mode∘_ParseGrep) _WithParsed)raw ⍝ same per-file/per-line shape as grep
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
          shown←_ToInt n1↑header
          total←shown
          rest←n1↓header
      :AndIf 0≠≢rest
      :AndIf '/'=1⊃rest
          rest←1↓rest
          n2←+/∧\rest∊digits
      :AndIf n2>0
          total←_ToInt n2↑rest
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
      :AndIf sep∊':|-'
          :Select sep
          :Case ':' ⋄ kind←'Match'
          :Case '|' ⋄ kind←'DefContext'
          :Case '-' ⋄ kind←'Context'
          :EndSelect
          num←_ToInt nd↑t
          text←(nd+1)↓t
          ⍝ ∧ isn't short-circuiting in APL — 1⊃text on an empty text
          ⍝ would INDEX ERROR if these were combined into one :If with
          ⍝ ∧; :AndIf short-circuits properly instead.
      :AndIf 0≠≢text
      :AndIf ' '=1⊃text
          text←1↓text
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
      :AndIf nd>0
          ⍝ ¯ is only valid as part of a numeric literal (¯1), not as
          ⍝ negation of a variable — ¯nd↑seg is a SYNTAX ERROR; the
          ⍝ actual negate-a-variable idiom is monadic -, (-nd)↑seg.
          ⍝ Never hit until this parser's "approximate" fallback path
          ⍝ was actually exercised against a real response — see ADR D15.
          n←_ToInt(-nd)↑seg
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

    ∇ q←_BroadenedTo line
      ⍝ "0 matches for '<q>'. Auto-broadened to '<q2>':" -> q2, or ''
      ⍝ when line isn't this shape (ground-truthed against server.rs'
      ⍝ perform_grep: the retry text is appended right after the
      ⍝ closing "':" with no space). qc is a single-quote character,
      ⍝ built via ⎕UCS rather than APL's doubled-quote literal escape
      ⍝ so the marker text reads plainly.
      qc←⎕UCS 39
      q←''
      prefix←'0 matches for ',qc
      marker←qc,'. Auto-broadened to ',qc
      :If prefix≡(≢prefix)↑line
          hits←⍸marker⍷line
      :AndIf 0≠≢hits
          rest←(((⊃hits)-1)+≢marker)↓line
          closer←qc,':'
      :AndIf closer≡¯2↑rest
          q←¯2↓rest
      :EndIf
    ∇

    ∇ p←_SuggestedPathFrom line
      ⍝ "0 content matches. But there is a relevant file path: <p>" ->
      ⍝ p, or '' when line isn't this shape.
      prefix←'0 content matches. But there is a relevant file path: '
      p←''
      :If prefix≡(≢prefix)↑line
          p←(≢prefix)↓line
      :EndIf
    ∇

    ∇ (path isDef)←_StripDefTag line
      ⍝ files_with_matches path lines may carry a trailing " [def]"
      ⍝ tag and/or a large-file size tag ("... (NNKB - use offset to
      ⍝ read relevant section)") — ground-truthed against output.rs'
      ⍝ format_files_with_matches/size_tag. Strip both, returning the
      ⍝ bare path and whether [def] was present.
      path←line ⋄ isDef←0
      sizeMarker←'KB - use offset to read relevant section)'
      hits←⍸sizeMarker⍷path
      :If 0≠≢hits
          openHits←⍸' ('⍷(¯1+⊃hits)↑path
          :If 0≠≢openHits
              path←(¯1+⊃¯1↑openHits)↑path
          :EndIf
      :EndIf
      defTag←' [def]'
      :If (≢defTag)≤≢path
      :AndIf defTag≡(-≢defTag)↑path
          isDef←1
          path←(-≢defTag)↓path
      :EndIf
    ∇

    ∇ (path num ok)←_ParseCountLine line
      ⍝ "{path}: {count}" (output.rs' format_count) -> path count 1,
      ⍝ or '' 0 0 when line doesn't end in ": <digits>".
      digits←'0123456789'
      path←'' ⋄ num←0 ⋄ ok←0
      sep←': '
      hits←⍸sep⍷line
      :If 0≠≢hits
          idx←⊃¯1↑hits
          rest←((idx-1)+≢sep)↓line
      :AndIf (0≠≢rest)∧(∧/rest∊digits)
          path←(idx-1)↑line
          num←_ToInt rest
          ok←1
      :EndIf
    ∇

    ∇ (shown total files)←_ParseGrepContentLines lines
      ⍝ The default ('content'/'usage') per-line shape, and also the
      ⍝ shape of every mode-independent fallback text (see
      ⍝ _ParseGrep) regardless of the output_mode actually requested —
      ⍝ ground-truthed against output.rs' GrepFormatter::format and
      ⍝ server.rs' fuzzy-fallback text builder, both of which always
      ⍝ emit this shape.
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
    ∇

    ∇ (shown total files)←_ParseFilesWithMatches lines
      ⍝ output_mode:'files_with_matches' (output.rs'
      ⍝ format_files_with_matches): never has a "N/Total matches"
      ⍝ header (Shown/Total default to the file count instead), but
      ⍝ path lines can carry a genuine "[def]" tag — unlike every
      ⍝ other mode. Preview ("  N: text") and def-expansion
      ⍝ ("  N| text") lines reuse _ParseMatchLine unchanged: it
      ⍝ strips all leading spaces before counting digits, so the
      ⍝ extra indentation here classifies the same as content mode's
      ⍝ Match/DefContext lines.
      files←⍬
      curPath←'' ⋄ curIsDef←0 ⋄ curMatches←⍬
      :For ln :In lines
          :If (0=≢ln)∨(ln≡'--') ⋄ :Continue ⋄ :EndIf
          (kind num mtext)←_ParseMatchLine ln
          :If 0≠≢kind
              curMatches,←⊂(LineNum:num ⋄ Text:mtext ⋄ Kind:kind)
          :Else
              :If 0≠≢curPath ⋄ files,←⊂(Path:curPath ⋄ IsDef:curIsDef ⋄ Matches:curMatches) ⋄ :EndIf
              (curPath curIsDef)←_StripDefTag ln
              curMatches←⍬
          :EndIf
      :EndFor
      :If 0≠≢curPath ⋄ files,←⊂(Path:curPath ⋄ IsDef:curIsDef ⋄ Matches:curMatches) ⋄ :EndIf
      shown←total←≢files
    ∇

    ∇ (shown total counts)←_ParseCountLines lines
      ⍝ output_mode:'count' (output.rs' format_count): one
      ⍝ "{path}: {count}" line per file, no header at all. Total is
      ⍝ the sum of the per-file counts (the closest analogue to
      ⍝ "total matches" this mode's text actually carries).
      counts←⍬ ⋄ total←0
      :For ln :In lines
          :If 0=≢ln ⋄ :Continue ⋄ :EndIf
          (path num ok)←_ParseCountLine ln
          :If ok
              counts,←⊂(Path:path ⋄ Count:num)
              total←total+num
          :EndIf
      :EndFor
      shown←total
    ∇

    ∇ parsed←{mode}_ParseGrep text
      ⍝ mode ('content' default | 'files_with_matches' | 'count' —
      ⍝ matches grep/multi_grep's output_mode; 'usage', per output.rs,
      ⍝ is textually identical to 'content'/the default, so it needs
      ⍝ no separate handling). See ADR D15 for the full shape catalog.
      ⍝
      ⍝ "{→ Read <path> (only match|[def]|(best match))\n}
      ⍝  {N/Total matches shown\n}
      ⍝  <path>\n <num>: <line>\n <num>-<context line>\n
      ⍝   <num>| <definition context line>\n...\n{\ncursor: <token>}"
      ⍝ (default mode) — or files_with_matches'/count's own per-file
      ⍝ shapes (_ParseFilesWithMatches/_ParseCountLines). A handful of
      ⍝ header/fallback shapes are emitted the *same way regardless of
      ⍝ output_mode* (ground-truthed against server.rs' perform_grep,
      ⍝ which builds them directly rather than through GrepFormatter)
      ⍝ and are recognized before any mode-specific dispatch:
      ⍝   "0 matches for '<q>'. Auto-broadened to '<q2>':" then, on
      ⍝   the same text, a normal *mode-formatted* grep result for the
      ⍝   broadened query (server.rs re-invokes GrepFormatter with the
      ⍝   original output_mode for the retry) — Broadened is set to
      ⍝   <q2> and the remaining lines are parsed exactly as if they
      ⍝   were the whole response.
      ⍝   "0 content matches. But there is a relevant file path: <p>"
      ⍝   -> SuggestedPath, no Files/Counts at all.
      ⍝   "0 matches." / "0 exact matches. N approximate:" -> always
      ⍝   this content-style shape, whatever output_mode was asked
      ⍝   for (server.rs builds this text directly, not through
      ⍝   GrepFormatter, so it never varies with output_mode).
      :If 0=⎕NC'mode' ⋄ mode←'content' ⋄ :EndIf
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
      broadened←''
      :If 0≠≢lines
          broadened←_BroadenedTo⊃lines
      :AndIf 0≠≢broadened
          lines←1↓lines ⍝ what remains is a normal, mode-formatted result
      :EndIf
      :If (1=≢lines)∧(0≠≢_SuggestedPathFrom⊃lines)
          parsed←(Shown:0 ⋄ Total:0 ⋄ Cursor:cursor ⋄ Suggestion:'' ⋄ Broadened:broadened ⋄ SuggestedPath:_SuggestedPathFrom⊃lines ⋄ Files:⍬ ⋄ Counts:⍬)
          :Return
      :EndIf
      suggestion←''
      :If (0≠≢lines)∧(2≤≢⊃lines)∧('→ '≡2↑⊃lines)
          suggestion←⊃lines
          lines←1↓lines
      :EndIf
      :If (1=≢lines)∧('0 matches.'≡⊃lines)
          parsed←(Shown:0 ⋄ Total:0 ⋄ Cursor:cursor ⋄ Suggestion:suggestion ⋄ Broadened:broadened ⋄ SuggestedPath:'' ⋄ Files:⍬ ⋄ Counts:⍬)
          :Return
      :EndIf
      counts←⍬
      :If (0≠≢lines)∧(∨/'approximate'⍷⊃lines)
          ⍝ The fuzzy-fallback text is content-style regardless of
          ⍝ what output_mode was requested — see the function header.
          (shown total files)←_ParseGrepContentLines lines
      :ElseIf mode≡'files_with_matches'
          (shown total files)←_ParseFilesWithMatches lines
      :ElseIf mode≡'count'
          files←⍬
          (shown total counts)←_ParseCountLines lines
      :Else
          (shown total files)←_ParseGrepContentLines lines
      :EndIf
      parsed←(Shown:shown ⋄ Total:total ⋄ Cursor:cursor ⋄ Suggestion:suggestion ⋄ Broadened:broadened ⋄ SuggestedPath:'' ⋄ Files:files ⋄ Counts:counts)
    ∇

:EndNamespace
