MODULE tkdemo;
(*
  tkdemo — a small Tk program: a counter, a text entry feeding a list box,
  and a canvas that draws a dot wherever you click.

  Build:  obc tkdemo.mod       (needs `wish` installed at run time)
*)

IMPORT Tk, Out, Strings;

VAR
  ev, tag, a1, a2, txt: ARRAY 256 OF CHAR;
  count, r: INTEGER;
  done: BOOLEAN;

(* Evaluate a script, reporting any Tcl error on stdout *)
PROCEDURE Do(script: ARRAY OF CHAR);
VAR err: ARRAY 256 OF CHAR; r: INTEGER;
BEGIN
  IF Tk.Eval(script) # 0 THEN
    r := Tk.Result(LEN(err), err);
    Out.String("Tk error: "); Out.String(err); Out.Ln
  END
END Do;

PROCEDURE BuildUI;
VAR r: INTEGER;
BEGIN
  Do("wm title . {Oberon + Tk}");
  Do("label .lbl -text {Count: 0} -font {Helvetica 18}");
  Do("button .inc -text {Increment} -command {ev inc}");
  Do("button .reset -text {Reset} -command {ev reset}");
  Do("entry .e -width 30");
  Do("button .add -text {Add to list} -command {ev add}");
  Do("bind .e <Return> {ev add}");
  Do("listbox .lb -height 6");
  Do("canvas .c -width 300 -height 120 -background white -relief sunken -borderwidth 2");
  Do("bind .c <Button-1> {ev click %x %y}");
  Do("button .quit -text {Quit} -command {ev quit}");
  Do("grid .lbl -row 0 -column 0 -columnspan 2 -pady 8");
  Do("grid .inc -row 1 -column 0 -sticky ew -padx 4");
  Do("grid .reset -row 1 -column 1 -sticky ew -padx 4");
  Do("grid .e -row 2 -column 0 -padx 4 -pady 8");
  Do("grid .add -row 2 -column 1 -sticky ew -padx 4");
  Do("grid .lb -row 3 -column 0 -columnspan 2 -sticky ew -padx 4");
  Do("grid .c -row 4 -column 0 -columnspan 2 -padx 4 -pady 8");
  Do("grid .quit -row 5 -column 0 -columnspan 2 -pady 8")
END BuildUI;

PROCEDURE ShowCount;
VAR n: ARRAY 32 OF CHAR; s: ARRAY 64 OF CHAR; r: INTEGER;
BEGIN
  Strings.IntToStr(count, n);
  Strings.Copy("Count: ", s);
  Strings.Append(n, s);
  r := Tk.Configure(".lbl", "text", s)
END ShowCount;

BEGIN
  IF Tk.Open() = 0 THEN
    r := Tk.Result(LEN(txt), txt);
    Out.String(txt); Out.Ln;
    HALT(1)
  END;
  BuildUI;
  count := 0;
  done := FALSE;
  WHILE ~done DO
    r := Tk.Wait(-1, LEN(ev), ev);
    IF r < 0 THEN
      done := TRUE                                (* window gone *)
    ELSE
      r := Tk.Word(ev, 0, LEN(tag), tag);
      IF Strings.Compare(tag, "inc") = 0 THEN
        INC(count); ShowCount
      ELSIF Strings.Compare(tag, "reset") = 0 THEN
        count := 0; ShowCount
      ELSIF Strings.Compare(tag, "add") = 0 THEN
        IF Tk.Eval(".e get") = 0 THEN
          r := Tk.Result(LEN(txt), txt);
          IF Strings.Length(txt) > 0 THEN
            r := Tk.Call1(".lb insert end", txt);
            Do(".e delete 0 end")
          END
        END
      ELSIF Strings.Compare(tag, "click") = 0 THEN
        r := Tk.Word(ev, 1, LEN(a1), a1);
        r := Tk.Word(ev, 2, LEN(a2), a2);
        r := Tk.Set("px", a1);
        r := Tk.Set("py", a2);
        Do(".c create oval [expr {$px - 5}] [expr {$py - 5}] [expr {$px + 5}] [expr {$py + 5}] -fill red")
      ELSIF (Strings.Compare(tag, "quit") = 0) OR (Strings.Compare(tag, "WM_DELETE_WINDOW") = 0) THEN
        done := TRUE
      END
    END
  END;
  Tk.Close
END tkdemo.

