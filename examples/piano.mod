MODULE Piano;

(*
 * Terminal piano: two octaves (C4-B5 + C6), raylib audio.
 *
 * White keys (octave 1): A S D F G H J K L ; '
 * Black keys (octave 1): W E   T Y U   O P
 * White keys (octave 2): Z X C   B N M , . /
 * Black keys (octave 2): number row: 2 3   5 6 7   9 0
 * C6: \
 *
 * Mouse: click the drawn piano keys.
 * +/- : volume up/down.
 * Esc : quit.
 *)

IMPORT Terminal, Raylib, Out, Math, Time;

CONST
  NNOTES   = 25;   (* C4 .. C6 inclusive *)
  NOTE_DUR = 600;  (* ms *)

  PIAX  = 2;   PIAY   = 4;
  KEYW  = 5;   KEYH   = 9;
  NWHITE = 15; (* two octaves of white keys + C6 = 7+7+1 *)

  (* white-key-index -> semitone within octave *)
  WK0 = 0; WK1 = 2; WK2 = 4; WK3 = 5; WK4 = 7; WK5 = 9; WK6 = 11;

VAR
  sounds    : ARRAY NNOTES OF Raylib.Sound;
  vol       : REAL;
  quit      : BOOLEAN;
  noteFreq  : ARRAY NNOTES OF REAL;
  noteNames : ARRAY NNOTES OF ARRAY 5 OF CHAR;
  isBlack   : ARRAY NNOTES OF BOOLEAN;
  keyNote   : ARRAY 256 OF INTEGER;
  wkSemitone: ARRAY 7 OF INTEGER;

PROCEDURE InitNotes;
  VAR i : INTEGER;
BEGIN
  wkSemitone[0] := 0;  wkSemitone[1] := 2;  wkSemitone[2] := 4;
  wkSemitone[3] := 5;  wkSemitone[4] := 7;  wkSemitone[5] := 9;
  wkSemitone[6] := 11;
  FOR i := 0 TO NNOTES-1 DO
    noteFreq[i] := 261.626 * Math.power(2.0, FLT(i) / 12.0)
  END;
  noteNames[0]  := "C4 "; noteNames[1]  := "C#4"; noteNames[2]  := "D4 ";
  noteNames[3]  := "D#4"; noteNames[4]  := "E4 "; noteNames[5]  := "F4 ";
  noteNames[6]  := "F#4"; noteNames[7]  := "G4 "; noteNames[8]  := "G#4";
  noteNames[9]  := "A4 "; noteNames[10] := "A#4"; noteNames[11] := "B4 ";
  noteNames[12] := "C5 "; noteNames[13] := "C#5"; noteNames[14] := "D5 ";
  noteNames[15] := "D#5"; noteNames[16] := "E5 "; noteNames[17] := "F5 ";
  noteNames[18] := "F#5"; noteNames[19] := "G5 "; noteNames[20] := "G#5";
  noteNames[21] := "A5 "; noteNames[22] := "A#5"; noteNames[23] := "B5 ";
  noteNames[24] := "C6 ";
  FOR i := 0 TO NNOTES-1 DO
    CASE i MOD 12 OF
      1, 3, 6, 8, 10: isBlack[i] := TRUE
    ELSE              isBlack[i] := FALSE
    END
  END
END InitNotes;

PROCEDURE InitKeyMap;
  VAR i : INTEGER;
