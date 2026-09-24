MODULE Zapf;
(*
  Zapf — Z-machine assembler, ported from zilf's Zapf/Zapf.Parsing (C#).

  Usage: zapf [options] input.zap [output]

  Compiles ZAP assembly source (as emitted by the ZILF compiler, or written
  by hand) into a Z-machine story file (.z3 .. .z8).

  Options:
    -q, --quiet            suppress the banner and progress messages
    -I, --inform           use Inform opcode/register names instead of
                            the classic ZIL names (e.g. "add" vs "ADD")
    -L, --list-addresses   list global label addresses after assembling
    -r, --release N        override the release number in the header
    -s, --serial SSSSSS    override the 6-character serial number
    -C, --creator NAME     override the 8-character creator ID
    -N, --no-creator       omit the creator ID entirely

  Scope note: this port omits the -A/--abbreviate abbreviation-finder
  report and the -X/--xml-debug debug-file output — both are diagnostic
  extras of the original tool, not needed to assemble a working story
  file. See Modules/ZapfAsm.mod's header comment for the full list of
  scope decisions made in this port.

  --mod-path Modules is required to build this (it pulls in ZapfAsm,
  ZapfParser, ZapfAst, ZapfExpr, ZapfTok, ZapfOpcodes, ZapfZChar):

    obc --mod-path Modules examples/zapf.mod -o zapf
*)

IMPORT ZapfAsm, ZapfOpcodes, ZapfZChar, Args, Strings, Out, OS;

VAR ctx: ZapfAsm.Context;

PROCEDURE Usage;
BEGIN
  Out.String("usage: zapf [options] input.zap [output]"); Out.Ln;
  Out.String("  -q, --quiet            suppress banner/progress"); Out.Ln;
  Out.String("  -I, --inform           use Inform opcode/register names"); Out.Ln;
  Out.String("  -L, --list-addresses   list global label addresses"); Out.Ln;
  Out.String("  -r, --release N        set release number"); Out.Ln;
  Out.String("  -s, --serial SSSSSS    set serial number"); Out.Ln;
  Out.String("  -C, --creator NAME     set creator ID (8 chars)"); Out.Ln;
  Out.String("  -N, --no-creator       omit creator ID"); Out.Ln
END Usage;

(* Path.ChangeExtension(inFile, ".z#") equivalent: replace (or append) the
   extension with the placeholder ".z#", which Assemble() later rewrites
   to ".z3".."z8" once the final Z-machine version is known. *)
PROCEDURE MakeDefaultOutput(inFile: ARRAY OF CHAR; VAR outFile: ARRAY OF CHAR);
VAR n, i, dot: INTEGER;
BEGIN
  n := Strings.Length(inFile);
  dot := n;
  FOR i := 0 TO n - 1 DO
    IF inFile[i] = "." THEN dot := i END
  END;
  FOR i := 0 TO dot - 1 DO outFile[i] := inFile[i] END;
  outFile[dot] := 0X;
  Strings.Append(".z#", outFile)
END MakeDefaultOutput;

VAR i, n, v: INTEGER;
    arg, inFile, outFile: ARRAY 512 OF CHAR;
    haveIn, haveOut: BOOLEAN;
    rc: INTEGER;

BEGIN
  NEW(ctx);
  ZapfAsm.InitContext(ctx);
  ZapfOpcodes.Init;
  ZapfZChar.Init;

  haveIn := FALSE; haveOut := FALSE;
  n := Args.Count();
  i := 1;
  WHILE i <= n DO
    Args.Get(i, arg);
    IF (arg = "-q") OR (arg = "--quiet") THEN
      ctx.quiet := TRUE
    ELSIF (arg = "-I") OR (arg = "--inform") THEN
      ctx.informMode := TRUE
    ELSIF (arg = "-L") OR (arg = "--list-addresses") THEN
      ctx.listAddresses := TRUE
    ELSIF (arg = "-N") OR (arg = "--no-creator") THEN
      ctx.noCreator := TRUE; ctx.creatorSpecified := TRUE
    ELSIF (arg = "-r") OR (arg = "--release") THEN
      INC(i);
      IF i > n THEN Out.String("zapf: --release requires a value"); Out.Ln; HALT(1) END;
      Args.Get(i, arg);
      IF Strings.StrToInt(arg, v) THEN
        ctx.release := v; ctx.releaseSpecified := TRUE
      ELSE
        Out.String("zapf: invalid --release value: "); Out.String(arg); Out.Ln; HALT(1)
      END
    ELSIF (arg = "-s") OR (arg = "--serial") THEN
      INC(i);
      IF i > n THEN Out.String("zapf: --serial requires a value"); Out.Ln; HALT(1) END;
      Args.Get(i, arg);
      Strings.Copy(arg, ctx.serial); ctx.serialSpecified := TRUE
    ELSIF (arg = "-C") OR (arg = "--creator") THEN
      INC(i);
      IF i > n THEN Out.String("zapf: --creator requires a value"); Out.Ln; HALT(1) END;
      Args.Get(i, arg);
      Strings.Copy(arg, ctx.creator); ctx.creatorSpecified := TRUE; ctx.noCreator := FALSE
    ELSIF (arg = "-h") OR (arg = "--help") OR (arg = "-?") THEN
      Usage; HALT(0)
    ELSIF ~haveIn THEN
      Strings.Copy(arg, inFile); haveIn := TRUE
    ELSIF ~haveOut THEN
      Strings.Copy(arg, outFile); haveOut := TRUE
    ELSE
      Out.String("zapf: unexpected argument: "); Out.String(arg); Out.Ln; HALT(1)
    END;
    INC(i)
  END;

  IF ~haveIn THEN
    Usage; HALT(1)
  END;

  Strings.Copy(inFile, ctx.inFile);
  IF haveOut THEN
    Strings.Copy(outFile, ctx.outFile)
  ELSE
    MakeDefaultOutput(inFile, ctx.outFile)
  END;

  rc := ZapfAsm.RunAssembler(ctx);
  OS.Exit(rc)
END Zapf.
