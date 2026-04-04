#include "codegen.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -----------------------------------------------------------------------
 * Emitter context
 * ----------------------------------------------------------------------- */
typedef struct {
    FILE *out;
    int   indent;
    char  modname[MAX_IDENT]; /* current module name (library mode) */
    int   is_main;            /* 1 = top-level program, 0 = library  */
    int   in_proc;            /* 1 when inside a procedure body      */
} CG;

static void emit(CG *g, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(g->out, fmt, ap); va_end(ap);
}
static void ind(CG *g)        { for (int i=0;i<g->indent;i++) fputs("    ",g->out); }
static void emit_expr(CG *g, Node *e);  /* forward */
/* Emit a C string literal with proper escaping of \, ", and control chars */
static void emit_string_lit(CG *g, const char *s);
/* Emit an expr node always as a char* string (not a char literal).
 * Used when a C function parameter is const char* but the Oberon arg
 * might be a 1-char string literal which emit_expr() would fold to 'x'. */
static void emit_as_string(CG *g, Node *e) {
    if (e && e->kind == ND_STRING) emit_string_lit(g, e->str);
    else if (e)                    emit_expr(g, e);
}
static void emit_string_lit(CG *g, const char *s) {
    fputc('"', g->out);
    for (; *s; s++) {
        if      (*s == '\\') fputs("\\\\", g->out);
        else if (*s == '"')  fputs("\\\"", g->out);
        else if (*s == '\n') fputs("\\n",  g->out);
        else if (*s == '\t') fputs("\\t",  g->out);
        else                 fputc(*s, g->out);
    }
    fputc('"', g->out);
}
static void iemit(CG *g, const char *fmt, ...) {
    ind(g); va_list ap; va_start(ap,fmt); vfprintf(g->out,fmt,ap); va_end(ap);
}

/* -----------------------------------------------------------------------
 * Symbol table — flat array with scope markers
 * ----------------------------------------------------------------------- */
#define MAX_SYMS 1024
typedef struct { char name[MAX_IDENT]; Node *type; int is_var; } Sym;
static Sym  g_syms[MAX_SYMS];
static int  g_nsyms = 0;
static int  g_marks[64];
static int  g_sdepth = 0;

static void sym_push(void) { g_marks[g_sdepth++] = g_nsyms; }
static void sym_pop(void)  { g_nsyms = g_marks[--g_sdepth]; }
static void sym_add(const char *name, Node *type, int is_var) {
    if (g_nsyms >= MAX_SYMS) return;
    strncpy(g_syms[g_nsyms].name, name, MAX_IDENT-1);
    g_syms[g_nsyms].type   = type;
    g_syms[g_nsyms].is_var = is_var;
    g_nsyms++;
}
static Node *sym_type(const char *name) {
    for (int i = g_nsyms-1; i >= 0; i--)
        if (strcmp(g_syms[i].name, name) == 0) return g_syms[i].type;
    return NULL;
}
static int sym_is_var(const char *name) {
    for (int i = g_nsyms-1; i >= 0; i--)
        if (strcmp(g_syms[i].name, name) == 0) return g_syms[i].is_var;
    return 0;
}

/* -----------------------------------------------------------------------
 * Procedure signature table — maps proc name → formal param list so that
 * call sites can decide whether to pass an argument by address (VAR param)
 * or by value.
 * ----------------------------------------------------------------------- */
#define MAX_PROCSIGS 256
typedef struct { char name[MAX_IDENT]; Node *params; } ProcSig;
static ProcSig g_procsigs[MAX_PROCSIGS];
static int g_nprocsigs = 0;

static void collect_proc_sigs(Node *decls) {
    for (Node *d = decls; d; d = d->next) {
        if (d->kind == ND_PROC_DECL && g_nprocsigs < MAX_PROCSIGS) {
            strncpy(g_procsigs[g_nprocsigs].name, d->str, MAX_IDENT-1);
            g_procsigs[g_nprocsigs].params = d->c0;
            g_nprocsigs++;
        }
    }
}
static Node *lookup_proc_params(const char *name) {
    for (int i = 0; i < g_nprocsigs; i++)
        if (!strcmp(g_procsigs[i].name, name)) return g_procsigs[i].params;
    return NULL;
}

/* Cross-module proc signatures — indexed by "RealModule.ProcName".
 * Accumulated across all codegen() calls (never reset) so that when
 * compiling the main module we can look up VAR-param info for imported procs. */
#define MAX_XMOD_PROCSIGS 512
typedef struct { char key[MAX_IDENT*2]; Node *params; } XModProcSig;
static XModProcSig g_xmod_procsigs[MAX_XMOD_PROCSIGS];
static int g_n_xmod_procsigs = 0;

static void collect_xmod_proc_sigs(Node *decls, const char *modname) {
    for (Node *d = decls; d; d = d->next) {
        if (d->kind == ND_PROC_DECL && g_n_xmod_procsigs < MAX_XMOD_PROCSIGS) {
            snprintf(g_xmod_procsigs[g_n_xmod_procsigs].key, MAX_IDENT*2,
                     "%s.%s", modname, d->str);
            g_xmod_procsigs[g_n_xmod_procsigs].params = d->c0;
            g_n_xmod_procsigs++;
        }
    }
}
static Node *lookup_xmod_proc_params(const char *modname, const char *procname) {
    char key[MAX_IDENT*2];
    snprintf(key, sizeof(key), "%s.%s", modname, procname);
    for (int i = 0; i < g_n_xmod_procsigs; i++)
        if (!strcmp(g_xmod_procsigs[i].key, key)) return g_xmod_procsigs[i].params;
    return NULL;
}

/* -----------------------------------------------------------------------
 * Known imports (module aliases)
 * ----------------------------------------------------------------------- */
static char g_imports[32][MAX_IDENT];      /* alias (or module name) */
static char g_import_real[32][MAX_IDENT];  /* real module name       */
static int  g_nimports = 0;

static int  is_import(const char *s) {
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],s)) return 1;
    return 0;
}
/* Resolve an import alias to its real module name. */
static const char *import_realname(const char *alias) {
    for (int i=0;i<g_nimports;i++)
        if (!strcmp(g_imports[i],alias)) return g_import_real[i];
    return alias;
}

/* -----------------------------------------------------------------------
 * Built-in module list
 * ----------------------------------------------------------------------- */
static const char *g_builtins[] = {
    "Out","In","Random","Terminal","Graphics","Math","Strings","Files",NULL
};
static int is_builtin_module(const char *s) {
    for (int i=0;g_builtins[i];i++) if (!strcmp(g_builtins[i],s)) return 1;
    return 0;
}

/* -----------------------------------------------------------------------
 * Module-level exported symbol names — used to emit #define aliases so
 * that proc bodies can call exported symbols by their original names.
 * Only exported (public) symbols need aliases; private ones keep their
 * original name and are marked static, so no aliasing is required.
 * ----------------------------------------------------------------------- */
#define MAX_MODSYMS 256
static char g_modsyms[MAX_MODSYMS][MAX_IDENT];
static int  g_nmodsyms = 0;

static void collect_modsyms(Node *decls) {
    g_nmodsyms = 0;
    for (Node *d=decls; d; d=d->next) {
        const char *name = NULL;
        int exported = 0;
        if ((d->kind==ND_CONST_DECL || d->kind==ND_TYPE_DECL) &&
            (d->flags & FLAG_EXPORTED)) {
            name = d->str; exported = 1;
        } else if (d->kind==ND_VAR_DECL) {
            /* Each ident in the list may be individually exported */
            for (Node *id=d->c0; id; id=id->next) {
                if ((id->flags & FLAG_EXPORTED) && g_nmodsyms < MAX_MODSYMS)
                    strncpy(g_modsyms[g_nmodsyms++], id->str, MAX_IDENT-1);
            }
            continue;
        } else if (d->kind==ND_PROC_DECL && (d->flags & FLAG_EXPORTED)) {
            name = d->str; exported = 1;
        }
        if (exported && name && g_nmodsyms < MAX_MODSYMS)
            strncpy(g_modsyms[g_nmodsyms++], name, MAX_IDENT-1);
    }
}

/* -----------------------------------------------------------------------
 * Type helpers
 * ----------------------------------------------------------------------- */

/* Map Oberon built-in type name → C type */
static const char *ctype(const char *name) {
    if (!strcmp(name,"INTEGER"))      return "int";
    if (!strcmp(name,"LONGINT"))      return "long";
    if (!strcmp(name,"SHORTINT"))     return "short";
    if (!strcmp(name,"REAL"))         return "double";
    if (!strcmp(name,"LONGREAL"))     return "double";
    if (!strcmp(name,"CHAR"))         return "char";
    if (!strcmp(name,"BOOLEAN"))      return "int";
    if (!strcmp(name,"BYTE"))         return "unsigned char";
    if (!strcmp(name,"SET"))          return "unsigned int";
    if (!strcmp(name,"Files.File"))   return "Files_File";
    if (!strcmp(name,"Files.Rider"))  return "Files_Rider";
    /* General qualified name: Alias.Type → RealModule_Type */
    {
        const char *dot = strchr(name, '.');
        if (dot) {
            static char buf[MAX_IDENT*2];
            int modlen = (int)(dot - name);
            if (modlen >= MAX_IDENT) modlen = MAX_IDENT - 1;
            char alias[MAX_IDENT];
            strncpy(alias, name, modlen); alias[modlen] = '\0';
            snprintf(buf, sizeof(buf), "%s_%s", import_realname(alias), dot + 1);
            return buf;
        }
    }
    return name; /* user-defined */
}

/* Is this type node a char array ("string" in Oberon)? */
static int is_char_array(Node *t) {
    if (!t) return 0;
    if (t->kind == ND_TNAME && !strcmp(t->str, "STRING")) return 1;
    if (t->kind != ND_TARRAY) return 0;  /* plain CHAR is not a char array */
    Node *e = t;
    while (e && e->kind == ND_TARRAY) e = e->c1;
    return e && e->kind == ND_TNAME && !strcmp(e->str, "CHAR");
}

/* Best-effort type of an expression (for WRITE/assign decisions) */
static Node *expr_type(Node *e) {
    if (!e) return NULL;
    if (e->kind == ND_IDENT)        return sym_type(e->str);
    if (e->kind == ND_FIELD_ACCESS) return NULL; /* TODO: record field types */
    if (e->kind == ND_INDEX)        return NULL;
    if (e->kind == ND_CALL)         return NULL; /* TODO: proc return type */
    if (e->kind == ND_INTEGER)      { static Node t={ND_TNAME}; strcpy(t.str,"INTEGER"); return &t; }
    if (e->kind == ND_REAL)         { static Node t={ND_TNAME}; strcpy(t.str,"REAL");    return &t; }
    if (e->kind == ND_CHAR)         { static Node t={ND_TNAME}; strcpy(t.str,"CHAR");    return &t; }
    if (e->kind == ND_TRUE || e->kind == ND_FALSE) {
        static Node t={ND_TNAME}; strcpy(t.str,"BOOLEAN"); return &t;
    }
    if (e->kind == ND_STRING) {
        static Node arr={ND_TARRAY}, ch={ND_TNAME};
        strcpy(ch.str,"CHAR"); arr.c0=NULL; arr.c1=&ch;
        return &arr;
    }
    return NULL;
}

