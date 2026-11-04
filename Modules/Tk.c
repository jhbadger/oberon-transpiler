/*
 * Tk.c — Tcl/Tk binding for obc.
 *
 * A `wish` process is started as a child and driven over pipes.
 *
 *   program -> wish : one line per request, "\" and newline escaped as \\ and \n
 *   wish -> program : framed replies
 *        R <status> <nbytes>\n<payload>     answer to a request (status 0 = ok)
 *        E <nbytes>\n<payload>              asynchronous event (from Tcl `ev`)
 *
 * Requests are strictly synchronous: Tk_Eval returns only after the reply
 * arrives, and any events that show up in the meantime are queued.
 */

#include "OBCTk.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ── Tcl side of the bridge ─────────────────────────────────────────────── */

static const char BOOTSTRAP[] =
"fconfigure stdin  -blocking 0 -translation lf -encoding utf-8\n"
"fconfigure stdout -translation lf -encoding utf-8 -buffering none\n"
"namespace eval ::tkb {}\n"
"proc ::tkb::frame {head payload} {\n"
"    set n [string length [encoding convertto utf-8 $payload]]\n"
"    puts -nonewline stdout \"$head $n\\n$payload\"\n"
"}\n"
"proc ev {args} { ::tkb::frame E $args }\n"
"proc ::tkb::readable {} {\n"
"    while {[gets stdin line] >= 0} {\n"
"        set script [string map [list \"\\\\\\\\\" \"\\\\\" \"\\\\n\" \"\\n\"] $line]\n"
"        set rc [catch {uplevel #0 $script} res]\n"
"        ::tkb::frame \"R [expr {$rc != 0}]\" $res\n"
"    }\n"
"    if {[eof stdin]} { exit }\n"
"}\n"
"fileevent stdin readable ::tkb::readable\n"
"wm protocol . WM_DELETE_WINDOW {ev WM_DELETE_WINDOW}\n"
"after idle {catch {raise .; focus -force .}}\n"
"::tkb::frame \"R 0\" ready\n";

/* ── state ──────────────────────────────────────────────────────────────── */

typedef struct Ev { struct Ev *next; char *text; } Ev;

static pid_t  g_pid   = -1;
static int    g_to    = -1;      /* we write requests here */
static int    g_from  = -1;      /* we read replies here   */
static int    g_alive = 0;

static char  *g_rbuf  = NULL;    /* receive buffer */
static size_t g_rlen  = 0, g_rcap = 0;

static char  *g_res   = NULL;    /* last result */
static size_t g_reslen = 0;

static Ev    *g_qhead = NULL, *g_qtail = NULL;
static int    g_qcount = 0;

static int    g_atexit = 0;

static void set_result(const char *s, size_t n) {
    char *p = (char *)realloc(g_res, n + 1);
    if (!p) return;
    g_res = p;
    memcpy(g_res, s, n);
    g_res[n] = 0;
    g_reslen = n;
}

static void set_result_str(const char *s) { set_result(s, strlen(s)); }

static void copy_out(const char *src, size_t n, int bufsize, char *buf) {
    if (bufsize <= 0 || !buf) return;
    size_t m = n < (size_t)(bufsize - 1) ? n : (size_t)(bufsize - 1);
    memcpy(buf, src, m);
    buf[m] = 0;
}

static void enqueue(const char *s, size_t n) {
    Ev *e = (Ev *)malloc(sizeof(Ev));
    if (!e) return;
    e->text = (char *)malloc(n + 1);
    if (!e->text) { free(e); return; }
    memcpy(e->text, s, n);
    e->text[n] = 0;
    e->next = NULL;
    if (g_qtail) g_qtail->next = e; else g_qhead = e;
    g_qtail = e;
    g_qcount++;
}

void Tk_Flush(void) {
    while (g_qhead) {
        Ev *e = g_qhead;
        g_qhead = e->next;
        free(e->text);
        free(e);
    }
    g_qtail = NULL;
    g_qcount = 0;
}

/* ── low-level I/O ──────────────────────────────────────────────────────── */

/* Read whatever is available into g_rbuf.  Returns 1 if data was read,
 * 0 on timeout, -1 on EOF/error.  timeout_ms < 0 blocks. */
