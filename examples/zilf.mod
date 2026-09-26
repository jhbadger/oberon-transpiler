MODULE Zilf;
(*
  zilf — ZIL compiler, ported from zilf (C#); see Notes/zilf_port_plan.md
  for the state of the port and what it does and doesn't cover yet.

  Usage: zilf [options] input.zil [output.zap]

  Reads a ZIL source file, evaluates it with the interpreter in ZilEval
  (which is what registers ROUTINE/OBJECT/GLOBAL/CONSTANT/... and expands
  DEFMAC macros), then emits ZAP assembly for everything registered. The
  .zap it writes is meant to be fed straight to the zapf assembler in this
  same tree:

    zilf game.zil game.zap && zapf game.zap

  With no output file named, the .zap goes to stdout.

  Options:
    -i, --include DIR  add DIR to the library search path (repeatable).
                        Real games live in their own directory and
                        <INSERT-FILE "parser"> the shared library out of
                        zilf's zillib/, so compiling one needs at least
                        -i /path/to/zilf/zillib
    -e, --entry NAME   compile NAME as the entry routine (default: GO)
    -q, --quiet        suppress progress messages

  IMPORTANT — this is a partial compiler. Object/property/flag tables,
  the vocabulary and parser tables, string packing, tables, and most of
  the original's 237 builtins are not emitted or compiled yet, so only
  programs staying inside the implemented subset (routines, locals,
  globals, constants, arithmetic, COND, and the handful of print/variable
  builtins listed in ZilCompile.mod's own header) will compile. Anything
  else is reported as an error rather than silently mis-compiled.

    obc --mod-path Modules examples/zilf.mod -o zilf
*)

IMPORT ZilObj, ZilRead, ZilEval, ZilModel, ZilCompile, Args, Strings, Out, OS;

VAR
  rd: ZilRead.Reader;
  z: ZilObj.Zo;
  r: ZilEval.ZResult;
  ok, done, isTerm, quiet, haveIn, haveOut: BOOLEAN;
  termChar, i, n, nForms: INTEGER;
  arg, inFile, outFile, entryName, dir: ARRAY 512 OF CHAR;
  detail: ARRAY 1024 OF CHAR;

PROCEDURE Usage;
BEGIN
  Out.String("usage: zilf [options] input.zil [output.zap]"); Out.Ln;
  Out.String("  -i, --include DIR  add DIR to the library search path (repeatable)"); Out.Ln;
  Out.String("  -e, --entry NAME   entry routine name (default: GO)"); Out.Ln;
  Out.String("  -q, --quiet        suppress progress messages"); Out.Ln
END Usage;

(* Diagnostics go to STDERR, because the compiled `.zap` goes to stdout when
   no -o was given. Reporting an error with Out.String put the message inside
   the .zap instead, which made a failed compile look like a successful one -
   and made any survey that checked stderr report the wrong thing. *)
PROCEDURE Fail(msg, detail: ARRAY OF CHAR);
BEGIN
  Out.Flush;
  Out.ErrString("zilf: "); Out.ErrString(msg);
  IF detail # "" THEN Out.ErrString(": "); Out.ErrString(detail) END;
  Out.ErrLn;
  OS.Exit(1)
END Fail;

(* The directory part of `path`, for INSERT-FILE to resolve against — see
   ZilEval.SetCurrentDir's own comment. *)
PROCEDURE DirOf(path: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
VAR k, lastSlash: INTEGER;
BEGIN
  lastSlash := -1;
  k := 0;
  WHILE path[k] # 0X DO
    IF path[k] = "/" THEN lastSlash := k END;
    INC(k)
  END;
  IF lastSlash < 0 THEN d[0] := 0X
  ELSE
    FOR k := 0 TO lastSlash - 1 DO d[k] := path[k] END;
    d[lastSlash] := 0X
  END
END DirOf;

BEGIN
  quiet := FALSE; haveIn := FALSE; haveOut := FALSE;
  Strings.Copy("GO", entryName);

  n := Args.Count();
  i := 1;
  WHILE i <= n DO
    Args.Get(i, arg);
    IF (arg = "-q") OR (arg = "--quiet") THEN
      quiet := TRUE
    ELSIF (arg = "-i") OR (arg = "--include") THEN
      INC(i);
      IF i > n THEN Fail("--include requires a directory", "") END;
      Args.Get(i, arg); ZilEval.AddIncludePath(arg)
    ELSIF (arg = "-e") OR (arg = "--entry") THEN
      INC(i);
      IF i > n THEN Fail("--entry requires a routine name", "") END;
      Args.Get(i, arg); Strings.Copy(arg, entryName)
    ELSIF (arg = "-h") OR (arg = "--help") OR (arg = "-?") THEN
      Usage; OS.Exit(0)
    ELSIF ~haveIn THEN
      Strings.Copy(arg, inFile); haveIn := TRUE
    ELSIF ~haveOut THEN
      Strings.Copy(arg, outFile); haveOut := TRUE
    ELSE
      Fail("unexpected argument", arg)
    END;
    INC(i)
  END;

  IF ~haveIn THEN Usage; OS.Exit(1) END;

  (* InitBuiltins resets ZilModel itself and then registers the predefined
     ZIL constants (TRUE-VALUE, the PS?/P1? part-of-speech values, ...) into
     it, so don't Reset again afterwards — that would throw them away. *)
  ZilEval.InitBuiltins;

  IF ~ZilRead.Open(rd, inFile) THEN Fail("cannot open", inFile) END;
  DirOf(inFile, dir);
  ZilEval.SetCurrentDir(dir);

  (* read-eval loop over the whole file: every top-level form is evaluated
     as it is read, exactly as the original does (its reader and evaluator
     are interleaved by design — %<...> and DEFMAC both need it) *)
  nForms := 0;
  done := FALSE;
  WHILE ~done DO
    z := ZilRead.ReadOne(rd, ok, done, isTerm, termChar);
    IF ~ok THEN
      ZilRead.Close(rd);
      (* a read-time %<...> evaluation failure surfaces as a READ error, but
         the useful message is the evaluator's — report both *)
      Strings.Copy(rd.errMsg, detail);
      IF ZilEval.evalErrFlag THEN
        Strings.Append(": ", detail); Strings.Append(ZilEval.evalErrMsg, detail)
      END;
      Fail("parse error", detail)
    END;
    IF ~done THEN
      IF isTerm THEN
        ZilRead.Close(rd);
        Fail("unexpected closing bracket in", inFile)
      END;
      ZilEval.ClearErr;
      r := ZilEval.Eval(z);
      IF ZilEval.evalErrFlag THEN
        ZilRead.Close(rd);
        Fail("evaluation error", ZilEval.evalErrMsg)
      END;
      INC(nForms)
    END
  END;
  ZilRead.Close(rd);

  (* The library installs finishers (zillib's ADD-FINISHER) on the
     PRE-COMPILE hook, and they build data the routines already reference —
     the achievements table, for one. Run them before anything is compiled,
     which is where the original calls it too (FrontEnd.EmitCompilation). *)
  IF ~ZilEval.RunHook("PRE-COMPILE") THEN
    Fail("pre-compile hook", ZilEval.evalErrMsg)
  END;

  IF ~quiet THEN
    Out.String("zilf: read "); Out.Int(nForms, 0);
    Out.String(" top-level forms; "); Out.Int(ZilModel.nRoutines, 0);
    Out.String(" routines, "); Out.Int(ZilModel.nGlobals, 0);
    Out.String(" globals, "); Out.Int(ZilModel.nConstants, 0);
    Out.String(" constants, "); Out.Int(ZilModel.nObjects, 0);
    Out.String(" objects"); Out.Ln
  END;

  IF haveOut THEN
    IF ~ZilCompile.OpenOutput(outFile) THEN Fail("cannot write", outFile) END
  END;

  ok := ZilCompile.CompileProgram(entryName);
  ZilCompile.CloseOutput;

  IF ~ok THEN Fail("compile error", ZilCompile.errMsg) END;

  IF ~quiet & haveOut THEN
    Out.String("zilf: wrote "); Out.String(outFile); Out.Ln
  END
END Zilf.
