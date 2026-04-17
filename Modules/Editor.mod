MODULE Editor;
(*
 * Gap-buffer text editor — C implementation, FFI-bound via Editor.ffi.
 *
 * This stub is documentation only; obc uses Editor.ffi instead.
 * Line and column numbers in the API are 1-based.
 *
 * FFI calling convention notes:
 *   - Input strings are NUL-terminated; no hidden length arg is passed.
 *   - GetLine takes an explicit bufsize INTEGER before the VAR buffer so
 *     the C side knows how much space is available.  Call as:
 *       n := Editor.GetLine(h, lineNo, LEN(buf), buf)
 *)

TYPE
  Handle* = POINTER TO RECORD END;  (* opaque C pointer *)

(* Lifecycle *)
PROCEDURE New*(): Handle;                                   BEGIN RETURN NIL END New;
PROCEDURE Free*(h: Handle);                                 BEGIN END Free;
PROCEDURE Load*(h: Handle; path: ARRAY OF CHAR): INTEGER;  BEGIN RETURN 0 END Load;
PROCEDURE Save*(h: Handle; path: ARRAY OF CHAR): INTEGER;  BEGIN RETURN 0 END Save;

(* Buffer state *)
PROCEDURE Len*(h: Handle): INTEGER;        BEGIN RETURN 0 END Len;
PROCEDURE LineCount*(h: Handle): INTEGER;  BEGIN RETURN 0 END LineCount;
PROCEDURE IsModified*(h: Handle): INTEGER; BEGIN RETURN 0 END IsModified;
PROCEDURE CursorPos*(h: Handle): INTEGER;  BEGIN RETURN 0 END CursorPos;
PROCEDURE CursorLine*(h: Handle): INTEGER; BEGIN RETURN 0 END CursorLine;
PROCEDURE CursorCol*(h: Handle): INTEGER;  BEGIN RETURN 0 END CursorCol;

(* Cursor movement *)
PROCEDURE MoveLeft*(h: Handle);      BEGIN END MoveLeft;
PROCEDURE MoveRight*(h: Handle);     BEGIN END MoveRight;
PROCEDURE MoveUp*(h: Handle);        BEGIN END MoveUp;
PROCEDURE MoveDown*(h: Handle);      BEGIN END MoveDown;
PROCEDURE MoveLineStart*(h: Handle); BEGIN END MoveLineStart;
PROCEDURE MoveLineEnd*(h: Handle);   BEGIN END MoveLineEnd;
PROCEDURE GotoLine*(h: Handle; line: INTEGER); BEGIN END GotoLine;
PROCEDURE GotoPos*(h: Handle; pos: INTEGER);   BEGIN END GotoPos;

(* Editing *)
PROCEDURE InsertChar*(h: Handle; ch: CHAR);        BEGIN END InsertChar;
PROCEDURE InsertStr*(h: Handle; s: ARRAY OF CHAR); BEGIN END InsertStr;
PROCEDURE Backspace*(h: Handle);                   BEGIN END Backspace;
PROCEDURE DeleteChar*(h: Handle);                  BEGIN END DeleteChar;
PROCEDURE Undo*(h: Handle);                        BEGIN END Undo;

(* Rendering: fills buf with line lineNo; returns char count.
   Pass LEN(buf) as bufsize. *)
PROCEDURE GetLine*(h: Handle; lineNo, bufsize: INTEGER;
                   VAR buf: ARRAY OF CHAR): INTEGER;
BEGIN RETURN 0 END GetLine;

(* Find/replace: returns 1 if match found, 0 otherwise *)
PROCEDURE Find*(h: Handle; pat: ARRAY OF CHAR;
                caseSensitive, wholeWord: INTEGER): INTEGER;
BEGIN RETURN 0 END Find;

PROCEDURE FindAgain*(h: Handle): INTEGER; BEGIN RETURN 0 END FindAgain;

PROCEDURE Replace*(h: Handle; repl: ARRAY OF CHAR): INTEGER;
BEGIN RETURN 0 END Replace;

END Editor.
