Oberon TUI IDE (rewrite oberon_ide.cpp in Oberon)

  Goal: eliminate the tvision dependency by building a TUI framework and IDE
  entirely in Oberon, using the FFI mechanism for any C-backed pieces.

  Phase 1 — Foundation (C-backed, FFI-wrapped) ✓

  - [x] Write Editor.c: gap-buffer text editor in C
          gap buffer with insert/delete, cursor movement, undo stack
          find/replace (forward, with wrap)
          file load/save
          API named Editor_* to match Oberon convention (no .ffi remapping needed)
  - [x] Write Editor.mod stub: procedure signatures + opaque handle type
          so the type checker and codegen know the interface
  - [x] Write Editor.h (or generate from Editor.mod):
          declares Editor_Open, Editor_Insert, Editor_Delete, Editor_Save, etc.
  - [x] FFI mechanism: .ffi file format (HEADER/LINK/MAP/CSRC), parsed by obc;
          CSRC files tracked separately so obc never deletes them after linking

  Phase 2 — TUI framework in Oberon (Modules/TUI.mod) ✓

  Builds on the existing Terminal and Graphics modules.

  - [x] Screen cell model: RECORD with char + fg + bg; double-buffered
          only redraw cells that changed (avoids flicker)
          Box-drawing chars stored as 0xC0–0xC5 pseudo-bytes; Flush
          maps them to UTF-8 sequences to avoid multi-byte CHAR issues.
  - [x] Event loop: parse ANSI escape sequences for arrow keys, function
          keys, Ctrl-chords, and mouse (click + drag) — delegates to
          Terminal.ReadKey; PollEvent/WaitEvent wrap it.
  - [x] Base View type: bounds (x, y, w, h), draw procedure variable,
          handleEvent procedure variable, next/child pointers
  - [x] Focus management: single focused view (Focused*), Tab cycles forward
  - [x] Window type (extends View): title bar, border, moveable flag
          DrawWindow auto-draws border + centred title, then calls draw proc.
  - [x] Desktop: z-ordered list of windows; hit-test for mouse; TileWindows
  - [x] Modal dialog execution: RunModal — push event loop, return command code

  Two transpiler bugs were fixed to support cross-module IS/WITH and
  pointer-field access on imported pointer types (codegen.c):
    - is_ptr_type: cross-module fallback via find_type_decl
    - _TAG_Mod.Type → _TAG_Mod_Type in IS/WITH emission
    - Prefixed _TAG_Mod_TypeName exported in module headers

  Phase 3 — Standard widgets in Oberon (Modules/Widgets.mod) ✓

  - [x] Label: static text
  - [x] Button: focusable, fires command on Enter/Space (onClick callback or TUI.ModalResult)
  - [x] InputLine: single-line text entry with cursor, insert/delete, horizontal scroll
  - [x] ListBox: scrollable list, keyboard + mouse navigation, onClick callback
  - [x] CheckBox: toggle with keyboard and mouse
  - [x] StaticText: multi-line read-only text area (newline-delimited)
  - [x] MenuBar + dropdown menus, separators, keyboard + mouse, onCmd callback
  - [x] StatusLine: bottom bar with hint text
  Smoke test: tests/widgettest.mod
  Note: ScrollBar and RadioButton group deferred (not needed for Phase 4/5).

  Phase 4 — File dialog in Oberon ✓

  - [x] OS.DirOpen/DirCount/DirName/DirIsDir added to OS module in codegen
          sorts entries: directories first (with ".." at top), then alpha
          filter is a suffix string (e.g. ".mod"); empty = show all files
  - [x] FileDialog.Show(title, startPath, filter, VAR result): BOOLEAN
          self-contained modal event loop (saves/restores TUI.Desktop)
          Tab cycles focus among list / filename input / OK / Cancel
          Enter on directory = navigate in; Enter on file = accept
          Esc or Cancel button = cancel
  Smoke test: tests/fdtest.mod
  Fix: cross-module VAR field access bug fully fixed in codegen.c — TUI.Focused.handle
       now correctly emits ->. g_xmod_vardecls table + find_type_decl xmod fallback.

  Phase 5 — IDE application in Oberon (ide.mod)

  Uses Editor (C FFI), TUI framework, and Widgets — replaces oberon_ide.cpp.

  - [x] EditorView: wraps the C Editor handle, renders buffer via TUI screen
          syntax highlighting (Oberon keywords, comments, strings, numbers)
          line number gutter
          error line highlight with inline annotation
  - [x] EditorWindow: Window containing an EditorView + scrollbars + indicator
  - [x] Multi-window desktop: window registry, Alt-1..9 switching, tile/cascade
  - [x] Menu bar: File / Edit / Build / Window / Help
  - [x] Run/Compile: fork obc, capture stderr, parse error line, jump to it
  - [x] Help system: Modules/Help.mod — F1 looks up word under cursor in stdlib.md;
          modal dialog with InputLine search, scrollable results, section headings
  - [x] Autocomplete: keyword + identifier prefix match, picker dialog
          Ctrl+Space triggers popup; Up/Down navigate; Enter/Tab accept; Esc dismiss
          Re-filters live on each printable char/backspace
  - [ ] Recent files: persist to ~/.oberon_ide_recent
  - [x] Goto line, Find dialogs

