MODULE FastaEditor;
(*
  Alignment editor for FASTA files.
  Loads via BioIO, edits gap-annotated sequences in a scrollable terminal UI,
  and can pairwise-align all sequences against seq[0] via BioAlign (key: A).
*)

IMPORT Terminal, Files, BioIO, BioSeq, BioAlign, Strings, Args, Out;

CONST
  MaxSeqs     = 100;
  HeaderWidth = 25;
  RawMax      = BioAlign.MaxSeqLen;  (* max ungapped length for alignment *)
  MaxBufLen   = 16384;               (* max gap-annotated buffer per sequence *)

TYPE
  Sequence = RECORD
    name : ARRAY 128 OF CHAR;
    desc : ARRAY 256 OF CHAR;
    data : ARRAY MaxBufLen OF CHAR   (* gap-annotated editable buffer *)
  END;

VAR
  seqs                      : ARRAY MaxSeqs OF Sequence;
  numSeqs, cursorX, cursorY : INTEGER;
  scrollX, scrollY          : INTEGER;
  filename                  : ARRAY 256 OF CHAR;
  cmdname                   : ARRAY 256 OF CHAR;
  showDots                  : BOOLEAN;
  statusMsg                 : ARRAY 64 OF CHAR;  (* transient status line override *)

(* ------------------------------------------------------------------ *)
(*  File I/O                                                            *)
(* ------------------------------------------------------------------ *)

PROCEDURE Load(name: ARRAY OF CHAR);
VAR
  rdr : BioIO.FastaReader;
  rec : BioIO.FastaRecord;
  len : INTEGER;
BEGIN
  IF ~BioIO.OpenFasta(rdr, name) THEN
    Out.String("Error opening: "); Out.String(name); Out.Ln;
    HALT(1)
  END;
  rec.seq := NIL;
  numSeqs := 0;
  WHILE BioIO.ReadFasta(rdr, rec) & (numSeqs < MaxSeqs) DO
    COPY(rec.name, seqs[numSeqs].name);
    COPY(rec.desc, seqs[numSeqs].desc);
    seqs[numSeqs].data[0] := 0X;
    len := BioSeq.Length(rec.seq);
    IF len >= MaxBufLen THEN len := MaxBufLen - 1 END;
    BioSeq.Slice(rec.seq, 0, len, seqs[numSeqs].data);
    INC(numSeqs)
  END;
  BioIO.CloseFasta(rdr);
  IF rec.seq # NIL THEN BioSeq.Free(rec.seq) END
END Load;

