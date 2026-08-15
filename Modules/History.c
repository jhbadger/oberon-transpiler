/*
 * History.c — command-line history with in-line editing.
 *
 * Implements a readline-style prompt:
 *   - Up/Down   : navigate history
 *   - Left/Right: move cursor within line
 *   - Home/End  : jump to start/end
 *   - Backspace : delete left
 *   - Delete    : delete right
 *   - Ctrl+A/E  : beginning/end of line
 *   - Ctrl+U    : kill to beginning of line
 *   - Ctrl+K    : kill to end of line
 *   - Ctrl+W    : kill previous word
 *   - Tab       : symbol completion (if callback registered)
 *   - Enter     : accept line
 *   - Ctrl+C    : cancel (returns empty string)
 *   - )  ]  }   : flash matching open delimiter
 *
 * History is stored in a circular buffer of MaxHist entries.
 * Load/Save persist one entry per line in a plain text file.
 */

#include "History.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <ctype.h>
#include <signal.h>

/* ── Ctrl+C interrupt flag ────────────────────────────────────────────────
 * Set either by the SIGINT handler below (normal/cooked terminal mode --
 * i.e. a program is running but not blocked in ReadLine) or directly by
 * ReadLine's raw-mode Ctrl+C case (raw mode disables ISIG, so the OS never
 * generates a real SIGINT while a keystroke read is in progress). Either
 * way, callers just poll History_Interrupted(). */

static volatile sig_atomic_t g_interrupted = 0;

static void on_sigint(int sig) { (void)sig; g_interrupted = 1; }

__attribute__((constructor))
static void History_init(void) { signal(SIGINT, on_sigint); }

int History_Interrupted(void) {
    if (g_interrupted) { g_interrupted = 0; return 1; }
    return 0;
}

#define HIST_MAX  500
#define HIST_LEN  256
#define LINE_MAX  255

/* ── Circular history buffer ─────────────────────────────────────────────── */

static char hist_entries[HIST_MAX][HIST_LEN];
static int  hist_total = 0;   /* number of entries ever added (may exceed HIST_MAX) */

static int hist_size(void) {
    return hist_total < HIST_MAX ? hist_total : HIST_MAX;
}

/* ridx 0 = most recent */
static const char *hist_at(int ridx) {
    int sz = hist_size();
    if (ridx < 0 || ridx >= sz) return NULL;
    int idx = (hist_total - 1 - ridx) % HIST_MAX;
    if (idx < 0) idx += HIST_MAX;
    return hist_entries[idx];
}

void History_Add(char *line) {
    if (!line || line[0] == '\0') return;
    /* skip duplicate of the most recent entry */
    if (hist_total > 0) {
        int last = (hist_total - 1) % HIST_MAX;
        if (strcmp(hist_entries[last], line) == 0) return;
    }
    int slot = hist_total % HIST_MAX;
    strncpy(hist_entries[slot], line, HIST_LEN - 1);
    hist_entries[slot][HIST_LEN - 1] = '\0';
    hist_total++;
}

/* ── Completion callback ──────────────────────────────────────────────────── */

static History_CompletionFn completion_fn = NULL;

void History_SetCompletionFn(History_CompletionFn fn) {
    completion_fn = fn;
}

/* ── Public wrappers without _len params (obc FFI ABI) ──────────────────── */

void History_Clear(void) {
    hist_total = 0;
    memset(hist_entries, 0, sizeof(hist_entries));
}

int History_Load(char *filename) {
    FILE *f = fopen(filename, "r");
    if (!f) return 0;
    char line[HIST_LEN];
    while (fgets(line, sizeof(line), f)) {
        /* strip trailing newline */
        size_t n = strlen(line);
        while (n > 0 && (line[n-1] == '\n' || line[n-1] == '\r')) { line[--n] = '\0'; }
        if (n > 0) History_Add(line);
    }
    fclose(f);
    return 1;
}

int History_Save(char *filename) {
    FILE *f = fopen(filename, "w");
    if (!f) return 0;
    int sz = hist_size();
    /* write oldest to newest */
    for (int i = sz - 1; i >= 0; i--) {
        const char *e = hist_at(i);
        if (e) fprintf(f, "%s\n", e);
    }
    fclose(f);
    return 1;
}

/* ── Raw terminal I/O ────────────────────────────────────────────────────── */

static struct termios saved_termios;
static int raw_mode_active = 0;

static void enable_raw(void) {
    if (!isatty(STDIN_FILENO)) return;
    tcgetattr(STDIN_FILENO, &saved_termios);
    struct termios raw = saved_termios;
    raw.c_iflag &= ~(unsigned)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~(unsigned)(OPOST);
    raw.c_cflag |= (CS8);
    raw.c_lflag &= ~(unsigned)(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN]  = 1;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    raw_mode_active = 1;
}

