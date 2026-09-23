MODULE StoryCubes;
(*
 * Rory's Story Cubes – TUI implementation.
 *
 * Roll 9 story dice and use the prompts to tell a tale.
 *
 * Controls:
 *   SPACE / ENTER : roll all unlocked dice
 *   1-9           : toggle lock on die N
 *   A             : unlock all dice
 *   R             : unlock all and re-roll everything
 *   Q             : quit
 *
 * Layout (80x24):
 *   Row  1 : Title
 *   Row  2 : Subtitle
 *   Rows 4-8   : Die row 1 (dice 1-3)
 *   Rows 10-14 : Die row 2 (dice 4-6)
 *   Rows 16-20 : Die row 3 (dice 7-9)
 *   Row 22 : Controls hint
 *   Row 23 : Current story prompt (all 9 images)
 *)

IMPORT Terminal, Out, Random;

CONST
  NDice     = 9;
  NFaces    = 6;
  DieW      = 11;  (* box width including borders *)
  DieH      = 5;   (* box height including borders *)
  ColStride = 13;  (* DieW + 2-col gap *)
  RowStride = 6;   (* DieH + 1-row gap *)
  StartX    = 22;  (* column of die 0, 1-based *)
  StartY    = 4;   (* row of die 0, 1-based *)
  KeyEnter  = 0DX;

VAR
  faces   : ARRAY NDice OF ARRAY NFaces OF ARRAY 10 OF CHAR;
  current : ARRAY NDice OF INTEGER;
  locked  : ARRAY NDice OF BOOLEAN;
  key     : CHAR;
  i       : INTEGER;

(* ── Positions ───────────────────────────────────────────────── *)

PROCEDURE DieX(idx : INTEGER) : INTEGER;
BEGIN RETURN StartX + (idx MOD 3) * ColStride END DieX;

PROCEDURE DieY(idx : INTEGER) : INTEGER;
BEGIN RETURN StartY + (idx DIV 3) * RowStride END DieY;

(* ── String helpers ──────────────────────────────────────────── *)

PROCEDURE StrLen(s : ARRAY OF CHAR) : INTEGER;
VAR n : INTEGER;
BEGIN
  n := 0;
  WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END;
  RETURN n
END StrLen;

(* Print s centered in a field of width chars, padding with spaces. *)
PROCEDURE PrintPad(s : ARRAY OF CHAR; width : INTEGER);
VAR len, left, right, j : INTEGER;
BEGIN
  len := StrLen(s);
  left  := (width - len) DIV 2;
  right := width - len - left;
  FOR j := 1 TO left  DO Out.Char(' ') END;
  Out.String(s);
  FOR j := 1 TO right DO Out.Char(' ') END
END PrintPad;

(* ── Die rendering ───────────────────────────────────────────── *)

PROCEDURE DrawDie(idx : INTEGER);
VAR x, y : INTEGER;
BEGIN
  x := DieX(idx);
  y := DieY(idx);

  IF locked[idx] THEN
    Terminal.Color256(220, 0)    (* gold = locked *)
  ELSE
    Terminal.Color256(255, 0)    (* white = free *)
  END;

  (* Row 0: top border *)
  Terminal.Goto(x, y);
  Out.String("+---------+");

  (* Row 1: die number + lock indicator *)
  Terminal.Goto(x, y + 1);
  Out.Char('|');
  Out.Char(CHR(ORD('1') + idx));
  IF locked[idx] THEN
    Out.String("  LOCK  |")    (* 2+4+2+| = 9 content chars *)
  ELSE
    Out.String("        |")    (* 8 spaces + | *)
  END;

  (* Row 2: face label, centered in 9-wide interior *)
  Terminal.Goto(x, y + 2);
  Out.Char('|');
  PrintPad(faces[idx][current[idx]], 9);
  Out.Char('|');

  (* Row 3: blank interior *)
  Terminal.Goto(x, y + 3);
  Out.String("|         |");

  (* Row 4: bottom border *)
  Terminal.Goto(x, y + 4);
  Out.String("+---------+");

  Terminal.Reset
END DrawDie;

PROCEDURE DrawAllDice;
VAR j : INTEGER;
BEGIN
  FOR j := 0 TO NDice - 1 DO DrawDie(j) END
END DrawAllDice;

(* ── Timing ──────────────────────────────────────────────────── *)

PROCEDURE Delay(ms : INTEGER);
VAR t : LONGINT;
BEGIN
  t := Terminal.GetTickCount() + ms;
  REPEAT UNTIL Terminal.GetTickCount() >= t
END Delay;

(* ── Game actions ────────────────────────────────────────────── *)

PROCEDURE RollUnlocked;
VAR j, frame : INTEGER;
BEGIN
  FOR frame := 1 TO 12 DO
    FOR j := 0 TO NDice - 1 DO
      IF ~locked[j] THEN current[j] := Random.Int(NFaces) END
    END;
    DrawAllDice;
    Out.Flush;
    Delay(55)
  END
END RollUnlocked;

PROCEDURE UnlockAll;
VAR j : INTEGER;
BEGIN
  FOR j := 0 TO NDice - 1 DO locked[j] := FALSE END
END UnlockAll;