static int pump(int timeout_ms) {
    struct pollfd p;
    p.fd = g_from; p.events = POLLIN; p.revents = 0;
    int r;
    do { r = poll(&p, 1, timeout_ms); } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;
    if (r == 0) return 0;
    if (g_rcap - g_rlen < 4096) {
        size_t nc = g_rcap ? g_rcap * 2 : 8192;
        char *nb = (char *)realloc(g_rbuf, nc);
        if (!nb) return -1;
        g_rbuf = nb; g_rcap = nc;
    }
    ssize_t n;
    do { n = read(g_from, g_rbuf + g_rlen, g_rcap - g_rlen); } while (n < 0 && errno == EINTR);
    if (n <= 0) return -1;
    g_rlen += (size_t)n;
    return 1;
}

/* Try to extract one complete frame from the receive buffer.
 * Returns 'R' or 'E' (payload malloc'd in *payload, status in *status),
 * or 0 if no complete frame is buffered yet. */
static int next_frame(char **payload, size_t *plen, int *status) {
    char *nl = (char *)memchr(g_rbuf, '\n', g_rlen);
    if (!nl) return 0;
    size_t hlen = (size_t)(nl - g_rbuf) + 1;
    char kind = g_rbuf[0];
    long st = 0, n = 0;
    if (kind == 'R') {
        if (sscanf(g_rbuf, "R %ld %ld", &st, &n) != 2) n = -1;
    } else if (kind == 'E') {
        if (sscanf(g_rbuf, "E %ld", &n) != 1) n = -1;
    } else n = -1;
    if (n < 0) {                       /* junk line (e.g. a stray puts): drop it */
        memmove(g_rbuf, g_rbuf + hlen, g_rlen - hlen);
        g_rlen -= hlen;
        return next_frame(payload, plen, status);
    }
    if (g_rlen < hlen + (size_t)n) return 0;
    char *p = (char *)malloc((size_t)n + 1);
    if (!p) return 0;
    memcpy(p, g_rbuf + hlen, (size_t)n);
    p[n] = 0;
    memmove(g_rbuf, g_rbuf + hlen + n, g_rlen - hlen - (size_t)n);
    g_rlen -= hlen + (size_t)n;
    *payload = p; *plen = (size_t)n; *status = (int)st;
    return kind;
}

static void mark_dead(void) {
    g_alive = 0;
}

static int write_all(const char *s, size_t n) {
    while (n > 0) {
        ssize_t w = write(g_to, s, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        s += w; n -= (size_t)w;
    }
    return 0;
}

/* Send one request line (escaped). */
static int send_request(const char *script) {
    size_t n = strlen(script);
    char *out = (char *)malloc(n * 2 + 2);
    if (!out) return -1;
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        char c = script[i];
        if (c == '\\')      { out[j++] = '\\'; out[j++] = '\\'; }
        else if (c == '\n') { out[j++] = '\\'; out[j++] = 'n'; }
        else                  out[j++] = c;
    }
    out[j++] = '\n';
    int r = write_all(out, j);
    free(out);
    return r;
}

/* ── lifecycle ──────────────────────────────────────────────────────────── */

static void kill_child(void) {
    if (g_to   >= 0) { close(g_to);   g_to = -1; }
    if (g_from >= 0) { close(g_from); g_from = -1; }
    if (g_pid  >  0) {
        int st, i;
        for (i = 0; i < 20; i++) {
            if (waitpid(g_pid, &st, WNOHANG) != 0) { g_pid = -1; break; }
            struct timespec ts = {0, 50 * 1000 * 1000};
            nanosleep(&ts, NULL);
        }
        if (g_pid > 0) { kill(g_pid, SIGKILL); waitpid(g_pid, &st, 0); g_pid = -1; }
    }
    g_alive = 0;
}

static void at_exit_close(void) { if (g_pid > 0) Tk_Close(); }

static void exec_wish(const char *script) {
    const char *env = getenv("OBC_WISH");
    const char *cands[] = {
        env,
        "/opt/homebrew/opt/tcl-tk/bin/wish9.0", "/opt/homebrew/opt/tcl-tk/bin/wish8.6",
        "/opt/homebrew/opt/tcl-tk/bin/wish",
        "/usr/local/opt/tcl-tk/bin/wish9.0", "/usr/local/opt/tcl-tk/bin/wish8.6",
        "/usr/local/opt/tcl-tk/bin/wish",
        "wish9.0", "wish8.6", "wish8.7", "wish",
        "/usr/bin/wish",
        NULL
    };
    for (size_t i = 0; i < sizeof cands / sizeof cands[0]; i++) {
        if (!cands[i] || !cands[i][0]) continue;
        if (cands[i][0] == '/' && access(cands[i], X_OK) != 0) continue;
        execlp(cands[i], "wish", script, (char *)NULL);
    }
}

