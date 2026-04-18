MODULE FDTest;
(*
 * Smoke test for FileDialog.
 * Pops open a file dialog starting in the examples/ directory,
 * then prints the selected path (or "Cancelled").
 *)
IMPORT TUI, FileDialog, Out;

VAR
  result: ARRAY 512 OF CHAR;
  ok:     BOOLEAN;

BEGIN
  TUI.Init();
  ok := FileDialog.Show("Open File", "examples", ".mod", result);
  TUI.Done();
  IF ok THEN
    Out.String("Selected: "); Out.String(result); Out.Ln
  ELSE
    Out.String("Cancelled"); Out.Ln
  END
END FDTest.
