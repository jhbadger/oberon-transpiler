MODULE XModVarTest;
(*
 * Tests that cross-module exported VAR field access emits -> not .
 * Specifically: TUI.Focused.handle, TUI.Focused.x, etc.
 *)
IMPORT TUI, Out;

VAR ev: TUI.Event;

BEGIN
  TUI.Init();
  (* Access fields of TUI.Focused directly — previously emitted
     TUI_Focused.handle which the C compiler rejected as . on pointer *)
  IF TUI.Focused # NIL THEN
    IF TUI.Focused.handle # NIL THEN
      Out.String("focused view has handle"); Out.Ln
    END;
    Out.Int(TUI.Focused.x, 0); Out.Ln
  ELSE
    Out.String("no focused view (expected)"); Out.Ln
  END;
  TUI.Done()
END XModVarTest.