int Tk_Open(void) {
    if (g_alive) return 1;
    signal(SIGPIPE, SIG_IGN);
    Tk_Flush();
    g_rlen = 0;

    char path[] = "/tmp/obctkXXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) { set_result_str("Tk: cannot create bootstrap file"); return 0; }
    size_t n = sizeof(BOOTSTRAP) - 1;
    if (write(fd, BOOTSTRAP, n) != (ssize_t)n) {
        close(fd); unlink(path);
        set_result_str("Tk: cannot write bootstrap file"); return 0;
    }
    close(fd);

    int p2w[2], w2p[2];
    if (pipe(p2w) < 0 || pipe(w2p) < 0) {
        unlink(path); set_result_str("Tk: pipe failed"); return 0;
    }
    pid_t pid = fork();
    if (pid < 0) {
        unlink(path); set_result_str("Tk: fork failed"); return 0;
    }
    if (pid == 0) {
        dup2(p2w[0], 0);
        dup2(w2p[1], 1);
        close(p2w[0]); close(p2w[1]); close(w2p[0]); close(w2p[1]);
        exec_wish(path);
        _exit(127);
    }
    close(p2w[0]); close(w2p[1]);
    g_pid = pid; g_to = p2w[1]; g_from = w2p[0];
    fcntl(g_to,   F_SETFD, FD_CLOEXEC);
    fcntl(g_from, F_SETFD, FD_CLOEXEC);

    /* wait (up to 15 s) for the "ready" handshake */
    int ok = 0;
    for (int tries = 0; tries < 15 && !ok; tries++) {
        char *pl; size_t pn; int st;
        for (;;) {
            int k = next_frame(&pl, &pn, &st);
            if (k == 'R') { free(pl); ok = 1; break; }
            if (k == 'E') { free(pl); continue; }
            break;
        }
        if (ok) break;
        int r = pump(1000);
        if (r < 0) break;
    }
    unlink(path);
    if (!ok) {
        kill_child();
        set_result_str("Tk: could not start wish (is Tcl/Tk installed? set OBC_WISH to its path)");
        return 0;
    }
    g_alive = 1;
    if (!g_atexit) { atexit(at_exit_close); g_atexit = 1; }
    set_result_str("");
    return 1;
}

int Tk_Alive(void) { return g_alive; }

void Tk_Close(void) {
    if (g_alive && g_to >= 0) {
        send_request("exit");
    }
    kill_child();
    Tk_Flush();
}

/* ── evaluation ─────────────────────────────────────────────────────────── */

int Tk_Eval(char *script) {
    if (!g_alive) { set_result_str("Tk: not running"); return 1; }
    if (send_request(script) < 0) { mark_dead(); set_result_str("Tk: wish has exited"); return 1; }
    for (;;) {
        char *pl; size_t pn; int st;
        int k;
        while ((k = next_frame(&pl, &pn, &st)) != 0) {
            if (k == 'E') { enqueue(pl, pn); free(pl); continue; }
            set_result(pl, pn);
            free(pl);
            return st ? 1 : 0;
        }
        if (pump(-1) < 0) {
            mark_dead();
            set_result_str("Tk: wish has exited");
            return 1;
        }
    }
}

int Tk_Result(int bufsize, char *buf) {
    copy_out(g_res ? g_res : "", g_reslen, bufsize, buf);
    return (int)g_reslen;
}

int Tk_ResultInt(void) {
    return g_res ? (int)strtol(g_res, NULL, 0) : 0;
}

double Tk_ResultReal(void) {
    return g_res ? strtod(g_res, NULL) : 0.0;
}

/* ── quoting and calls ──────────────────────────────────────────────────── */

/* Quote s as a single Tcl word into a malloc'd string. */
static char *quote_word(const char *s) {
    size_t n = strlen(s);
    char *out = (char *)malloc(n * 2 + 3);
    if (!out) return NULL;
    if (n == 0) { strcpy(out, "{}"); return out; }
    size_t j = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '\n': out[j++] = '\\'; out[j++] = 'n'; break;
        case '\t': out[j++] = '\\'; out[j++] = 't'; break;
        case '\r': out[j++] = '\\'; out[j++] = 'r'; break;
        case ' ': case '[': case ']': case '{': case '}': case '$':
        case '"': case ';': case '\\':
            out[j++] = '\\'; out[j++] = (char)c; break;
        default:
            if (i == 0 && c == '#') out[j++] = '\\';
            out[j++] = (char)c;
        }
    }
    out[j] = 0;
    return out;
}

