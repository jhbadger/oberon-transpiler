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

  Phase 3 — Standard widgets in Oberon (Modules/Widgets.mod)

  - [ ] Label: static text
  - [ ] Button: focusable, fires command on Enter/Space
  - [ ] InputLine: single-line text entry with cursor, insert/delete
  - [ ] ListBox: scrollable list, keyboard + mouse navigation
  - [ ] ScrollBar: vertical and horizontal, connected to a scroller
  - [ ] CheckBox / RadioButton group
  - [ ] StaticText: multi-line read-only text area (for output dialogs)
  - [ ] MenuBar + MenuItem + SubMenu
  - [ ] StatusLine: bottom bar with hotkey hints

  Phase 4 — File dialog in Oberon

  - [ ] Read directory entries (needs OS.ReadDir or a small C helper)
  - [ ] FileDialog: path input, scrollable file list, filter (*.mod)

  Phase 5 — IDE application in Oberon (ide.mod)

  Uses Editor (C FFI), TUI framework, and Widgets — replaces oberon_ide.cpp.

  - [ ] EditorView: wraps the C Editor handle, renders buffer via TUI screen
          syntax highlighting (Oberon keywords, comments, strings, numbers)
          line number gutter
          error line highlight with inline annotation
  - [ ] EditorWindow: Window containing an EditorView + scrollbars + indicator
  - [ ] Multi-window desktop: window registry, Alt-1..9 switching, tile/cascade
  - [ ] Menu bar: File / Edit / Run / Search / Window / Help
  - [ ] Run/Compile: fork obc, capture stderr, parse error line, jump to it
  - [ ] Help system: load stdlib.md, searchable topic list + description panel
  - [ ] Autocomplete: keyword + identifier prefix match, picker dialog
  - [ ] Recent files: persist to ~/.oberon_ide_recent
  - [ ] Goto line, Find, Replace dialogs

  Phase 6 — Build integration

  - [ ] Update Makefile: compile Editor.c alongside the Oberon sources
  - [ ] Confirm IDE binary works on macOS and Linux (Termux stretch goal)
  - [ ] Remove tvision directory and oberon_ide.cpp once IDE is stable

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