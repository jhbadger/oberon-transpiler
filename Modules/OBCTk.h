#ifndef OBC_TK_H_
#define OBC_TK_H_

/* Tk — graphical user interfaces via Tcl/Tk (C implementation, FFI-bound).
 *
 * The binding drives a `wish` interpreter running as a child process,
 * talking to it over a pair of pipes.  Nothing is linked against Tcl/Tk,
 * so no headers or pkg-config are needed; only a `wish` executable
 * (Tk 8.5 or later) must be installed at run time.  Set the environment
 * variable OBC_WISH to pick a specific wish.
 *
 * Widgets are created and manipulated by sending ordinary Tcl/Tk commands.
 * User actions are reported back as events: the bootstrap defines a Tcl
 * command `ev` that queues its arguments for the Oberon program, e.g.
 *     button .b -text Go -command {ev go}
 * and the program retrieves the string "go" with Tk_Wait.
 *
 * Conventions (same as Net/Editor): input strings are NUL-terminated and
 * carry no hidden length; output buffers are preceded by an explicit int
 * bufsize.  Results are truncated (and always NUL-terminated) to fit.
 */

/* Start wish and the bridge.  1 = ok, 0 = failure (Tk_Result has the reason). */
int  Tk_Open(void);

/* 1 while the wish process is running, 0 once it has exited or was closed. */
int  Tk_Alive(void);

/* Shut down wish and release resources. */
void Tk_Close(void);

/* Evaluate a Tcl script.  Returns 0 on success, 1 on a Tcl error; the value
 * (or the error message) is stored for Tk_Result / Tk_ResultInt / Tk_ResultReal. */
int  Tk_Eval(char *script);

/* Copy the last result into buf; returns its full length (before truncation). */
int  Tk_Result(int bufsize, char *buf);
int  Tk_ResultInt(void);       /* last result as an integer (0 if not numeric)  */
double Tk_ResultReal(void);    /* last result as a real (0 if not numeric)      */

/* Build and evaluate "cmd arg1 ..." with every argument safely quoted. */
int  Tk_Call1(char *cmd, char *a1);
int  Tk_Call2(char *cmd, char *a1, char *a2);
int  Tk_Call3(char *cmd, char *a1, char *a2, char *a3);

/* Convenience: "widget configure -option value" and "set var value". */
int  Tk_Configure(char *widget, char *option, char *value);
int  Tk_Set(char *var, char *value);
int  Tk_Get(char *var, int bufsize, char *buf);   /* 1 = defined, 0 = no such variable */

/* The n-th (0-based) element of a Tcl list; returns its length, or 0 if absent.
 * Useful for picking apart events such as "click 10 20". */
int  Tk_Word(char *list, int n, int bufsize, char *buf);

/* Quote an arbitrary string so it can be pasted into a Tcl script as one word. */
int  Tk_Quote(char *s, int bufsize, char *buf);

/* Wait up to ms milliseconds (negative = forever, 0 = poll) for an event.
 * Returns 1 and fills buf when one arrives, 0 on timeout, -1 if wish exited. */
int  Tk_Wait(int ms, int bufsize, char *buf);

/* Number of events waiting to be read. */
int  Tk_Pending(void);

/* Discard all queued events. */
void Tk_Flush(void);

#endif /* OBC_TK_H_ */
