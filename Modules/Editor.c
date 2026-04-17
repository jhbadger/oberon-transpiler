/* Editor.c — gap-buffer text editor for the Oberon TUI IDE.
 *
 * The gap buffer stores text as:
 *   [ text before cursor ][ gap ][ text after cursor ]
 * The cursor always sits at gapstart.  Insertions fill the gap;
 * deletions widen it.  Moving the cursor slides the gap.
 */

#include "Editor.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

/* ── tunables ──────────────────────────────────────────────────────────── */
#define INITIAL_GAP  4096
#define GROW_GAP     4096
#define MAX_UNDO     512

/* ── undo record ───────────────────────────────────────────────────────── */
#define UD_INSERT 0
#define UD_DELETE 1

typedef struct {
    int   type;  /* UD_INSERT or UD_DELETE */
    int   pos;   /* logical byte offset    */
    char *data;  /* heap copy of the text  */
    int   len;
} UndoRec;

/* ── editor state ──────────────────────────────────────────────────────── */
struct Editor_State_s {
    char *buf;
    int   bufsize;   /* total allocated bytes (text + gap) */
    int   gapstart;  /* cursor = gap start                 */
    int   gapend;

    int   modified;

    /* find state */
    char  fpat[256];
    int   fcase;
    int   fwhole;
    int   flast;     /* logical start of last match, -1 = none */
    int   flastlen;

    /* undo stack */
    UndoRec undo[MAX_UNDO];
    int     utop;
};

/* ── internal gap-buffer helpers ───────────────────────────────────────── */

static int ed_len(Editor_State *e) {
    return e->bufsize - (e->gapend - e->gapstart);
}

/* Character at logical position i (no bounds guard — callers must check). */
static char ed_at(Editor_State *e, int i) {
    int g = e->gapend - e->gapstart;
    return i < e->gapstart ? e->buf[i] : e->buf[i + g];
}

/* Ensure gap has at least `need` bytes. */
static void ed_grow(Editor_State *e, int need) {
    int have = e->gapend - e->gapstart;
    if (have >= need) return;
    int add     = need - have + GROW_GAP;
    int newsize = e->bufsize + add;
    char *nb    = realloc(e->buf, newsize);
    if (!nb) return;
    int post      = e->bufsize - e->gapend;
    int newgapend = newsize - post;
    if (post > 0) memmove(nb + newgapend, nb + e->gapend, post);
    e->buf     = nb;
    e->gapend  = newgapend;
    e->bufsize = newsize;
}

/* Move gap so that gapstart == pos (logical). */
static void ed_movegap(Editor_State *e, int pos) {
    int len = ed_len(e);
    if (pos < 0)   pos = 0;
    if (pos > len) pos = len;
    if (pos == e->gapstart) return;
    if (pos < e->gapstart) {
        int n = e->gapstart - pos;
        e->gapend -= n;
        memmove(e->buf + e->gapend, e->buf + pos, n);
        e->gapstart = pos;
    } else {
        int n = pos - e->gapstart;
        memmove(e->buf + e->gapstart, e->buf + e->gapend, n);
        e->gapstart += n;
        e->gapend   += n;
    }
}

/* ── raw insert/delete (no undo recording) ─────────────────────────────── */

static void ed_rawinsert(Editor_State *e, int pos, const char *text, int len) {
    ed_grow(e, len);
    ed_movegap(e, pos);
    memcpy(e->buf + e->gapstart, text, len);
    e->gapstart += len;
    e->modified  = 1;
}

static void ed_rawdelete(Editor_State *e, int pos, int len) {
    ed_movegap(e, pos);
    e->gapend  += len;
    e->modified = 1;
}

/* ── line navigation helpers ───────────────────────────────────────────── */

/* Byte offset of the start of 0-based line lineIdx. */
static int line_start(Editor_State *e, int lineIdx) {
    if (lineIdx <= 0) return 0;
    int len = ed_len(e), line = 0, pos = 0;
    while (pos < len) {
        if (ed_at(e, pos++) == '\n')
            if (++line == lineIdx) return pos;
    }
    return pos;
}

/* Byte offset of the newline ending the line at pos, or end-of-buffer. */
static int line_end(Editor_State *e, int pos) {
    int len = ed_len(e);
    while (pos < len && ed_at(e, pos) != '\n') pos++;
    return pos;
}

/* 0-based line index of the cursor (counts \n in pre-gap region). */
static int cursor_line_idx(Editor_State *e) {
    int line = 0;
    for (int i = 0; i < e->gapstart; i++)
        if (e->buf[i] == '\n') line++;
    return line;
}

/* 0-based column of the cursor (bytes since last \n in pre-gap region). */
static int cursor_col_idx(Editor_State *e) {
    int col = 0;
    for (int i = e->gapstart - 1; i >= 0 && e->buf[i] != '\n'; i--)
        col++;
    return col;
}

/* ── undo helpers ──────────────────────────────────────────────────────── */