static void disable_raw(void) {
    if (raw_mode_active) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_termios);
        raw_mode_active = 0;
    }
}

static void out(const char *s) { fputs(s, stdout); }
static void outch(char c)      { fputc((unsigned char)c, stdout); }

/* Redraw the line: \r, prompt, buffer, erase-to-eol, reposition cursor. */
static void redraw(const char *prompt, int plen,
                   const char *buf, int len, int pos) {
    out("\r");
    out(prompt);
    for (int i = 0; i < len; i++) outch(buf[i]);
    out("\033[K");   /* erase to end of line */
    /* move cursor back from end to pos */
    int back = len - pos;
    if (back > 0) {
        char esc[32];
        snprintf(esc, sizeof(esc), "\033[%dD", back);
        out(esc);
    }
    fflush(stdout);
}

/* Read one byte; returns -1 on error/EOF */
static int readbyte(void) {
    unsigned char c;
    if (read(STDIN_FILENO, &c, 1) != 1) return -1;
    return (int)c;
}

/* Read and decode one keystroke into an action code + char. */
#define K_CHAR      0
#define K_ENTER     1
#define K_BACKSPACE 2
#define K_DELETE    3
#define K_LEFT      4
#define K_RIGHT     5
#define K_UP        6
#define K_DOWN      7
#define K_HOME      8
#define K_END       9
#define K_CTRL_A   10
#define K_CTRL_E   11
#define K_CTRL_U   12
#define K_CTRL_K   13
#define K_CTRL_W   14
#define K_CTRL_C   15
#define K_CTRL_D   16
#define K_TAB      17
#define K_UNKNOWN  99

typedef struct { int kind; char ch; } Key;

static Key read_key(void) {
    Key k = { K_UNKNOWN, 0 };
    int c = readbyte();
    if (c < 0) { k.kind = K_CTRL_D; return k; }

    if (c == '\r' || c == '\n') { k.kind = K_ENTER; return k; }
    if (c == 127 || c == 8)     { k.kind = K_BACKSPACE; return k; }
    if (c == 9)  { k.kind = K_TAB;    return k; }
    if (c == 1)  { k.kind = K_CTRL_A; return k; }
    if (c == 5)  { k.kind = K_CTRL_E; return k; }
    if (c == 21) { k.kind = K_CTRL_U; return k; }
    if (c == 11) { k.kind = K_CTRL_K; return k; }
    if (c == 23) { k.kind = K_CTRL_W; return k; }
    if (c == 3)  { k.kind = K_CTRL_C; return k; }
    if (c == 4)  { k.kind = K_CTRL_D; return k; }

    if (c == 27) {   /* escape sequence */
        int c2 = readbyte();
        if (c2 < 0) { k.kind = K_UNKNOWN; return k; }
        if (c2 == '[') {
            int c3 = readbyte();
            if (c3 < 0) { k.kind = K_UNKNOWN; return k; }
            if (c3 == 'A') { k.kind = K_UP;    return k; }
            if (c3 == 'B') { k.kind = K_DOWN;  return k; }
            if (c3 == 'C') { k.kind = K_RIGHT; return k; }
            if (c3 == 'D') { k.kind = K_LEFT;  return k; }
            if (c3 == 'H') { k.kind = K_HOME;  return k; }
            if (c3 == 'F') { k.kind = K_END;   return k; }
            if (c3 >= '1' && c3 <= '8') {
                int c4 = readbyte();  /* expect '~' */
                if (c4 == '~') {
                    if (c3 == '1' || c3 == '7') { k.kind = K_HOME;   return k; }
                    if (c3 == '3')              { k.kind = K_DELETE; return k; }
                    if (c3 == '4' || c3 == '8') { k.kind = K_END;    return k; }
                }
            }
        } else if (c2 == 'O') {
            int c3 = readbyte();
            if (c3 == 'H') { k.kind = K_HOME; return k; }
            if (c3 == 'F') { k.kind = K_END;  return k; }
        }
        return k;  /* K_UNKNOWN */
    }

    if (c >= 32 && c < 127) { k.kind = K_CHAR; k.ch = (char)c; return k; }
    return k;
}

/* ── Paren flash ──────────────────────────────────────────────────────────── */

/* After inserting a closing delimiter at buf[pos-1], briefly move the cursor
   to the matching opener so the user can see it, then restore. */
