#include "codegen.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -----------------------------------------------------------------------
 * Emitter context
 * ----------------------------------------------------------------------- */
typedef struct { FILE *out; int indent; } CG;

static void emit(CG *g, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(g->out, fmt, ap); va_end(ap);
}
static void ind(CG *g)        { for (int i=0;i<g->indent;i++) fputs("    ",g->out); }
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
 * Known imports (module aliases)
 * ----------------------------------------------------------------------- */
static char g_imports[32][MAX_IDENT];
static int  g_nimports = 0;
static int  is_import(const char *s) {
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],s)) return 1;
    return 0;
}

/* -----------------------------------------------------------------------
 * Type helpers
 * ----------------------------------------------------------------------- */

/* Map Oberon built-in type name → C type */
static const char *ctype(const char *name) {
    if (!strcmp(name,"INTEGER"))  return "int";
    if (!strcmp(name,"LONGINT"))  return "long";
    if (!strcmp(name,"SHORTINT")) return "short";
    if (!strcmp(name,"REAL"))     return "double";
    if (!strcmp(name,"LONGREAL")) return "double";
    if (!strcmp(name,"CHAR"))     return "char";
    if (!strcmp(name,"BOOLEAN"))  return "int";
    if (!strcmp(name,"BYTE"))     return "unsigned char";
    if (!strcmp(name,"SET"))      return "unsigned int";
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
                emit(g,"\"%s\"", a0->str);
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
    /* Unknown import call → Module_Proc(args) */
    emit(g,"%s_%s(",mod,proc);
    for (Node *a=args;a;a=a->next) { if(a!=args) emit(g,","); emit_expr(g,a); }
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
            emit(g,"\"%s\"",e->str);
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
        /* For each argument, pass address if it's a VAR param destination.
         * We can't know this without a full type system; pass as-is. */
        for (Node *a=e->c1;a;a=a->next) {
            if (a!=e->c1) emit(g,",");
            emit_expr(g,a);
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
            if (rhs->kind == ND_STRING) emit(g,"\"%s\"", rhs->str);
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
        for (Node *a=s->c1;a;a=a->next) {
            if (a!=s->c1) emit(g,",");
            emit_expr(g,a);
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
        emit_expr(g,s->c0); emit(g,"; %s <= ",s->str);
        emit_expr(g,s->c1);
        if (s->c2) { emit(g,"; %s += ",s->str); emit_expr(g,s->c2); }
        else        emit(g,"; %s++",s->str);
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
        emit_var_decl_raw(g, id->str, n->c1, 0);
        /* Zero-initialise globals */
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

/* Emit a forward declaration (prototype) for a procedure */
static void emit_proc_proto(CG *g, Node *proc) {
    /* proc: ND_PROC_DECL, str=name, c0=params, c1=ret_type, c2=decls, c3=stmts */
    emit_proc_ret(g, proc);
    emit(g," %s", proc->str);
    emit_proc_params(g, proc->c0);
    emit(g,";\n");
    /* Also handle nested procedure declarations */
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_proto(g, d);
}

/* Emit a complete procedure definition */
static void emit_proc_def(CG *g, Node *proc) {
    emit(g,"\n");
    emit_proc_ret(g, proc);
    emit(g," %s", proc->str);

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

    /* Nested procedure prototypes */
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) { iemit(g,""); emit_proc_proto(g,d); }

    /* Local variable declarations */
    emit_local_vars(g, proc->c2);

    /* Nested procedure definitions */
    /* Note: C99 does not support nested functions; emit them outside.
     * For now we skip nested proc bodies here — they were emitted at top level. */

    /* Body statements */
    for (Node *s=proc->c3; s; s=s->next) emit_stmt(g,s);

    g->indent--;
    emit(g,"}\n");
    sym_pop();

    /* Emit any nested procedures (they'll be hoisted to file scope in C) */
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_def(g, d);
}

/* -----------------------------------------------------------------------
 * Main entry point
 * ----------------------------------------------------------------------- */

void codegen(Node *module, FILE *out) {
    CG cg = { out, 0 };
    CG *g = &cg;
    g_nsyms=0; g_sdepth=0; g_nimports=0;

    /* ── Collect import module names ─────────────────────────────── */
    for (Node *imp=module->c0; imp; imp=imp->next) {
        /* str = alias (or module name if no alias) */
        if (g_nimports < 32)
            strncpy(g_imports[g_nimports++], imp->str, MAX_IDENT-1);
        /* Also register the real name if aliased */
        if ((imp->flags & FLAG_HAS_ALIAS) && imp->c0 && g_nimports < 32)
            strncpy(g_imports[g_nimports++], imp->c0->str, MAX_IDENT-1);
    }

    /* ── Standard includes ───────────────────────────────────────── */
    emit(g,"#include <stdio.h>\n");
    emit(g,"#include <stdlib.h>\n");
    emit(g,"#include <string.h>\n");
    emit(g,"#include <assert.h>\n");

    /* ── Detect imported modules ─────────────────────────────────── */
    int has_terminal = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Terminal")) { has_terminal=1; break; }
    int has_graphics = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Graphics")) { has_graphics=1; break; }
    int has_random = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Random"))   { has_random=1;   break; }

    if (has_random && !has_terminal)
        emit(g,"#include <time.h>\n");

    /* ── Terminal module runtime (emitted when Terminal is imported) ─ */
    if (has_terminal) {
        emit(g,"#include <termios.h>\n");
        emit(g,"#include <sys/time.h>\n");
        emit(g,"#include <unistd.h>\n");
        emit(g,"#include <time.h>\n");
        emit(g,"\n");
        emit(g,"static struct termios _term_orig;\n");
        emit(g,"static char _term_kbuf = 0;\n");
        emit(g,"static int  _term_kready = 0;\n");
        emit(g,"static void _term_restore(void) {\n");
        emit(g,"    tcsetattr(STDIN_FILENO, TCSANOW, &_term_orig);\n");
        emit(g,"    printf(\"\\033[?25h\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void _term_init(void) {\n");
        emit(g,"    struct termios raw;\n");
        emit(g,"    tcgetattr(STDIN_FILENO, &_term_orig);\n");
        emit(g,"    raw = _term_orig;\n");
        emit(g,"    raw.c_lflag &= ~(unsigned)(ECHO|ICANON|ISIG);\n");
        emit(g,"    raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 0;\n");
        emit(g,"    tcsetattr(STDIN_FILENO, TCSANOW, &raw);\n");
        emit(g,"    printf(\"\\033[?25l\"); fflush(stdout);\n");
        emit(g,"    atexit(_term_restore);\n");
        emit(g,"    srand((unsigned)time(NULL));\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Goto(int x, int y) {\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\", y, x); fflush(stdout);\n");
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
        emit(g,"static char Terminal_ReadKey(void) {\n");
        emit(g,"    if (_term_kready) { _term_kready=0; return _term_kbuf; }\n");
        emit(g,"    /* switch to blocking */\n");
        emit(g,"    struct termios t; tcgetattr(STDIN_FILENO,&t);\n");
        emit(g,"    t.c_cc[VMIN]=1; t.c_cc[VTIME]=0;\n");
        emit(g,"    tcsetattr(STDIN_FILENO,TCSANOW,&t);\n");
        emit(g,"    char c; read(STDIN_FILENO,&c,1);\n");
        emit(g,"    t.c_cc[VMIN]=0; tcsetattr(STDIN_FILENO,TCSANOW,&t);\n");
        emit(g,"    if (c == '\\033') {\n");
        emit(g,"        char c2,c3;\n");
        emit(g,"        if (read(STDIN_FILENO,&c2,1)==1 && c2=='[') {\n");
        emit(g,"            if (read(STDIN_FILENO,&c3,1)==1) {\n");
        emit(g,"                if (c3=='A') return '\\x01';\n"); /* Up    */
        emit(g,"                if (c3=='B') return '\\x02';\n"); /* Down  */
        emit(g,"                if (c3=='C') return '\\x04';\n"); /* Right */
        emit(g,"                if (c3=='D') return '\\x03';\n"); /* Left  */
        emit(g,"            }\n");
        emit(g,"        }\n");
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
    }
    emit(g,"\n");

    /* ── Helper: set range ───────────────────────────────────────── */
    emit(g,"static unsigned int _obc_range(int lo, int hi) {\n");
    emit(g,"    unsigned int m=0; for(int i=lo;i<=hi;i++) m|=(1u<<i); return m;\n");
    emit(g,"}\n\n");

    /* ── Constant definitions (before types — may be used as array sizes) ── */
    int has_consts = 0;
    for (Node *d=module->c1; d; d=d->next) {
        if (d->kind==ND_CONST_DECL) {
            /* Emit as enum value so it's usable as an array size constant */
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
        if (d->kind==ND_PROC_DECL) emit_proc_proto(g,d);
    emit(g,"\n");

    /* ── Procedure definitions ───────────────────────────────────── */
    for (Node *d=module->c1; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_def(g,d);

    /* ── Module body → main() ────────────────────────────────────── */
    emit(g,"\nint main(void) {\n");
    g->indent++;
    if (has_terminal) iemit(g,"_term_init();\n");
    if (has_graphics) iemit(g,"Graphics_Init();\n");
    if (has_random && !has_terminal) iemit(g,"srand((unsigned)time(NULL));\n");
    for (Node *s=module->c2; s; s=s->next) emit_stmt(g,s);
    iemit(g,"return 0;\n");
    g->indent--;
    emit(g,"}\n");
}