/* -----------------------------------------------------------------------
 * Forward declarations
 * ----------------------------------------------------------------------- */
static void emit_expr(CG *g, Node *e);
static void emit_stmt(CG *g, Node *s);
static void emit_type_prefix(CG *g, Node *t);
static void emit_type_dims(CG *g, Node *t);

/* -----------------------------------------------------------------------
 * Type emission
 * ----------------------------------------------------------------------- */

/* Emit the C "base" type (ignoring array dimensions).
 * e.g. ARRAY 10 OF INTEGER → "int"                                   */
static void emit_type_prefix(CG *g, Node *t) {
    if (!t) { emit(g,"void"); return; }
    switch (t->kind) {
    case ND_TNAME:
        if (!strcmp(t->str,"STRING")) emit(g,"char"); /* +[256] via dims */
        else emit(g,"%s", ctype(t->str));
        break;
    case ND_TARRAY: {
        Node *e = t; while (e && e->kind==ND_TARRAY) e=e->c1;
        emit_type_prefix(g,e); break;
    }
    case ND_TRECORD: emit(g,"struct %s_s", t->str[0]?t->str:"_anon"); break;
    case ND_TPOINTER: emit_type_prefix(g,t->c0); emit(g,"*"); break;
    default: emit(g,"void*");
    }
}

/* Emit array brackets after a variable name: "[10][64]..." */
static void emit_type_dims(CG *g, Node *t) {
    if (!t) return;
    if (t->kind == ND_TNAME && !strcmp(t->str,"STRING")) { emit(g,"[256]"); return; }
    if (t->kind != ND_TARRAY) return;
    emit(g,"["); if (t->c0) emit_expr(g,t->c0); emit(g,"]");
    emit_type_dims(g,t->c1);
}

/* Emit "type name[dims]", handling VAR params (pointer) and open arrays.
 * This is the single place where Oberon types map to C declarations.  */
static void emit_var_decl_raw(CG *g, const char *name, Node *t, int is_var) {
    /* VAR parameter → always pointer */
    if (is_var) {
        if (t && t->kind==ND_TARRAY) {
            emit_type_prefix(g,t); emit(g," *%s",name);
        } else {
            emit_type_prefix(g,t); emit(g," *%s",name);
        }
        return;
    }
    /* Open array (no length expr) → pointer in C */
    if (t && t->kind==ND_TARRAY && !t->c0) {
        Node *e=t; while(e&&e->kind==ND_TARRAY) e=e->c1;
        emit_type_prefix(g,e); emit(g," *%s",name);
        return;
    }
    emit_type_prefix(g,t);
    emit(g," %s",name);
    emit_type_dims(g,t);
}

/* -----------------------------------------------------------------------
 * Expression emission
 * ----------------------------------------------------------------------- */

static int is_builtin(const char *n) {
    return !strcasecmp(n,"INC")||!strcasecmp(n,"DEC")||!strcasecmp(n,"NEW")||
           !strcasecmp(n,"HALT")||!strcasecmp(n,"ASSERT")||!strcasecmp(n,"ABS")||
           !strcasecmp(n,"ODD")||!strcasecmp(n,"ORD")||!strcasecmp(n,"CHR")||
           !strcasecmp(n,"LEN")||!strcasecmp(n,"WRITE")||!strcasecmp(n,"READ")||
           !strcasecmp(n,"WRITELN")||!strcasecmp(n,"COPY");
}

/* Emit a WRITE(arg) call based on the argument's type.
 * String literals get NO added newline (matching old-transpiler behaviour). */
static void emit_write(CG *g, Node *arg, int newline) {
    if (!arg) { if (newline) emit(g,"putchar('\\n')"); return; }

    /* String literal — no added newline */
    if (arg->kind == ND_STRING) {
        emit(g,"fputs(\"%s\", stdout)", arg->str);
        return;
    }

    Node *t = expr_type(arg);

    /* Char array / STRING type → %s */
    if (t && is_char_array(t)) {
        emit(g,"printf(\"%%s%s\",", newline?"\\n":"");
        emit_expr(g,arg); emit(g,")"); return;
    }

    /* Scalar types */
    const char *fmt = newline ? "%d\\n" : "%d";
    if (t && t->kind == ND_TNAME) {
        const char *tn = t->str;
        if (!strcmp(tn,"REAL")||!strcmp(tn,"LONGREAL")) fmt = newline ? "%g\\n" : "%g";
        else if (!strcmp(tn,"CHAR"))                    fmt = newline ? "%c\\n" : "%c";
    }
    emit(g,"printf(\"%s\",",fmt); emit_expr(g,arg); emit(g,")");
}

/* Emit a READ(arg) call based on the argument's type */
static void emit_read(CG *g, Node *arg) {
    if (!arg) return;
    Node *t = expr_type(arg);
    if (t && t->kind==ND_TNAME) {
        if (!strcmp(t->str,"REAL")||!strcmp(t->str,"LONGREAL")) {
            emit(g,"scanf(\"%%lf\",&"); emit_expr(g,arg); emit(g,")"); return;
        }
        if (!strcmp(t->str,"CHAR")) {
            emit(g,"("); emit_expr(g,arg); emit(g," = (char)getchar())"); return;
        }
        if (is_char_array(t)) {
            emit(g,"scanf(\"%%s\","); emit_expr(g,arg); emit(g,")"); return;
        }
    }
    if (t && is_char_array(t)) {
        emit(g,"scanf(\"%%s\","); emit_expr(g,arg); emit(g,")"); return;
    }
    emit(g,"scanf(\"%%d\",&"); emit_expr(g,arg); emit(g,")");
}

/* Emit a built-in procedure call as an expression */
static void emit_builtin(CG *g, const char *name, Node *args) {
    Node *a0=args, *a1=a0?a0->next:NULL;
    if (!strcasecmp(name,"INC")) {
        if (a1) { emit_expr(g,a0); emit(g," += "); emit_expr(g,a1); }
        else    { emit_expr(g,a0); emit(g,"++"); }
    } else if (!strcasecmp(name,"DEC")) {
        if (a1) { emit_expr(g,a0); emit(g," -= "); emit_expr(g,a1); }
        else    { emit_expr(g,a0); emit(g,"--"); }
    } else if (!strcasecmp(name,"NEW")) {
        emit_expr(g,a0); emit(g," = malloc(sizeof(*"); emit_expr(g,a0); emit(g,"))");
    } else if (!strcasecmp(name,"HALT")) {
        emit(g,"exit("); if(a0) emit_expr(g,a0); else emit(g,"0"); emit(g,")");
    } else if (!strcasecmp(name,"ASSERT")) {
        emit(g,"assert("); if(a0) emit_expr(g,a0); emit(g,")");
    } else if (!strcasecmp(name,"ABS")) {
        emit(g,"abs("); if(a0) emit_expr(g,a0); emit(g,")");
    } else if (!strcasecmp(name,"ODD")) {
        emit(g,"(("); if(a0) emit_expr(g,a0); emit(g,") & 1)");
    } else if (!strcasecmp(name,"ORD")) {
        emit(g,"((int)("); if(a0) emit_expr(g,a0); emit(g,"))");
    } else if (!strcasecmp(name,"CHR")) {
        emit(g,"((char)("); if(a0) emit_expr(g,a0); emit(g,"))");
    } else if (!strcasecmp(name,"LEN")) {
        /* For fixed arrays we emit the count; for pointers it's unknown */
        emit(g,"(int)(sizeof("); if(a0) emit_expr(g,a0);
        emit(g,")/sizeof("); if(a0) emit_expr(g,a0); emit(g,"[0]))");
    } else if (!strcasecmp(name,"WRITE")) {
        emit_write(g, a0, 1);
    } else if (!strcasecmp(name,"WRITELN")) {
        if (a0) emit_write(g, a0, 1);
        else    emit(g,"putchar('\\n')");
    } else if (!strcasecmp(name,"READ")) {
        emit_read(g, a0);
    } else if (!strcasecmp(name,"COPY")) {
        /* COPY(src, dst) → strcpy(dst, src) */
        emit(g,"strcpy("); if(a1) emit_expr(g,a1); emit(g,", ");
        if(a0) emit_expr(g,a0); emit(g,")");
    } else {
        /* Unknown builtin — emit as-is */
        emit(g,"%s(",name);
        for (Node *a=args;a;a=a->next) { if(a!=args) emit(g,","); emit_expr(g,a); }
        emit(g,")");
    }
}

/* Emit the address of an expression — used when a C function needs a pointer
 * to an Oberon VAR parameter.  If the node is an IDENT that is already a
 * VAR param (i.e. already a pointer in C), emit it bare; otherwise add &. */
static void emit_addr_of(CG *g, Node *e) {
    if (!e) { emit(g,"NULL"); return; }
    if (e->kind == ND_IDENT) {
        if (sym_is_var(e->str)) { emit(g,"%s",e->str); return; }
        emit(g,"&%s",e->str); return;
    }
    emit(g,"&("); emit_expr(g,e); emit(g,")");
}