High impact / frequently needed
  1. [x] Undo  circular buffer, UOpEdit/UOpSplit/UOpJoin, Ctrl+Z
  2. [x] Auto-indent  Enter copies leading whitespace; smart indent adds 4 spaces
          after BEGIN/THEN/ELSE/DO/REPEAT/RECORD/OF/WITH/LOOP; auto-dedent
          when END/UNTIL/ELSE/ELSIF typed alone on a line
  3. [x] Save prompt on close/quit  "Modified. Close without saving? (Y/N)"
  4. [ ] Jump to error line  when compile fails, parse the error message (e.g.
          file.mod:42:) and move the cursor there

  Useful quality-of-life
  5. [ ] Line numbers  gutter showing line numbers alongside the text
  6. [ ] Find & Replace  currently only Find
  7. [ ] Copy to system clipboard / paste from it  kill/yank works within one
          window but not across windows or with external programs
  8. [ ] Bracket/BEGIN–END matching  highlight the matching delimiter

  Nice to have eventually
  9. [ ] Recent files menu
  10. [ ] Word wrap toggle
  11. [ ] Configurable tab width
  12. [x] Help/keybindings viewer  (Help.mod, F1)

----

Z-machine v5 crash investigation

  Symptom

  Running Heidi.z5 (a simple v5 Inform game), the interpreter prints the game
  banner up to "Release " then crashes into an infinite loop executing garbage
  instructions.

  Debug trace

  Added file-based logging of each instruction's PC and opbyte. The trace shows:

  0x379e  print_paddr    → emits "Release "
  0x37a0  rtrue          → returns 1, restores PC to 0x0cdd7
  0xcdd7  2OP:23 (div)   → SC(77), var(0x8A), store L2
  0xcDDB  2OP:0          → undefined, skipped (3 bytes)
  0xcDDE  1OP:15         → call_1n, packed operand = 3
            PackedAddr(3) = 3×4 = 12 = 0x000C  ← inside the header!
  0x000D  garbage...     → RB(0x000C)=11, treats it as "11 locals"
           then executes through the header into infinite loop of 0x00 bytes

  Root cause: wrong operand in call_1n

  The call_1n at 0xcDDE reads a 2-byte large-constant operand = 0x0003. Calling
  PackedAddr(3) = 12, which lands inside the Z-machine header. No legitimate
  game calls into the header; this is clearly a decoding error.

  Why the operand is wrong: PC misalignment

  The bytes at 0xcDDB are 0x00 0x00 0xC9. The interpreter decodes 0x00 as
  undefined 2OP:0, reads 2 operand bytes (consuming 0x00 and 0xC9), does nothing
   with them, and advances PC by 3 to 0xcDDE. But 2OP:0 is not a real
  opcode—those bytes are actually part of the surrounding instruction stream,
  and consuming them as a 3-byte no-op puts the PC two bytes ahead of where it
  should be. The subsequent 0x8F 0x00 0x03 then gets decoded as call_1n
  packed(3) instead of whatever the real instruction is.

  Why is there a 2OP:0 at 0xcDDB?

  Working backwards: the frame with retPC=0xcdd7 was pushed by a call_vn2
  instruction at 0xcdd0. After decoding that call's type bytes and operands, PC
  lands at 0xcdd7. Then:
  - div at 0xcdd7 (4 bytes) → PC = 0xcDDB
  - Something at 0xcDDB that decodes as 0x00

  The real question is whether the div at 0xcdd7 is itself correct, or whether
  the PC was already misaligned when it returned there from rtrue.

  What's still unknown

  The call chain leading from iPC=0x2969 all the way to the function at 0x379e
  hasn't been fully traced. It's possible that:

  1. An earlier opcode was decoded with the wrong byte-count (consuming too many
   or too few bytes), putting the PC out of sync, and everything from 0xcdd7
  onward is being read at the wrong offset.
  2. A v5-specific opcode is being decoded as if it were v3, with a different
  number of operand bytes or a missing/extra store-var byte.

  Next steps

  - Fix DbgHex (currently truncates addresses to 16 bits, masking addresses like
   0x1380C → shown as 0x380C)
  - Add call/return tracing to see the full call chain and verify each retPC is
  set correctly
  - Check v5-specific opcodes where our byte-count might differ from the spec
  (especially opcodes that conditionally have a store variable or branch byte in
   v4+ but not v3)