BEGIN
  FOR i := 0 TO 255 DO keyNote[i] := -1 END;
  (* octave 1 white: A S D F G H J K L ; ' *)
  keyNote[ORD('a')] :=  0;  keyNote[ORD('s')] :=  2;
  keyNote[ORD('d')] :=  4;  keyNote[ORD('f')] :=  5;
  keyNote[ORD('g')] :=  7;  keyNote[ORD('h')] :=  9;
  keyNote[ORD('j')] := 11;  keyNote[ORD('k')] := 12;
  keyNote[ORD('l')] := 14;  keyNote[ORD(';')] := 16;
  keyNote[39]       := 17;  (* apostrophe = F5 *)
  (* octave 1 black: W E T Y U O P *)
  keyNote[ORD('w')] :=  1;  keyNote[ORD('e')] :=  3;
  keyNote[ORD('t')] :=  6;  keyNote[ORD('y')] :=  8;
  keyNote[ORD('u')] := 10;  keyNote[ORD('o')] := 13;
  keyNote[ORD('p')] := 15;
  (* octave 2 white: Z X C B N M , . / \ *)
  keyNote[ORD('z')] := 17;  keyNote[ORD('x')] := 19;
  keyNote[ORD('c')] := 21;  keyNote[ORD('b')] := 23;
  keyNote[ORD('n')] := 24;  keyNote[ORD('m')] := 12;
  keyNote[ORD(',')] := 14;  keyNote[ORD('.')] := 16;
  keyNote[ORD('/')] := 17;  keyNote[92]       := 24; (* backslash = C6 *)
  (* octave 2 black: 2 3  5 6 7  9 0 *)
  keyNote[ORD('2')] := 13; keyNote[ORD('3')] := 15;
  keyNote[ORD('5')] := 18; keyNote[ORD('6')] := 20;
  keyNote[ORD('7')] := 22; keyNote[ORD('9')] := 13;
  keyNote[ORD('0')] := 15;
  keyNote[ORD('v')] := 22  (* A#5 *)
END InitKeyMap;

PROCEDURE WhiteKeyX(wk: INTEGER): INTEGER;
BEGIN RETURN PIAX + wk * KEYW END WhiteKeyX;

PROCEDURE WhiteKeyNote(wk: INTEGER): INTEGER;
  VAR oct, pos : INTEGER;
BEGIN
  IF wk >= NWHITE THEN RETURN -1 END;
  IF wk = NWHITE - 1 THEN RETURN 24 END; (* C6 *)
  oct := wk DIV 7;
  pos := wk MOD 7;
  RETURN oct * 12 + wkSemitone[pos]
END WhiteKeyNote;

(* Black key to the RIGHT of white key wk; -1 = none *)
PROCEDURE BlackKeyNote(wk: INTEGER): INTEGER;
  VAR pos, oct : INTEGER;
BEGIN
  IF wk >= NWHITE - 1 THEN RETURN -1 END;
  oct := wk DIV 7;
  pos := wk MOD 7;
  IF (pos = 0) OR (pos = 1) OR (pos = 3) OR (pos = 4) OR (pos = 5) THEN
    IF pos = 0 THEN RETURN oct * 12 + 1  (* C# *)
    ELSIF pos = 1 THEN RETURN oct * 12 + 3  (* D# *)
    ELSIF pos = 3 THEN RETURN oct * 12 + 6  (* F# *)
    ELSIF pos = 4 THEN RETURN oct * 12 + 8  (* G# *)
    ELSE               RETURN oct * 12 + 10 (* A# *)
    END
  END;
  RETURN -1
END BlackKeyNote;

PROCEDURE DrawPiano(active: INTEGER);
  VAR wk, x, y, bx, note : INTEGER;
BEGIN
  (* White keys *)
  FOR wk := 0 TO NWHITE-1 DO
    note := WhiteKeyNote(wk);
    x    := WhiteKeyX(wk);
    FOR y := 0 TO KEYH-1 DO
      IF note = active THEN
        Terminal.Color256(220, 0)
      ELSIF ODD(y) & (y < KEYH-1) THEN
        Terminal.Color256(250, 240)
      ELSE
        Terminal.Color256(232, 255)
      END;
      Terminal.Fill(x, PIAY + y, KEYW - 1, 1, ' ');
      Terminal.Color256(232, 0);
      Terminal.Goto(x + KEYW - 1, PIAY + y);
      Out.Char('|')
    END;
    (* note label at bottom of key *)
    IF note = active THEN
      Terminal.Color256(0, 220)
    ELSE
      Terminal.Color256(238, 255)
    END;
    Terminal.Goto(x, PIAY + KEYH - 2);
    IF note >= 0 THEN Out.String(noteNames[note]) END
  END;
  (* Black keys drawn on top *)
  FOR wk := 0 TO NWHITE-2 DO
    note := BlackKeyNote(wk);
    IF note >= 0 THEN
      bx := WhiteKeyX(wk) + 3;
      FOR y := 0 TO (KEYH * 5) DIV 8 DO
        IF note = active THEN
          Terminal.Color256(226, 0)
        ELSE
          Terminal.Color256(252, 232)
        END;
        Terminal.Fill(bx, PIAY + y, 3, 1, ' ')
      END;
      IF note = active THEN Terminal.Color256(0, 226)
      ELSE Terminal.Color256(252, 232) END;
      Terminal.Goto(bx, PIAY + (KEYH * 5) DIV 8 - 1);
      Out.String(noteNames[note])
    END
  END;
  Terminal.Reset
END DrawPiano;

PROCEDURE DrawUI(active: INTEGER);
BEGIN
  Terminal.Clear;
  Terminal.Goto(1, 1);
  Terminal.Color256(220, 0);
  Out.String(" TERMINAL PIANO");
  Terminal.Reset;
  Out.String("  |  Vol: ");
  Terminal.Color256(51, 0);
  Out.Fixed(vol * 100.0, 3, 0);
  Out.String("%");
  Terminal.Reset;
  Out.String("  |  +/- volume  |  Esc quit");
  IF active >= 0 THEN
    Out.String("  |  ");
    Terminal.Color256(226, 0);
    Out.String(noteNames[active]);
    Terminal.Reset
  END;
  Terminal.Goto(1, 2);
  Terminal.Color256(242, 0);
  Out.String(" White: A-;' = C4-F5   Z,X,C,B,N,\\=F5-C6");
  Out.String("   Black: W E T Y U O P  |  2 3 5 6 7");
  Terminal.Reset;
  DrawPiano(active)
END DrawUI;

PROCEDURE NoteForMouse(mx, my: INTEGER): INTEGER;
  VAR wk, bx, note : INTEGER;
BEGIN
  IF (my < PIAY) OR (my >= PIAY + KEYH) THEN RETURN -1 END;
  (* black keys first *)
  IF my < PIAY + (KEYH * 5) DIV 8 + 1 THEN
    FOR wk := 0 TO NWHITE-2 DO
      note := BlackKeyNote(wk);
      IF note >= 0 THEN
        bx := WhiteKeyX(wk) + 3;
        IF (mx >= bx) & (mx < bx + 3) THEN RETURN note END
      END
    END
  END;
  wk := (mx - PIAX) DIV KEYW;
  IF (wk >= 0) & (wk < NWHITE) THEN
    RETURN WhiteKeyNote(wk)
  END;
  RETURN -1
END NoteForMouse;

PROCEDURE PlayNote(n: INTEGER);
BEGIN
  IF (n >= 0) & (n < NNOTES) & (sounds[n] # NIL) THEN
    Raylib.SetSoundVolume(sounds[n], vol);
    Raylib.PlaySound(sounds[n])
  END
END PlayNote;

VAR
  i    : INTEGER;
  key  : CHAR;
  note : INTEGER;
  btn  : INTEGER;

BEGIN
  vol  := 0.8;
  quit := FALSE;
  InitNotes;
  InitKeyMap;
  Raylib.InitAudioDevice;
  FOR i := 0 TO NNOTES-1 DO
    sounds[i] := Raylib.GenToneSound(noteFreq[i], NOTE_DUR)
  END;
  Terminal.MouseOn;
  DrawUI(-1);
  LOOP
    key  := Terminal.ReadKey();
    note := -1;
    IF (key = 1BX) OR (key = 11X) THEN  (* Esc or Ctrl-Q *)
      quit := TRUE
    ELSIF key = '+' THEN
      vol := Math.min(vol + 0.1, 1.0);  DrawUI(-1)
    ELSIF key = '-' THEN
      vol := Math.max(vol - 0.1, 0.0);  DrawUI(-1)
    ELSIF key = 0A4X THEN  (* KMouse *)
      btn := Terminal.MouseBtn();
      IF (btn = 0) OR (btn = 64) OR (btn = 65) THEN
        IF btn = 0 THEN
          note := NoteForMouse(Terminal.MouseX(), Terminal.MouseY())
        END
      END
    ELSIF ORD(key) < 128 THEN
      note := keyNote[ORD(key)]
    END;
    IF note >= 0 THEN
      PlayNote(note);
      DrawUI(note);
      Time.Sleep(100);
      DrawUI(-1)
    END;
    IF quit THEN EXIT END
  END;
  FOR i := 0 TO NNOTES-1 DO
    IF sounds[i] # NIL THEN Raylib.UnloadSound(sounds[i]) END
  END;
  Raylib.CloseAudioDevice;
  Terminal.MouseOff
END Piano.