static void undo_push(Editor_State *e, int type, int pos,
                      const char *data, int len)
{
    if (e->utop >= MAX_UNDO) {
        free(e->undo[0].data);
        memmove(e->undo, e->undo + 1, (MAX_UNDO - 1) * sizeof(UndoRec));
        e->utop--;
    }
    UndoRec *r = &e->undo[e->utop++];
    r->type = type;
    r->pos  = pos;
    r->len  = len;
    r->data = malloc(len + 1);
    if (r->data) { memcpy(r->data, data, len); r->data[len] = '\0'; }
}

/* ── public API ────────────────────────────────────────────────────────── */

Editor_Handle Editor_New(void) {
    Editor_State *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->buf = malloc(INITIAL_GAP);
    if (!e->buf) { free(e); return NULL; }
    e->bufsize  = INITIAL_GAP;
    e->gapstart = 0;
    e->gapend   = INITIAL_GAP;
    e->flast    = -1;
    return e;
}

void Editor_Free(Editor_Handle h) {
    if (!h) return;
    for (int i = 0; i < h->utop; i++) free(h->undo[i].data);
    free(h->buf);
    free(h);
}

int Editor_Load(Editor_Handle h, char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    rewind(f);
    h->gapstart = 0;
    h->gapend   = h->bufsize;
    ed_grow(h, (int)sz + 1);
    long n = (long)fread(h->buf + h->gapstart, 1, (size_t)sz, f);
    fclose(f);
    h->gapstart += (int)n;
    h->modified  = 0;
    h->flast     = -1;
    for (int i = 0; i < h->utop; i++) free(h->undo[i].data);
    h->utop = 0;
    return 1;
}

int Editor_Save(Editor_Handle h, char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    int ok = 1;
    if (h->gapstart > 0)
        ok &= (fwrite(h->buf, 1, (size_t)h->gapstart, f)
               == (size_t)h->gapstart);
    int post = ed_len(h) - h->gapstart;
    if (post > 0)
        ok &= (fwrite(h->buf + h->gapend, 1, (size_t)post, f)
               == (size_t)post);
    fclose(f);
    if (ok) h->modified = 0;
    return ok;
}

int Editor_Len(Editor_Handle h)        { return ed_len(h); }
int Editor_IsModified(Editor_Handle h) { return h->modified; }
int Editor_CursorPos(Editor_Handle h)  { return h->gapstart; }

int Editor_LineCount(Editor_Handle h) {
    int n = 1, len = ed_len(h);
    for (int i = 0; i < len; i++)
        if (ed_at(h, i) == '\n') n++;
    return n;
}

int Editor_CursorLine(Editor_Handle h) { return cursor_line_idx(h) + 1; }
int Editor_CursorCol(Editor_Handle h)  { return cursor_col_idx(h)  + 1; }

/* ── cursor movement ───────────────────────────────────────────────────── */

/* Left/right: slide a single character across the gap — O(1). */
void Editor_MoveLeft(Editor_Handle h) {
    if (h->gapstart == 0) return;
    h->buf[--h->gapend] = h->buf[--h->gapstart];
}

void Editor_MoveRight(Editor_Handle h) {
    if (h->gapend >= h->bufsize) return;
    h->buf[h->gapstart++] = h->buf[h->gapend++];
}

void Editor_MoveUp(Editor_Handle h) {
    int li = cursor_line_idx(h);
    if (li == 0) return;
    int col = cursor_col_idx(h);
    int ps  = line_start(h, li - 1);
    int len = line_end(h, ps) - ps;
    ed_movegap(h, ps + (col < len ? col : len));
}

void Editor_MoveDown(Editor_Handle h) {
    int li = cursor_line_idx(h);
    if (li >= Editor_LineCount(h) - 1) return;
    int col = cursor_col_idx(h);
    int ns  = line_start(h, li + 1);
    int len = line_end(h, ns) - ns;
    ed_movegap(h, ns + (col < len ? col : len));
}

void Editor_MoveLineStart(Editor_Handle h) {
    int pos = h->gapstart;
    while (pos > 0 && h->buf[pos - 1] != '\n') pos--;
    ed_movegap(h, pos);
}

void Editor_MoveLineEnd(Editor_Handle h) {
    ed_movegap(h, line_end(h, h->gapstart));
}

void Editor_GotoLine(Editor_Handle h, int line) {
    ed_movegap(h, line_start(h, line - 1));
}

void Editor_GotoPos(Editor_Handle h, int pos) {
    ed_movegap(h, pos);
}

/* ── editing ───────────────────────────────────────────────────────────── */

void Editor_InsertChar(Editor_Handle h, char ch) {
    /* Merge into the previous INSERT record when chars are consecutive. */
    if (h->utop > 0) {
        UndoRec *r = &h->undo[h->utop - 1];
        if (r->type == UD_INSERT && r->pos + r->len == h->gapstart) {
            char *nd = realloc(r->data, r->len + 2);
            if (nd) {
                r->data = nd;
                r->data[r->len++] = ch;
                r->data[r->len]   = '\0';
                ed_rawinsert(h, h->gapstart, &ch, 1);
                return;
            }
        }
    }
    undo_push(h, UD_INSERT, h->gapstart, &ch, 1);
    ed_rawinsert(h, h->gapstart, &ch, 1);
}

