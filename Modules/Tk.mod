MODULE Tk;
(*
 * Tk — graphical user interfaces through Tcl/Tk.  C implementation, FFI-bound
 * via Tk.ffi (Tk.c / OBCTk.h).
 *
 * This stub is documentation only; obc uses Tk.ffi instead.
 *
 * How it works
 *   A `wish` interpreter is started as a child process and driven over pipes,
 *   so nothing is linked against Tcl/Tk: you only need `wish` (Tk 8.5+) on the
 *   machine at run time.  Set the environment variable OBC_WISH to choose a
 *   particular wish executable.
 *
 *   You build the interface by sending ordinary Tcl/Tk commands with Tk.Eval.
 *   The interpreter predefines one extra command, `ev`, which queues a string
 *   for your program:
 *
 *       button .go -text Go -command {ev go}
 *       bind .c <Button-1> {ev click %x %y}
 *
 *   The program receives those strings with Tk.Wait, normally in a loop.
 *   Closing the main window delivers the event "WM_DELETE_WINDOW" (the window
 *   stays open until your program calls Tk.Close or sends `destroy .`).
 *
 * Calling convention
 *   Input strings are NUL-terminated.  Output buffers are preceded by an
 *   explicit bufsize INTEGER; pass LEN(buf).  Output is truncated and always
 *   NUL-terminated.  Note that Oberon strings are limited to 256 bytes, so use
 *   Tk.Call1..3 / Tk.Configure / Tk.Set to pass long or awkward text (they quote
 *   every argument), rather than gluing text into a script yourself.
 *
 *   Note: obc treats a one-character string literal (e.g. "x") as a CHAR, so it cannot be passed
 *   where a string is expected.  Use names/values of two or more characters, or a string variable.
 *)

(* Lifecycle *)
PROCEDURE Open*(): INTEGER;                 BEGIN RETURN 0 END Open;    (* 1 = ok, 0 = failed; see Result *)
PROCEDURE Alive*(): INTEGER;                BEGIN RETURN 0 END Alive;
PROCEDURE Close*;                           BEGIN END Close;

(* Evaluation: 0 = ok, 1 = Tcl error.  The value or message is kept for Result*. *)
PROCEDURE Eval*(script: ARRAY OF CHAR): INTEGER;           BEGIN RETURN 0 END Eval;
PROCEDURE Result*(bufsize: INTEGER; VAR buf: ARRAY OF CHAR): INTEGER;
BEGIN RETURN 0 END Result;                                 (* returns full length *)
PROCEDURE ResultInt*(): INTEGER;            BEGIN RETURN 0 END ResultInt;
PROCEDURE ResultReal*(): REAL;              BEGIN RETURN 0.0 END ResultReal;

(* "cmd a1 ..." with each argument quoted; cmd itself may hold several plain
   words, e.g. Tk.Call1(".list insert end", text) *)
PROCEDURE Call1*(cmd, a1: ARRAY OF CHAR): INTEGER;         BEGIN RETURN 0 END Call1;
PROCEDURE Call2*(cmd, a1, a2: ARRAY OF CHAR): INTEGER;     BEGIN RETURN 0 END Call2;
PROCEDURE Call3*(cmd, a1, a2, a3: ARRAY OF CHAR): INTEGER; BEGIN RETURN 0 END Call3;

(* widget configure -option value;   set var value;   value of var *)
PROCEDURE Configure*(widget, option, value: ARRAY OF CHAR): INTEGER; BEGIN RETURN 0 END Configure;
PROCEDURE Set*(var, value: ARRAY OF CHAR): INTEGER;                  BEGIN RETURN 0 END Set;
PROCEDURE Get*(var: ARRAY OF CHAR; bufsize: INTEGER; VAR buf: ARRAY OF CHAR): INTEGER;
BEGIN RETURN 0 END Get;                                    (* 1 = defined, 0 = no such variable *)

(* n-th (0-based) element of a Tcl list, e.g. to split the event "click 10 20" *)
PROCEDURE Word*(list: ARRAY OF CHAR; n, bufsize: INTEGER; VAR buf: ARRAY OF CHAR): INTEGER;
BEGIN RETURN 0 END Word;

(* Quote an arbitrary string as one Tcl word *)
PROCEDURE Quote*(s: ARRAY OF CHAR; bufsize: INTEGER; VAR buf: ARRAY OF CHAR): INTEGER;
BEGIN RETURN 0 END Quote;

(* Events: ms < 0 waits forever, 0 polls.  Returns 1 = event in buf,
   0 = timeout, -1 = wish has exited. *)
PROCEDURE Wait*(ms, bufsize: INTEGER; VAR buf: ARRAY OF CHAR): INTEGER;
BEGIN RETURN 0 END Wait;
PROCEDURE Pending*(): INTEGER;              BEGIN RETURN 0 END Pending;
PROCEDURE Flush*;                           BEGIN END Flush;

END Tk.