/* Map import module calls:  Out.String(s) → fputs(s,stdout), etc. */
static int try_emit_import(CG *g, Node *fa, Node *args) {
    if (!fa || fa->kind!=ND_FIELD_ACCESS) return 0;
    if (!fa->c0 || fa->c0->kind!=ND_IDENT) return 0;
    if (!is_import(fa->c0->str)) return 0;
    const char *mod  = fa->c0->str;
    const char *proc = fa->str;
    Node *a0=args, *a1=a0?a0->next:NULL;
    /* Out module */
    if (!strcmp(mod,"Out")) {
        if (!strcmp(proc,"String")) {
            /* Single-char string literals must stay as strings for fputs.
             * emit_expr() would turn them into char literals ('x'), which
             * is wrong here — always force the double-quoted form. */
            emit(g,"fputs(");
            if (a0 && a0->kind == ND_STRING)
                emit_string_lit(g, a0->str);
            else
                emit_expr(g,a0);
            emit(g,",stdout)");
            return 1;
        }
        if (!strcmp(proc,"Ln"))      { emit(g,"putchar('\\n')"); return 1; }
        if (!strcmp(proc,"Int"))     {
            if (a1) { emit(g,"printf(\"%%*d\",(int)("); emit_expr(g,a1); emit(g,"),(int)("); emit_expr(g,a0); emit(g,"))"); }
            else    { emit(g,"printf(\"%%d\",(int)(");  emit_expr(g,a0); emit(g,"))"); }
            return 1; }
        if (!strcmp(proc,"Real"))    { emit(g,"printf(\"%%g\","); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Char"))    { emit(g,"putchar("); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Fixed"))   { emit(g,"printf(\"%%-*.*f\",");
                                        if(a1) emit_expr(g,a1); emit(g,",");
                                        if(a1&&a1->next) emit_expr(g,a1->next);
                                        emit(g,","); emit_expr(g,a0); emit(g,")"); return 1; }
    }
    /* In module */
    if (!strcmp(mod,"In")) {
        if (!strcmp(proc,"Read")) {
            /* In.Read(ch) for a CHAR — assign from getchar */
            emit(g,"("); emit_expr(g,a0); emit(g," = (char)getchar())"); return 1;
        }
        if (!strcmp(proc,"Int"))  { emit(g,"scanf(\"%%d\",&"); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Real")) { emit(g,"scanf(\"%%lf\",&"); emit_expr(g,a0); emit(g,")"); return 1; }
    }
    /* Random module */
    if (!strcmp(mod,"Random")) {
        if (!strcmp(proc,"Int")) {
            /* Random.Int(n) -> random integer in [0, n) */
            emit(g,"(int)(rand()%%(unsigned)("); emit_expr(g,a0); emit(g,"))");
            return 1;
        }
        if (!strcmp(proc,"Real")) {
            /* Random.Real() -> random double in [0.0, 1.0) */
            emit(g,"((double)rand()/(double)RAND_MAX)");
            return 1;
        }
    }
    /* Math module */
    if (!strcmp(mod,"Math")) {
        /* one-argument functions */
        if (!strcmp(proc,"sqrt"))   { emit(g,"sqrt(");  emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"exp"))    { emit(g,"exp(");   emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"ln"))     { emit(g,"log(");   emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"log"))    { emit(g,"log10("); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"sin"))    { emit(g,"sin(");   emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"cos"))    { emit(g,"cos(");   emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"tan"))    { emit(g,"tan(");   emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"arcsin")) { emit(g,"asin(");  emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"arccos")) { emit(g,"acos(");  emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"arctan")) { emit(g,"atan(");  emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"floor"))  { emit(g,"floor("); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"ceil"))   { emit(g,"ceil(");  emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"round"))  { emit(g,"round("); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"entier")) { emit(g,"(int)floor("); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"abs"))    { emit(g,"fabs(");  emit_expr(g,a0); emit(g,")"); return 1; }
        /* two-argument functions */
        if (!strcmp(proc,"arctan2")) { emit(g,"atan2("); emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"power"))   { emit(g,"pow(");   emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
    }
    /* Strings module */
    if (!strcmp(mod,"Strings")) {
        Node *a2=a1?a1->next:NULL;
        if (!strcmp(proc,"Length"))  { emit(g,"Strings_Length(");  emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Append"))  { emit(g,"Strings_Append(");  emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Copy"))    { emit(g,"Strings_Copy(");    emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Compare")) { emit(g,"Strings_Compare("); emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Pos"))     { emit(g,"Strings_Pos(");     emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        (void)a2;
    }
    /* Files module — standard Oberon Files API */
    if (!strcmp(mod,"Files")) {
        Node *a2 = a1 ? a1->next : NULL;
        /* File operations */
        if (!strcmp(proc,"Old"))         { emit(g,"Files_Old(");         emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"New"))         { emit(g,"Files_New(");         emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Register"))    { emit(g,"Files_Register(");    emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Close"))       { emit(g,"Files_Close(");       emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Length"))      { emit(g,"Files_Length(");      emit_expr(g,a0); emit(g,")"); return 1; }
        /* Rider operations: Set(VAR r, f, pos)  Pos(VAR r)  Base(VAR r) */
        if (!strcmp(proc,"Set"))         { emit(g,"Files_Set(");  emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"Pos"))         { emit(g,"Files_Pos(");  emit_addr_of(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Base"))        { emit(g,"Files_Base("); emit_addr_of(g,a0); emit(g,")"); return 1; }
        /* Read procedures — VAR r, VAR x  (string: VAR r, x array) */
        if (!strcmp(proc,"Read"))        { emit(g,"Files_Read(");        emit_addr_of(g,a0); emit(g,",(unsigned char*)("); emit_addr_of(g,a1); emit(g,"))"); return 1; }
        if (!strcmp(proc,"ReadInt"))     { emit(g,"Files_ReadInt(");     emit_addr_of(g,a0); emit(g,","); emit_addr_of(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"ReadBool"))    { emit(g,"Files_ReadBool(");    emit_addr_of(g,a0); emit(g,","); emit_addr_of(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"ReadReal"))    { emit(g,"Files_ReadReal(");    emit_addr_of(g,a0); emit(g,","); emit_addr_of(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"ReadString"))  { emit(g,"Files_ReadString(");  emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"ReadNum"))     { emit(g,"Files_ReadNum(");     emit_addr_of(g,a0); emit(g,","); emit_addr_of(g,a1); emit(g,")"); return 1; }
        /* Write procedures — VAR r, x by value  (string: const char*) */
        if (!strcmp(proc,"Write"))       { emit(g,"Files_Write(");       emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteInt"))    { emit(g,"Files_WriteInt(");    emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteBool"))   { emit(g,"Files_WriteBool(");   emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteReal"))   { emit(g,"Files_WriteReal(");   emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteString")) { emit(g,"Files_WriteString("); emit_addr_of(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteNum"))    { emit(g,"Files_WriteNum(");    emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
    }
    /* Unknown import call → RealModule_Proc(args)  (resolves aliases) */
    const char *real = import_realname(mod);
    emit(g,"%s_%s(",real,proc);
    {
        Node *params = lookup_xmod_proc_params(real, proc);
        Node *fp    = params;
        Node *fp_id = fp ? fp->c0 : NULL;
        for (Node *a=args;a;a=a->next) {
            if (a!=args) emit(g,",");
            int is_var = fp ? (fp->flags & FLAG_VAR_PARAM) != 0 : 0;
            if (is_var) emit_addr_of(g, a);
            else        emit_expr(g, a);
            if (fp) {
                fp_id = fp_id ? fp_id->next : NULL;
                if (!fp_id) { fp = fp->next; fp_id = fp ? fp->c0 : NULL; }
            }
        }
    }
    emit(g,")");
    return 1;
}

static void emit_expr(CG *g, Node *e) {
    if (!e) return;
    switch (e->kind) {
    case ND_INTEGER: emit(g,"%ld",e->ival); break;
    case ND_REAL:    emit(g,"%s",e->str);   break;
    case ND_STRING:
        /* Single-character string literals act as CHAR in Oberon */
        if (strlen(e->str)==1) {
            char c=e->str[0];
            if      (c=='\'') emit(g,"'\\''");
            else if (c=='\\') emit(g,"'\\\\'");
            else              emit(g,"'%c'",c);
        } else {
            emit_string_lit(g, e->str);
        }
        break;
    case ND_CHAR:
        if      (e->ival==0)  emit(g,"'\\0'");
        else if (e->ival==10) emit(g,"'\\n'");
        else if (e->ival==13) emit(g,"'\\r'");
        else if (e->ival==9)  emit(g,"'\\t'");
        else if (e->ival>=32 && e->ival<127) emit(g,"'%c'",(char)e->ival);
        else emit(g,"'\\x%02X'",(unsigned)e->ival);
        break;
    case ND_NIL:   emit(g,"NULL");  break;
    case ND_TRUE:  emit(g,"1");     break;
    case ND_FALSE: emit(g,"0");     break;
    case ND_IDENT: {
        /* VAR parameters are pointers.  Array-type VAR params are already
         * passed as a pointer in C (char*, int*, etc.) so no extra deref. */
        int is_var = sym_is_var(e->str);
        Node *vt   = is_var ? sym_type(e->str) : NULL;
        int arr_var = is_var && vt && (vt->kind==ND_TARRAY ||
                      (vt->kind==ND_TNAME && !strcmp(vt->str,"STRING")));
        if (is_var && !arr_var) emit(g,"(*%s)",e->str);
        else                    emit(g,"%s",e->str);
        break;
    }
    case ND_NEG:  emit(g,"(-("); emit_expr(g,e->c0); emit(g,"))"); break;
    case ND_NOT:  emit(g,"(!(");  emit_expr(g,e->c0); emit(g,"))"); break;
    case ND_ADD: emit(g,"("); emit_expr(g,e->c0); emit(g,"+");  emit_expr(g,e->c1); emit(g,")"); break;
    case ND_SUB: emit(g,"("); emit_expr(g,e->c0); emit(g,"-");  emit_expr(g,e->c1); emit(g,")"); break;
    case ND_MUL: emit(g,"("); emit_expr(g,e->c0); emit(g,"*");  emit_expr(g,e->c1); emit(g,")"); break;
    case ND_DIVF:emit(g,"("); emit_expr(g,e->c0); emit(g,"/");  emit_expr(g,e->c1); emit(g,")"); break;
    case ND_DIVI:emit(g,"("); emit_expr(g,e->c0); emit(g,"/");  emit_expr(g,e->c1); emit(g,")"); break;
    case ND_MOD: emit(g,"("); emit_expr(g,e->c0); emit(g,"%%"); emit_expr(g,e->c1); emit(g,")"); break;
    case ND_AND: emit(g,"("); emit_expr(g,e->c0); emit(g,"&&"); emit_expr(g,e->c1); emit(g,")"); break;
    case ND_OR:  emit(g,"("); emit_expr(g,e->c0); emit(g,"||"); emit_expr(g,e->c1); emit(g,")"); break;
    case ND_EQ: {
        /* Multi-char ARRAY OF CHAR comparison → strcmp(...)==0 */
        Node *lt = expr_type(e->c0);
        int lhs_str = (e->c0->kind==ND_STRING && strlen(e->c0->str)>1);
        int rhs_str = (e->c1->kind==ND_STRING && strlen(e->c1->str)>1);
        if (is_char_array(lt) || lhs_str || rhs_str) {
            emit(g,"(strcmp("); emit_expr(g,e->c0); emit(g,","); emit_expr(g,e->c1); emit(g,")==0)");
        } else {
            emit(g,"("); emit_expr(g,e->c0); emit(g,"=="); emit_expr(g,e->c1); emit(g,")");
        }
        break;
    }
    case ND_NEQ: {
        Node *lt = expr_type(e->c0);
        int lhs_str = (e->c0->kind==ND_STRING && strlen(e->c0->str)>1);
        int rhs_str = (e->c1->kind==ND_STRING && strlen(e->c1->str)>1);
        if (is_char_array(lt) || lhs_str || rhs_str) {
            emit(g,"(strcmp("); emit_expr(g,e->c0); emit(g,","); emit_expr(g,e->c1); emit(g,")!=0)");
        } else {
            emit(g,"("); emit_expr(g,e->c0); emit(g,"!="); emit_expr(g,e->c1); emit(g,")");
        }
        break;
    }
    case ND_LT: emit(g,"("); emit_expr(g,e->c0); emit(g,"<");  emit_expr(g,e->c1); emit(g,")"); break;
    case ND_LE: emit(g,"("); emit_expr(g,e->c0); emit(g,"<="); emit_expr(g,e->c1); emit(g,")"); break;
    case ND_GT: emit(g,"("); emit_expr(g,e->c0); emit(g,">");  emit_expr(g,e->c1); emit(g,")"); break;
    case ND_GE: emit(g,"("); emit_expr(g,e->c0); emit(g,">="); emit_expr(g,e->c1); emit(g,")"); break;
    case ND_IN:
        /* x IN set — check bit x in set */
        emit(g,"(("); emit_expr(g,e->c1); emit(g,">>"); emit_expr(g,e->c0); emit(g,")&1)");
        break;
    case ND_DEREF: emit(g,"(*"); emit_expr(g,e->c0); emit(g,")"); break;
    case ND_INDEX:
        emit_expr(g,e->c0); emit(g,"["); emit_expr(g,e->c1); emit(g,"]");
        break;
    case ND_FIELD_ACCESS:
        /* Module constants / variables (e.g. Math.pi, Utils.count) */
        if (e->c0 && e->c0->kind==ND_IDENT && is_import(e->c0->str)) {
            const char *real = import_realname(e->c0->str);
            if (!strcmp(real,"Math")) {
                if (!strcmp(e->str,"pi")) { emit(g,"M_PI"); break; }
                if (!strcmp(e->str,"e"))  { emit(g,"M_E");  break; }
            }
            /* User module variable/constant: alias.Name → RealMod_Name */
            if (!is_builtin_module(real)) {
                emit(g,"%s_%s", real, e->str);
                break;
            }
        }
        /* If base is pointer: use ->, else use . */
        emit_expr(g,e->c0);
        {
            Node *bt = expr_type(e->c0);
            if (bt && bt->kind==ND_TPOINTER) emit(g,"->%s",e->str);
            else emit(g,".%s",e->str);
        }
        break;
    case ND_CALL: {
        /* Check for import call */
        if (try_emit_import(g, e->c0, e->c1)) break;
        /* Check for builtin */
        if (e->c0 && e->c0->kind==ND_IDENT && is_builtin(e->c0->str)) {
            emit_builtin(g, e->c0->str, e->c1); break;
        }
        /* Normal call */
        emit_expr(g,e->c0); emit(g,"(");
        /* Use the proc signature table to know which args are VAR params
         * so we can pass the pointer directly instead of dereferencing. */
        Node *params = NULL;
        if (e->c0 && e->c0->kind == ND_IDENT)
            params = lookup_proc_params(e->c0->str);
        Node *fp    = params;
        Node *fp_id = fp ? fp->c0 : NULL;
        for (Node *a=e->c1;a;a=a->next) {
            if (a!=e->c1) emit(g,",");
            int is_var = fp ? (fp->flags & FLAG_VAR_PARAM) != 0 : 0;
            if (is_var) emit_addr_of(g, a);
            else        emit_expr(g, a);
            /* advance to next formal parameter */
            if (fp) {
                fp_id = fp_id ? fp_id->next : NULL;
                if (!fp_id) { fp = fp->next; fp_id = fp ? fp->c0 : NULL; }
            }
        }
        emit(g,")");
        break;
    }
    case ND_SET: {
        /* Build a SET value as a bitmask */
        emit(g,"(0");
        for (Node *el=e->c0;el;el=el->next) {
            if (el->kind==ND_RANGE) {
                /* Set a range of bits — simplified: just OR in lo..hi */
                /* In C: for(i=lo;i<=hi;i++) mask |= 1<<i — not easy inline */
                /* Emit a helper expression: _obc_range(lo,hi) */
                emit(g,"|_obc_range("); emit_expr(g,el->c0);
                emit(g,","); emit_expr(g,el->c1); emit(g,")");
            } else {
                emit(g,"|(1u<<("); emit_expr(g,el); emit(g,"))");
            }
        }
        emit(g,")");
        break;
    }
    default:
        emit(g,"/*?%s*/0", node_kind_name(e->kind));
    }
}

/* -----------------------------------------------------------------------
 * Statement emission
 * ----------------------------------------------------------------------- */

static void emit_stmt(CG *g, Node *s) {
    if (!s) return;
    switch (s->kind) {

    case ND_ASSIGN: {
        Node *lhs = s->c0, *rhs = s->c1;
        /* Determine if LHS is a char array type → use strcpy */
        Node *lt = NULL;
        if (lhs->kind==ND_IDENT)  lt = sym_type(lhs->str);
        /* Single-char string literals are char values; only multi-char strings
         * need strcpy. A single-char RHS ("X") is emitted as 'X' by emit_expr. */
        int rhs_is_multichar_str = (rhs->kind == ND_STRING && strlen(rhs->str) > 1);
        int is_str = is_char_array(lt) ||
                     (lt == NULL && rhs_is_multichar_str);
        if (is_str) {
            iemit(g,"strcpy("); emit_expr(g,lhs); emit(g,",");
            /* Always emit RHS as string literal for strcpy */
            if (rhs->kind == ND_STRING) emit_string_lit(g, rhs->str);
            else emit_expr(g,rhs);
            emit(g,");\n");
        } else {
            iemit(g,""); emit_expr(g,lhs);
            emit(g," = "); emit_expr(g,rhs); emit(g,";\n");
        }
        break;
    }

    case ND_CALL: {
        /* Check for import procedure call */
        if (s->c0 && try_emit_import(g, s->c0, s->c1)) { emit(g,";\n"); break; }
        /* Built-in procedure call */
        if (s->c0 && s->c0->kind==ND_IDENT && is_builtin(s->c0->str)) {
            iemit(g,""); emit_builtin(g, s->c0->str, s->c1); emit(g,";\n"); break;
        }
        /* Regular procedure call */
        iemit(g,""); emit_expr(g,s->c0); emit(g,"(");
        {
            Node *params = NULL;
            if (s->c0 && s->c0->kind == ND_IDENT)
                params = lookup_proc_params(s->c0->str);
            Node *fp    = params;
            Node *fp_id = fp ? fp->c0 : NULL;
            for (Node *a=s->c1;a;a=a->next) {
                if (a!=s->c1) emit(g,",");
                int is_var = fp ? (fp->flags & FLAG_VAR_PARAM) != 0 : 0;
                if (is_var) emit_addr_of(g, a);
                else        emit_expr(g, a);
                if (fp) {
                    fp_id = fp_id ? fp_id->next : NULL;
                    if (!fp_id) { fp = fp->next; fp_id = fp ? fp->c0 : NULL; }
                }
            }
        }
        emit(g,");\n");
        break;
    }

    case ND_IF: {
        iemit(g,"if ("); emit_expr(g,s->c0); emit(g,") {\n");
        g->indent++;
        for (Node *st=s->c1;st;st=st->next) emit_stmt(g,st);
        g->indent--;
        /* ELSIF chain */
        for (Node *ei=s->c2;ei;ei=ei->next) {
            iemit(g,"} else if ("); emit_expr(g,ei->c0); emit(g,") {\n");
            g->indent++;
            for (Node *st=ei->c1;st;st=st->next) emit_stmt(g,st);
            g->indent--;
        }
        /* ELSE */
        if (s->c3) {
            iemit(g,"} else {\n");
            g->indent++;
            for (Node *st=s->c3;st;st=st->next) emit_stmt(g,st);
            g->indent--;
        }
        iemit(g,"}\n");
        break;
    }

    case ND_WHILE: {
        iemit(g,"while ("); emit_expr(g,s->c0); emit(g,") {\n");
        g->indent++;
        for (Node *st=s->c1;st;st=st->next) emit_stmt(g,st);
        g->indent--;
        iemit(g,"}\n");
        break;
    }

    case ND_REPEAT: {
        iemit(g,"do {\n");
        g->indent++;
        for (Node *st=s->c0;st;st=st->next) emit_stmt(g,st);
        g->indent--;
        iemit(g,"} while (!("); emit_expr(g,s->c1); emit(g,"));\n");
        break;
    }

    case ND_FOR: {
        /* FOR var := from TO to [BY step] DO stmts END */
        Node *t = sym_type(s->str);
        const char *ct = t ? ctype(t->kind==ND_TNAME?t->str:"INTEGER") : "int";
        iemit(g,"for (%s %s = ", ct, s->str);
        emit_expr(g,s->c0);
        if (s->c2) {
            /* step may be negative — use runtime ternary for correct comparison */
            emit(g,"; ("); emit_expr(g,s->c2); emit(g,")>0 ? %s<=",s->str);
            emit_expr(g,s->c1); emit(g," : %s>=",s->str); emit_expr(g,s->c1);
            emit(g,"; %s += ",s->str); emit_expr(g,s->c2);
        } else {
            emit(g,"; %s <= ",s->str); emit_expr(g,s->c1);
            emit(g,"; %s++",s->str);
        }
        emit(g,") {\n");
        g->indent++;
        for (Node *st=s->c3;st;st=st->next) emit_stmt(g,st);
        g->indent--;
        iemit(g,"}\n");
        break;
    }

    case ND_LOOP:
        iemit(g,"for(;;) {\n");
        g->indent++;
        for (Node *st=s->c0;st;st=st->next) emit_stmt(g,st);
        g->indent--;
        iemit(g,"}\n");
        break;

    case ND_EXIT:
        iemit(g,"break;\n");
        break;

    case ND_RETURN:
        if (s->c0) { iemit(g,"return "); emit_expr(g,s->c0); emit(g,";\n"); }
        else if (g->is_main && !g->in_proc) iemit(g,"return 0;\n");
        else        iemit(g,"return;\n");
        break;

    case ND_CASE: {
        /* Emit as if/else if chain (switch can't handle string/range cases) */
        int first = 1;
        for (Node *cl=s->c1;cl;cl=cl->next) {
            /* Build condition from labels */
            if (first) { iemit(g,"if ("); first=0; }
            else          iemit(g,"} else if (");
            int lf = 1;
            for (Node *lb=cl->c0;lb;lb=lb->next) {
                if (!lf) emit(g," || ");
                if (lb->c1) {
                    /* range: lo..hi */
                    emit(g,"("); emit_expr(g,s->c0);
                    emit(g,">="); emit_expr(g,lb->c0);
                    emit(g," && "); emit_expr(g,s->c0);
                    emit(g,"<="); emit_expr(g,lb->c1); emit(g,")");
                } else {
                    emit(g,"("); emit_expr(g,s->c0);
                    emit(g,"=="); emit_expr(g,lb->c0); emit(g,")");
                }
                lf = 0;
            }
            emit(g,") {\n");
            g->indent++;
            for (Node *st=cl->c1;st;st=st->next) emit_stmt(g,st);
            g->indent--;
        }
        if (!first) {
            if (s->c2) {
                iemit(g,"} else {\n");
                g->indent++;
                for (Node *st=s->c2;st;st=st->next) emit_stmt(g,st);
                g->indent--;
            }
            iemit(g,"}\n");
        }
        break;
    }

    default:
        iemit(g,"/* unhandled stmt %s */\n", node_kind_name(s->kind));
    }
}

/* -----------------------------------------------------------------------
 * Declaration emission
 * ----------------------------------------------------------------------- */

/* Emit the C return type of a procedure (c1 = ND_TNAME ret-type node) */
static void emit_proc_ret(CG *g, Node *proc) {
    if (proc->c1) emit_type_prefix(g, proc->c1);
    else          emit(g,"void");
}

/* Emit a procedure's parameter list "(type name, ...)" */
static void emit_proc_params(CG *g, Node *params) {
    emit(g,"(");
    if (!params) { emit(g,"void"); }
    else {
        int first = 1;
        for (Node *fp=params; fp; fp=fp->next) {
            int is_var = (fp->flags & FLAG_VAR_PARAM) != 0;
            for (Node *id=fp->c0; id; id=id->next) {
                if (!first) emit(g,", ");
                emit_var_decl_raw(g, id->str, fp->c1, is_var);
                first = 0;
            }
        }
    }
    emit(g,")");
}

/* Emit a typedef struct for a record type */
static void emit_type_decl(CG *g, Node *n) {
    /* n: ND_TYPE_DECL, str=name, c0=type */
    if (!n->c0) return;
    if (n->c0->kind == ND_TRECORD) {
        Node *rec = n->c0;
        /* Two-pass: forward declare struct, then define typedef */
        emit(g,"typedef struct %s_s {\n", n->str);
        for (Node *fl=rec->c0; fl; fl=fl->next) {
            for (Node *id=fl->c0; id; id=id->next) {
                emit(g,"    ");
                emit_var_decl_raw(g, id->str, fl->c1, 0);
                emit(g,";\n");
            }
        }
        emit(g,"} %s;\n", n->str);
    } else if (n->c0->kind == ND_TNAME) {
        emit(g,"typedef %s %s;\n", ctype(n->c0->str), n->str);
    } else if (n->c0->kind == ND_TPOINTER) {
        emit(g,"typedef ");
        emit_type_prefix(g, n->c0->c0);
        emit(g," *%s;\n", n->str);
    }
    /* Other type aliases could be added here */
}

/* Emit a global variable declaration */
static void emit_global_var(CG *g, Node *n) {
    /* n: ND_VAR_DECL, c0=idents, c1=type */
    for (Node *id=n->c0; id; id=id->next) {
        sym_add(id->str, n->c1, 0);
        if (!g->is_main) {
            /* Library module:
             *   exported → ModName_VarName  (extern linkage, #define alias)
             *   private  → static VarName   (internal linkage, original name) */
            int exp = (id->flags & FLAG_EXPORTED);
            if (!exp) {
                emit(g,"static ");
                emit_var_decl_raw(g, id->str, n->c1, 0);
            } else {
                char pname[MAX_IDENT*2+2];
                snprintf(pname,sizeof(pname),"%s_%s",g->modname,id->str);
                emit_var_decl_raw(g, pname, n->c1, 0);
            }
        } else {
            emit_var_decl_raw(g, id->str, n->c1, 0);
        }
        if (n->c1 && n->c1->kind==ND_TNAME && !strcmp(n->c1->str,"STRING"))
            emit(g," = \"\"");
        emit(g,";\n");
    }
}

/* Emit local variable declarations inside a procedure body */
static void emit_local_vars(CG *g, Node *decls) {
    for (Node *d=decls; d; d=d->next) {
        if (d->kind != ND_VAR_DECL) continue;
        for (Node *id=d->c0; id; id=id->next) {
            sym_add(id->str, d->c1, 0);
            iemit(g,""); emit_var_decl_raw(g, id->str, d->c1, 0); emit(g,";\n");
        }
    }
}

/* Emit a forward declaration (prototype) for a procedure.
 * nested=1 when called recursively for an inner procedure. */
static void emit_proc_proto(CG *g, Node *proc, int nested) {
    if (!g->is_main) {
        /* Library module:
         *   exported top-level → ModName_ProcName (extern linkage)
         *   private top-level  → static ProcName  (internal linkage)
         *   nested             → static ProcName  (always private) */
        int exp = !nested && (proc->flags & FLAG_EXPORTED);
        if (!exp) emit(g,"static ");
        emit_proc_ret(g, proc);
        if (exp) emit(g," %s_%s", g->modname, proc->str);
        else     emit(g," %s", proc->str);
    } else {
        emit_proc_ret(g, proc);
        emit(g," %s", proc->str);
    }
    emit_proc_params(g, proc->c0);
    emit(g,";\n");
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_proto(g, d, 1);
}

/* Emit a complete procedure definition.
 * nested=1 when called recursively for an inner procedure. */
static void emit_proc_def(CG *g, Node *proc, int nested) {
    emit(g,"\n");
    if (!g->is_main) {
        int exp = !nested && (proc->flags & FLAG_EXPORTED);
        if (!exp) emit(g,"static ");
        emit_proc_ret(g, proc);
        if (exp) emit(g," %s_%s", g->modname, proc->str);
        else     emit(g," %s", proc->str);
    } else {
        emit_proc_ret(g, proc);
        emit(g," %s", proc->str);
    }

    /* Register parameters in a new scope */
    sym_push();
    emit_proc_params(g, proc->c0);
    /* Now register params in symbol table for body */
    for (Node *fp=proc->c0; fp; fp=fp->next) {
        int is_var = (fp->flags & FLAG_VAR_PARAM) != 0;
        for (Node *id=fp->c0; id; id=id->next)
            sym_add(id->str, fp->c1, is_var);
    }

    emit(g," {\n");
    g->indent++;
    g->in_proc++;

    /* Nested procedure prototypes */
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) { iemit(g,""); emit_proc_proto(g,d,1); }

    /* Local variable declarations */
    emit_local_vars(g, proc->c2);

    /* Nested procedure definitions */
    /* Note: C99 does not support nested functions; emit them outside.
     * For now we skip nested proc bodies here — they were emitted at top level. */

    /* Body statements */
    for (Node *s=proc->c3; s; s=s->next) emit_stmt(g,s);

    g->indent--;
    g->in_proc--;
    emit(g,"}\n");
    sym_pop();

    /* Emit any nested procedures (they'll be hoisted to file scope in C) */
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_def(g, d, 1);
}

/* -----------------------------------------------------------------------
 * Main entry point
 * ----------------------------------------------------------------------- */

void codegen(Node *module, FILE *out, int is_main) {
    CG cg;
    memset(&cg, 0, sizeof(cg));
    cg.out     = out;
    cg.is_main = is_main;
    strncpy(cg.modname, module->str, MAX_IDENT-1);
    CG *g = &cg;
    g_nsyms=0; g_sdepth=0; g_nimports=0; g_nprocsigs=0;
    collect_proc_sigs(module->c1);
    if (!is_main) collect_xmod_proc_sigs(module->c1, module->str);

    /* ── Collect import module names (alias + real name) ─────────── */
    for (Node *imp=module->c0; imp; imp=imp->next) {
        if (g_nimports >= 32) break;
        const char *alias = imp->str;
        const char *real  = (imp->flags & FLAG_HAS_ALIAS) && imp->c0
                            ? imp->c0->str : imp->str;
        strncpy(g_imports[g_nimports],      alias, MAX_IDENT-1);
        strncpy(g_import_real[g_nimports],  real,  MAX_IDENT-1);
        g_nimports++;
    }

    /* ── Collect module-level exported symbols (for #define aliases) ─ */
    if (!is_main) collect_modsyms(module->c1);

    /* ── Standard includes ───────────────────────────────────────── */
    emit(g,"#include <stdio.h>\n");
    emit(g,"#include <stdlib.h>\n");
    emit(g,"#include <string.h>\n");
    emit(g,"#include <assert.h>\n");

    /* ── Include headers for user-imported modules ───────────────── */
    for (int i=0;i<g_nimports;i++) {
        const char *real = g_import_real[i];
        if (!is_builtin_module(real))
            emit(g,"#include \"%s.h\"\n", real);
    }

    /* ── Detect imported modules ─────────────────────────────────── */
    int has_terminal = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Terminal")) { has_terminal=1; break; }
    int has_graphics = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Graphics")) { has_graphics=1; break; }
    int has_random = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Random"))   { has_random=1;   break; }
    int has_math = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Math"))     { has_math=1;     break; }
    int has_strings = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Strings"))  { has_strings=1;  break; }
    int has_files = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Files"))    { has_files=1;    break; }

    if (has_random && !has_terminal)
        emit(g,"#include <time.h>\n");
    if (has_math)
        emit(g,"#include <math.h>\n");

    /* ── Terminal module runtime (emitted when Terminal is imported) ─ */
    if (has_terminal) {
        emit(g,"#include <termios.h>\n");
        emit(g,"#include <sys/time.h>\n");
        emit(g,"#include <unistd.h>\n");
        emit(g,"#include <time.h>\n");
        emit(g,"\n");
        /* State */
        emit(g,"static struct termios _term_orig;\n");
        emit(g,"static char _term_kbuf   = 0;\n");
        emit(g,"static int  _term_kready = 0;\n");
        emit(g,"static int  _term_mouse_x   = 0;\n");
        emit(g,"static int  _term_mouse_y   = 0;\n");
        emit(g,"static int  _term_mouse_btn = 0;\n");
        emit(g,"static int  _term_mouse_on  = 0;\n");
        /* _term_restore — also disables mouse reporting if it was on */
        emit(g,"static void _term_restore(void) {\n");
        emit(g,"    if (_term_mouse_on) {\n");
        emit(g,"        printf(\"\\033[?1000l\\033[?1006l\"); fflush(stdout);\n");
        emit(g,"    }\n");
        emit(g,"    tcsetattr(STDIN_FILENO, TCSANOW, &_term_orig);\n");
        emit(g,"    printf(\"\\033[?25h\"); fflush(stdout);\n");
        emit(g,"}\n");
        /* _term_init */
        emit(g,"static void _term_init(void) {\n");
        emit(g,"    struct termios raw;\n");
        emit(g,"    tcgetattr(STDIN_FILENO, &_term_orig);\n");
        emit(g,"    raw = _term_orig;\n");
        emit(g,"    raw.c_iflag &= ~(unsigned)(ICRNL|IXON);\n");
        emit(g,"    raw.c_lflag &= ~(unsigned)(ECHO|ICANON|ISIG);\n");
        emit(g,"    raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 0;\n");
        emit(g,"    tcsetattr(STDIN_FILENO, TCSANOW, &raw);\n");
        emit(g,"    printf(\"\\033[?25l\"); fflush(stdout);\n");
        emit(g,"    atexit(_term_restore);\n");
        emit(g,"    srand((unsigned)time(NULL));\n");
        emit(g,"}\n");
        /* Mouse on/off */
        emit(g,"static void Terminal_MouseOn(void) {\n");
        emit(g,"    if (!_term_mouse_on) {\n");
        emit(g,"        printf(\"\\033[?1000h\\033[?1006h\"); fflush(stdout);\n");
        emit(g,"        _term_mouse_on = 1;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_MouseOff(void) {\n");
        emit(g,"    if (_term_mouse_on) {\n");
        emit(g,"        printf(\"\\033[?1000l\\033[?1006l\"); fflush(stdout);\n");
        emit(g,"        _term_mouse_on = 0;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        /* Mouse state accessors */
        emit(g,"static int Terminal_MouseX(void)   { return _term_mouse_x; }\n");
        emit(g,"static int Terminal_MouseY(void)   { return _term_mouse_y; }\n");
        emit(g,"static int Terminal_MouseBtn(void) { return _term_mouse_btn; }\n");
        /* Standard procedures */
        emit(g,"static void Terminal_Goto(int x, int y) {\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\", y, x); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_ShowCursor(void) {\n");
        emit(g,"    printf(\"\\033[?25h\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_HideCursor(void) {\n");
        emit(g,"    printf(\"\\033[?25l\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Clear(void) {\n");
        emit(g,"    printf(\"\\033[2J\\033[H\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static long Terminal_GetTickCount(void) {\n");
        emit(g,"    struct timeval tv;\n");
        emit(g,"    gettimeofday(&tv, NULL);\n");
        emit(g,"    return (long)(tv.tv_sec * 1000L + tv.tv_usec / 1000);\n");
        emit(g,"}\n");
        emit(g,"static int Terminal_Random(int n) {\n");
        emit(g,"    return n > 0 ? rand() %% n : 0;\n");
        emit(g,"}\n");
        emit(g,"static int Terminal_KeyPressed(void) {\n");
        emit(g,"    if (_term_kready) return 1;\n");
        emit(g,"    char c; if (read(STDIN_FILENO,&c,1)==1) {\n");
        emit(g,"        _term_kbuf=c; _term_kready=1; return 1;\n");
        emit(g,"    }\n");
        emit(g,"    return 0;\n");
        emit(g,"}\n");
        /* ReadKey — handles keyboard sequences AND SGR mouse events.
         * Returns:
         *   01X  Up arrow      02X  Down arrow
         *   03X  Left arrow    04X  Right arrow
         *   05X  Mouse event   (call MouseX/Y/Btn for details)
         *   1BX  Bare ESC
         *   otherwise: the character itself
         *
         * Mouse button values stored in _term_mouse_btn:
         *   0  left press     1  middle press   2  right press
         *   3  any release    64 wheel up        65 wheel down    */
        emit(g,"static char Terminal_ReadKey(void) {\n");
        emit(g,"    char c;\n");
        emit(g,"    if (_term_kready) { _term_kready=0; c=_term_kbuf; }\n");
        emit(g,"    else {\n");
        emit(g,"        struct termios t; tcgetattr(STDIN_FILENO,&t);\n");
        emit(g,"        t.c_cc[VMIN]=1; t.c_cc[VTIME]=0;\n");
        emit(g,"        tcsetattr(STDIN_FILENO,TCSANOW,&t);\n");
        emit(g,"        read(STDIN_FILENO,&c,1);\n");
        emit(g,"        t.c_cc[VMIN]=0; tcsetattr(STDIN_FILENO,TCSANOW,&t);\n");
        emit(g,"    }\n");
        emit(g,"    if (c == '\\033') {\n");
        emit(g,"        struct termios t2; tcgetattr(STDIN_FILENO,&t2);\n");
        emit(g,"        t2.c_cc[VMIN]=0; t2.c_cc[VTIME]=1;\n");
        emit(g,"        tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"        char c2=0, c3=0;\n");
        emit(g,"        if (read(STDIN_FILENO,&c2,1)==1 && c2=='[') {\n");
        emit(g,"            if (read(STDIN_FILENO,&c3,1)!=1) c3=0;\n");
        /* Arrow keys */
        emit(g,"            if (c3=='A') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return '\\x01'; }\n");
        emit(g,"            if (c3=='B') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return '\\x02'; }\n");
        emit(g,"            if (c3=='D') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return '\\x03'; }\n");
        emit(g,"            if (c3=='C') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return '\\x04'; }\n");
        /* SGR mouse: \033[<btn;x;yM or \033[<btn;x;ym */
        emit(g,"            if (c3=='<') {\n");
        emit(g,"                char buf[32]; int bi=0; char last=0;\n");
        emit(g,"                while (bi<31) {\n");
        emit(g,"                    char ch=0;\n");
        emit(g,"                    if (read(STDIN_FILENO,&ch,1)!=1) break;\n");
        emit(g,"                    if (ch=='M'||ch=='m') { last=ch; break; }\n");
        emit(g,"                    buf[bi++]=ch;\n");
        emit(g,"                }\n");
        emit(g,"                buf[bi]=0;\n");
        emit(g,"                int btn=0,mx=0,my=0;\n");
        emit(g,"                sscanf(buf,\"%%d;%%d;%%d\",&btn,&mx,&my);\n");
        emit(g,"                _term_mouse_x = mx;\n");
        emit(g,"                _term_mouse_y = my;\n");
        /* btn: bits 0-1 = button (0=left,1=mid,2=right), bit 6 set = wheel.
         * Release is signalled by the final 'm' rather than a button-3 code. */
        emit(g,"                if (last=='m') _term_mouse_btn=3;\n");
        emit(g,"                else           _term_mouse_btn=(btn&67);\n");
        emit(g,"                tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"                return '\\x05';\n");
        emit(g,"            }\n");
        emit(g,"        }\n");
        emit(g,"        t2.c_cc[VMIN]=0; t2.c_cc[VTIME]=0;\n");
        emit(g,"        tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"        return '\\x1B';\n");
        emit(g,"    }\n");
        emit(g,"    return c;\n");
        emit(g,"}\n");
    }

    /* ── Graphics module runtime (emitted when Graphics is imported) ─ */
    if (has_graphics) {
        emit(g,"\n");
        emit(g,"static void _gfx_restore(void) {\n");
        emit(g,"    printf(\"\\033[0m\\033[?25h\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Init(void) {\n");
        emit(g,"    printf(\"\\033[?25l\"); fflush(stdout);\n");
        emit(g,"    atexit(_gfx_restore);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Color(int fg, int bg) {\n");
        emit(g,"    printf(\"\\033[3%%d;4%%dm\", fg & 7, bg & 7); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Color256(int fg, int bg) {\n");
        emit(g,"    printf(\"\\033[38;5;%%d;48;5;%%dm\", fg & 255, bg & 255); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Reset(void) {\n");
        emit(g,"    printf(\"\\033[0m\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Goto(int x, int y) {\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\", y, x); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Clear(void) {\n");
        emit(g,"    printf(\"\\033[2J\\033[H\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Fill(int x, int y, int w, int h, char ch) {\n");
        emit(g,"    for (int row = 0; row < h; row++) {\n");
        emit(g,"        printf(\"\\033[%%d;%%dH\", y + row, x);\n");
        emit(g,"        for (int col = 0; col < w; col++) putchar(ch);\n");
        emit(g,"    }\n");
        emit(g,"    fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_HLine(int x, int y, int len, char ch) {\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\", y, x);\n");
        emit(g,"    for (int i = 0; i < len; i++) putchar(ch);\n");
        emit(g,"    fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_VLine(int x, int y, int len, char ch) {\n");
        emit(g,"    for (int i = 0; i < len; i++) {\n");
        emit(g,"        printf(\"\\033[%%d;%%dH\", y + i, x); putchar(ch);\n");
        emit(g,"    }\n");
        emit(g,"    fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Box(int x, int y, int w, int h) {\n");
        emit(g,"    if (w < 2 || h < 2) return;\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\\xe2\\x94\\x8c\", y, x);\n");      /* ┌ */
        emit(g,"    for (int i=1;i<w-1;i++) fputs(\"\\xe2\\x94\\x80\",stdout);\n"); /* ─ */
        emit(g,"    fputs(\"\\xe2\\x94\\x90\",stdout);\n");                    /* ┐ */
        emit(g,"    for (int row=1;row<h-1;row++) {\n");
        emit(g,"        printf(\"\\033[%%d;%%dH\\xe2\\x94\\x82\", y+row, x);\n"); /* │ */
        emit(g,"        printf(\"\\033[%%d;%%dH\\xe2\\x94\\x82\", y+row, x+w-1);\n");
        emit(g,"    }\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\\xe2\\x94\\x94\", y+h-1, x);\n");  /* └ */
        emit(g,"    for (int i=1;i<w-1;i++) fputs(\"\\xe2\\x94\\x80\",stdout);\n");
        emit(g,"    fputs(\"\\xe2\\x94\\x98\\n\",stdout);\n");                  /* ┘ */
        emit(g,"    fflush(stdout);\n");
        emit(g,"}\n");
        /* ── Pixel buffer (half-block: each cell = 2 vertical pixels) ── */
        emit(g,"#define _GFX_W 240\n");
        emit(g,"#define _GFX_H 100\n");
        emit(g,"static int _gfx_buf[_GFX_H][_GFX_W];\n");
        emit(g,"static void Graphics_ClearBuf(void) {\n");
        emit(g,"    for(int r=0;r<_GFX_H;r++) for(int c=0;c<_GFX_W;c++) _gfx_buf[r][c]=0;\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Plot(int x, int y, int color) {\n");
        emit(g,"    if(x<0||x>=_GFX_W||y<0||y>=_GFX_H) return;\n");
        emit(g,"    _gfx_buf[y][x] = color ? color : 7;\n");
        emit(g,"}\n");
        emit(g,"static void Graphics_Flush(void) {\n");
        emit(g,"    for(int row=0;row<_GFX_H;row+=2) {\n");
        /* Find the last non-empty column so we don't write trailing spaces
         * that would wrap onto the next terminal line on narrow terminals. */
        emit(g,"        int last=-1;\n");
        emit(g,"        for(int c=0;c<_GFX_W;c++) {\n");
        emit(g,"            int b=(row+1<_GFX_H)?_gfx_buf[row+1][c]:0;\n");
        emit(g,"            if(_gfx_buf[row][c]||b) last=c;\n");
        emit(g,"        }\n");
        emit(g,"        if(last<0) continue;\n");
        emit(g,"        printf(\"\\033[%%d;1H\",row/2+1);\n");
        emit(g,"        for(int col=0;col<=last;col++) {\n");
        emit(g,"            int top=_gfx_buf[row][col];\n");
        emit(g,"            int bot=(row+1<_GFX_H)?_gfx_buf[row+1][col]:0;\n");
        emit(g,"            if(!top&&!bot) { printf(\"\\033[0m \"); }\n");
        /* same color both halves → full block █ */
        emit(g,"            else if(top&&bot&&top==bot) { printf(\"\\033[3%%dm\\xe2\\x96\\x88\",top); }\n");
        /* different colors → ▀ with fg=top, bg=bot */
        emit(g,"            else if(top&&bot) { printf(\"\\033[3%%d;4%%dm\\xe2\\x96\\x80\",top,bot); }\n");
        /* top only → ▀ */
        emit(g,"            else if(top) { printf(\"\\033[3%%dm\\xe2\\x96\\x80\",top); }\n");
        /* bot only → ▄ */
        emit(g,"            else { printf(\"\\033[3%%dm\\xe2\\x96\\x84\",bot); }\n");
        emit(g,"        }\n");
        emit(g,"    }\n");
        emit(g,"    printf(\"\\033[0m\"); fflush(stdout);\n");
        emit(g,"}\n");
        /* Bresenham circle using Plot */
        emit(g,"static void Graphics_Circle(int cx, int cy, int r, int color) {\n");
        emit(g,"    int x=0,y=r,d=1-r;\n");
        emit(g,"    while(x<=y) {\n");
        emit(g,"        Graphics_Plot(cx+x,cy+y,color); Graphics_Plot(cx-x,cy+y,color);\n");
        emit(g,"        Graphics_Plot(cx+x,cy-y,color); Graphics_Plot(cx-x,cy-y,color);\n");
        emit(g,"        Graphics_Plot(cx+y,cy+x,color); Graphics_Plot(cx-y,cy+x,color);\n");
        emit(g,"        Graphics_Plot(cx+y,cy-x,color); Graphics_Plot(cx-y,cy-x,color);\n");
        emit(g,"        if(d<0) d+=2*x+3; else { d+=2*(x-y)+5; y--; } x++;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        /* Sprite: draw multi-line string at (x,y) with ANSI color */
        emit(g,"static void Graphics_Sprite(int x, int y, const char *s, int color) {\n");
        emit(g,"    printf(\"\\033[3%%dm\",color&7);\n");
        emit(g,"    int cx=x,cy=y;\n");
        emit(g,"    for(const char *p=s;*p;p++) {\n");
        emit(g,"        if(*p=='\\n') { cy++; cx=x; printf(\"\\033[%%d;%%dH\",cy,cx); }\n");
        emit(g,"        else { printf(\"\\033[%%d;%%dH\",cy,cx++); putchar(*p); }\n");
        emit(g,"    }\n");
        emit(g,"    printf(\"\\033[0m\"); fflush(stdout);\n");
        emit(g,"}\n");
    }
    emit(g,"\n");

    /* ── Strings module runtime ─────────────────────────────────── */
    if (has_strings) {
        emit(g,"/* Strings module — Oberon-07 compatible */\n");
        emit(g,"static int Strings_Length(const char *s) {\n");
        emit(g,"    return (int)strlen(s);\n");
        emit(g,"}\n");
        /* Append(extra, VAR dst) — dst := dst + extra */
        emit(g,"static void Strings_Append(const char *src, char *dst) {\n");
        emit(g,"    size_t dl=strlen(dst), sl=strlen(src), cap=256;\n");
        emit(g,"    if (dl+sl < cap) strcat(dst, src);\n");
        emit(g,"    else { strncat(dst, src, cap-dl-1); dst[cap-1]=0; }\n");
        emit(g,"}\n");
        /* Copy(src, VAR dst) — full string copy */
        emit(g,"static void Strings_Copy(const char *src, char *dst) {\n");
        emit(g,"    strncpy(dst, src, 255); dst[255]=0;\n");
        emit(g,"}\n");
        /* Compare(s1, s2): INTEGER — returns -1, 0, or 1 */
        emit(g,"static int Strings_Compare(const char *a, const char *b) {\n");
        emit(g,"    int r=strcmp(a,b); return r<0?-1:r>0?1:0;\n");
        emit(g,"}\n");
        /* Pos(pattern, s): INTEGER — first occurrence, -1 if absent */
        emit(g,"static int Strings_Pos(const char *pat, const char *s) {\n");
        emit(g,"    const char *p=strstr(s,pat); return p?(int)(p-s):-1;\n");
        emit(g,"}\n");
        emit(g,"\n");
    }

    /* ── Files module runtime — standard Oberon Files API ───────── */
    if (has_files) {
        emit(g,"/* Files module — standard Oberon Files API */\n");
        /* Types — guarded so including a module header doesn't redefine them */
        emit(g,"#ifndef OBC_FILES_TYPES_H_\n#define OBC_FILES_TYPES_H_\n");
        emit(g,"typedef struct _Files_Rec { FILE *fp; char name[512]; } _Files_Rec;\n");
        emit(g,"typedef _Files_Rec *Files_File;\n");
        emit(g,"typedef struct { Files_File f; long pos; int eof; } Files_Rider;\n");
        emit(g,"#endif /* OBC_FILES_TYPES_H_ */\n");
        /* Old(name): File */
        emit(g,"static Files_File Files_Old(const char *name) {\n");
        emit(g,"    FILE *fp=fopen(name,\"rb\"); if(!fp) return NULL;\n");
        emit(g,"    Files_File f=(Files_File)malloc(sizeof(_Files_Rec));\n");
        emit(g,"    f->fp=fp; strncpy(f->name,name,511); f->name[511]=0; return f;\n");
        emit(g,"}\n");
        /* New(name): File */
        emit(g,"static Files_File Files_New(const char *name) {\n");
        emit(g,"    FILE *fp=fopen(name,\"w+b\"); if(!fp) return NULL;\n");
        emit(g,"    Files_File f=(Files_File)malloc(sizeof(_Files_Rec));\n");
        emit(g,"    f->fp=fp; strncpy(f->name,name,511); f->name[511]=0; return f;\n");
        emit(g,"}\n");
        /* Register(f) — no-op here (file is already on disk) */
        emit(g,"static void Files_Register(Files_File f) { if(f) fflush(f->fp); }\n");
        /* Close(f) */
        emit(g,"static void Files_Close(Files_File f) { if(f){fclose(f->fp);free(f);} }\n");
        /* Length(f): INTEGER */
        emit(g,"static int Files_Length(Files_File f) {\n");
        emit(g,"    if(!f) return 0;\n");
        emit(g,"    long p=ftell(f->fp); fseek(f->fp,0,SEEK_END);\n");
        emit(g,"    long len=ftell(f->fp); fseek(f->fp,p,SEEK_SET); return (int)len;\n");
        emit(g,"}\n");
        /* Set(VAR r, f, pos) */
        emit(g,"static void Files_Set(Files_Rider *r, Files_File f, int pos) {\n");
        emit(g,"    r->f=f; r->eof=0;\n");
        emit(g,"    if(f){fseek(f->fp,(long)pos,SEEK_SET);r->pos=pos;}else r->pos=0;\n");
        emit(g,"}\n");
        /* Pos(VAR r): INTEGER */
        emit(g,"static int Files_Pos(Files_Rider *r) { return (int)r->pos; }\n");
        /* Base(VAR r): File */
        emit(g,"static Files_File Files_Base(Files_Rider *r) { return r->f; }\n");
        /* Read(VAR r, VAR x: BYTE) */
        emit(g,"static void Files_Read(Files_Rider *r, unsigned char *x) {\n");
        emit(g,"    if(!r->f||r->eof){r->eof=1;return;}\n");
        emit(g,"    int c=fgetc(r->f->fp);\n");
        emit(g,"    if(c==EOF){r->eof=1;*x=0;}else{*x=(unsigned char)c;r->pos++;}\n");
        emit(g,"}\n");
        /* ReadInt(VAR r, VAR x: INTEGER) — binary */
        emit(g,"static void Files_ReadInt(Files_Rider *r, int *x) {\n");
        emit(g,"    if(!r->f||r->eof){r->eof=1;return;}\n");
        emit(g,"    if(fread(x,sizeof(int),1,r->f->fp)<1)r->eof=1;else r->pos+=sizeof(int);\n");
        emit(g,"}\n");
        /* ReadBool(VAR r, VAR x: BOOLEAN) */
        emit(g,"static void Files_ReadBool(Files_Rider *r, int *x) {\n");
        emit(g,"    unsigned char b=0; Files_Read(r,&b); *x=b?1:0;\n");
        emit(g,"}\n");
        /* ReadReal(VAR r, VAR x: REAL) — binary */
        emit(g,"static void Files_ReadReal(Files_Rider *r, double *x) {\n");
        emit(g,"    if(!r->f||r->eof){r->eof=1;return;}\n");
        emit(g,"    if(fread(x,sizeof(double),1,r->f->fp)<1)r->eof=1;else r->pos+=sizeof(double);\n");
        emit(g,"}\n");
        /* ReadString(VAR r, VAR x: ARRAY OF CHAR) — null-terminated */
        emit(g,"static void Files_ReadString(Files_Rider *r, char *x) {\n");
        emit(g,"    int i=0,c;\n");
        emit(g,"    if(!r->f||r->eof){x[0]=0;r->eof=1;return;}\n");
        emit(g,"    while((c=fgetc(r->f->fp))!=EOF&&c!=0){x[i++]=(char)c;r->pos++;}\n");
        emit(g,"    if(c==0)r->pos++;else r->eof=1;\n");
        emit(g,"    x[i]=0;\n");
        emit(g,"}\n");
        /* ReadNum(VAR r, VAR x: INTEGER) — LEB128 */
        emit(g,"static void Files_ReadNum(Files_Rider *r, int *x) {\n");
        emit(g,"    unsigned int n=0; int sh=0; unsigned char b;\n");
        emit(g,"    do{Files_Read(r,&b);n|=((unsigned)(b&0x7F))<<sh;sh+=7;}while(b&0x80);\n");
        emit(g,"    *x=(int)n;\n");
        emit(g,"}\n");
        /* Write(VAR r, x: BYTE) */
        emit(g,"static void Files_Write(Files_Rider *r, unsigned char x) {\n");
        emit(g,"    if(!r->f||r->eof)return;\n");
        emit(g,"    if(fputc(x,r->f->fp)!=EOF)r->pos++;else r->eof=1;\n");
        emit(g,"}\n");
        /* WriteInt(VAR r, x: INTEGER) — binary */
        emit(g,"static void Files_WriteInt(Files_Rider *r, int x) {\n");
        emit(g,"    if(!r->f||r->eof)return;\n");
        emit(g,"    if(fwrite(&x,sizeof(int),1,r->f->fp)==1)r->pos+=sizeof(int);else r->eof=1;\n");
        emit(g,"}\n");
        /* WriteBool(VAR r, x: BOOLEAN) */
        emit(g,"static void Files_WriteBool(Files_Rider *r, int x) {\n");
        emit(g,"    unsigned char b=(unsigned char)(x?1:0); Files_Write(r,b);\n");
        emit(g,"}\n");
        /* WriteReal(VAR r, x: REAL) — binary */
        emit(g,"static void Files_WriteReal(Files_Rider *r, double x) {\n");
        emit(g,"    if(!r->f||r->eof)return;\n");
        emit(g,"    if(fwrite(&x,sizeof(double),1,r->f->fp)==1)r->pos+=sizeof(double);else r->eof=1;\n");
        emit(g,"}\n");
        /* WriteString(VAR r, x: ARRAY OF CHAR) — null-terminated */
        emit(g,"static void Files_WriteString(Files_Rider *r, const char *x) {\n");
        emit(g,"    while(*x)Files_Write(r,(unsigned char)*x++);\n");
        emit(g,"    Files_Write(r,0);\n");
        emit(g,"}\n");
        /* WriteNum(VAR r, x: INTEGER) — LEB128 */
        emit(g,"static void Files_WriteNum(Files_Rider *r, int x) {\n");
        emit(g,"    unsigned int n=(unsigned int)x;\n");
        emit(g,"    do{unsigned char b=n&0x7F;n>>=7;if(n)b|=0x80;Files_Write(r,b);}while(n);\n");
        emit(g,"}\n");
        emit(g,"\n");
    }

    /* ── Helper: set range ───────────────────────────────────────── */
    emit(g,"static unsigned int _obc_range(int lo, int hi) {\n");
    emit(g,"    unsigned int m=0; for(int i=lo;i<=hi;i++) m|=(1u<<i); return m;\n");
    emit(g,"}\n\n");

    /* ── #define aliases (lib mode only): let proc bodies reference
     *    exported symbols by their original Oberon names, which the C
     *    preprocessor then expands to the prefixed C names.          ── */
    if (!g->is_main) {
        for (int i=0; i<g_nmodsyms; i++)
            emit(g,"#define %s %s_%s\n", g_modsyms[i], g->modname, g_modsyms[i]);
        emit(g,"\n");
    }

    /* ── Constant definitions (before types — may be used as array sizes) ── */
    int has_consts = 0;
    for (Node *d=module->c1; d; d=d->next) {
        if (d->kind==ND_CONST_DECL) {
            /* Library: exported consts get module prefix; private keep name.
             * Use enum so the constant can serve as an array size.          */
            int exp = !is_main && (d->flags & FLAG_EXPORTED);
            if (exp)
                emit(g,"enum { %s_%s = ", g->modname, d->str);
            else
                emit(g,"enum { %s = ", d->str);
            emit_expr(g, d->c0);
            emit(g," };\n");
            has_consts = 1;
        }
    }
    if (has_consts) emit(g,"\n");

    /* ── Type declarations ───────────────────────────────────────── */
    int has_types = 0;
    for (Node *d=module->c1; d; d=d->next)
        if (d->kind==ND_TYPE_DECL) { emit_type_decl(g,d); has_types=1; }
    if (has_types) emit(g,"\n");

    /* ── Global variable declarations ───────────────────────────── */
    int has_globals = 0;
    for (Node *d=module->c1; d; d=d->next)
        if (d->kind==ND_VAR_DECL) { emit_global_var(g,d); has_globals=1; }
    if (has_globals) emit(g,"\n");

    /* ── Forward declarations for all procedures ─────────────────── */
    for (Node *d=module->c1; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_proto(g,d,0);
    emit(g,"\n");

    /* ── Procedure definitions ───────────────────────────────────── */
    for (Node *d=module->c1; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_def(g,d,0);

    if (g->is_main) {
        /* ── Main program: extern + call each user-imported init() ── */
        for (int i=0;i<g_nimports;i++) {
            const char *real = g_import_real[i];
            if (!is_builtin_module(real))
                emit(g,"extern void %s_init(void);\n", real);
        }
        emit(g,"\nint main(void) {\n");
        g->indent++;
        if (has_terminal) iemit(g,"_term_init();\n");
        if (has_graphics) iemit(g,"Graphics_Init();\n");
        if (has_random && !has_terminal) iemit(g,"srand((unsigned)time(NULL));\n");
        for (int i=0;i<g_nimports;i++) {
            const char *real = g_import_real[i];
            if (!is_builtin_module(real))
                iemit(g,"%s_init();\n", real);
        }
        for (Node *s=module->c2; s; s=s->next) emit_stmt(g,s);
        iemit(g,"return 0;\n");
        g->indent--;
        emit(g,"}\n");
    } else {
        /* ── Library module: emit ModName_init() with once-guard ──── */
        /* Extern declarations for this module's own user-module deps */
        for (int i=0;i<g_nimports;i++) {
            const char *real = g_import_real[i];
            if (!is_builtin_module(real))
                emit(g,"extern void %s_init(void);\n", real);
        }
        emit(g,"\nvoid %s_init(void) {\n", g->modname);
        g->indent++;
        iemit(g,"static int _once = 0;\n");
        iemit(g,"if (_once) return; _once = 1;\n");
        if (has_terminal) iemit(g,"_term_init();\n");
        if (has_graphics) iemit(g,"Graphics_Init();\n");
        if (has_random && !has_terminal) iemit(g,"srand((unsigned)time(NULL));\n");
        /* Call each user-module dependency's init */
        for (int i=0;i<g_nimports;i++) {
            const char *real = g_import_real[i];
            if (!is_builtin_module(real))
                iemit(g,"%s_init();\n", real);
        }
        for (Node *s=module->c2; s; s=s->next) emit_stmt(g,s);
        g->indent--;
        emit(g,"}\n");
        /* #undef aliases after the entire init body */
        emit(g,"\n");
        for (int i=0; i<g_nmodsyms; i++)
            emit(g,"#undef %s\n", g_modsyms[i]);
    }
}

/* -----------------------------------------------------------------------
 * Header generation for library modules.
 * Emits extern declarations for all exported procedures and variables,
 * plus the module's init function declaration.
 * ----------------------------------------------------------------------- */
void codegen_header(Node *module, FILE *out) {
    /* Guard macro */
    char guard[MAX_IDENT*2];
    snprintf(guard, sizeof(guard), "OBC_%s_H_", module->str);
    for (char *p=guard; *p; p++) if (*p>='a'&&*p<='z') *p -= 32;

    fprintf(out,"#ifndef %s\n#define %s\n\n", guard, guard);
    fprintf(out,"#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n\n");

    /* Use a temporary CG writing to `out` for type/ret emission */
    CG cg;
    memset(&cg,0,sizeof(cg));
    cg.out = out; cg.is_main = 0;
    strncpy(cg.modname, module->str, MAX_IDENT-1);
    CG *g = &cg;
    /* Re-init globals so emit_proc_ret / emit_type_prefix work */
    g_nsyms=0; g_sdepth=0; g_nimports=0;

    /* Collect imports for dependency detection */
    for (Node *imp=module->c0; imp; imp=imp->next) {
        if (g_nimports >= 32) break;
        const char *alias = imp->str;
        const char *real  = (imp->flags & FLAG_HAS_ALIAS) && imp->c0
                            ? imp->c0->str : imp->str;
        strncpy(g_imports[g_nimports],      alias, MAX_IDENT-1);
        strncpy(g_import_real[g_nimports],  real,  MAX_IDENT-1);
        g_nimports++;
    }

    /* Emit Files type definitions (guarded) if module uses Files */
    int has_files = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_import_real[i],"Files")) { has_files=1; break; }
    if (has_files) {
        fprintf(out,"#ifndef OBC_FILES_TYPES_H_\n#define OBC_FILES_TYPES_H_\n");
        fprintf(out,"typedef struct _Files_Rec { FILE *fp; char name[512]; } _Files_Rec;\n");
        fprintf(out,"typedef _Files_Rec *Files_File;\n");
        fprintf(out,"typedef struct { Files_File f; long pos; int eof; } Files_Rider;\n");
        fprintf(out,"#endif\n\n");
    }

    /* Include headers for user-imported modules */
    for (int i=0;i<g_nimports;i++) {
        const char *real = g_import_real[i];
        if (!is_builtin_module(real))
            fprintf(out,"#include \"%s.h\"\n", real);
    }

    /* #define aliases so bare type/proc names expand to prefixed versions */
    collect_modsyms(module->c1);
    if (g_nmodsyms) {
        for (int i=0; i<g_nmodsyms; i++)
            fprintf(out,"#define %s %s_%s\n", g_modsyms[i], module->str, g_modsyms[i]);
        fprintf(out,"\n");
    }

    /* All constants (exported and private — both may be needed for type dimensions) */
    for (Node *d=module->c1; d; d=d->next) {
        if (d->kind==ND_CONST_DECL) {
            if (d->flags & FLAG_EXPORTED)
                fprintf(out,"enum { %s_%s = ", module->str, d->str);
            else
                fprintf(out,"enum { %s = ", d->str);
            emit_expr(g, d->c0);
            fprintf(out," };\n");
        }
    }

    /* Exported type definitions */
    for (Node *d=module->c1; d; d=d->next) {
        if (d->kind==ND_TYPE_DECL && (d->flags & FLAG_EXPORTED))
            emit_type_decl(g, d);
    }
    fprintf(out,"\n");

    /* Exported variables */
    for (Node *d=module->c1; d; d=d->next) {
        if (d->kind==ND_VAR_DECL) {
            for (Node *id=d->c0; id; id=id->next) {
                if (id->flags & FLAG_EXPORTED) {
                    fprintf(out,"extern ");
                    char pname[MAX_IDENT*2+2];
                    snprintf(pname,sizeof(pname),"%s_%s",module->str,id->str);
                    emit_var_decl_raw(g, pname, d->c1, 0);
                    fprintf(out,";\n");
                }
            }
        }
    }

    /* Exported procedures */
    for (Node *d=module->c1; d; d=d->next) {
        if (d->kind==ND_PROC_DECL && (d->flags & FLAG_EXPORTED)) {
            emit_proc_ret(g, d);
            fprintf(out," %s_%s", module->str, d->str);
            emit_proc_params(g, d->c0);
            fprintf(out,";\n");
        }
    }

    /* Module init */
    fprintf(out,"\nvoid %s_init(void);\n", module->str);
    fprintf(out,"\n#endif /* %s */\n", guard);
}