static void paren_flash(const char *prompt, int plen,
                        char *buf, int len, int pos) {
    char close = buf[pos - 1];
    char open  = (close == ')') ? '(' : (close == ']') ? '[' : '{';

    int depth = 0, in_str = 0, match = -1;
    for (int i = pos - 2; i >= 0; i--) {
        char c = buf[i];
        if (in_str) {
            /* a bare '"' while scanning backward exits the string */
            if (c == '"' && (i == 0 || buf[i-1] != '\\')) in_str = 0;
        } else {
            if (c == '"')    { in_str = 1; }
            else if (c == close) { depth++; }
            else if (c == open)  {
                if (depth == 0) { match = i; break; }
                depth--;
            }
        }
    }

    if (match < 0) return;

    /* Move cursor to the matching opener */
    int fc = plen + match;
    char esc[32];
    out("\r");
    if (fc > 0) { snprintf(esc, sizeof(esc), "\033[%dC", fc); out(esc); }
    fflush(stdout);
    usleep(200000);   /* 200 ms flash */
    redraw(prompt, plen, buf, len, pos);
}

/* ── Tab completion ───────────────────────────────────────────────────────── */

#define COMP_BUF  8192
#define COMP_WORDS 128

static void do_tab(const char *prompt, int plen,
                   char *buf, int *plen2, int *ppos) {
    int len = *plen2, pos = *ppos;

    /* Find start of the symbol being typed (stop at Lisp delimiters) */
    int ws = pos;
    while (ws > 0) {
        char c = buf[ws-1];
        if (c == ' ' || c == '(' || c == '[' || c == '{' ||
            c == ')' || c == ']' || c == '}' || c == '"') break;
        ws--;
    }
    int wlen = pos - ws;

    char prefix[LINE_MAX + 1];
    strncpy(prefix, buf + ws, (size_t)wlen);
    prefix[wlen] = '\0';

    static char completions[COMP_BUF];
    completions[0] = '\0';
    completion_fn(prefix, completions, sizeof(completions));

    if (!completions[0]) { outch('\a'); fflush(stdout); return; }

    /* Split completions into words */
    static char words[COMP_WORDS][LINE_MAX + 1];
    int nwords = 0;
    const char *p = completions;
    while (*p && nwords < COMP_WORDS) {
        while (*p == ' ') p++;
        if (!*p) break;
        int i = 0;
        while (*p && *p != ' ' && i < LINE_MAX) words[nwords][i++] = *p++;
        words[nwords][i] = '\0';
        nwords++;
    }

    if (nwords == 1) {
        /* Unique match: complete it in-place */
        int nlen = (int)strlen(words[0]);
        int total = len - wlen + nlen;
        if (total <= LINE_MAX) {
            memmove(buf + ws + nlen, buf + pos, (size_t)(len - pos));
            memcpy(buf + ws, words[0], (size_t)nlen);
            len = total; pos = ws + nlen;
            buf[len] = '\0';
            *plen2 = len; *ppos = pos;
            redraw(prompt, plen, buf, len, pos);
        }
        return;
    }

    /* Multiple matches: extend to longest common prefix */
    char common[LINE_MAX + 1];
    strncpy(common, words[0], LINE_MAX);
    common[LINE_MAX] = '\0';
    for (int wi = 1; wi < nwords; wi++) {
        int cp = 0;
        while (common[cp] && words[wi][cp] && common[cp] == words[wi][cp]) cp++;
        common[cp] = '\0';
    }
    int clen = (int)strlen(common);
    if (clen > wlen) {
        int total = len - wlen + clen;
        if (total <= LINE_MAX) {
            memmove(buf + ws + clen, buf + pos, (size_t)(len - pos));
            memcpy(buf + ws, common, (size_t)clen);
            len = total; pos = ws + clen;
            buf[len] = '\0';
            *plen2 = len; *ppos = pos;
        }
    }

    /* Print candidates below the current line */
    out("\r\n");
    int shown = nwords < 20 ? nwords : 20;
    for (int wi = 0; wi < shown; wi++) { out(words[wi]); outch(' '); }
    if (nwords > 20) out("...");
    out("\r\n");
    redraw(prompt, plen, buf, len, pos);
}

/* ── ReadLine ─────────────────────────────────────────────────────────────── */