void Editor_InsertStr(Editor_Handle h, char *s) {
    int len = (int)strlen(s);
    if (len == 0) return;
    undo_push(h, UD_INSERT, h->gapstart, s, len);
    ed_rawinsert(h, h->gapstart, s, len);
}

void Editor_Backspace(Editor_Handle h) {
    if (h->gapstart == 0) return;
    char ch = h->buf[h->gapstart - 1];
    /* Merge consecutive backspaces: deleted run grows leftward. */
    if (h->utop > 0) {
        UndoRec *r = &h->undo[h->utop - 1];
        if (r->type == UD_DELETE && r->pos == h->gapstart - 1) {
            char *nd = realloc(r->data, r->len + 2);
            if (nd) {
                memmove(nd + 1, nd, r->len + 1);
                nd[0] = ch;
                r->data = nd;
                r->len++;
                r->pos--;
                h->gapstart--;
                h->modified = 1;
                return;
            }
        }
    }
    undo_push(h, UD_DELETE, h->gapstart - 1, &ch, 1);
    h->gapstart--;
    h->modified = 1;
}

void Editor_DeleteChar(Editor_Handle h) {
    if (h->gapstart >= ed_len(h)) return;
    char ch = h->buf[h->gapend];
    undo_push(h, UD_DELETE, h->gapstart, &ch, 1);
    h->gapend++;
    h->modified = 1;
}

void Editor_Undo(Editor_Handle h) {
    if (h->utop == 0) return;
    UndoRec r = h->undo[--h->utop];
    if (r.type == UD_INSERT) {
        ed_rawdelete(h, r.pos, r.len);
        ed_movegap(h, r.pos);
    } else {
        ed_rawinsert(h, r.pos, r.data, r.len);
        ed_movegap(h, r.pos);
    }
    free(r.data);
}

/* ── rendering ─────────────────────────────────────────────────────────── */

int Editor_GetLine(Editor_Handle h, int lineNo, int bufsize, char *buf) {
    int start = line_start(h, lineNo - 1);
    int end   = line_end(h, start);
    int n     = end - start;
    if (n > bufsize - 1) n = bufsize - 1;
    for (int i = 0; i < n; i++) buf[i] = ed_at(h, start + i);
    buf[n] = '\0';
    return n;
}

/* ── find / replace ────────────────────────────────────────────────────── */

static int pat_matches(Editor_State *e, int pos, const char *pat, int plen,
                       int cs, int whole)
{
    int len = ed_len(e);
    if (pos + plen > len) return 0;
    for (int i = 0; i < plen; i++) {
        char a = ed_at(e, pos + i), b = pat[i];
        if (!cs) { a = (char)tolower((unsigned char)a);
                   b = (char)tolower((unsigned char)b); }
        if (a != b) return 0;
    }
    if (whole) {
        if (pos > 0) {
            char c = ed_at(e, pos - 1);
            if (isalnum((unsigned char)c) || c == '_') return 0;
        }
        if (pos + plen < len) {
            char c = ed_at(e, pos + plen);
            if (isalnum((unsigned char)c) || c == '_') return 0;
        }
    }
    return 1;
}

int Editor_Find(Editor_Handle h, char *pat, int caseSensitive, int wholeWord) {
    strncpy(h->fpat, pat, sizeof(h->fpat) - 1);
    h->fpat[sizeof(h->fpat) - 1] = '\0';
    h->fcase  = caseSensitive;
    h->fwhole = wholeWord;
    h->flast  = -1;
    return Editor_FindAgain(h);
}

int Editor_FindAgain(Editor_Handle h) {
    int plen = (int)strlen(h->fpat);
    if (plen == 0) return 0;
    int len   = ed_len(h);
    int start = h->gapstart;
    /* Two-pass: from cursor to end, then wrap from start to cursor. */
    for (int pass = 0; pass < 2; pass++) {
        int from = (pass == 0) ? start : 0;
        int to   = (pass == 0) ? len   : start;
        for (int i = from; i <= to - plen; i++) {
            if (pat_matches(h, i, h->fpat, plen, h->fcase, h->fwhole)) {
                ed_movegap(h, i + plen);
                h->flast    = i;
                h->flastlen = plen;
                return 1;
            }
        }
    }
    return 0;
}

int Editor_Replace(Editor_Handle h, char *repl) {
    if (h->flast < 0) return 0;
    int pos  = h->flast;
    int plen = h->flastlen;
    int rlen = (int)strlen(repl);

    /* Record the actual matched text for clean undo. */
    char *matched = malloc(plen + 1);
    if (matched) {
        for (int i = 0; i < plen; i++) matched[i] = ed_at(h, pos + i);
        matched[plen] = '\0';
        undo_push(h, UD_DELETE, pos, matched, plen);
        free(matched);
    }
    ed_rawdelete(h, pos, plen);
    undo_push(h, UD_INSERT, pos, repl, rlen);
    ed_rawinsert(h, pos, repl, rlen);
    ed_movegap(h, pos + rlen);

    h->flast = -1;
    return Editor_FindAgain(h);
}