int Tk_Quote(char *s, int bufsize, char *buf) {
    char *q = quote_word(s);
    if (!q) { if (bufsize > 0) buf[0] = 0; return 0; }
    int n = (int)strlen(q);
    copy_out(q, (size_t)n, bufsize, buf);
    free(q);
    return n;
}

/* cmd followed by n quoted arguments */
static int call_n(const char *cmd, int n, const char **args) {
    size_t cap = strlen(cmd) + 2;
    char *q[8];
    for (int i = 0; i < n; i++) {
        q[i] = quote_word(args[i]);
        if (!q[i]) { for (int k = 0; k < i; k++) free(q[k]); set_result_str("Tk: out of memory"); return 1; }
        cap += strlen(q[i]) + 1;
    }
    char *script = (char *)malloc(cap);
    if (!script) { for (int i = 0; i < n; i++) free(q[i]); set_result_str("Tk: out of memory"); return 1; }
    strcpy(script, cmd);
    for (int i = 0; i < n; i++) { strcat(script, " "); strcat(script, q[i]); free(q[i]); }
    int r = Tk_Eval(script);
    free(script);
    return r;
}

int Tk_Call1(char *cmd, char *a1) {
    const char *a[] = { a1 };
    return call_n(cmd, 1, a);
}
int Tk_Call2(char *cmd, char *a1, char *a2) {
    const char *a[] = { a1, a2 };
    return call_n(cmd, 2, a);
}
int Tk_Call3(char *cmd, char *a1, char *a2, char *a3) {
    const char *a[] = { a1, a2, a3 };
    return call_n(cmd, 3, a);
}

int Tk_Configure(char *widget, char *option, char *value) {
    /* widget configure -option value  (widget path and option are plain words) */
    size_t cap = strlen(widget) + strlen(option) + 32;
    char *script = (char *)malloc(cap);
    if (!script) return 1;
    snprintf(script, cap, "%s configure %s%s", widget, option[0] == '-' ? "" : "-", option);
    int r = Tk_Call1(script, value);
    free(script);
    return r;
}

int Tk_Set(char *var, char *value) { return Tk_Call2("set", var, value); }

int Tk_Get(char *var, int bufsize, char *buf) {
    if (Tk_Call1("set", var) != 0) { if (bufsize > 0) buf[0] = 0; return 0; }
    Tk_Result(bufsize, buf);
    return 1;
}

int Tk_Word(char *list, int n, int bufsize, char *buf) {
    char idx[32];
    snprintf(idx, sizeof idx, "%d", n);
    if (Tk_Call2("lindex", list, idx) != 0) { if (bufsize > 0) buf[0] = 0; return 0; }
    return Tk_Result(bufsize, buf);
}

/* ── events ─────────────────────────────────────────────────────────────── */

static void drain(int timeout_ms) {
    /* absorb buffered frames, optionally waiting for more */
    for (;;) {
        char *pl; size_t pn; int st, k, got = 0;
        while ((k = next_frame(&pl, &pn, &st)) != 0) {
            if (k == 'E') { enqueue(pl, pn); got = 1; }
            free(pl);     /* stray R frames are discarded */
        }
        if (got || timeout_ms == 0) return;
        int r = pump(timeout_ms);
        if (r < 0) { mark_dead(); return; }
        if (r == 0) return;
        timeout_ms = 0;      /* have data now: one more parse pass, then return */
    }
}

int Tk_Pending(void) {
    if (g_from >= 0 && g_alive) {
        drain(0);
        while (g_alive && pump(0) > 0) drain(0);
    }
    return g_qcount;
}

int Tk_Wait(int ms, int bufsize, char *buf) {
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        if (g_qhead) {
            Ev *e = g_qhead;
            g_qhead = e->next;
            if (!g_qhead) g_qtail = NULL;
            g_qcount--;
            copy_out(e->text, strlen(e->text), bufsize, buf);
            free(e->text); free(e);
            return 1;
        }
        if (!g_alive) { if (bufsize > 0) buf[0] = 0; return -1; }
        int wait = ms;
        if (ms > 0) {
            struct timespec t1;
            clock_gettime(CLOCK_MONOTONIC, &t1);
            long el = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
            wait = (int)(ms - el);
            if (wait < 0) wait = 0;
        }
        drain(wait);
        if (!g_qhead && g_alive && ms >= 0) {
            if (ms == 0) { if (bufsize > 0) buf[0] = 0; return 0; }
            struct timespec t1;
            clock_gettime(CLOCK_MONOTONIC, &t1);
            long el = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
            if (el >= ms) { if (bufsize > 0) buf[0] = 0; return 0; }
        }
    }
}