PROCEDURE WriteStr(VAR r: Files.Rider; s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    Files.Write(r, ORD(s[i])); INC(i)
  END
END WriteStr;

PROCEDURE Save;
VAR
  f : Files.File;
  r : Files.Rider;
  i, j : INTEGER;
BEGIN
  f := Files.New(filename);
  Files.Set(r, f, 0);
  FOR i := 0 TO numSeqs - 1 DO
    Files.Write(r, ORD('>'));
    WriteStr(r, seqs[i].name);
    IF seqs[i].desc[0] # 0X THEN
      Files.Write(r, ORD(' '));
      WriteStr(r, seqs[i].desc)
    END;
    Files.Write(r, 10);
    j := 0;
    WHILE (j < MaxBufLen) & (seqs[i].data[j] # 0X) DO
      Files.Write(r, ORD(seqs[i].data[j])); INC(j)
    END;
    Files.Write(r, 10)
  END;
  Files.Register(f);
  Files.Close(f)
END Save;

(* ------------------------------------------------------------------ *)
(*  Alignment helpers                                                   *)
(* ------------------------------------------------------------------ *)

PROCEDURE StripGaps(data: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
(* Copy data into out, omitting '-' gap characters. *)
VAR i, j: INTEGER;
BEGIN
  i := 0; j := 0;
  WHILE (i < LEN(data)) & (data[i] # 0X) & (j < LEN(out) - 1) DO
    IF data[i] # '-' THEN out[j] := data[i]; INC(j) END;
    INC(i)
  END;
  out[j] := 0X
END StripGaps;

PROCEDURE RebuildFromCigar(rawQ: ARRAY OF CHAR; VAR aln: BioAlign.Alignment;
                            VAR out: ARRAY OF CHAR);
(*
  Reconstruct the gap-annotated query string from the CIGAR trace:
    opMatch / opSubst  → copy base from rawQ
    opDel              → insert '-' (gap in query vs reference)
    opIns              → skip (base in query not present in reference)
*)
VAR qi, oi, k, p: INTEGER;
BEGIN
  qi := 0; oi := 0;
  FOR k := 0 TO aln.nOps - 1 DO
    FOR p := 0 TO aln.cigar[k].len - 1 DO
      IF (aln.cigar[k].op = BioAlign.opMatch) OR
         (aln.cigar[k].op = BioAlign.opSubst) THEN
        IF oi < LEN(out) - 1 THEN out[oi] := rawQ[qi]; INC(oi) END;
        INC(qi)
      ELSIF aln.cigar[k].op = BioAlign.opDel THEN
        IF oi < LEN(out) - 1 THEN out[oi] := '-'; INC(oi) END
      ELSE  (* opIns: query base has no match in ref — drop it *)
        INC(qi)
      END
    END
  END;
  out[oi] := 0X
END RebuildFromCigar;

PROCEDURE AlignAll;
(*
  Pairwise-align every sequence against seq[0] using Needleman-Wunsch.
  Gaps are inserted into seqs[1..n-1]; seq[0] is left unchanged.
  Sequences longer than BioAlign.MaxSeqLen are skipped.
*)
VAR
  m      : BioAlign.ScoreMatrix;
  aln    : BioAlign.Alignment;
  q, ref : BioSeq.Seq;
  rawQ   : ARRAY RawMax + 1 OF CHAR;
  rawR   : ARRAY RawMax + 1 OF CHAR;
  i      : INTEGER;
BEGIN
  IF numSeqs < 2 THEN
    statusMsg := "Need >= 2 sequences to align";
    RETURN
  END;

  BioAlign.DefaultScore(m);
  BioSeq.New(q);
  BioSeq.New(ref);

  StripGaps(seqs[0].data, rawR);
  IF Strings.Length(rawR) > RawMax THEN
    statusMsg := "Seq 0 too long for alignment";
    BioSeq.Free(q);  BioSeq.Free(ref);
    RETURN
  END;
  BioSeq.FromStr(ref, rawR);

  FOR i := 1 TO numSeqs - 1 DO
    StripGaps(seqs[i].data, rawQ);
    IF Strings.Length(rawQ) <= RawMax THEN
      BioSeq.FromStr(q, rawQ);
      BioAlign.Global(q, ref, m, aln);
      RebuildFromCigar(rawQ, aln, seqs[i].data)
    END
  END;

  BioSeq.Free(q);
  BioSeq.Free(ref);
  statusMsg := "Aligned"
END AlignAll;

(* ------------------------------------------------------------------ *)
(*  Display                                                             *)
(* ------------------------------------------------------------------ *)

PROCEDURE Draw;
VAR
  i, j, k, viewW, viewH, screenRow, colIndex : INTEGER;
  sub : ARRAY 512 OF CHAR;
  ch, refCh : CHAR;
  isIdentical : BOOLEAN;
BEGIN
  Terminal.HideCursor();
  Terminal.Reset();
  Terminal.Clear();
  viewW := Terminal.Cols() - (HeaderWidth + 1);
  viewH := Terminal.Rows() - 2;

  (* Title bar *)
  Terminal.Color(7, 4);
  Terminal.Fill(1, 1, Terminal.Cols(), 1, " ");
  Terminal.Goto(2, 1);
  Out.String("FILE: "); Out.String(filename);
  Out.String("  .: Dots  G: Gap  DEL: Rm  A: Align  S: Save  Q: Quit");

  (* Sequence rows *)
  FOR i := 0 TO viewH - 1 DO
    screenRow := i + scrollY;
    IF screenRow < numSeqs THEN
      Terminal.Color(2, 0);
      Terminal.Goto(1, i + 2);
      Strings.Extract(seqs[screenRow].name, 0, HeaderWidth, sub);
      Out.String(sub);

      Terminal.Goto(HeaderWidth + 1, i + 2);
      Strings.Extract(seqs[screenRow].data, scrollX, viewW, sub);

      FOR j := 0 TO Strings.Length(sub) - 1 DO
        ch       := sub[j];
        colIndex := scrollX + j;

        IF showDots & (numSeqs > 1) THEN
          isIdentical := TRUE;
          IF colIndex < Strings.Length(seqs[0].data) THEN
            refCh := seqs[0].data[colIndex];
            FOR k := 1 TO numSeqs - 1 DO
              IF (colIndex >= Strings.Length(seqs[k].data)) OR
                 (seqs[k].data[colIndex] # refCh) THEN
                isIdentical := FALSE
              END
            END
          ELSE
            isIdentical := FALSE
          END;
          IF isIdentical & (ch # '-') & (ch # 0X) THEN ch := '.' END
        END;

        CASE ch OF
          'A', 'a' : Terminal.Color(1, 0)
        | 'T', 't',
          'U', 'u' : Terminal.Color(4, 0)
        | 'G', 'g' : Terminal.Color(3, 0)
        | 'C', 'c' : Terminal.Color(2, 0)
        | 'V', 'v', 'I', 'i', 'L', 'l',
          'M', 'm', 'F', 'f', 'Y', 'y',
          'W', 'w'  : Terminal.Color(7, 0)
        | 'S', 's', 'P', 'p', 'Q', 'q',
          'N', 'n'  : Terminal.Color(6, 0)
        | 'D', 'd', 'E', 'e', 'K', 'k',
          'R', 'r', 'H', 'h' : Terminal.Color(5, 0)
        ELSE Terminal.Color(7, 0)
        END;
        Out.Char(ch)
      END
    END
  END;

  (* Status bar *)
  Terminal.Color(0, 7);
  Terminal.Fill(1, Terminal.Rows(), Terminal.Cols(), 1, " ");
  Terminal.Goto(1, Terminal.Rows());
  IF statusMsg[0] # 0X THEN
    Out.String(statusMsg);
    statusMsg := ""
  ELSE
    Out.String("Col:"); Out.Int(cursorX + 1, 0);
    Out.String(" Seq:"); Out.Int(cursorY + 1, 0);
    Out.String("/"); Out.Int(numSeqs, 0);
    Out.String("  J:Jump F:Find ShArr:Reorder")
  END;

  Terminal.Goto((HeaderWidth + 1) + (cursorX - scrollX), (cursorY - scrollY) + 2);
  Terminal.ShowCursor()
END Draw;

(* ------------------------------------------------------------------ *)
(*  Input                                                               *)
(* ------------------------------------------------------------------ *)

PROCEDURE ReadInput(prompt: ARRAY OF CHAR; VAR res: ARRAY OF CHAR);
VAR ch: CHAR; idx: INTEGER;
BEGIN
  Terminal.Color(0, 7);
  Terminal.Fill(1, Terminal.Rows(), Terminal.Cols(), 1, " ");
  Terminal.Goto(1, Terminal.Rows());
  Out.String(prompt);
  Terminal.ShowCursor();
  idx := 0;  res[0] := 0X;
  LOOP
    ch := Terminal.ReadKey();
    IF (ch = 0DX) OR (ch = 0AX) THEN EXIT
    ELSIF (ch = 7FX) OR (ch = 08X) THEN
      IF idx > 0 THEN
        DEC(idx);  res[idx] := 0X;
        Terminal.Goto(Strings.Length(prompt) + 1 + idx, Terminal.Rows());
        Out.String(" ");
        Terminal.Goto(Strings.Length(prompt) + 1 + idx, Terminal.Rows())
      END
    ELSIF (ch >= ' ') & (ch <= '~') & (idx < 255) THEN
      res[idx] := ch;  INC(idx);  res[idx] := 0X;
      Out.Char(ch)
    END
  END;
  Terminal.HideCursor()
END ReadInput;

(* ------------------------------------------------------------------ *)
(*  Main event loop                                                     *)
(* ------------------------------------------------------------------ *)

PROCEDURE Run;
VAR
  ch       : CHAR;
  looping, match, found : BOOLEAN;
  viewW, viewH, actualMax, i, j, val, patLen : INTEGER;
  gapStr   : ARRAY 2 OF CHAR;
  inputStr : ARRAY 256 OF CHAR;
  tempSeq  : Sequence;
BEGIN
  looping  := TRUE;
  cursorX  := 0;  cursorY  := 0;
  scrollX  := 0;  scrollY  := 0;
  gapStr[0] := '-';  gapStr[1] := 0X;
  showDots  := FALSE;
  statusMsg := "";

  WHILE looping DO
    viewW := Terminal.Cols() - (HeaderWidth + 1);
    viewH := Terminal.Rows() - 2;
    Draw();
    ch := Terminal.ReadKey();

    actualMax := 0;
    FOR i := 0 TO numSeqs - 1 DO
      IF Strings.Length(seqs[i].data) > actualMax THEN
        actualMax := Strings.Length(seqs[i].data)
      END
    END;
    IF actualMax = 0 THEN actualMax := 1 END;

    CASE ch OF
      '.' : showDots := ~showDots

    | 0A0X : IF cursorY > 0 THEN DEC(cursorY) END
    | 0A1X : IF cursorY < numSeqs - 1 THEN INC(cursorY) END
    | 0A2X : IF cursorX > 0 THEN DEC(cursorX) END
    | 0A3X : IF cursorX < actualMax THEN INC(cursorX) END

    | 0A5X :  (* Shift+Up: reorder sequence up *)
        IF cursorY > 0 THEN
          tempSeq           := seqs[cursorY];
          seqs[cursorY]     := seqs[cursorY - 1];
          seqs[cursorY - 1] := tempSeq;
          DEC(cursorY)
        END
    | 0A6X :  (* Shift+Down: reorder sequence down *)
        IF cursorY < numSeqs - 1 THEN
          tempSeq           := seqs[cursorY];
          seqs[cursorY]     := seqs[cursorY + 1];
          seqs[cursorY + 1] := tempSeq;
          INC(cursorY)
        END

    | 80X : IF cursorX > viewW THEN DEC(cursorX, viewW) ELSE cursorX := 0 END
    | 81X : IF cursorX + viewW < actualMax THEN INC(cursorX, viewW) ELSE cursorX := actualMax - 1 END
    | 82X : cursorX := 0
    | 83X : cursorX := actualMax - 1

    | 'j', 'J' :
        ReadInput("Jump to column (1-based): ", inputStr);
        val := 0;  i := 0;
        WHILE (inputStr[i] >= '0') & (inputStr[i] <= '9') DO
          val := val * 10 + (ORD(inputStr[i]) - ORD('0'));  INC(i)
        END;
        IF val > 0 THEN cursorX := val - 1 END

    | 'f', 'F' :
        ReadInput("Find: ", inputStr);
        patLen := Strings.Length(inputStr);
        IF patLen > 0 THEN
          i := cursorX + 1;  found := FALSE;
          WHILE (i <= actualMax - patLen) & ~found DO
            match := TRUE;  j := 0;
            WHILE (j < patLen) & match DO
              IF seqs[cursorY].data[i + j] # inputStr[j] THEN match := FALSE END;
              INC(j)
            END;
            IF match THEN cursorX := i;  found := TRUE ELSE INC(i) END
          END
        END

    | 'g', 'G' :
        IF Strings.Length(seqs[cursorY].data) < MaxBufLen - 1 THEN
          Strings.Insert(gapStr, cursorX, seqs[cursorY].data)
        END

    | 84X :  (* DEL *)
        Strings.Delete(seqs[cursorY].data, cursorX, 1)

    | 'a', 'A' :
        statusMsg := "Aligning...";
        Draw();
        AlignAll()

    | 's', 'S' : Save();  statusMsg := "Saved"
    | 'q', 'Q' : looping := FALSE
    ELSE
    END;

    IF cursorX < 0 THEN cursorX := 0 END;
    IF cursorX > actualMax THEN cursorX := actualMax END;
    IF cursorY < 0 THEN cursorY := 0 END;
    IF cursorY > numSeqs - 1 THEN cursorY := numSeqs - 1 END;

    IF cursorY < scrollY THEN scrollY := cursorY
    ELSIF cursorY >= scrollY + viewH THEN scrollY := cursorY - viewH + 1
    END;
    IF cursorX < scrollX THEN scrollX := cursorX
    ELSIF cursorX >= scrollX + viewW THEN scrollX := cursorX - viewW + 1
    END
  END
END Run;

BEGIN
  Args.Get(0, cmdname);
  IF Args.Count() < 1 THEN
    Out.String("Usage: "); Out.String(cmdname); Out.String(" <file.fasta>"); Out.Ln
  ELSE
    Args.Get(1, filename);
    Load(filename);
    Run();
    Terminal.Restore();
    Terminal.Clear()
  END
END FastaEditor.
