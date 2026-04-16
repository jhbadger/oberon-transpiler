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