(* ── UI panels ───────────────────────────────────────────────── *)

PROCEDURE DrawTitle;
BEGIN
  Terminal.Color256(226, 0);
  Terminal.Goto(31, 1);
  Out.String("RORY'S STORY CUBES");
  Terminal.Reset;
  Terminal.Color256(242, 0);
  Terminal.Goto(23, 2);
  Out.String("Roll the dice ~ tell a tale!");
  Terminal.Reset
END DrawTitle;

PROCEDURE DrawControls;
BEGIN
  Terminal.Color256(242, 0);
  Terminal.Goto(2, 22);
  Out.String("SPACE/ENTER: roll   1-9: lock/unlock   A: unlock all   R: reroll all   Q: quit");
  Terminal.Reset
END DrawControls;

PROCEDURE DrawStoryLine;
VAR j : INTEGER;
BEGIN
  Terminal.Goto(2, 23);
  Terminal.Color256(8, 0);
  Out.String("Story: ");
  Terminal.Color256(7, 0);
  FOR j := 0 TO NDice - 1 DO
    IF j > 0 THEN Out.String("  ") END;
    Out.String(faces[j][current[j]])
  END;
  Out.String("        ");
  Terminal.Reset
END DrawStoryLine;

(* ── Face data ───────────────────────────────────────────────── *)

PROCEDURE InitFaces;
BEGIN
  (* Die 1: Nature *)
  faces[0][0] := "TREE";    faces[0][1] := "FLOWER";
  faces[0][2] := "BEE";     faces[0][3] := "WAVE";
  faces[0][4] := "LEAF";    faces[0][5] := "BIRD";

  (* Die 2: Sky *)
  faces[1][0] := "STAR";    faces[1][1] := "SUN";
  faces[1][2] := "MOON";    faces[1][3] := "STORM";
  faces[1][4] := "RAINBOW"; faces[1][5] := "CLOUD";

  (* Die 3: Places *)
  faces[2][0] := "HOUSE";   faces[2][1] := "CASTLE";
  faces[2][2] := "TENT";    faces[2][3] := "BRIDGE";
  faces[2][4] := "CAVE";    faces[2][5] := "WELL";

  (* Die 4: Senses *)
  faces[3][0] := "EYE";     faces[3][1] := "EAR";
  faces[3][2] := "HAND";    faces[3][3] := "NOSE";
  faces[3][4] := "MOUTH";   faces[3][5] := "FOOT";

  (* Die 5: Travel *)
  faces[4][0] := "CAR";     faces[4][1] := "BOAT";
  faces[4][2] := "PLANE";   faces[4][3] := "ROCKET";
  faces[4][4] := "BIKE";    faces[4][5] := "GLOBE";

  (* Die 6: Objects *)
  faces[5][0] := "KEY";     faces[5][1] := "BOOK";
  faces[5][2] := "CROWN";   faces[5][3] := "SWORD";
  faces[5][4] := "MAP";     faces[5][5] := "MIRROR";

  (* Die 7: Feelings *)
  faces[6][0] := "HAPPY";   faces[6][1] := "SAD";
  faces[6][2] := "ANGRY";   faces[6][3] := "SCARED";
  faces[6][4] := "LAUGH";   faces[6][5] := "CRY";

  (* Die 8: Characters *)
  faces[7][0] := "HERO";    faces[7][1] := "WIZARD";
  faces[7][2] := "KING";    faces[7][3] := "GHOST";
  faces[7][4] := "ROBOT";   faces[7][5] := "CHILD";

  (* Die 9: Actions *)
  faces[8][0] := "RUN";     faces[8][1] := "SLEEP";
  faces[8][2] := "THINK";   faces[8][3] := "FIND";
  faces[8][4] := "BUILD";   faces[8][5] := "SPEAK";
END InitFaces;

(* ── Main ────────────────────────────────────────────────────── *)

BEGIN
  InitFaces;

  FOR i := 0 TO NDice - 1 DO
    current[i] := Random.Int(NFaces);
    locked[i]  := FALSE
  END;

  Terminal.HideCursor;
  Terminal.Clear;
  DrawTitle;
  DrawAllDice;
  DrawStoryLine;
  DrawControls;
  Out.Flush;

  LOOP
    key := Terminal.ReadKey();

    IF (key = 'q') OR (key = 'Q') THEN
      EXIT

    ELSIF (key = ' ') OR (key = KeyEnter) THEN
      RollUnlocked;
      DrawStoryLine;
      Out.Flush

    ELSIF (key = 'r') OR (key = 'R') THEN
      UnlockAll;
      RollUnlocked;
      DrawStoryLine;
      Out.Flush

    ELSIF (key = 'a') OR (key = 'A') THEN
      UnlockAll;
      DrawAllDice;
      DrawStoryLine;
      Out.Flush

    ELSIF (key >= '1') & (key <= '9') THEN
      i := ORD(key) - ORD('1');
      locked[i] := ~locked[i];
      DrawDie(i);
      Out.Flush

    END
  END;

  Terminal.Clear;
  Terminal.Goto(1, 1);
  Out.String("Thanks for playing Rory's Story Cubes!"); Out.Ln
END StoryCubes.