void History_ReadLine(char *prompt, char *result) {
    /* Fallback: no tty — use fgets */
    if (!isatty(STDIN_FILENO)) {
        out(prompt);
        fflush(stdout);
        if (fgets(result, LINE_MAX + 1, stdin)) {
            int n = (int)strlen(result);
            while (n > 0 && (result[n-1] == '\n' || result[n-1] == '\r'))
                result[--n] = '\0';
            if (result[0] != '\0') History_Add(result);
        } else {
            result[0] = '\0';
        }
        return;
    }

    int plen = (int)strlen(prompt);

    char buf[LINE_MAX + 1];
    int  len = 0, pos = 0;
    int  hidx = -1;   /* -1 = current input; >= 0 = history offset */
    char saved[LINE_MAX + 1];  /* stash current input while browsing history */
    buf[0] = '\0';
    saved[0] = '\0';

    enable_raw();
    out(prompt);
    fflush(stdout);

    for (;;) {
        Key k = read_key();

        switch (k.kind) {

        case K_ENTER:
            buf[len] = '\0';
            out("\r\n");
            fflush(stdout);
            disable_raw();
            History_Add(buf);
            strncpy(result, buf, LINE_MAX);
            result[LINE_MAX] = '\0';
            return;

        case K_CTRL_C:
            out("\r\n");
            fflush(stdout);
            disable_raw();
            g_interrupted = 1;
            result[0] = '\0';
            return;

        case K_CTRL_D:
            if (len == 0) {
                out("\r\n");
                fflush(stdout);
                disable_raw();
                result[0] = '\0';
                return;
            }
            /* delete char at cursor (same as Delete) */
            if (pos < len) {
                memmove(buf + pos, buf + pos + 1, (size_t)(len - pos - 1));
                len--;
                buf[len] = '\0';
                redraw(prompt, plen, buf, len, pos);
            }
            break;

        case K_BACKSPACE:
            if (pos > 0) {
                memmove(buf + pos - 1, buf + pos, (size_t)(len - pos));
                pos--; len--;
                buf[len] = '\0';
                redraw(prompt, plen, buf, len, pos);
            }
            break;

        case K_DELETE:
            if (pos < len) {
                memmove(buf + pos, buf + pos + 1, (size_t)(len - pos - 1));
                len--;
                buf[len] = '\0';
                redraw(prompt, plen, buf, len, pos);
            }
            break;

        case K_LEFT:
            if (pos > 0) { pos--; out("\033[D"); fflush(stdout); }
            break;

        case K_RIGHT:
            if (pos < len) { pos++; out("\033[C"); fflush(stdout); }
            break;

        case K_HOME: case K_CTRL_A:
            pos = 0;
            redraw(prompt, plen, buf, len, pos);
            break;

        case K_END: case K_CTRL_E:
            pos = len;
            redraw(prompt, plen, buf, len, pos);
            break;

        case K_CTRL_U:
            if (pos > 0) {
                memmove(buf, buf + pos, (size_t)(len - pos));
                len -= pos; pos = 0;
                buf[len] = '\0';
                redraw(prompt, plen, buf, len, pos);
            }
            break;

        case K_CTRL_K:
            if (pos < len) {
                len = pos;
                buf[len] = '\0';
                redraw(prompt, plen, buf, len, pos);
            }
            break;

        case K_CTRL_W: {
            int end = pos;
            while (pos > 0 && buf[pos-1] == ' ') pos--;
            while (pos > 0 && buf[pos-1] != ' ') pos--;
            int killed = end - pos;
            memmove(buf + pos, buf + end, (size_t)(len - end));
            len -= killed;
            buf[len] = '\0';
            redraw(prompt, plen, buf, len, pos);
            break;
        }

        case K_TAB:
            if (completion_fn) {
                do_tab(prompt, plen, buf, &len, &pos);
            }
            break;

        case K_UP:
            if (hidx == -1) {
                /* save current input */
                strncpy(saved, buf, LINE_MAX);
                saved[LINE_MAX] = '\0';
            }
            if (hidx + 1 < hist_size()) {
                hidx++;
                const char *e = hist_at(hidx);
                if (e) {
                    strncpy(buf, e, LINE_MAX);
                    buf[LINE_MAX] = '\0';
                    len = (int)strlen(buf);
                    pos = len;
                    redraw(prompt, plen, buf, len, pos);
                }
            }
            break;

        case K_DOWN:
            if (hidx > 0) {
                hidx--;
                const char *e = hist_at(hidx);
                if (e) {
                    strncpy(buf, e, LINE_MAX);
                    buf[LINE_MAX] = '\0';
                    len = (int)strlen(buf);
                    pos = len;
                    redraw(prompt, plen, buf, len, pos);
                }
            } else if (hidx == 0) {
                hidx = -1;
                strncpy(buf, saved, LINE_MAX);
                buf[LINE_MAX] = '\0';
                len = (int)strlen(buf);
                pos = len;
                redraw(prompt, plen, buf, len, pos);
            }
            break;

        case K_CHAR:
            if (len < LINE_MAX) {
                memmove(buf + pos + 1, buf + pos, (size_t)(len - pos));
                buf[pos] = k.ch;
                pos++; len++;
                buf[len] = '\0';
                /* reset history browsing on any typed char */
                hidx = -1;
                redraw(prompt, plen, buf, len, pos);
                /* flash matching open delimiter for ) ] } */
                if ((k.ch == ')' || k.ch == ']' || k.ch == '}') && pos >= 2) {
                    paren_flash(prompt, plen, buf, len, pos);
                }
            }
            break;

        default:
            break;
        }
    }
}
