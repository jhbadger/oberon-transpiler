MODULE TUITest;
(*
 * Smoke test for the TUI framework.
 *
 * Opens two windows on the desktop, demonstrates:
 *   - double-buffered rendering
 *   - focus (Tab to cycle)
 *   - mouse click focus transfer
 *   - Esc to quit
 *)

IMPORT TUI, Out;

VAR
  winA, winB: TUI.Window;
  ev: TUI.Event;
  running: BOOLEAN;

(* ── Draw proc for window A ─────────────────────────────────────────── *)

PROCEDURE DrawA(v: TUI.View);
VAR w: TUI.Window;
BEGIN
  WITH v: TUI.WindowRec DO
    w := v;
    TUI.PutStr(w.x + 2, w.y + 2, "Hello from Window A!", TUI.White, TUI.Black);
    TUI.PutStr(w.x + 2, w.y + 3, "Tab = cycle focus", TUI.Cyan, TUI.Black);
    TUI.PutStr(w.x + 2, w.y + 4, "Esc = quit", TUI.Cyan, TUI.Black)
  END
END DrawA;

(* ── Draw proc for window B ─────────────────────────────────────────── *)

PROCEDURE DrawB(v: TUI.View);
VAR w: TUI.Window;
BEGIN
  WITH v: TUI.WindowRec DO
    w := v;
    TUI.PutStr(w.x + 2, w.y + 2, "Hello from Window B!", TUI.White, TUI.Black);
    TUI.PutInt(w.x + 2, w.y + 3, TUI.Cols, TUI.Yellow, TUI.Black);
    TUI.PutStr(w.x + 8, w.y + 3, " cols", TUI.Yellow, TUI.Black);
    TUI.PutInt(w.x + 2, w.y + 4, TUI.Rows, TUI.Yellow, TUI.Black);
    TUI.PutStr(w.x + 8, w.y + 4, " rows", TUI.Yellow, TUI.Black)
  END
END DrawB;

(* ── Handle proc (shared) — Esc exits ──────────────────────────────── *)

PROCEDURE HandleKey(v: TUI.View; ev: TUI.Event): BOOLEAN;
BEGIN
  IF ev.key = TUI.KEsc THEN
    running := FALSE;
    RETURN TRUE
  END;
  RETURN FALSE
END HandleKey;

(* ── Main ────────────────────────────────────────────────────────────── *)

BEGIN
  TUI.Init();

  (* Create Window A *)
  NEW(winA);
  winA.x := 2;   winA.y := 2;
  winA.w := 30;  winA.h := 8;
  winA.title    := "Window A";
  winA.moveable := FALSE;
  winA.draw     := DrawA;
  winA.handle   := HandleKey;
  winA.next     := NIL;
  winA.child    := NIL;
  winA.focused  := FALSE;

  (* Create Window B *)
  NEW(winB);
  winB.x := 35;  winB.y := 4;
  winB.w := 30;  winB.h := 8;
  winB.title    := "Window B";
  winB.moveable := FALSE;
  winB.draw     := DrawB;
  winB.handle   := HandleKey;
  winB.next     := NIL;
  winB.child    := NIL;
  winB.focused  := FALSE;

  TUI.AddView(winB);   (* add behind-most first... *)
  TUI.AddView(winA);   (* ...winA ends up in front *)
  TUI.SetFocus(winA);

  running := TRUE;
  REPEAT
    TUI.ClearBack(TUI.White, TUI.Black);
    TUI.DrawAll();
    TUI.Flush();
    TUI.WaitEvent(ev);
    IF TUI.Dispatch(ev) THEN END
  UNTIL ~running;

  TUI.Done()
END TUITest.
