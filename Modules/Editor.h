#ifndef OBC_EDITOR_H_
#define OBC_EDITOR_H_

/* Editor — gap-buffer text editor (C implementation, FFI-bound).
 *
 * Parameter conventions for FFI:
 *   - Input strings  (char *): NUL-terminated; no extra length arg.
 *   - Output buffers (char *): caller passes an explicit int bufsize
 *     before the buffer pointer so C knows how much space is available.
 *   - CHAR params    (char):   passed directly.
 *
 * Line and column numbers in the public API are 1-based.
 */

typedef struct Editor_State_s Editor_State;
typedef Editor_State *Editor_Handle;

/* lifecycle */
Editor_Handle Editor_New(void);
void          Editor_Free(Editor_Handle h);
int           Editor_Load(Editor_Handle h, char *path);
int           Editor_Save(Editor_Handle h, char *path);

/* buffer state */
int  Editor_Len(Editor_Handle h);
int  Editor_LineCount(Editor_Handle h);
int  Editor_IsModified(Editor_Handle h);
int  Editor_CursorPos(Editor_Handle h);   /* byte offset */
int  Editor_CursorLine(Editor_Handle h);  /* 1-based */
int  Editor_CursorCol(Editor_Handle h);   /* 1-based */

/* cursor movement */
void Editor_MoveLeft(Editor_Handle h);
void Editor_MoveRight(Editor_Handle h);
void Editor_MoveUp(Editor_Handle h);
void Editor_MoveDown(Editor_Handle h);
void Editor_MoveLineStart(Editor_Handle h);
void Editor_MoveLineEnd(Editor_Handle h);
void Editor_GotoLine(Editor_Handle h, int line);   /* 1-based */
void Editor_GotoPos(Editor_Handle h, int pos);     /* byte offset */

/* editing */
void Editor_InsertChar(Editor_Handle h, char ch);
void Editor_InsertStr(Editor_Handle h, char *s);
void Editor_Backspace(Editor_Handle h);
void Editor_DeleteChar(Editor_Handle h);
void Editor_Undo(Editor_Handle h);

/* rendering: copies line lineNo (1-based) into buf[0..bufsize-1];
 * returns number of chars written (excluding NUL).               */
int  Editor_GetLine(Editor_Handle h, int lineNo, int bufsize, char *buf);

/* find/replace: return 1 if match found, 0 otherwise */
int  Editor_Find(Editor_Handle h, char *pat, int caseSensitive, int wholeWord);
int  Editor_FindAgain(Editor_Handle h);
int  Editor_Replace(Editor_Handle h, char *repl);

#endif /* OBC_EDITOR_H_ */
