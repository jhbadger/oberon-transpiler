#include "codegen.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* -----------------------------------------------------------------------
 * Emitter context
 * ----------------------------------------------------------------------- */
typedef struct {
    FILE *out;
    int   indent;
    char  modname[MAX_IDENT]; /* current module name (library mode) */
    char  srcfile[512];       /* source .mod path for #line directives */
    int   last_line;          /* last #line directive emitted          */
    int   is_main;            /* 1 = top-level program, 0 = library  */
    int   in_proc;            /* 1 when inside a procedure body      */
    /* Nested procedure closure support */
    int   in_nested_proc;                   /* emitting a nested proc body */
    char  outer_proc_name[MAX_IDENT];       /* enclosing proc name         */
    int   n_frame;                           /* # outer vars in frame       */
    char  frame_names[128][MAX_IDENT];
    Node *frame_types[128];
    int   frame_is_var[128];                 /* 1 if was a VAR param        */
    int   nested_sym_start;                  /* g_nsyms after nested push   */
    int   n_nested_procs;
    char  nested_proc_names[32][MAX_IDENT];
} CG;

/* -----------------------------------------------------------------------
 * FFI module registry
 * ----------------------------------------------------------------------- */
#define MAX_FFI_MODS 64

typedef struct {
    char modname[64];
    char header[256];              /* full include arg: "<foo.h>" or "\"foo.h\"" */
    OBCFfiMap maps[OBC_FFI_MAP_MAX];
    int  nmaps;
} FfiMod;

static FfiMod g_ffi_mods[MAX_FFI_MODS];
static int    g_n_ffi_mods = 0;

void ffi_register(const char *modname, const char *header,
                  const OBCFfiMap *maps, int nmaps)
{
    if (g_n_ffi_mods >= MAX_FFI_MODS) {
        fprintf(stderr, "obc: too many FFI modules (max %d)\n", MAX_FFI_MODS);
        return;
    }
    FfiMod *m = &g_ffi_mods[g_n_ffi_mods++];
    strncpy(m->modname, modname, sizeof(m->modname)-1);
    m->modname[sizeof(m->modname)-1] = '\0';
    strncpy(m->header, header, sizeof(m->header)-1);
    m->header[sizeof(m->header)-1] = '\0';
    int n = nmaps < OBC_FFI_MAP_MAX ? nmaps : OBC_FFI_MAP_MAX;
    for (int i = 0; i < n; i++) m->maps[i] = maps[i];
    m->nmaps = n;
}

int ffi_is_registered(const char *modname) {
    for (int i = 0; i < g_n_ffi_mods; i++)
        if (!strcmp(g_ffi_mods[i].modname, modname)) return 1;
    return 0;
}

static const FfiMod *ffi_lookup(const char *modname) {
    for (int i = 0; i < g_n_ffi_mods; i++)
        if (!strcmp(g_ffi_mods[i].modname, modname)) return &g_ffi_mods[i];
    return NULL;
}

static int is_open_array(Node *t);   /* forward */

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
    else if (e && e->kind == ND_DEREF) emit_expr(g, e->c0); /* ptr^ → just the ptr */
    else if (e)                        emit_expr(g, e);
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
#define MAX_SYMS 4096
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
typedef struct { char name[MAX_IDENT]; Node *params; Node *rettype; } ProcSig;
static ProcSig g_procsigs[MAX_PROCSIGS];
static int g_nprocsigs = 0;

/* Module declaration list (set in codegen()) — used for type lookups. */
static Node *g_module_decls = NULL;

/* Pointer-type registry: names that are POINTER TO ... typedefs */
#define MAX_PTR_TYPES 256
static char g_ptr_types[MAX_PTR_TYPES][MAX_IDENT];
static int  g_n_ptr_types = 0;
static void ptr_type_add(const char *name) {
    if (g_n_ptr_types < MAX_PTR_TYPES)
        strncpy(g_ptr_types[g_n_ptr_types++], name, MAX_IDENT-1);
}
/* Forward declarations — defined later in this file. */
static const char *import_realname(const char *alias);
static Node *find_type_decl(const char *name);
static Node *expr_type(Node *e);

static int is_ptr_type(const char *name) {
    for (int i=0;i<g_n_ptr_types;i++)
        if (!strcmp(g_ptr_types[i],name)) return 1;
    /* Cross-module fallback: look up the type decl and check if it is
     * a POINTER TO declaration.  find_type_decl handles "Alias.TypeName"
     * resolution via the xmod table. */
    {
        Node *td = find_type_decl(name);
        if (td && td->c0 && td->c0->kind == ND_TPOINTER) return 1;
    }
    return 0;
}
static void ptr_types_reset(void) { g_n_ptr_types = 0; }

/* Cross-module type decl lookup table — variables declared here so
 * find_type_decl() can reference them; populated later by
 * collect_xmod_type_decls() which is defined after the node pool. */
#define MAX_XMOD_TYPEDECLS 256
static Node *g_xmod_typedecls[MAX_XMOD_TYPEDECLS];
static int   g_n_xmod_typedecls = 0;

/* Find a TYPE_DECL node by name.  First searches the current module's decl
 * list; then falls back to the cross-module persistent table, resolving a
 * qualified "Alias.TypeName" to the C-style "RealModule_TypeName" key. */
static Node *find_type_decl(const char *name) {
    for (Node *d=g_module_decls; d; d=d->next)
        if (d->kind==ND_TYPE_DECL && !strcmp(d->str,name)) return d;
    /* Cross-module fallback: resolve "Alias.TypeName" → "RealMod_TypeName" */
    {
        const char *dot = strchr(name, '.');
        if (dot) {
            char alias[MAX_IDENT];
            int modlen = (int)(dot - name);
            if (modlen >= MAX_IDENT) modlen = MAX_IDENT - 1;
            strncpy(alias, name, modlen); alias[modlen] = '\0';
            char ckey[MAX_IDENT];
            snprintf(ckey, sizeof(ckey), "%s_%s", import_realname(alias), dot + 1);
            for (int i = 0; i < g_n_xmod_typedecls; i++)
                if (!strcmp(g_xmod_typedecls[i]->str, ckey)) return g_xmod_typedecls[i];
        }
    }
    /* Direct xmod lookup: already-mangled names like "TUI_View" */
    for (int i = 0; i < g_n_xmod_typedecls; i++)
        if (!strcmp(g_xmod_typedecls[i]->str, name)) return g_xmod_typedecls[i];
    return NULL;
}

/* -----------------------------------------------------------------------
 * Type-tag table — maps record type names to unique integer tags.
 * Tag 0 is reserved for "uninitialized / no type".
 * ----------------------------------------------------------------------- */
#define MAX_TYPE_TAGS 256
static char g_type_tags[MAX_TYPE_TAGS][MAX_IDENT];
static int  g_n_type_tags = 0;

static void type_tags_reset(void) { g_n_type_tags = 0; }
static int  type_tag_of(const char *name) {
    for (int i=0;i<g_n_type_tags;i++)
        if (!strcmp(g_type_tags[i],name)) return i+1;
    return 0;
}
static int type_tag_add(const char *name) {
    int t = type_tag_of(name);
    if (t) return t;
    if (g_n_type_tags < MAX_TYPE_TAGS)
        strncpy(g_type_tags[g_n_type_tags++],name,MAX_IDENT-1);
    return g_n_type_tags;
}
static int is_known_record_type(const char *name) { return type_tag_of(name)!=0; }

/* Convert a possibly-qualified type name "Mod.Type" to its C tag name
 * "Mod_Type" (replacing the dot with underscore).  For unqualified names
 * the input is returned unchanged.  Result is written into buf[buflen]. */
static const char *tag_cname(const char *name, char *buf, int buflen) {
    const char *dot = strchr(name, '.');
    if (!dot) return name;
    /* "Alias.TypeName" → resolve alias to real module name then "_TypeName" */
    int modlen = (int)(dot - name);
    char alias[MAX_IDENT]; if (modlen >= MAX_IDENT) modlen = MAX_IDENT-1;
    strncpy(alias, name, modlen); alias[modlen] = '\0';
    snprintf(buf, buflen, "%s_%s", import_realname(alias), dot + 1);
    return buf;
}

static void collect_proc_sigs(Node *decls) {
    for (Node *d = decls; d; d = d->next) {
        if (d->kind == ND_PROC_DECL && g_nprocsigs < MAX_PROCSIGS) {
            strncpy(g_procsigs[g_nprocsigs].name, d->str, MAX_IDENT-1);
            g_procsigs[g_nprocsigs].params  = d->c0;
            g_procsigs[g_nprocsigs].rettype = d->c1;
            g_nprocsigs++;
            collect_proc_sigs(d->c2);  /* recurse into nested procedures */
        }
    }
}
static Node *lookup_proc_params(const char *name) {
    for (int i = 0; i < g_nprocsigs; i++)
        if (!strcmp(g_procsigs[i].name, name)) return g_procsigs[i].params;
    return NULL;
}
static Node *lookup_proc_rettype(const char *name) {
    for (int i = 0; i < g_nprocsigs; i++)
        if (!strcmp(g_procsigs[i].name, name)) return g_procsigs[i].rettype;
    return NULL;
}

/* Return the formal parameter list for any callee expression.
 * For named procedures, checks g_procsigs.  For procedure variables and
 * field accesses, resolves the callee's PROCEDURE type via expr_type() so
 * that VAR-param status is known even when calling through a proc variable. */
static Node *lookup_callee_params(Node *callee) {
    if (!callee) return NULL;
    /* Named procedure: signature table has the definitive answer */
    if (callee->kind == ND_IDENT) {
        Node *p = lookup_proc_params(callee->str);
        if (p) return p;
    }
    /* Procedure variable or field access: derive from the expression's type */
    Node *t = expr_type(callee);
    /* Resolve a named alias (e.g. HandleProc → TPROC) */
    if (t && t->kind == ND_TNAME) {
        Node *td = find_type_decl(t->str);
        if (td && td->c0) t = td->c0;
    }
    /* c0 of a TPROC node is the formal-parameter list */
    if (t && t->kind == ND_TPROC) return t->c0;
    return NULL;
}

/* Cross-module proc signatures — indexed by "RealModule.ProcName".
 * Accumulated across all codegen() calls (never reset) so that when
 * compiling the main module we can look up VAR-param info for imported procs.
 *
 * We store a compact per-slot array rather than AST node pointers, because
 * ast_free_all() is called after each dependency module is codegen'd and would
 * leave dangling pointers into the freed arena. */
#define MAX_XMOD_PROCSIGS  512
#define MAX_PARAMS_PER_PROC 64
typedef struct { int8_t is_var; int8_t is_open_array; } XParamSlot;
typedef struct {
    char       key[MAX_IDENT*2];
    int        nslots;
    XParamSlot slots[MAX_PARAMS_PER_PROC];
} XModProcSig;
static XModProcSig g_xmod_procsigs[MAX_XMOD_PROCSIGS];
static int g_n_xmod_procsigs = 0;

static void collect_xmod_proc_sigs(Node *decls, const char *modname) {
    for (Node *d = decls; d; d = d->next) {
        if (d->kind != ND_PROC_DECL) continue;
        if (g_n_xmod_procsigs >= MAX_XMOD_PROCSIGS) continue;
        XModProcSig *sig = &g_xmod_procsigs[g_n_xmod_procsigs++];
        snprintf(sig->key, sizeof(sig->key), "%s.%s", modname, d->str);
        sig->nslots = 0;
        for (Node *fp = d->c0; fp && sig->nslots < MAX_PARAMS_PER_PROC; fp = fp->next) {
            int isv = (fp->flags & FLAG_VAR_PARAM) != 0;
            int ioa = is_open_array(fp->c1);
            for (Node *id = fp->c0; id && sig->nslots < MAX_PARAMS_PER_PROC; id = id->next) {
                sig->slots[sig->nslots].is_var        = (int8_t)isv;
                sig->slots[sig->nslots].is_open_array = (int8_t)ioa;
                sig->nslots++;
            }
        }
    }
}
static XModProcSig *lookup_xmod_proc_params(const char *modname, const char *procname) {
    char key[MAX_IDENT*2];
    snprintf(key, sizeof(key), "%s.%s", modname, procname);
    for (int i = 0; i < g_n_xmod_procsigs; i++)
        if (!strcmp(g_xmod_procsigs[i].key, key)) return &g_xmod_procsigs[i];
    return NULL;
}

/* -----------------------------------------------------------------------
 * Cross-module type declaration table.
 * Node structures here live in a static pool (not the arena), so they
 * survive ast_free_all() and can be referenced by find_type_decl().
 * Populated during codegen() of each library module.
 * ----------------------------------------------------------------------- */
#define XMOD_NODE_POOL_SIZE 2048
static Node g_xmod_node_pool[XMOD_NODE_POOL_SIZE];
static int  g_n_xmod_nodes = 0;

static Node *xmod_node_alloc(NodeKind kind) {
    if (g_n_xmod_nodes >= XMOD_NODE_POOL_SIZE) return NULL;
    Node *n = &g_xmod_node_pool[g_n_xmod_nodes++];
    memset(n, 0, sizeof(Node));
    n->kind = kind;
    return n;
}

/* Forward declaration */
static Node *xmod_copy_typetree(Node *t);

static Node *xmod_copy_nodelist(Node *head) {
    Node *result = NULL, *tail = NULL;
    for (Node *src = head; src; src = src->next) {
        Node *dst = xmod_copy_typetree(src);
        if (!dst) break;
        if (tail) tail->next = dst; else result = dst;
        tail = dst;
    }
    return result;
}

static Node *xmod_copy_typetree(Node *t) {
    if (!t) return NULL;
    Node *n = xmod_node_alloc(t->kind);
    if (!n) return NULL;
    strncpy(n->str, t->str, MAX_IDENT-1);
    n->flags = t->flags;
    n->ival  = t->ival;
    switch (t->kind) {
    case ND_TARRAY:
        /* Preserve open vs. fixed (c0 present/absent) with a dummy bound node.
         * Copy the bound's ival so ARRAY 64 OF CHAR stays char[64], not char[0]. */
        if (t->c0) {
            Node *dummy = xmod_node_alloc(ND_INTEGER);
            if (dummy) dummy->ival = t->c0->ival;
            n->c0 = dummy;
        }
        n->c1 = xmod_copy_typetree(t->c1);
        break;
    case ND_TPOINTER:
        n->c0 = xmod_copy_typetree(t->c0);
        break;
    case ND_TRECORD:
        n->c0 = xmod_copy_nodelist(t->c0);  /* field list */
        break;
    case ND_FIELD:
        n->c0 = xmod_copy_nodelist(t->c0);  /* ident list */
        n->c1 = xmod_copy_typetree(t->c1);  /* field type */
        break;
    case ND_TNAME:
    case ND_IDENT:
    default:
        break;
    }
    return n;
}

/* Collect type declarations from a library module into the persistent table.
 * Types are keyed by "RealModuleName_TypeName" so find_type_decl() can resolve
 * qualified references like "Alias.TypeName" via import_realname(). */
static void collect_xmod_type_decls(Node *decls, const char *modname) {
    for (Node *d = decls; d; d = d->next) {
        if (d->kind != ND_TYPE_DECL || !d->c0) continue;
        if (g_n_xmod_typedecls >= MAX_XMOD_TYPEDECLS) break;
        Node *td = xmod_node_alloc(ND_TYPE_DECL);
        if (!td) break;
        snprintf(td->str, MAX_IDENT, "%s_%s", modname, d->str);
        td->c0 = xmod_copy_typetree(d->c0);
        /* Qualify unqualified base type names in TRECORD nodes.
         * e.g. WindowRec = RECORD (ViewRec) stores "ViewRec" in str, but
         * cross-module lookup needs "TUI_ViewRec". */
        if (td->c0 && td->c0->kind == ND_TRECORD && td->c0->str[0]
                && !strchr(td->c0->str, '.') && !strchr(td->c0->str, '_')) {
            char qualified[MAX_IDENT];
            snprintf(qualified, sizeof(qualified), "%s_%s", modname, td->c0->str);
            strncpy(td->c0->str, qualified, MAX_IDENT-1);
        }
        g_xmod_typedecls[g_n_xmod_typedecls++] = td;
    }
}

/* -----------------------------------------------------------------------
 * Cross-module exported VAR declarations
 * Keyed "RealModName_VarName" → type node.  Local TNAME references in the
 * type are qualified with the module name so that is_ptr_type() can resolve
 * them via g_xmod_typedecls (e.g. "View" → "TUI_View").
 * ----------------------------------------------------------------------- */
static int is_builtin_type_name(const char *n) {
    return !strcmp(n,"INTEGER")||!strcmp(n,"CHAR")||!strcmp(n,"BOOLEAN")||
           !strcmp(n,"REAL")||!strcmp(n,"LONGREAL")||!strcmp(n,"LONGINT")||
           !strcmp(n,"STRING")||!strcmp(n,"BYTE")||!strcmp(n,"SET");
}

#define MAX_XMOD_VARDECLS 512
typedef struct { char name[MAX_IDENT*2]; Node *type; } XModVarDecl;
static XModVarDecl g_xmod_vardecls[MAX_XMOD_VARDECLS];
static int g_n_xmod_vardecls = 0;

static Node *lookup_xmod_var_type(const char *modname, const char *varname) {
    char key[MAX_IDENT*2];
    snprintf(key, sizeof(key), "%s_%s", modname, varname);
    for (int i = 0; i < g_n_xmod_vardecls; i++)
        if (!strcmp(g_xmod_vardecls[i].name, key)) return g_xmod_vardecls[i].type;
    return NULL;
}

static void collect_xmod_var_decls(Node *decls, const char *modname) {
    for (Node *d = decls; d; d = d->next) {
        if (d->kind != ND_VAR_DECL || !d->c1) continue;
        for (Node *id = d->c0; id; id = id->next) {
            if (!(id->flags & FLAG_EXPORTED)) continue;
            if (g_n_xmod_vardecls >= MAX_XMOD_VARDECLS) break;
            XModVarDecl *vd = &g_xmod_vardecls[g_n_xmod_vardecls++];
            snprintf(vd->name, sizeof(vd->name), "%s_%s", modname, id->str);
            /* Qualify local TNAME so the caller can resolve it via find_type_decl.
             * Direct TPOINTER nodes already satisfy bt->kind==ND_TPOINTER, so only
             * TNAME aliases (like View = POINTER TO …) need this treatment. */
            Node *t = d->c1;
            if (t && t->kind == ND_TNAME && !is_builtin_type_name(t->str)
                                         && !strchr(t->str, '_')) {
                Node *n = xmod_node_alloc(ND_TNAME);
                if (n) { snprintf(n->str, MAX_IDENT, "%s_%s", modname, t->str); }
                vd->type = n ? n : xmod_copy_typetree(t);
            } else {
                vd->type = xmod_copy_typetree(t);
            }
        }
    }
}

/* -----------------------------------------------------------------------
 * Nested-proc frame helpers
 * ----------------------------------------------------------------------- */
static int has_nested_procs(Node *proc) {
    for (Node *d=proc->c2;d;d=d->next)
        if (d->kind==ND_PROC_DECL) return 1;
    return 0;
}

/* Fill g->frame_* with all params + locals of proc. */
static void build_frame(CG *g, Node *proc) {
    g->n_frame = 0;
    strncpy(g->outer_proc_name, proc->str, MAX_IDENT-1);
    for (Node *fp=proc->c0;fp;fp=fp->next) {
        int isv=(fp->flags&FLAG_VAR_PARAM)!=0;
        for (Node *id=fp->c0;id;id=id->next) {
            if (g->n_frame>=128) break;
            strncpy(g->frame_names[g->n_frame],id->str,MAX_IDENT-1);
            g->frame_types[g->n_frame]=fp->c1;
            g->frame_is_var[g->n_frame]=isv;
            g->n_frame++;
        }
    }
    for (Node *d=proc->c2;d;d=d->next) {
        if (d->kind!=ND_VAR_DECL) continue;
        for (Node *id=d->c0;id;id=id->next) {
            if (g->n_frame>=128) break;
            strncpy(g->frame_names[g->n_frame],id->str,MAX_IDENT-1);
            g->frame_types[g->n_frame]=d->c1;
            g->frame_is_var[g->n_frame]=0;
            g->n_frame++;
        }
    }
}

static void collect_nested_names(CG *g, Node *proc) {
    g->n_nested_procs=0;
    for (Node *d=proc->c2;d;d=d->next)
        if (d->kind==ND_PROC_DECL && g->n_nested_procs<32)
            strncpy(g->nested_proc_names[g->n_nested_procs++],d->str,MAX_IDENT-1);
}

static int is_nested_call(CG *g, const char *name) {
    for (int i=0;i<g->n_nested_procs;i++)
        if (!strcmp(g->nested_proc_names[i],name)) return 1;
    return 0;
}

/* Is this variable from the outer proc's scope (not shadowed locally)? */
static int is_outer_var(CG *g, const char *name) {
    if (!g->in_nested_proc || g->n_frame==0) return 0;
    int in_frame=0;
    for (int i=0;i<g->n_frame;i++)
        if (!strcmp(g->frame_names[i],name)) { in_frame=1; break; }
    if (!in_frame) return 0;
    /* Shadowed by nested proc's own vars? */
    for (int i=g->nested_sym_start;i<g_nsyms;i++)
        if (!strcmp(g_syms[i].name,name)) return 0;
    return 1;
}

static int outer_var_is_array(CG *g, const char *name) {
    for (int i=0;i<g->n_frame;i++) {
        if (!strcmp(g->frame_names[i],name)) {
            Node *t=g->frame_types[i];
            return t && (t->kind==ND_TARRAY ||
                         (t->kind==ND_TNAME&&!strcmp(t->str,"STRING")));
        }
    }
    return 0;
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
    "Out","In","Terminal","Strings","Files","Args","Dict","Zip",
    "Env","OS","Time",NULL
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
    if (!strcmp(name,"Zip.Archive"))  return "Zip_Archive";
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

/* Walk a TRECORD's field list and return the type of field named 'fname'. */
static Node *find_field_type(Node *rec, const char *fname) {
    for (Node *f = rec->c0; f; f = f->next) {
        if (f->kind != ND_FIELD) continue;
        for (Node *id = f->c0; id; id = id->next)
            if (!strcmp(id->str, fname)) return f->c1;
    }
    return NULL;
}

/* Resolve a named type to the underlying type node (one level of typedef). */
static Node *resolve_named_type(const char *tname) {
    Node *td = find_type_decl(tname);
    return td ? td->c0 : NULL;
}

/* Best-effort type of an expression (for WRITE/assign/comparison decisions) */
static Node *expr_type(Node *e) {
    if (!e) return NULL;
    if (e->kind == ND_IDENT)   return sym_type(e->str);
    if (e->kind == ND_INTEGER) { static Node t={ND_TNAME}; strcpy(t.str,"INTEGER"); return &t; }
    if (e->kind == ND_REAL)    { static Node t={ND_TNAME}; strcpy(t.str,"REAL");    return &t; }
    if (e->kind == ND_CHAR)    { static Node t={ND_TNAME}; strcpy(t.str,"CHAR");    return &t; }
    if (e->kind == ND_TRUE || e->kind == ND_FALSE) {
        static Node t={ND_TNAME}; strcpy(t.str,"BOOLEAN"); return &t;
    }
    if (e->kind == ND_STRING) {
        static Node arr={ND_TARRAY}, ch={ND_TNAME};
        strcpy(ch.str,"CHAR"); arr.c0=NULL; arr.c1=&ch;
        return &arr;
    }
    if (e->kind == ND_INDEX) {
        Node *bt = expr_type(e->c0);
        if (bt && bt->kind == ND_TARRAY) return bt->c1;
        return NULL;
    }
    if (e->kind == ND_CALL) {
        /* Only works for local procs registered in g_procsigs */
        Node *proc = e->c0;
        if (proc && proc->kind == ND_IDENT)
            return lookup_proc_rettype(proc->str);
        return NULL;
    }
    if (e->kind == ND_FIELD_ACCESS) {
        /* Cross-module exported variable: Mod.VarName → look up its type. */
        if (e->c0 && e->c0->kind == ND_IDENT && is_import(e->c0->str)) {
            const char *real = import_realname(e->c0->str);
            Node *t = lookup_xmod_var_type(real, e->str);
            if (t) return t;
        }
        Node *bt = expr_type(e->c0);
        if (!bt) return NULL;
        /* Unwrap pointer: POINTER TO Foo → look up Foo */
        if (bt->kind == ND_TPOINTER) bt = bt->c0;
        /* Resolve a named type to its underlying TRECORD */
        Node *rec = NULL;
        if (bt && bt->kind == ND_TRECORD) {
            rec = bt;
        } else if (bt && bt->kind == ND_TNAME) {
            Node *ut = resolve_named_type(bt->str);
            if (ut && ut->kind == ND_TRECORD)       rec = ut;
            else if (ut && ut->kind == ND_TPOINTER) {
                Node *inner = ut->c0;
                if (inner && inner->kind == ND_TNAME)
                    ut = resolve_named_type(inner->str);
                else
                    ut = inner;
                if (ut && ut->kind == ND_TRECORD) rec = ut;
            }
        }
        if (rec) return find_field_type(rec, e->str);
        return NULL;
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
    case ND_TPROC:
        /* For use as a plain type prefix (e.g. in casts), emit return type */
        if (t->c1) emit_type_prefix(g,t->c1); else emit(g,"void");
        break;
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
    /* Procedure-type variable: rettype (*name)(params)  */
    if (t && t->kind==ND_TPROC) {
        if (t->c1) emit_type_prefix(g,t->c1); else emit(g,"void");
        if (is_var) emit(g," (**%s)(",name); else emit(g," (*%s)(",name);
        if (!t->c0) { emit(g,"void"); }
        else {
            int first=1;
            for (Node *fp=t->c0;fp;fp=fp->next) {
                int isv=(fp->flags&FLAG_VAR_PARAM)!=0;
                for (Node *id=fp->c0;id;id=id->next) {
                    if (!first) emit(g,", ");
                    emit_var_decl_raw(g,id->str,fp->c1,isv);
                    first=0;
                }
            }
        }
        emit(g,")");
        return;
    }
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
           !strcasecmp(n,"ODD")||!strcasecmp(n,"ORD")||!strcasecmp(n,"CHR")||!strcasecmp(n,"CAP")||
           !strcasecmp(n,"FLOOR")||!strcasecmp(n,"INCL")||!strcasecmp(n,"EXCL")||
           !strcasecmp(n,"LEN")||!strcasecmp(n,"WRITE")||!strcasecmp(n,"READ")||
           !strcasecmp(n,"WRITELN")||!strcasecmp(n,"COPY")||
           !strcasecmp(n,"FLT")||!strcasecmp(n,"ASR")||!strcasecmp(n,"LSL")||
           !strcasecmp(n,"ROR")||!strcasecmp(n,"PACK")||!strcasecmp(n,"UNPK");
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
        /* NEW(p) — fixed type: calloc(1, sizeof(*p))
         * NEW(p, n) — dynamic array: calloc(n, sizeof((*p)[0])) */
        if (a1) {
            /* POINTER TO ARRAY OF T: allocate n elements of the element type.
             * We must look up the element type from the AST because the C type
             * for POINTER TO ARRAY OF CHAR collapses to char*, making both
             * sizeof(*p) and sizeof(**p) unreliable. */
            const char *elem_ctype = "char"; /* sensible default */
            if (a0->kind == ND_IDENT) {
                Node *pt = sym_type(a0->str);
                if (pt && pt->kind == ND_TPOINTER && pt->c0 && pt->c0->kind == ND_TARRAY) {
                    Node *elem = pt->c0->c1; /* element type of the array */
                    if (elem && elem->kind == ND_TNAME) elem_ctype = ctype(elem->str);
                }
            } else {
                /* Field access or index: try expr_type */
                Node *pt = expr_type(a0);
                if (pt && pt->kind == ND_TPOINTER && pt->c0 && pt->c0->kind == ND_TARRAY) {
                    Node *elem = pt->c0->c1;
                    if (elem && elem->kind == ND_TNAME) elem_ctype = ctype(elem->str);
                }
            }
            emit_expr(g,a0); emit(g," = calloc("); emit_expr(g,a1);
            emit(g,", sizeof(%s))", elem_ctype);
        } else {
            emit_expr(g,a0); emit(g," = calloc(1, sizeof(*"); emit_expr(g,a0); emit(g,"))");
            /* Set _tag if we can determine the pointed-to record type */
            if (a0 && a0->kind==ND_IDENT) {
                const char *recname = NULL;
                int is_xmod_rec = 0;
                Node *pt = sym_type(a0->str);
                if (pt && pt->kind==ND_TPOINTER && pt->c0 && pt->c0->kind==ND_TNAME)
                    recname = pt->c0->str;
                else if (pt && pt->kind==ND_TNAME) {
                    Node *alias = find_type_decl(pt->str);
                    if (alias && alias->c0 && alias->c0->kind==ND_TPOINTER &&
                        alias->c0->c0 && alias->c0->c0->kind==ND_TNAME) {
                        const char *dot = strchr(pt->str, '.');
                        if (dot) {
                            char modalias[MAX_IDENT];
                            int modlen = (int)(dot - pt->str);
                            if (modlen >= MAX_IDENT) modlen = MAX_IDENT - 1;
                            strncpy(modalias, pt->str, modlen); modalias[modlen] = '\0';
                            static char xmod_recname[MAX_IDENT*2];
                            snprintf(xmod_recname, sizeof(xmod_recname), "%s_%s",
                                     import_realname(modalias), alias->c0->c0->str);
                            recname = xmod_recname;
                            is_xmod_rec = 1;
                        } else {
                            recname = alias->c0->c0->str;
                        }
                    }
                }
                if (recname && (is_xmod_rec || is_known_record_type(recname))) {
                    emit(g,"; if("); emit_expr(g,a0);
                    emit(g,") ("); emit_expr(g,a0);
                    emit(g,")->_tag = _TAG_%s", recname);
                }
            }
        }
        
    } else if (!strcasecmp(name,"HALT")) {
        emit(g,"exit("); if(a0) emit_expr(g,a0); else emit(g,"0"); emit(g,")");
    } else if (!strcasecmp(name,"ASSERT")) {
        emit(g,"assert("); if(a0) emit_expr(g,a0); emit(g,")");
    } else if (!strcasecmp(name,"ABS")) {
        Node *t = a0 ? expr_type(a0) : NULL;
        int is_real = t && t->kind==ND_TNAME &&
                      (!strcmp(t->str,"REAL")||!strcmp(t->str,"LONGREAL"));
        if (is_real) { emit(g,"fabs("); if(a0) emit_expr(g,a0); emit(g,")"); }
        else         { emit(g,"abs(");  if(a0) emit_expr(g,a0); emit(g,")"); }
    } else if (!strcasecmp(name,"ODD")) {
        emit(g,"(("); if(a0) emit_expr(g,a0); emit(g,") & 1)");
    } else if (!strcasecmp(name,"ORD")) {
        emit(g,"((int)(unsigned char)("); if(a0) emit_expr(g,a0); emit(g,"))");
    } else if (!strcasecmp(name,"CHR")) {
        emit(g,"((char)("); if(a0) emit_expr(g,a0); emit(g,"))");
    } else if (!strcasecmp(name,"CAP")) {
        emit(g,"((char)toupper((unsigned char)("); if(a0) emit_expr(g,a0); emit(g,")))");
    } else if (!strcasecmp(name,"FLOOR")) {
        emit(g,"((int)floor("); if(a0) emit_expr(g,a0); emit(g,"))");
    } else if (!strcasecmp(name,"INCL")) {
        if(a0) emit_expr(g,a0); emit(g," |= (1u << ("); if(a1) emit_expr(g,a1); emit(g,"))");
    } else if (!strcasecmp(name,"EXCL")) {
        if(a0) emit_expr(g,a0); emit(g," &= ~(1u << ("); if(a1) emit_expr(g,a1); emit(g,"))");
    } else if (!strcasecmp(name,"LEN")) {
        /* Open array param → use hidden _len; fixed array → sizeof trick */
        if (a0 && a0->kind==ND_IDENT && is_open_array(sym_type(a0->str))) {
            emit(g,"%s_len", a0->str);
        } else {
            emit(g,"(int)(sizeof("); if(a0) emit_expr(g,a0);
            emit(g,")/sizeof("); if(a0) emit_expr(g,a0); emit(g,"[0]))");
        }
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
    } else if (!strcasecmp(name,"FLT")) {
        emit(g,"(double)("); if(a0) emit_expr(g,a0); emit(g,")");
    } else if (!strcasecmp(name,"ASR")) {
        /* Arithmetic shift right: (int)(x) >> (n & 31) */
        emit(g,"((int)("); if(a0) emit_expr(g,a0);
        emit(g,") >> (("); if(a1) emit_expr(g,a1); emit(g,") & 31))");
    } else if (!strcasecmp(name,"LSL")) {
        /* Logical shift left */
        emit(g,"(int)((unsigned int)("); if(a0) emit_expr(g,a0);
        emit(g,") << (("); if(a1) emit_expr(g,a1); emit(g,") & 31))");
    } else if (!strcasecmp(name,"ROR")) {
        /* Rotate right */
        emit(g,"(int)(((unsigned int)("); if(a0) emit_expr(g,a0);
        emit(g,") >> (("); if(a1) emit_expr(g,a1); emit(g,") & 31)) | ");
        emit(g,"((unsigned int)("); if(a0) emit_expr(g,a0);
        emit(g,") << ((32 - (("); if(a1) emit_expr(g,a1); emit(g,") & 31)) & 31)))");
    } else if (!strcasecmp(name,"PACK") || !strcasecmp(name,"UNPK")) {
        /* PACK/UNPK are proper procedures — handled in emit_stmt.
         * Reaching here means they appeared in expression context, which is
         * not valid Oberon; emit a best-effort no-op. */
        if(a0) emit_expr(g,a0);
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
/* Is this type node an open array (ARRAY OF T with no bound)? */
static int is_open_array(Node *t) { return t && t->kind==ND_TARRAY && !t->c0; }

/* Emit the runtime length of an array argument being passed to an open array
 * formal parameter.  If the argument is itself an open array param, forward
 * its hidden _len; otherwise compute from sizeof at compile time. */
/* Emit the capacity of a STRING/array arg for Strings_Append.
 * STRING formal params decay to char* so sizeof gives pointer size (8), not 256;
 * detect that case and emit the literal 256 instead. */
static void emit_string_capacity(CG *g, Node *arg) {
    /* Unwrap a ^ dereference — the capacity comes from the allocation size,
     * which for POINTER TO ARRAY OF CHAR we must get from the pointer's
     * declared type since sizeof(char*) is just the pointer size (8). */
    Node *inner = (arg && arg->kind == ND_DEREF) ? arg->c0 : arg;

    if (inner && inner->kind == ND_IDENT) {
        Node *t = sym_type(inner->str);
        /* Direct STRING variable */
        if (t && t->kind == ND_TNAME && !strcmp(t->str, "STRING"))
            { emit(g, "256"); return; }
        /* Open-array VAR param */
        if (is_open_array(t))
            { emit(g, "%s_len", inner->str); return; }
        /* POINTER TO ARRAY OF CHAR: emit the array bound from the type */
        if (t && t->kind == ND_TPOINTER && t->c0 && t->c0->kind == ND_TARRAY) {
            Node *bound = t->c0->c0; /* the size expression */
            if (bound) { emit_expr(g, bound); return; }
        }
        /* Named pointer type e.g. SeqData = POINTER TO ARRAY OF CHAR */
        if (t && t->kind == ND_TNAME) {
            Node *td = find_type_decl(t->str);
            if (td && td->c0 && td->c0->kind == ND_TPOINTER &&
                td->c0->c0 && td->c0->c0->kind == ND_TARRAY) {
                Node *bound = td->c0->c0->c0;
                if (bound) { emit_expr(g, bound); return; }
            }
        }
    }
    /* For a deref of a non-ident (e.g. seqs[i].data^), try expr_type on inner */
    if (arg && arg->kind == ND_DEREF) {
        Node *pt = expr_type(inner);
        if (pt && pt->kind == ND_TPOINTER && pt->c0 && pt->c0->kind == ND_TARRAY) {
            Node *bound = pt->c0->c0;
            if (bound) { emit_expr(g, bound); return; }
        }
        /* expr_type failed but we know it's a dynamic array pointer —
         * emit maxLen directly as the capacity variable name is not available,
         * so fall back to the allocation argument if we can find it.
         * Best we can do without type info: use a large safe constant. */
        emit(g, "maxLen"); /* module-level variable holding the allocation size */
        return;
    }
    emit(g, "sizeof("); emit_expr(g, arg); emit(g, ")");
}

static void emit_open_array_len(CG *g, Node *arg) {
    if (arg && arg->kind == ND_IDENT) {
        Node *t = sym_type(arg->str);
        if (is_open_array(t)) {
            emit(g, "%s_len", arg->str);
            return;
        }
    }
    emit(g, "(int)(sizeof("); emit_as_string(g, arg);
    emit(g, ")/sizeof(");     emit_as_string(g, arg); emit(g, "[0]))");
}

static void emit_addr_of(CG *g, Node *e) {
    if (!e) { emit(g,"NULL"); return; }
    if (e->kind == ND_IDENT) {
        if (is_outer_var(g, e->str)) {
            /* Frame member is already a pointer; return it directly */
            emit(g,"_frame->%s", e->str); return;
        }
        if (sym_is_var(e->str)) { emit(g,"%s",e->str); return; }
        { Node *t = sym_type(e->str);
          if (t && t->kind==ND_TNAME) {
              Node *td = find_type_decl(t->str);
              if (td) t = td->c0;
          }
          if (t && t->kind==ND_TPOINTER) { emit(g,"%s",e->str); return; } }
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
        if (!strcmp(proc,"Int"))    { emit(g,"scanf(\"%%d\",&"); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Real"))   { emit(g,"scanf(\"%%lf\",&"); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Char"))   { emit(g,"("); emit_expr(g,a0); emit(g," = (char)getchar())"); return 1; }
        if (!strcmp(proc,"String")) {
					emit(g, "({ static char _buf[256]; ");
					emit(g, "fflush(stdout); ");
					emit(g, "if (fgets(_buf, sizeof(_buf), stdin)) { ");
					emit(g, "  size_t l = strlen(_buf); ");
					emit(g, "  if (l > 0 && _buf[l-1] == '\\n') _buf[l-1] = 0; ");
					emit(g, "  strncpy("); emit_expr(g, a0); emit(g, ", _buf, 255); ");
					emit(g, "}})");
					return 1;
				}
				if (!strcmp(proc, "Line")) {
					/* Use an inline block to handle the buffer sync issue */
					emit(g, "({ ");
					emit(g, "  int c; char *p = "); emit_expr(g, a0); emit(g, "; ");
					emit(g, "  int i = 0; fflush(stdout); ");
					/* 1. Skip any leftover newlines or carriage returns from the menu */
					emit(g, "  while ((c = getchar()) == '\\n' || c == '\\r'); ");
					/* 2. Read the actual input until the next newline */
					emit(g, "  if (c != EOF) p[i++] = (char)c; ");
					emit(g, "  while (i < 255 && (c = getchar()) != '\\n' && c != '\\r' && c != EOF) ");
					emit(g, "    p[i++] = (char)c; ");
					emit(g, "  p[i] = 0; ");
					emit(g, "})");
					return 1;
				}
    }
    /* Strings module */
    if (!strcmp(mod,"Strings")) {
        Node *a2=a1?a1->next:NULL;
        if (!strcmp(proc,"Length"))  { emit(g,"Strings_Length(");  emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Append"))  { emit(g,"Strings_Append(");  emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_string_capacity(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Copy"))    { emit(g,"Strings_Copy(");    emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_string_capacity(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Compare")) { emit(g,"Strings_Compare("); emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Pos"))      { emit(g,"Strings_PosFrom(");   emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,","); if (a2) emit_expr(g,a2); else emit(g,"0"); emit(g,")"); return 1; }
        if (!strcmp(proc,"Extract"))  { emit(g,"Strings_Extract(");   emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,","); emit_expr(g,a2->next); emit(g,")"); return 1; }
        if (!strcmp(proc,"NextWord")) { emit(g,"Strings_NextWord(");   emit_as_string(g,a0); emit(g,",&"); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"Insert"))   { emit(g,"Strings_Insert(");    emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"Delete"))   { emit(g,"Strings_Delete(");    emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"Replace"))  { emit(g,"Strings_Replace(");   emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"ToUpper"))   { emit(g,"Strings_ToUpper(");    emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"ToLower"))   { emit(g,"Strings_ToLower(");    emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Trim"))      { emit(g,"Strings_Trim(");       emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"IntToStr"))  { emit(g,"Strings_IntToStr(");   emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_open_array_len(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"RealToStr")) { emit(g,"Strings_RealToStr(");  emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_open_array_len(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"StrToInt"))    { emit(g,"Strings_StrToInt(");    emit_as_string(g,a0); emit(g,",&"); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"StrToReal"))   { emit(g,"Strings_StrToReal(");   emit_as_string(g,a0); emit(g,",&"); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"StartsWith"))  { emit(g,"Strings_StartsWith(");  emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"EndsWith"))    { emit(g,"Strings_EndsWith(");    emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Split")) {
            Node *a3 = a2 ? a2->next : NULL;
            emit(g,"Strings_Split("); emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,","); emit_expr(g,a3); emit(g,")"); return 1;
        }
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
        if (!strcmp(proc,"Delete"))      { emit(g,"Files_Delete(");      emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Rename"))      { emit(g,"Files_Rename(");      emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Exists"))      { emit(g,"Files_Exists(");      emit_as_string(g,a0); emit(g,")"); return 1; }
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
        if (!strcmp(proc,"ReadLine"))    { emit(g,"Files_ReadLine(");    emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"ReadNum"))     { emit(g,"Files_ReadNum(");     emit_addr_of(g,a0); emit(g,","); emit_addr_of(g,a1); emit(g,")"); return 1; }
        /* Write procedures — VAR r, x by value  (string: const char*) */
        if (!strcmp(proc,"Write"))       { emit(g,"Files_Write(");       emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteInt"))    { emit(g,"Files_WriteInt(");    emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteBool"))   { emit(g,"Files_WriteBool(");   emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteReal"))   { emit(g,"Files_WriteReal(");   emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteString")) { emit(g,"Files_WriteString("); emit_addr_of(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteLine"))   { emit(g,"Files_WriteLine(");   emit_addr_of(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"WriteNum"))    { emit(g,"Files_WriteNum(");    emit_addr_of(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
    }
    /* Args module */
    if (!strcmp(mod,"Args")) {
        Node *a2=a1?a1->next:NULL; (void)a2;
        if (!strcmp(proc,"Count")) { emit(g,"Args_Count()"); return 1; }
        if (!strcmp(proc,"Get"))   {
            emit(g,"Args_Get("); emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")");
            return 1;
        }
        if (!strcmp(proc,"GetEnv")) {
            emit(g,"Args_GetEnv("); emit_as_string(g,a0); emit(g,","); emit_expr(g,a1);
            emit(g,","); emit_open_array_len(g,a1); emit(g,")");
            return 1;
        }
        if (!strcmp(proc,"ExeDir")) {
            emit(g,"Args_ExeDir("); emit_expr(g,a0); emit(g,")");
            return 1;
        }
    }
    /* Dict module — string-keyed hash table */
    if (!strcmp(mod,"Dict")) {
        Node *a2 = a1 ? a1->next : NULL;
        if (!strcmp(proc,"Init"))   { emit(g,"Dict_Init(&");   emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Put"))    { emit(g,"Dict_Put(&");    emit_expr(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,","); emit_as_string(g,a1->next); emit(g,")"); return 1; }
        if (!strcmp(proc,"Get"))    { emit(g,"Dict_Get(&");    emit_expr(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,","); emit_expr(g,a1->next); emit(g,")"); return 1; }
        if (!strcmp(proc,"Has"))    { emit(g,"Dict_Has(&");    emit_expr(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Remove")) { emit(g,"Dict_Remove(&"); emit_expr(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Clear"))  { emit(g,"Dict_Clear(&");  emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"First"))  { emit(g,"Dict_First(&");  emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"Next"))   { emit(g,"Dict_Next(&");   emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
    }
    /* Zip module — ZIP archive reading */
    if (!strcmp(mod,"Zip")) {
        Node *a2 = a1 ? a1->next : NULL;
        if (!strcmp(proc,"Open"))        { emit(g,"Zip_Open(");        emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Count"))       { emit(g,"Zip_Count(");       emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"EntryName"))   { emit(g,"Zip_EntryName(");   emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"EntrySize"))   { emit(g,"Zip_EntrySize(");   emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Find"))        { emit(g,"Zip_Find(");        emit_expr(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"Extract"))     { emit(g,"Zip_Extract(");     emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_expr(g,a2); emit(g,","); emit_open_array_len(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"ExtractFile")) { emit(g,"Zip_ExtractFile("); emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_as_string(g,a2); emit(g,")"); return 1; }
        if (!strcmp(proc,"Close"))       { emit(g,"Zip_Close(");       emit_expr(g,a0); emit(g,")"); return 1; }
    }
    /* Env module — environment variable access */
    if (!strcmp(mod,"Env")) {
        if (!strcmp(proc,"Get")) {
            emit(g,"Env_Get("); emit_as_string(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_open_array_len(g,a1); emit(g,")"); return 1;
        }
    }
    /* OS module — basic OS calls */
    if (!strcmp(mod,"OS")) {
        Node *a2 = a1 ? a1->next : NULL; (void)a2;
        if (!strcmp(proc,"Exec"))    { emit(g,"OS_Exec(");    emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Exit"))    { emit(g,"exit(");       emit_expr(g,a0);      emit(g,")"); return 1; }
        if (!strcmp(proc,"GetCwd"))  { emit(g,"OS_GetCwd(");  emit_expr(g,a0); emit(g,","); emit_open_array_len(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"ChDir"))   { emit(g,"OS_ChDir(");   emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"DirOpen")) { emit(g,"OS_DirOpen("); emit_as_string(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"DirCount")){ emit(g,"OS_DirCount()"); return 1; }
        if (!strcmp(proc,"DirName")) { emit(g,"OS_DirName("); emit_expr(g,a0); emit(g,","); emit_expr(g,a1); emit(g,","); emit_open_array_len(g,a1); emit(g,")"); return 1; }
        if (!strcmp(proc,"DirIsDir"))     { emit(g,"OS_DirIsDir("); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"ClipWriteFile")){ emit(g,"OS_ClipWriteFile("); emit_as_string(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"ClipPasteCmd")) { emit(g,"OS_ClipPasteCmd("); emit_as_string(g,a0); emit(g,")"); return 1; }
    }
    /* Time module — time, formatting, sleep */
    if (!strcmp(mod,"Time")) {
        Node *a2 = a1 ? a1->next : NULL;
        if (!strcmp(proc,"Now"))    { emit(g,"Time_Now()"); return 1; }
        if (!strcmp(proc,"Sleep"))  { emit(g,"Time_Sleep("); emit_expr(g,a0); emit(g,")"); return 1; }
        if (!strcmp(proc,"Format")) {
            /* Format(t, fmt, VAR s) */
            emit(g,"Time_Format("); emit_expr(g,a0); emit(g,","); emit_as_string(g,a1); emit(g,","); emit_expr(g,a2); emit(g,","); emit_open_array_len(g,a2); emit(g,")");
            return 1;
        }
        (void)a2;
    }
    /* Terminal.Shell — restore terminal, run command, wait, reinit */
		/* Terminal.Shell — restore terminal, run command, wait, reinit */
    if (!strcmp(mod,"Terminal") && !strcmp(proc,"Shell")) {
        emit(g,"(_term_restore(), system("); emit_expr(g,a0);
        emit(g,"), printf(\"\\n-- Press Enter to return --\"), fflush(stdout),"
               "(void)getchar(), _term_init())");
        return 1;
    }
    if (!strcmp(mod,"Terminal") && !strcmp(proc,"Restore")) {
        emit(g,"_term_restore()"); return 1;
    }
    if (!strcmp(mod,"Terminal") && !strcmp(proc,"Init")) {
        emit(g,"Terminal_Init()"); return 1;
    }
    
    /* Unknown import call → RealModule_Proc(args)  (resolves aliases) */
    const char *real = import_realname(mod);
    emit(g,"%s_%s(",real,proc);
    {
        XModProcSig *sig = lookup_xmod_proc_params(real, proc);
        int slot = 0;
        for (Node *a=args;a;a=a->next) {
            if (a!=args) emit(g,",");
            int is_var = (sig && slot < sig->nslots) ? sig->slots[slot].is_var        : 0;
            int ioa    = (sig && slot < sig->nslots) ? sig->slots[slot].is_open_array  : 0;
            if (is_var)   emit_addr_of(g, a);
            else if (ioa) emit_as_string(g, a);
            else          emit_expr(g, a);
            if (ioa) { emit(g,","); emit_open_array_len(g,a); }
            slot++;
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
        else if (e->ival==39)  emit(g,"'\\''");
        else if (e->ival>=32 && e->ival<127) emit(g,"'%c'",(char)e->ival);
        else emit(g,"'\\x%02X'",(unsigned)e->ival);
        break;
    case ND_NIL:   emit(g,"NULL");  break;
    case ND_TRUE:  emit(g,"1");     break;
    case ND_FALSE: emit(g,"0");     break;
    case ND_IDENT: {
        /* Outer scope variable accessed through nested-proc frame */
        if (is_outer_var(g, e->str)) {
            if (outer_var_is_array(g, e->str))
                emit(g,"(_frame->%s)", e->str);   /* array: no extra deref */
            else
                emit(g,"(*(_frame->%s))", e->str);
            break;
        }
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
    case ND_DIVI:emit(g,"_OBC_DIV(");emit_expr(g,e->c0);emit(g,",");emit_expr(g,e->c1);emit(g,")");break;
    case ND_MOD: emit(g,"_OBC_MOD(");emit_expr(g,e->c0);emit(g,",");emit_expr(g,e->c1);emit(g,")");break;
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
    case ND_IS:
        /* v IS T — runtime type test via _tag */
        {
            char _tbuf[MAX_IDENT*2];
            const char *_tn = tag_cname(e->c1->str, _tbuf, sizeof(_tbuf));
            emit(g,"(");
            emit_addr_of(g,e->c0);
            emit(g," && (");
            emit_addr_of(g,e->c0);
            emit(g,")->_tag == _TAG_%s)", _tn);
        }
        break;
    case ND_DEREF: emit_expr(g, e->c0); break;
    case ND_INDEX:
        emit_expr(g,e->c0); emit(g,"["); emit_expr(g,e->c1); emit(g,"]");
        break;
    case ND_FIELD_ACCESS:
        /* Module constants / variables (e.g. Utils.count) */
        if (e->c0 && e->c0->kind==ND_IDENT && is_import(e->c0->str)) {
            const char *real = import_realname(e->c0->str);
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
            int use_arrow = (bt && bt->kind==ND_TPOINTER) ||
                            (bt && bt->kind==ND_TNAME && is_ptr_type(bt->str));
            if (use_arrow) emit(g,"->%s",e->str);
            else emit(g,".%s",e->str);
        }
        break;
    case ND_CALL: {
        /* Type guard: v(T) — single ident arg that is a known record type */
        if (e->c0 && e->c0->kind==ND_IDENT &&
            e->c1 && !e->c1->next && e->c1->kind==ND_IDENT &&
            is_known_record_type(e->c1->str)) {
            const char *tn = e->c1->str;
            emit(g,"((assert(");
            emit_expr(g,e->c0);
            emit(g," && (");
            emit_expr(g,e->c0);
            emit(g,")->_tag == _TAG_%s), (%s*)(", tn, ctype(tn));
            emit_expr(g,e->c0);
            emit(g,")))");
            break;
        }
        /* Check for import call */
        if (try_emit_import(g, e->c0, e->c1)) break;
        /* Check for builtin */
        if (e->c0 && e->c0->kind==ND_IDENT && is_builtin(e->c0->str)) {
            emit_builtin(g, e->c0->str, e->c1); break;
        }
        /* Normal call */
        emit_expr(g,e->c0); emit(g,"(");
        int first_arg = 1;
        /* Nested proc call: prepend frame pointer (only when frame exists) */
        if (e->c0 && e->c0->kind==ND_IDENT && is_nested_call(g, e->c0->str) && g->n_frame > 0) {
            if (g->in_nested_proc) emit(g,"_frame");
            else                   emit(g,"&_frame");
            first_arg = 0;
        }
        /* Use the proc signature table to know which args are VAR params */
        Node *params = lookup_callee_params(e->c0);
        Node *fp    = params;
        Node *fp_id = fp ? fp->c0 : NULL;
        for (Node *a=e->c1;a;a=a->next) {
            if (!first_arg) emit(g,",");
            first_arg = 0;
            int is_var = fp ? (fp->flags & FLAG_VAR_PARAM) != 0 : 0;
            int ioa    = fp ? is_open_array(fp->c1) : 0;
            if (is_var) emit_addr_of(g, a);
            else if (ioa) emit_as_string(g, a);
            else          emit_expr(g, a);
            if (fp && ioa) { emit(g,","); emit_open_array_len(g,a); }
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

static void emit_line(CG *g, int line) {
    if (line > 0 && line != g->last_line && g->srcfile[0]) {
        emit(g, "#line %d \"%s\"\n", line, g->srcfile);
        g->last_line = line;
    }
}

static void emit_stmt(CG *g, Node *s) {
    if (!s) return;
    emit_line(g, s->line);
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
        /* Check if LHS is a non-char array type (named or direct) → memcpy */
        int is_arr = 0;
        if (!is_str) {
            Node *arr_t = lt;
            if (arr_t && arr_t->kind == ND_TNAME) {
                Node *td = find_type_decl(arr_t->str);
                if (td && td->c0) arr_t = td->c0;
            }
            if (arr_t && arr_t->kind == ND_TARRAY && !is_char_array(arr_t))
                is_arr = 1;
        }
        if (is_str) {
            iemit(g,"strcpy("); emit_expr(g,lhs); emit(g,",");
            /* Always emit RHS as string literal for strcpy */
            if (rhs->kind == ND_STRING) emit_string_lit(g, rhs->str);
            else emit_expr(g,rhs);
            emit(g,");\n");
        } else if (is_arr) {
            iemit(g,"memcpy("); emit_expr(g,lhs); emit(g,",");
            emit_expr(g,rhs); emit(g,",sizeof("); emit_expr(g,lhs); emit(g,"));\n");
        } else {
            iemit(g,""); emit_expr(g,lhs);
            emit(g," = "); emit_expr(g,rhs); emit(g,";\n");
        }
        break;
    }

    case ND_CALL: {
        /* Check for import procedure call */
        if (s->c0 && try_emit_import(g, s->c0, s->c1)) { emit(g,";\n"); break; }
        /* PACK(x, n) → x = ldexp(x, n)  [VAR x: REAL; n: INTEGER] */
        if (s->c0 && s->c0->kind==ND_IDENT && !strcasecmp(s->c0->str,"PACK")) {
            Node *a0=s->c1, *a1=a0?a0->next:NULL;
            iemit(g,""); emit_expr(g,a0); emit(g," = ldexp(");
            emit_expr(g,a0); emit(g,", "); if(a1) emit_expr(g,a1); emit(g,");\n");
            break;
        }
        /* UNPK(x, n) → x := mantissa in [1,2), n := exponent  (frexp returns [0.5,1)) */
        if (s->c0 && s->c0->kind==ND_IDENT && !strcasecmp(s->c0->str,"UNPK")) {
            Node *a0=s->c1, *a1=a0?a0->next:NULL;
            iemit(g,"{ int _obc_e; ");
            emit_expr(g,a0); emit(g," = frexp("); emit_expr(g,a0); emit(g,", &_obc_e) * 2.0; ");
            if(a1) emit_expr(g,a1); emit(g," = _obc_e - 1; }\n");
            break;
        }
        /* Built-in procedure call */
        if (s->c0 && s->c0->kind==ND_IDENT && is_builtin(s->c0->str)) {
            iemit(g,""); emit_builtin(g, s->c0->str, s->c1); emit(g,";\n"); break;
        }
        /* Regular procedure call */
        iemit(g,""); emit_expr(g,s->c0); emit(g,"(");
        {
            int first_s = 1;
            if (s->c0 && s->c0->kind==ND_IDENT && is_nested_call(g,s->c0->str) && g->n_frame > 0) {
                if (g->in_nested_proc) emit(g,"_frame");
                else                   emit(g,"&_frame");
                first_s = 0;
            }
            Node *params = lookup_callee_params(s->c0);
            Node *fp    = params;
            Node *fp_id = fp ? fp->c0 : NULL;
            for (Node *a=s->c1;a;a=a->next) {
                if (!first_s) emit(g,",");
                first_s = 0;
                int is_var = fp ? (fp->flags & FLAG_VAR_PARAM) != 0 : 0;
                int ioa    = fp ? is_open_array(fp->c1) : 0;
                if (is_var)   emit_addr_of(g, a);
                else if (ioa) emit_as_string(g, a);  /* single-char "x" must stay "x", not 'x' */
                else          emit_expr(g, a);
                if (fp && ioa) { emit(g,","); emit_open_array_len(g,a); }
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
        /* Hoist the case expression into a temp so it is evaluated exactly once.
         * Without this, function-call expressions (e.g. Random.Int(5)) would be
         * re-called for every branch comparison, producing wrong results. */
        iemit(g,"{ int _case_val_ = (int)("); emit_expr(g,s->c0); emit(g,");\n");
        g->indent++;
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
                    emit(g,"(_case_val_>="); emit_expr(g,lb->c0);
                    emit(g," && _case_val_<="); emit_expr(g,lb->c1); emit(g,")");
                } else {
                    emit(g,"(_case_val_=="); emit_expr(g,lb->c0); emit(g,")");
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
        g->indent--;
        iemit(g,"}\n");
        break;
    }

    case ND_WITH: {
        /* WITH v: T DO stmts {| v: T DO stmts} [ELSE stmts] END
         * Emits as if/else if chain based on runtime _tag check.          */
        int first = 1;
        for (Node *cl=s->c0; cl; cl=cl->next) {
            char _wtbuf[MAX_IDENT*2];
            const char *_wtn = tag_cname(cl->str, _wtbuf, sizeof(_wtbuf));
            if (first) { iemit(g,"if ("); first=0; }
            else         iemit(g,"} else if (");
            emit_addr_of(g, cl->c0);
            emit(g," && (");
            emit_addr_of(g, cl->c0);
            emit(g,")->_tag == _TAG_%s) {\n", _wtn);
            g->indent++;
            /* Shadow the variable with the narrowed pointer type.
             * Use a void* temp to avoid the C scoping trap where the
             * new declaration's initializer would refer to itself.   */
            if (cl->c0 && cl->c0->kind==ND_IDENT) {
                iemit(g,"void *_obc_wt_ = (void*)(");
                emit_addr_of(g, cl->c0);
                emit(g,");\n");
                iemit(g,"%s *%s = (%s*)_obc_wt_;\n",
                      ctype(cl->str), cl->c0->str, ctype(cl->str));
            }
            for (Node *st=cl->c1; st; st=st->next) emit_stmt(g,st);
            g->indent--;
        }
        if (!first) {
            if (s->c1) {
                iemit(g,"} else {\n");
                g->indent++;
                for (Node *st=s->c1; st; st=st->next) emit_stmt(g,st);
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
                if (is_open_array(fp->c1)) emit(g,", int %s_len", id->str);
                first = 0;
            }
        }
    }
    emit(g,")");
}

/* Emit inherited + own fields of a RECORD node, flattened (no _base wrapper).
 * Recurses into base type declarations so inherited fields appear first. */
static void emit_record_fields_flat(CG *g, Node *rec) {
    if (rec->str[0]) {
        Node *base = find_type_decl(rec->str);
        if (base && base->c0 && base->c0->kind==ND_TRECORD)
            emit_record_fields_flat(g, base->c0);
    }
    for (Node *fl=rec->c0; fl; fl=fl->next)
        for (Node *id=fl->c0; id; id=id->next) {
            emit(g,"    ");
            emit_var_decl_raw(g, id->str, fl->c1, 0);
            emit(g,";\n");
        }
}

/* Emit a typedef struct for a record type */
static void emit_type_decl(CG *g, Node *n) {
    /* n: ND_TYPE_DECL, str=name, c0=type */
    if (!n->c0) return;
    if (n->c0->kind == ND_TRECORD) {
        Node *rec = n->c0;
        type_tag_add(n->str);   /* register tag for IS/WITH */
        emit(g,"typedef struct %s_s {\n", n->str);
        emit(g,"    int _tag;\n");  /* runtime type tag */
        emit_record_fields_flat(g, rec);  /* flattened inherited + own fields */
        emit(g,"} %s;\n", n->str);
    } else if (n->c0->kind == ND_TNAME) {
        emit(g,"typedef %s %s;\n", ctype(n->c0->str), n->str);
    } else if (n->c0->kind == ND_TPOINTER) {
        ptr_type_add(n->str);   /* register as a pointer type */
        /* Use struct tag directly so the pointer typedef works before the
         * struct body is declared (common for linked-list / extension types). */
        if (n->c0->c0 && n->c0->c0->kind==ND_TNAME) {
            const char *base = n->c0->c0->str;
            emit(g,"struct %s_s;\n", base);
            emit(g,"typedef struct %s_s *%s;\n", base, n->str);
        } else {
            emit(g,"typedef ");
            emit_type_prefix(g, n->c0->c0);
            emit(g," *%s;\n", n->str);
        }
    } else if (n->c0->kind == ND_TARRAY) {
        emit(g,"typedef ");
        emit_type_prefix(g, n->c0);
        emit(g," %s", n->str);
        emit_type_dims(g, n->c0);
        emit(g,";\n");
    } else if (n->c0->kind == ND_TPROC) {
        /* Procedure-type alias: typedef rettype (*Name)(params); */
        emit(g,"typedef ");
        if (n->c0->c1) emit_type_prefix(g,n->c0->c1); else emit(g,"void");
        emit(g," (*%s)(", n->str);
        if (!n->c0->c0) { emit(g,"void"); }
        else {
            int first=1;
            for (Node *fp=n->c0->c0;fp;fp=fp->next) {
                int isv=(fp->flags&FLAG_VAR_PARAM)!=0;
                for (Node *id=fp->c0;id;id=id->next) {
                    if (!first) emit(g,", ");
                    emit_var_decl_raw(g,id->str,fp->c1,isv);
                    first=0;
                }
            }
        }
        emit(g,");\n");
    }
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
        else if (n->c1 && n->c1->kind==ND_TNAME && is_known_record_type(n->c1->str))
            emit(g," = { ._tag = _TAG_%s }", n->c1->str);
        emit(g,";\n");
    }
}

/* Emit local variable declarations inside a procedure body */
static void emit_local_vars(CG *g, Node *decls) {
    for (Node *d=decls; d; d=d->next) {
        if (d->kind != ND_VAR_DECL) continue;
        for (Node *id=d->c0; id; id=id->next) {
            sym_add(id->str, d->c1, 0);
            iemit(g,""); emit_var_decl_raw(g, id->str, d->c1, 0);
            /* Oberon requires local variables to be zero-initialised */
            if (d->c1 && (d->c1->kind==ND_TARRAY ||
                          (d->c1->kind==ND_TNAME && !strcmp(d->c1->str,"STRING"))))
                emit(g,"={0}");
            emit(g,";\n");
            /* Initialise _tag for stack-allocated records */
            if (d->c1 && d->c1->kind==ND_TNAME && is_known_record_type(d->c1->str))
                iemit(g,"%s._tag = _TAG_%s;\n", id->str, d->c1->str);
        }
    }
}

/* Emit the _Frame_ProcName typedef for a proc that has nested procs. */
static void emit_frame_struct(CG *g, Node *proc) {
    if (!has_nested_procs(proc)) return;
    /* Temporarily build frame info without modifying g */
    CG tmp; memset(&tmp,0,sizeof(tmp)); tmp.out=g->out;
    build_frame(&tmp, proc);
    if (tmp.n_frame==0) return;
    emit(g,"typedef struct {\n");
    for (int i=0;i<tmp.n_frame;i++) {
        Node *t=tmp.frame_types[i];
        int is_arr = t && (t->kind==ND_TARRAY||
                     (t->kind==ND_TNAME&&!strcmp(t->str,"STRING")));
        emit(g,"    ");
        if (is_arr) {
            /* Store pointer to element type */
            Node *et=t; while(et&&et->kind==ND_TARRAY) et=et->c1;
            emit_type_prefix(g,et);
        } else {
            emit_type_prefix(g,t);
        }
        emit(g," *%s;\n", tmp.frame_names[i]);
    }
    emit(g,"} _Frame_%s;\n\n", proc->str);
}

/* Emit params, optionally prepending a frame pointer as the first param. */
static void emit_proc_params_ex(CG *g, Node *params, const char *frame_type) {
    emit(g,"(");
    int first=1;
    if (frame_type) { emit(g,"%s *_frame",frame_type); first=0; }
    if (!params && first) { emit(g,"void"); }
    else if (params) {
        for (Node *fp=params;fp;fp=fp->next) {
            int isv=(fp->flags&FLAG_VAR_PARAM)!=0;
            for (Node *id=fp->c0;id;id=id->next) {
                if (!first) emit(g,", ");
                emit_var_decl_raw(g,id->str,fp->c1,isv);
                if (is_open_array(fp->c1)) emit(g,", int %s_len", id->str);
                first=0;
            }
        }
    }
    emit(g,")");
}

/* Emit a forward declaration (prototype) for a procedure.
 * nested=1 when called recursively for an inner procedure. */
static void emit_proc_proto(CG *g, Node *proc, int nested) {
    /* When emitting protos for a proc's nested children, build frame first
     * so that the nested protos get the correct _Frame_* parameter.       */
    int saved_n_frame = g->n_frame;
    int saved_n_nested = g->n_nested_procs;
    char saved_outer[MAX_IDENT];
    strncpy(saved_outer, g->outer_proc_name, MAX_IDENT-1);

    if (!nested && has_nested_procs(proc)) {
        build_frame(g, proc);
        collect_nested_names(g, proc);
    }

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
    if (nested && g->n_frame > 0) {
        char _ft[MAX_IDENT+8];
        snprintf(_ft,sizeof(_ft),"_Frame_%s",g->outer_proc_name);
        emit_proc_params_ex(g, proc->c0, _ft);
    } else {
        emit_proc_params(g, proc->c0);
    }
    emit(g,";\n");
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_proto(g, d, 1);

    /* Restore frame context */
    if (!nested) {
        g->n_frame = saved_n_frame;
        g->n_nested_procs = saved_n_nested;
        strncpy(g->outer_proc_name, saved_outer, MAX_IDENT-1);
    }
}

/* Emit a complete procedure definition.
 * nested=1 when called recursively for an inner procedure. */
static void emit_proc_def(CG *g, Node *proc, int nested) {
    emit(g,"\n");

    /* For outer procs with nested procs: build frame context */
    int save_in_nested  = g->in_nested_proc;
    int save_n_nested   = g->n_nested_procs;
    int save_n_frame    = g->n_frame;
    int save_nested_sym = g->nested_sym_start;
    char save_outer[MAX_IDENT];
    strncpy(save_outer, g->outer_proc_name, MAX_IDENT-1);
    char save_nested_names[32][MAX_IDENT];
    memcpy(save_nested_names, g->nested_proc_names, sizeof(g->nested_proc_names));

    if (!nested && has_nested_procs(proc)) {
        build_frame(g, proc);
        collect_nested_names(g, proc);
    }
    if (nested) {
        g->in_nested_proc = 1;
    }

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

    sym_push();
    if (nested && g->n_frame > 0) {
        char _ft2[MAX_IDENT+8];
        snprintf(_ft2,sizeof(_ft2),"_Frame_%s",g->outer_proc_name);
        emit_proc_params_ex(g, proc->c0, _ft2);
        g->nested_sym_start = g_nsyms;  /* record boundary before own vars */
    } else {
        emit_proc_params(g, proc->c0);
    }
    for (Node *fp=proc->c0; fp; fp=fp->next) {
        int is_var = (fp->flags & FLAG_VAR_PARAM) != 0;
        for (Node *id=fp->c0; id; id=id->next)
            sym_add(id->str, fp->c1, is_var);
    }

    emit(g," {\n");
    g->indent++;
    g->in_proc++;

    /* Forward-declare nested procs inside this proc's body */
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) { iemit(g,""); emit_proc_proto(g,d,1); }

    /* Local variable declarations */
    emit_local_vars(g, proc->c2);

    /* If outer proc has nested procs, init the frame struct */
    if (!nested && g->n_frame > 0) {
        iemit(g,"_Frame_%s _frame;\n", proc->str);
        for (int i=0;i<g->n_frame;i++) {
            Node *t=g->frame_types[i];
            int is_arr = t && (t->kind==ND_TARRAY||
                         (t->kind==ND_TNAME&&!strcmp(t->str,"STRING")));
            if (is_arr || g->frame_is_var[i])
                iemit(g,"_frame.%s = %s;\n",
                      g->frame_names[i], g->frame_names[i]);
            else
                iemit(g,"_frame.%s = &%s;\n",
                      g->frame_names[i], g->frame_names[i]);
        }
    }

    /* Body statements */
    for (Node *s=proc->c3; s; s=s->next) emit_stmt(g,s);

    g->indent--;
    g->in_proc--;
    emit(g,"}\n");
    sym_pop();

    /* Restore outer proc context before emitting hoisted nested procs */
    /* (they need g->frame_* from the outer proc, which is still valid) */
    g->in_nested_proc = 1;  /* nested procs emitted here are indeed nested */
    for (Node *d=proc->c2; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_proc_def(g, d, 1);

    /* Restore CG context */
    g->in_nested_proc   = save_in_nested;
    g->n_nested_procs   = save_n_nested;
    g->n_frame          = save_n_frame;
    g->nested_sym_start = save_nested_sym;
    strncpy(g->outer_proc_name, save_outer, MAX_IDENT-1);
    memcpy(g->nested_proc_names, save_nested_names, sizeof(g->nested_proc_names));
}

/* -----------------------------------------------------------------------
 * Main entry point
 * ----------------------------------------------------------------------- */

void codegen(Node *module, FILE *out, int is_main, const char *srcfile) {
    CG cg;
    memset(&cg, 0, sizeof(cg));
    cg.out     = out;
    cg.is_main = is_main;
    strncpy(cg.modname, module->str, MAX_IDENT-1);
    if (srcfile) strncpy(cg.srcfile, srcfile, sizeof(cg.srcfile)-1);
    CG *g = &cg;
    g_nsyms=0; g_sdepth=0; g_nimports=0; g_nprocsigs=0;
    type_tags_reset(); ptr_types_reset();
    g_module_decls = module->c1;
    collect_proc_sigs(module->c1);
    if (!is_main) {
        collect_xmod_proc_sigs(module->c1, module->str);
        collect_xmod_type_decls(module->c1, module->str);
        collect_xmod_var_decls(module->c1, module->str);
    }

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
		emit(g,"#ifdef __linux__\n#define _GNU_SOURCE\n#endif\n");
    emit(g,"#include <stdio.h>\n");
    emit(g,"#include <stdlib.h>\n");
    emit(g,"#include <string.h>\n");
    emit(g,"#include <math.h>\n");
    emit(g,"#include <assert.h>\n");
    /* Floor-division and floor-mod macros (Oberon-07 semantics) */
    emit(g,"#define _OBC_DIV(a,b) ((a)/(b)-((((a)%%(b))!=0)&&(((a)^(b))<0)))\n");
    emit(g,"#define _OBC_MOD(a,b) ((a)%%(b)+((((a)%%(b))!=0)&&(((a)^(b))<0)?(b):0))\n");

    /* ── Include headers for user-imported modules ───────────────── */
    for (int i=0;i<g_nimports;i++) {
        const char *real = g_import_real[i];
        if (is_builtin_module(real)) continue;
        const FfiMod *ffi = ffi_lookup(real);
        if (ffi) {
            emit(g,"#include %s\n", ffi->header);
            for (int j = 0; j < ffi->nmaps; j++)
                emit(g,"#define %s_%s %s\n",
                     real, ffi->maps[j].oberon, ffi->maps[j].cname);
        } else {
            emit(g,"#include \"%s.h\"\n", real);
        }
    }

    /* ── Detect imported modules ─────────────────────────────────── */
    int has_terminal = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Terminal")) { has_terminal=1; break; }
    int has_strings = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Strings"))  { has_strings=1;  break; }
    int has_files = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Files"))    { has_files=1;    break; }
    int has_args = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Args"))     { has_args=1;     break; }
    int has_dict = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Dict"))     { has_dict=1;     break; }
    int has_zip = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Zip"))      { has_zip=1;      break; }
    int has_in = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"In"))       { has_in=1;       break; }
    int has_env = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Env"))      { has_env=1;      break; }
    int has_os = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"OS"))       { has_os=1;       break; }
    int has_time = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_imports[i],"Time"))     { has_time=1;     break; }

    /* ── Terminal module runtime (emitted when Terminal is imported) ─ */
    if (has_terminal) {
        emit(g,"#include <termios.h>\n");
        emit(g,"#include <sys/time.h>\n");
        emit(g,"#include <sys/ioctl.h>\n");
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
        emit(g,"    printf(\"\\033[0m\\033[?25h\"); fflush(stdout);\n");
        emit(g,"}\n");
        /* _term_init */
        emit(g,"static void _term_init(void) {\n");
        emit(g,"    struct termios raw;\n");
        emit(g,"    tcgetattr(STDIN_FILENO, &_term_orig);\n");
        emit(g,"    raw = _term_orig;\n");
        emit(g,"    raw.c_iflag &= ~(unsigned)(ICRNL|IXON);\n");
        emit(g,"    raw.c_lflag &= ~(unsigned)(ECHO|ICANON|ISIG\n");
        emit(g,"#ifdef FLUSHO\n");
        emit(g,"        |FLUSHO\n");
        emit(g,"#endif\n");
        emit(g,"    );\n");
        emit(g,"    raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 0;\n");
        emit(g,"#ifdef VDISCARD\n");
        emit(g,"    raw.c_cc[VDISCARD] = _POSIX_VDISABLE;\n");
        emit(g,"#endif\n");
        emit(g,"#ifdef VLNEXT\n");
        emit(g,"    raw.c_cc[VLNEXT] = _POSIX_VDISABLE;\n");
        emit(g,"#endif\n");
        emit(g,"    tcsetattr(STDIN_FILENO, TCSANOW, &raw);\n");
        emit(g,"    setvbuf(stdout, NULL, _IOFBF, 65536);\n");
        emit(g,"    printf(\"\\033[?25l\"); fflush(stdout);\n");
        emit(g,"    atexit(_term_restore);\n");
        emit(g,"    srand((unsigned)time(NULL));\n");
        emit(g,"}\n");
				emit(g,"static void Terminal_Restore(void) { _term_restore(); }\n");
				emit(g,"static void Terminal_Init(void) {\n");
				emit(g,"    struct termios raw = _term_orig;\n");
				emit(g,"    raw.c_iflag &= ~(unsigned)(ICRNL|IXON);\n");
				emit(g,"    raw.c_lflag &= ~(unsigned)(ECHO|ICANON|ISIG\n");
				emit(g,"#ifdef FLUSHO\n");
				emit(g,"        |FLUSHO\n");
				emit(g,"#endif\n");
				emit(g,"    );\n");
				emit(g,"    raw.c_cc[VMIN] = 0; raw.c_cc[VTIME] = 0;\n");
				emit(g,"#ifdef VDISCARD\n");
				emit(g,"    raw.c_cc[VDISCARD] = _POSIX_VDISABLE;\n");
				emit(g,"#endif\n");
				emit(g,"#ifdef VLNEXT\n");
				emit(g,"    raw.c_cc[VLNEXT] = _POSIX_VDISABLE;\n");
				emit(g,"#endif\n");
				emit(g,"    tcsetattr(STDIN_FILENO, TCSANOW, &raw);\n");
				emit(g,"    setvbuf(stdout, NULL, _IOFBF, 65536);\n");
				emit(g,"    printf(\"\\033[?25l\"); fflush(stdout);\n");
				emit(g,"}\n");
        /* Mouse on/off */
        emit(g,"static void Terminal_MouseOn(void) {\n");
        emit(g,"    if (!_term_mouse_on) {\n");
        emit(g,"        printf(\"\\033[?1000h\\033[?1003h\\033[?1006h\");\n");
        emit(g,"        _term_mouse_on = 1;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_MouseOff(void) {\n");
        emit(g,"    if (_term_mouse_on) {\n");
        emit(g,"        printf(\"\\033[?1000l\\033[?1003l\\033[?1006l\");\n");
        emit(g,"        _term_mouse_on = 0;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        /* Mouse state accessors */
        emit(g,"static int Terminal_MouseX(void)   { return _term_mouse_x; }\n");
        emit(g,"static int Terminal_MouseY(void)   { return _term_mouse_y; }\n");
        emit(g,"static int Terminal_MouseBtn(void) { return _term_mouse_btn; }\n");
        /* Standard procedures */
        emit(g,"static void Terminal_Goto(int x, int y) {\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\", y, x);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_ShowCursor(void) {\n");
        emit(g,"    printf(\"\\033[?25h\"); fflush(stdout);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_HideCursor(void) {\n");
        emit(g,"    printf(\"\\033[?25l\");\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Clear(void) {\n");
        emit(g,"    printf(\"\\033[2J\\033[H\");\n");
        emit(g,"}\n");
        emit(g,"static long Terminal_GetTickCount(void) {\n");
        emit(g,"    struct timeval tv;\n");
        emit(g,"    gettimeofday(&tv, NULL);\n");
        emit(g,"    return (long)(tv.tv_sec * 1000L + tv.tv_usec / 1000);\n");
        emit(g,"}\n");
        emit(g,"static int Terminal_Cols(void) {\n");
        emit(g,"    struct winsize ws;\n");
        emit(g,"    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) return ws.ws_col;\n");
        emit(g,"    return 80;\n");
        emit(g,"}\n");
        emit(g,"static int Terminal_Rows(void) {\n");
        emit(g,"    struct winsize ws;\n");
        emit(g,"    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0) return ws.ws_row;\n");
        emit(g,"    return 24;\n");
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
         *   A0X  Up arrow      A1X  Down arrow
         *   A2X  Left arrow    A3X  Right arrow
         *   A4X  Mouse event   (call MouseX/Y/Btn for details)
         *   A5X  Shift+Up      A6X  Shift+Down
         *   A7X  Shift+Left    A8X  Shift+Right
         *   1BX  Bare ESC
         *   otherwise: the character itself
         *
         * Mouse button values stored in _term_mouse_btn:
         *   0  left press     1  middle press   2  right press
         *   3  any release    64 wheel up        65 wheel down    */
        emit(g,"static char Terminal_ReadKey(void) {\n");
        emit(g,"    fflush(stdout);\n");
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
        emit(g,"            if (c3=='A') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return (char)0xa0; }\n");
        emit(g,"            if (c3=='B') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return (char)0xa1; }\n");
        emit(g,"            if (c3=='D') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return (char)0xa2; }\n");
        emit(g,"            if (c3=='C') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return (char)0xa3; }\n");
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
        /* btn: bits 0-1 = button (0=left,1=mid,2=right), bit 5 = motion, bit 6 = wheel.
         * Release is signalled by the final 'm'.
         * We expose: 0=L-press 1=M-press 2=R-press 3=release 32=motion 64=whl↑ 65=whl↓ */
        emit(g,"                if (last=='m')            _term_mouse_btn=3;\n");
        emit(g,"                else if (btn & 64)        _term_mouse_btn=(btn&67);\n");
        emit(g,"                else if (btn & 32)        _term_mouse_btn=32;\n");
        emit(g,"                else                      _term_mouse_btn=(btn&3);\n");
        emit(g,"                tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"                return (char)0xa4;\n");
        emit(g,"            }\n");
        /* Home / End (ESC [ H / ESC [ F) */
        emit(g,"            if (c3=='H') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return (char)130; }\n");
        emit(g,"            if (c3=='F') { tcsetattr(STDIN_FILENO,TCSANOW,&t2); return (char)131; }\n");
        /* ESC [ digit ~ sequences: PgUp=5, PgDn=6, Del=3, Home=1/7, End=4/8
         * Also ESC [ 1 ; 5 D/C/H/F for Ctrl+Left/Right/Home/End */
        emit(g,"            if (c3>='1' && c3<='9') {\n");
        emit(g,"                char c4=0; read(STDIN_FILENO,&c4,1);\n");
        emit(g,"                if (c4==';') {\n");
        emit(g,"                    char c5=0,c6=0;\n");
        emit(g,"                    read(STDIN_FILENO,&c5,1);\n");
        emit(g,"                    read(STDIN_FILENO,&c6,1);\n");
        emit(g,"                    tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"                    if (c5=='5') {\n");
        emit(g,"                        if (c6=='D') return (char)133;\n");
        emit(g,"                        if (c6=='C') return (char)134;\n");
        emit(g,"                        if (c6=='H') return (char)135;\n");
        emit(g,"                        if (c6=='F') return (char)136;\n");
        emit(g,"                    }\n");
        emit(g,"                    if (c5=='2') {\n");
        emit(g,"                        if (c6=='A') return (char)0xa5;\n");
        emit(g,"                        if (c6=='B') return (char)0xa6;\n");
        emit(g,"                        if (c6=='D') return (char)0xa7;\n");
        emit(g,"                        if (c6=='C') return (char)0xa8;\n");
        emit(g,"                    }\n");
        emit(g,"                    return '\\x1B';\n");
        emit(g,"                }\n");
        /* Two-digit sequences: ESC[11~ = F1 .. ESC[24~ = F12 */
        emit(g,"                if (c4>='0' && c4<='9') {\n");
        emit(g,"                    int num=(c3-'0')*10+(c4-'0'); char term=0;\n");
        emit(g,"                    read(STDIN_FILENO,&term,1);\n");
        emit(g,"                    tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"                    if (term=='~') {\n");
        emit(g,"                        if (num==11) return (char)137;\n"); /* F1  */
        emit(g,"                        if (num==12) return (char)138;\n"); /* F2  */
        emit(g,"                        if (num==13) return (char)139;\n"); /* F3  */
        emit(g,"                        if (num==14) return (char)140;\n"); /* F4  */
        emit(g,"                        if (num==15) return (char)141;\n"); /* F5  */
        emit(g,"                        if (num==17) return (char)142;\n"); /* F6  */
        emit(g,"                        if (num==18) return (char)143;\n"); /* F7  */
        emit(g,"                        if (num==19) return (char)144;\n"); /* F8  */
        emit(g,"                        if (num==20) return (char)145;\n"); /* F9  */
        emit(g,"                        if (num==21) return (char)146;\n"); /* F10 */
        emit(g,"                        if (num==23) return (char)147;\n"); /* F11 */
        emit(g,"                        if (num==24) return (char)148;\n"); /* F12 */
        emit(g,"                    }\n");
        emit(g,"                    return '\\x1B';\n");
        emit(g,"                }\n");
        emit(g,"                tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"                if (c3=='5') return (char)128;\n");
        emit(g,"                if (c3=='6') return (char)129;\n");
        emit(g,"                if (c3=='3') return (char)132;\n");
        emit(g,"                if (c3=='1'||c3=='7') return (char)130;\n");
        emit(g,"                if (c3=='4'||c3=='8') return (char)131;\n");
        emit(g,"                return '\\x1B';\n");
        emit(g,"            }\n");
        emit(g,"        }\n");
        /* ESC O P/Q/R/S = F1-F4 (xterm application-cursor mode) */
        emit(g,"        if (c2=='O') {\n");
        emit(g,"            char co=0; read(STDIN_FILENO,&co,1);\n");
        emit(g,"            tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"            if (co=='P') return (char)137;\n"); /* F1 */
        emit(g,"            if (co=='Q') return (char)138;\n"); /* F2 */
        emit(g,"            if (co=='R') return (char)139;\n"); /* F3 */
        emit(g,"            if (co=='S') return (char)140;\n"); /* F4 */
        emit(g,"            return '\\x1B';\n");
        emit(g,"        }\n");
        emit(g,"        t2.c_cc[VMIN]=0; t2.c_cc[VTIME]=0;\n");
        emit(g,"        tcsetattr(STDIN_FILENO,TCSANOW,&t2);\n");
        emit(g,"        return '\\x1B';\n");
        emit(g,"    }\n");
        emit(g,"    return c;\n");
        emit(g,"}\n");
        /* ── Graphics functions (part of Terminal) ─────────────────── */
        emit(g,"static void Terminal_Color(int fg, int bg) {\n");
        emit(g,"    printf(\"\\033[3%%d;4%%dm\", fg & 7, bg & 7);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Color256(int fg, int bg) {\n");
        emit(g,"    printf(\"\\033[38;5;%%d;48;5;%%dm\", fg & 255, bg & 255);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Reset(void) {\n");
        emit(g,"    printf(\"\\033[0m\");\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Fill(int x, int y, int w, int h, char ch) {\n");
        emit(g,"    for (int row = 0; row < h; row++) {\n");
        emit(g,"        printf(\"\\033[%%d;%%dH\", y + row, x);\n");
        emit(g,"        for (int col = 0; col < w; col++) putchar(ch);\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_HLine(int x, int y, int len, char ch) {\n");
        emit(g,"    printf(\"\\033[%%d;%%dH\", y, x);\n");
        emit(g,"    for (int i = 0; i < len; i++) putchar(ch);\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_VLine(int x, int y, int len, char ch) {\n");
        emit(g,"    for (int i = 0; i < len; i++) {\n");
        emit(g,"        printf(\"\\033[%%d;%%dH\", y + i, x); putchar(ch);\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Box(int x, int y, int w, int h) {\n");
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
        emit(g,"}\n");
        emit(g,"static void Terminal_Sprite(int x, int y, const char *s, int color) {\n");
        emit(g,"    printf(\"\\033[3%%dm\",color&7);\n");
        emit(g,"    int cx=x,cy=y;\n");
        emit(g,"    for(const char *p=s;*p;p++) {\n");
        emit(g,"        if(*p=='\\n') { cy++; cx=x; printf(\"\\033[%%d;%%dH\",cy,cx); }\n");
        emit(g,"        else { printf(\"\\033[%%d;%%dH\",cy,cx++); putchar(*p); }\n");
        emit(g,"    }\n");
        emit(g,"    printf(\"\\033[0m\");\n");
        emit(g,"}\n");
        /* ── Pixel buffer (half-block: each cell = 2 vertical pixels) ── */
        emit(g,"#define _GFX_W 240\n");
        emit(g,"#define _GFX_H 100\n");
        emit(g,"static int _gfx_buf[_GFX_H][_GFX_W];\n");
        emit(g,"static void Terminal_ClearBuf(void) {\n");
        emit(g,"    for(int r=0;r<_GFX_H;r++) for(int c=0;c<_GFX_W;c++) _gfx_buf[r][c]=0;\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Plot(int x, int y, int color) {\n");
        emit(g,"    if(x<0||x>=_GFX_W||y<0||y>=_GFX_H) return;\n");
        emit(g,"    _gfx_buf[y][x] = color ? color : 7;\n");
        emit(g,"}\n");
        emit(g,"static void Terminal_Flush(void) {\n");
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
        emit(g,"            else if(top&&bot&&top==bot) { printf(\"\\033[38;5;%%dm\\xe2\\x96\\x88\",top); }\n");
        /* different colors → ▀ with fg=top, bg=bot */
        emit(g,"            else if(top&&bot) { printf(\"\\033[38;5;%%d;48;5;%%dm\\xe2\\x96\\x80\",top,bot); }\n");
        /* top only → ▀ */
        emit(g,"            else if(top) { printf(\"\\033[38;5;%%dm\\xe2\\x96\\x80\",top); }\n");
        /* bot only → ▄ */
        emit(g,"            else { printf(\"\\033[38;5;%%dm\\xe2\\x96\\x84\",bot); }\n");
        emit(g,"        }\n");
        emit(g,"    }\n");
        emit(g,"    printf(\"\\033[0m\"); fflush(stdout);\n");
        emit(g,"}\n");
        /* Bresenham circle */
        emit(g,"static void Terminal_Circle(int cx, int cy, int r, int color) {\n");
        emit(g,"    int x=0,y=r,d=1-r;\n");
        emit(g,"    while(x<=y) {\n");
        emit(g,"        Terminal_Plot(cx+x,cy+y,color); Terminal_Plot(cx-x,cy+y,color);\n");
        emit(g,"        Terminal_Plot(cx+x,cy-y,color); Terminal_Plot(cx-x,cy-y,color);\n");
        emit(g,"        Terminal_Plot(cx+y,cy+x,color); Terminal_Plot(cx-y,cy+x,color);\n");
        emit(g,"        Terminal_Plot(cx+y,cy-x,color); Terminal_Plot(cx-y,cy-x,color);\n");
        emit(g,"        if(d<0) d+=2*x+3; else { d+=2*(x-y)+5; y--; } x++;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        /* Bresenham line in pixel buffer */
        emit(g,"static void Terminal_Line(int x0, int y0, int x1, int y1, int color) {\n");
        emit(g,"    int dx=x1-x0; if(dx<0)dx=-dx;\n");
        emit(g,"    int dy=y1-y0; if(dy<0)dy=-dy;\n");
        emit(g,"    int sx=x0<x1?1:-1, sy=y0<y1?1:-1, err=dx-dy;\n");
        emit(g,"    while(1) {\n");
        emit(g,"        Terminal_Plot(x0,y0,color);\n");
        emit(g,"        if(x0==x1 && y0==y1) break;\n");
        emit(g,"        int e2=2*err;\n");
        emit(g,"        if(e2>-dy){err-=dy;x0+=sx;}\n");
        emit(g,"        if(e2< dx){err+=dx;y0+=sy;}\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        /* Filled circle (Bresenham scan-fill) */
        emit(g,"static void Terminal_FillCircle(int cx, int cy, int r, int color) {\n");
        emit(g,"    int x=0,y=r,d=1-r,i;\n");
        emit(g,"    while(x<=y) {\n");
        emit(g,"        for(i=cx-x;i<=cx+x;i++){Terminal_Plot(i,cy-y,color);Terminal_Plot(i,cy+y,color);}\n");
        emit(g,"        for(i=cx-y;i<=cx+y;i++){Terminal_Plot(i,cy-x,color);Terminal_Plot(i,cy+x,color);}\n");
        emit(g,"        if(d<0)d+=2*x+3;else{d+=2*(x-y)+5;y--;} x++;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        /* Fill entire pixel buffer */
        emit(g,"static void Terminal_FillBuf(int color) {\n");
        emit(g,"    for(int r=0;r<_GFX_H;r++) for(int c=0;c<_GFX_W;c++) _gfx_buf[r][c]=color;\n");
        emit(g,"}\n");
        /* Map RGB (0-255 each) to nearest xterm-256 color index */
        emit(g,"static int Terminal_RGBColor(int r, int g, int b) {\n");
        emit(g,"    if(r==g && g==b) {\n");
        emit(g,"        if(r<8)return 16; if(r>248)return 231;\n");
        emit(g,"        return (int)((r-8)/247.0*24.0+232.5);\n");
        emit(g,"    }\n");
        emit(g,"    int ri=(int)(r/255.0*5.0+0.5);\n");
        emit(g,"    int gi=(int)(g/255.0*5.0+0.5);\n");
        emit(g,"    int bi=(int)(b/255.0*5.0+0.5);\n");
        emit(g,"    return 16+36*ri+6*gi+bi;\n");
        emit(g,"}\n");
    }
    emit(g,"\n");

    /* ── In module runtime (In.Line needs a helper function) ─────── */
    if (has_in) {
			emit(g, "static void In_Line(char *str) {\n");
			emit(g, "    int c, i = 0;\n");
			emit(g, "    while ((c = getchar()) != '\\n' && c != EOF) {\n");
			emit(g, "        if (i < 255) str[i++] = (char)c;\n");
			emit(g, "    }\n");
			emit(g, "    str[i] = '\\0';\n");
			emit(g, "}\n");
    }

    /* ── Env module runtime ──────────────────────────────────────── */
    if (has_env) {
        /* Env_Get(name, val, val_len): BOOLEAN — get environment variable */
        emit(g,"static int Env_Get(const char *name, char *val, int val_len) {\n");
        emit(g,"    const char *v=getenv(name);\n");
        emit(g,"    if(v){strncpy(val,v,(size_t)(val_len-1));val[val_len-1]=0;return 1;}\n");
        emit(g,"    val[0]=0; return 0;\n");
        emit(g,"}\n\n");
    }

    /* ── OS module runtime ───────────────────────────────────────── */
    if (has_os) {
        emit(g,"#include <unistd.h>\n");
        /* OS_Exec(cmd): INTEGER — run command, return exit code */
        emit(g,"static int OS_Exec(const char *cmd) {\n");
        emit(g,"    int r=system(cmd); return (r==-1)?-1:(r>>8)&0xff;\n");
        emit(g,"}\n");
        /* OS_GetCwd(VAR s, len) */
        emit(g,"static void OS_GetCwd(char *s, int len) {\n");
        emit(g,"    if(!getcwd(s,(size_t)len)) s[0]=0;\n");
        emit(g,"}\n");
        /* OS_ChDir(path): BOOLEAN */
        emit(g,"static int OS_ChDir(const char *path) { return chdir(path)==0; }\n");
        /* Directory listing — stateful, sorted (dirs first then alpha) */
        emit(g,"#include <dirent.h>\n");
        emit(g,"#define _OS_MAX_DIR 4096\n");
        emit(g,"typedef struct { char name[256]; int isdir; } _OSDirEntry;\n");
        emit(g,"static _OSDirEntry _os_dir[_OS_MAX_DIR];\n");
        emit(g,"static int _os_dir_n = 0;\n");
        emit(g,"static int _os_dir_cmp(const void *a, const void *b) {\n");
        emit(g,"    const _OSDirEntry *ea=(const _OSDirEntry*)a;\n");
        emit(g,"    const _OSDirEntry *eb=(const _OSDirEntry*)b;\n");
        emit(g,"    if (ea->isdir != eb->isdir) return eb->isdir - ea->isdir;\n");
        emit(g,"    return strcmp(ea->name, eb->name);\n");
        emit(g,"}\n");
        emit(g,"static void OS_DirOpen(const char *path, const char *filter) {\n");
        emit(g,"    DIR *d = opendir(path[0] ? path : \".\");\n");
        emit(g,"    _os_dir_n = 0;\n");
        emit(g,"    if (!d) return;\n");
        emit(g,"    int flen = filter ? (int)strlen(filter) : 0;\n");
        emit(g,"    struct dirent *e;\n");
        emit(g,"    while ((e = readdir(d)) != NULL && _os_dir_n < _OS_MAX_DIR) {\n");
        emit(g,"        if (strcmp(e->d_name,\".\") == 0) continue;\n");
        emit(g,"        int isdir = (e->d_type == DT_DIR);\n");
        emit(g,"        if (!isdir && flen > 0) {\n");
        emit(g,"            int nlen = (int)strlen(e->d_name);\n");
        emit(g,"            if (nlen < flen || strcmp(e->d_name+nlen-flen,filter) != 0) continue;\n");
        emit(g,"        }\n");
        emit(g,"        strncpy(_os_dir[_os_dir_n].name, e->d_name, 255);\n");
        emit(g,"        _os_dir[_os_dir_n].name[255] = 0;\n");
        emit(g,"        _os_dir[_os_dir_n].isdir = isdir;\n");
        emit(g,"        _os_dir_n++;\n");
        emit(g,"    }\n");
        emit(g,"    closedir(d);\n");
        emit(g,"    qsort(_os_dir, _os_dir_n, sizeof(_os_dir[0]), _os_dir_cmp);\n");
        emit(g,"}\n");
        emit(g,"static int  OS_DirCount(void) { return _os_dir_n; }\n");
        emit(g,"static void OS_DirName(int i, char *name, int nlen) {\n");
        emit(g,"    if (i<0||i>=_os_dir_n){name[0]=0;return;}\n");
        emit(g,"    strncpy(name,_os_dir[i].name,nlen-1); name[nlen-1]=0;\n");
        emit(g,"}\n");
        emit(g,"static int  OS_DirIsDir(int i) {\n");
        emit(g,"    return (i>=0 && i<_os_dir_n) ? _os_dir[i].isdir : 0;\n");
        emit(g,"}\n");
        /* OS_ClipWriteFile: read file, base64-encode, write OSC 52 to /dev/tty */
        emit(g,"static void OS_ClipWriteFile(const char *path) {\n");
        emit(g,"    FILE *f = fopen(path, \"rb\"); if (!f) return;\n");
        emit(g,"    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);\n");
        emit(g,"    if (sz<=0){fclose(f);return;}\n");
        emit(g,"    unsigned char *buf=(unsigned char*)malloc(sz);\n");
        emit(g,"    if(!buf){fclose(f);return;}\n");
        emit(g,"    fread(buf,1,sz,f); fclose(f);\n");
        emit(g,"    /* base64 encode */\n");
        emit(g,"    static const char b64[]=\"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";\n");
        emit(g,"    long enclen = ((sz+2)/3)*4;\n");
        emit(g,"    char *enc=(char*)malloc(enclen+1);\n");
        emit(g,"    if(!enc){free(buf);return;}\n");
        emit(g,"    long si=0,di=0;\n");
        emit(g,"    while(si<sz){\n");
        emit(g,"        unsigned int v=(unsigned int)buf[si++]<<16;\n");
        emit(g,"        if(si<sz) v|=(unsigned int)buf[si++]<<8;\n");
        emit(g,"        if(si<sz) v|=(unsigned int)buf[si++];\n");
        emit(g,"        enc[di++]=b64[(v>>18)&63]; enc[di++]=b64[(v>>12)&63];\n");
        emit(g,"        enc[di++]=b64[(v>>6)&63];  enc[di++]=b64[v&63];\n");
        emit(g,"    }\n");
        emit(g,"    /* fix padding */\n");
        emit(g,"    long rem=sz%%3;\n");
        emit(g,"    if(rem==1){enc[enclen-2]='=';enc[enclen-1]='=';}\n");
        emit(g,"    else if(rem==2){enc[enclen-1]='=';}\n");
        emit(g,"    enc[enclen]=0;\n");
        emit(g,"    free(buf);\n");
        emit(g,"    FILE *tty=fopen(\"/dev/tty\",\"wb\");\n");
        emit(g,"    if(tty){ fprintf(tty,\"\\033]52;c;%%s\\a\",enc); fclose(tty); }\n");
        emit(g,"    free(enc);\n");
        emit(g,"}\n");
        /* OS_ClipPasteCmd: run paste command, write stdout to file */
        emit(g,"static void OS_ClipPasteCmd(const char *outpath) {\n");
        emit(g,"    const char *cmds[]={\n");
        emit(g,"        \"pbpaste\",\n");
        emit(g,"        \"wl-paste --no-newline\",\n");
        emit(g,"        \"xclip -selection clipboard -o\",\n");
        emit(g,"        \"xsel --clipboard --output\",\n");
        emit(g,"        NULL};\n");
        emit(g,"    char cmd[512];\n");
        emit(g,"    for(int i=0;cmds[i];i++){\n");
        emit(g,"        snprintf(cmd,sizeof(cmd),\"%%s > %%s 2>/dev/null\",cmds[i],outpath);\n");
        emit(g,"        if(system(cmd)==0) return;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        emit(g,"\n");
    }

    /* ── Time module runtime ─────────────────────────────────────── */
    if (has_time) {
				emit(g,"#include <time.h>\n");
        /* Time_Now(): LONGINT — milliseconds since Unix epoch */
        emit(g,"static long Time_Now(void) {\n");
        emit(g,"    struct timespec ts;\n");
        emit(g,"    clock_gettime(CLOCK_REALTIME,&ts);\n");
        emit(g,"    return (long)ts.tv_sec*1000L + ts.tv_nsec/1000000L;\n");
        emit(g,"}\n");
        /* Time_Sleep(ms) — sleep for ms milliseconds */
        emit(g,"static void Time_Sleep(int ms) {\n");
        emit(g,"    struct timespec ts; ts.tv_sec=ms/1000; ts.tv_nsec=(ms%%1000)*1000000L;\n");
        emit(g,"    nanosleep(&ts,NULL);\n");
        emit(g,"}\n");
        /* Time_Format(t_ms, fmt, VAR s, slen) — format a millisecond timestamp */
        emit(g,"static void Time_Format(long t_ms, const char *fmt, char *s, int slen) {\n");
        emit(g,"    time_t sec=(time_t)(t_ms/1000);\n");
        emit(g,"    struct tm *tm=localtime(&sec);\n");
        emit(g,"    if(tm) strftime(s,(size_t)slen,fmt,tm); else s[0]=0;\n");
        emit(g,"}\n\n");
    }

    /* ── Strings module runtime ─────────────────────────────────── */
    if (has_strings) {
        emit(g,"/* Strings module — Oberon-07 compatible */\n");
        emit(g,"static int Strings_Length(const char *s) {\n");
        emit(g,"    return (int)strlen(s);\n");
        emit(g,"}\n");
        /* Append(extra, VAR dst, cap) — dst := dst + extra, bounded by cap */
        emit(g,"static char* Strings_Append(const char *src, char *dst, size_t cap) {\n");
        emit(g,"    size_t dl=strlen(dst), sl=strlen(src);\n");
        emit(g,"    if (cap==0) return dst;\n");
        emit(g,"    if (dl+sl < cap) strcat(dst, src);\n");
        emit(g,"    else { strncat(dst, src, cap-dl-1); dst[cap-1]=0; }\n");
        emit(g,"    return dst;\n");
        emit(g,"}\n");
        /* Copy(src, VAR dst) — full string copy */
        emit(g,"static void Strings_Copy(const char *src, char *dst, int dst_len) {\n");
        emit(g,"    strncpy(dst, src, dst_len-1); dst[dst_len-1]=0;\n");
        emit(g,"}\n");
        /* Compare(s1, s2): INTEGER — returns -1, 0, or 1 */
        emit(g,"static int Strings_Compare(const char *a, const char *b) {\n");
        emit(g,"    int r=strcmp(a,b); return r<0?-1:r>0?1:0;\n");
        emit(g,"}\n");
        /* Pos(pattern, s, startPos): INTEGER — first occurrence at or after startPos, -1 if absent */
        emit(g,"static int Strings_PosFrom(const char *pat, const char *s, int from) {\n");
        emit(g,"    int slen=(int)strlen(s);\n");
        emit(g,"    if (from<0) from=0;\n");
        emit(g,"    if (from>slen) return -1;\n");
        emit(g,"    const char *p=strstr(s+from,pat); return p?(int)(p-s):-1;\n");
        emit(g,"}\n");
        /* Extract(src, pos, len, VAR dst) — copy substring */
        emit(g,"static void Strings_Extract(const char *src, int pos, int len, char *dst) {\n");
        emit(g,"    int slen=(int)strlen(src);\n");
        emit(g,"    if (pos<0) pos=0;\n");
        emit(g,"    if (pos>slen) { dst[0]=0; return; }\n");
        emit(g,"    if (len>slen-pos) len=slen-pos;\n");
        emit(g,"    if (len>255) len=255;\n");
        emit(g,"    strncpy(dst, src+pos, len); dst[len]=0;\n");
        emit(g,"}\n");
        /* NextWord(src, VAR pos, VAR dst) — skip whitespace, copy next word, advance pos */
        emit(g,"static void Strings_NextWord(const char *src, int *pos, char *dst) {\n");
        emit(g,"    int i=*pos, j=0, cap=255;\n");
        emit(g,"    while (src[i] && (src[i]==' '||src[i]=='\\t'||src[i]=='\\n'||src[i]=='\\r')) i++;\n");
        emit(g,"    while (src[i] && src[i]!=' '&&src[i]!='\\t'&&src[i]!='\\n'&&src[i]!='\\r' && j<cap) dst[j++]=src[i++];\n");
        emit(g,"    dst[j]=0; *pos=i;\n");
        emit(g,"}\n");
        /* Insert(src, pos, VAR dst) — insert src into dst at pos */
        emit(g,"static void Strings_Insert(const char *src, int pos, char *dst) {\n");
        emit(g,"    int dlen=(int)strlen(dst), slen=(int)strlen(src);\n");
        emit(g,"    if (pos<0) pos=0; if (pos>dlen) pos=dlen;\n");
        emit(g,"    int tail=dlen-pos; if (pos+slen+tail>255) tail=255-pos-slen; if (tail<0) tail=0;\n");
        emit(g,"    memmove(dst+pos+slen, dst+pos, tail);\n");
        emit(g,"    int copy=slen; if (pos+copy>255) copy=255-pos; if (copy>0) memcpy(dst+pos,src,copy);\n");
        emit(g,"    int newlen=pos+copy+tail; dst[newlen]=0;\n");
        emit(g,"}\n");
        /* Delete(VAR s, pos, len) — delete len chars at pos */
        emit(g,"static void Strings_Delete(char *s, int pos, int len) {\n");
        emit(g,"    int slen=(int)strlen(s);\n");
        emit(g,"    if (pos<0) pos=0; if (pos>=slen) return;\n");
        emit(g,"    if (pos+len>slen) len=slen-pos;\n");
        emit(g,"    memmove(s+pos, s+pos+len, slen-pos-len+1);\n");
        emit(g,"}\n");
        /* Replace(src, pos, VAR dst) — overwrite dst at pos with src */
        emit(g,"static void Strings_Replace(const char *src, int pos, char *dst) {\n");
        emit(g,"    int dlen=(int)strlen(dst), slen=(int)strlen(src);\n");
        emit(g,"    if (pos<0) pos=0; if (pos>dlen) pos=dlen;\n");
        emit(g,"    int end=pos+slen; if (end>255) end=255;\n");
        emit(g,"    memcpy(dst+pos, src, end-pos);\n");
        emit(g,"    if (end>dlen) dst[end]=0;\n");
        emit(g,"}\n");
        /* ToUpper / ToLower / Trim */
        emit(g,"#include <ctype.h>\n");
        emit(g,"static void Strings_ToUpper(char *s) { for(;*s;s++) *s=(char)toupper((unsigned char)*s); }\n");
        emit(g,"static void Strings_ToLower(char *s) { for(;*s;s++) *s=(char)tolower((unsigned char)*s); }\n");
        emit(g,"static void Strings_Trim(char *s) {\n");
        emit(g,"    int i=0, len=(int)strlen(s);\n");
        emit(g,"    while (s[i]==' '||s[i]=='\\t'||s[i]=='\\n'||s[i]=='\\r') i++;\n");
        emit(g,"    if (i>0) memmove(s, s+i, len-i+1);\n");
        emit(g,"    len=(int)strlen(s);\n");
        emit(g,"    while (len>0 && (s[len-1]==' '||s[len-1]=='\\t'||s[len-1]=='\\n'||s[len-1]=='\\r')) s[--len]=0;\n");
        emit(g,"}\n");
        /* Number ↔ string conversions */
        emit(g,"static void Strings_IntToStr(int n, char *s, int s_len) { snprintf(s,(size_t)s_len,\"%%d\",n); }\n");
        emit(g,"static void Strings_RealToStr(double x, char *s, int s_len) { snprintf(s,(size_t)s_len,\"%%g\",x); }\n");
        emit(g,"static int Strings_StrToInt(const char *s, int *n) { return sscanf(s,\"%%d\",n)==1; }\n");
        emit(g,"static int Strings_StrToReal(const char *s, double *x) { return sscanf(s,\"%%lf\",x)==1; }\n");
        emit(g,"static int Strings_StartsWith(const char *s, const char *prefix) {\n");
        emit(g,"    size_t pl=strlen(prefix); return strncmp(s,prefix,pl)==0;\n");
        emit(g,"}\n");
        emit(g,"static int Strings_EndsWith(const char *s, const char *suffix) {\n");
        emit(g,"    size_t sl=strlen(s), xl=strlen(suffix);\n");
        emit(g,"    if (xl>sl) return 0; return strcmp(s+sl-xl,suffix)==0;\n");
        emit(g,"}\n");
        /* Split(s, sep, n, VAR part): BOOLEAN — extract nth (0-based) field delimited by sep */
        emit(g,"static int Strings_Split(const char *s, char sep, int n, char *dst) {\n");
        emit(g,"    int field=0; const char *p=s;\n");
        emit(g,"    while (1) {\n");
        emit(g,"        if (field==n) {\n");
        emit(g,"            int j=0;\n");
        emit(g,"            while (*p && *p!=sep && j<255) dst[j++]=*p++;\n");
        emit(g,"            dst[j]=0; return 1;\n");
        emit(g,"        }\n");
        emit(g,"        while (*p && *p!=sep) p++;\n");
        emit(g,"        if (!*p) break;\n");
        emit(g,"        p++; field++;\n");
        emit(g,"    }\n");
        emit(g,"    dst[0]=0; return 0;\n");
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
        /* ReadLine(VAR r, VAR x: ARRAY OF CHAR) — reads until \n or EOF, strips \n */
        emit(g,"static void Files_ReadLine(Files_Rider *r, char *x) {\n");
        emit(g,"    int i=0,c;\n");
        emit(g,"    if(!r->f||r->eof){x[0]=0;r->eof=1;return;}\n");
        emit(g,"    while((c=fgetc(r->f->fp))!=EOF&&c!='\\n'){x[i++]=(char)c;r->pos++;}\n");
        emit(g,"    if(c=='\\n')r->pos++;else if(i==0)r->eof=1;\n");
        emit(g,"    x[i]=0;\n");
        emit(g,"}\n");
        /* WriteLine(VAR r, x: ARRAY OF CHAR) — writes string followed by \n */
        emit(g,"static void Files_WriteLine(Files_Rider *r, const char *x) {\n");
        emit(g,"    while(*x)Files_Write(r,(unsigned char)*x++);\n");
        emit(g,"    Files_Write(r,'\\n');\n");
        emit(g,"}\n");
        /* Delete(name) — delete a file by name */
        emit(g,"static void Files_Delete(const char *name) { remove(name); }\n");
        /* Rename(old, new) — rename/move a file */
        emit(g,"static void Files_Rename(const char *old, const char *n) { rename(old,n); }\n");
        /* Exists(name): BOOLEAN — check if file exists */
        emit(g,"static int Files_Exists(const char *name) {\n");
        emit(g,"    FILE *fp=fopen(name,\"rb\"); if(!fp)return 0; fclose(fp); return 1;\n");
        emit(g,"}\n");
        emit(g,"\n");
    }

    /* ── Args module runtime ─────────────────────────────────────── */
    if (has_args) {
        if (!has_terminal) emit(g,"#include <unistd.h>\n");
        emit(g,"/* Args module — command-line argument access */\n");
        if (g->is_main) {
            emit(g,"int   _args_argc = 0;\n");
            emit(g,"char **_args_argv = NULL;\n");
        } else {
            emit(g,"extern int   _args_argc;\n");
            emit(g,"extern char **_args_argv;\n");
        }
        emit(g,"static int Args_Count(void) { return _args_argc > 0 ? _args_argc - 1 : 0; }\n");
        emit(g,"static void Args_Get(int n, char *s) {\n");
        emit(g,"    if (n >= 0 && n < _args_argc && _args_argv) {\n");
        emit(g,"        int i=0; const char *src=_args_argv[n];\n");
        emit(g,"        while(src[i] && i<255){s[i]=src[i];i++;} s[i]=0;\n");
        emit(g,"    } else { s[0]=0; }\n");
        emit(g,"}\n");
        emit(g,"static void Args_GetEnv(const char *name, char *val, int val_len) {\n");
        emit(g,"    const char *v=getenv(name);\n");
        emit(g,"    if(v){strncpy(val,v,(size_t)(val_len-1));val[val_len-1]=0;} else val[0]=0;\n");
        emit(g,"}\n");
        /* Args_ExeDir: returns directory containing the running binary.
         * If argv[0] contains '/', extract dir from it (handles ./foo and /abs/path).
         * Otherwise search PATH for argv[0]. */
        emit(g,"static void Args_ExeDir(char *s) {\n");
        emit(g,"    char resolved[512]={0};\n");
        emit(g,"    if (_args_argv && _args_argc > 0) {\n");
        emit(g,"        const char *a0=_args_argv[0]; int hasslash=0;\n");
        emit(g,"        for(int i=0;a0[i];i++){if(a0[i]=='/'){hasslash=1;break;}}\n");
        emit(g,"        if (hasslash) {\n");
        emit(g,"            int i=0; while(a0[i]&&i<511){resolved[i]=a0[i];i++;} resolved[i]=0;\n");
        emit(g,"        } else {\n");
        emit(g,"            const char *pe=getenv(\"PATH\");\n");
        emit(g,"            if (pe) {\n");
        emit(g,"                char dir[256]; int di;\n");
        emit(g,"                while (*pe) {\n");
        emit(g,"                    di=0;\n");
        emit(g,"                    while(*pe && *pe!=':'){if(di<255)dir[di++]=*pe; pe++;}\n");
        emit(g,"                    dir[di]=0; if(*pe==':')pe++;\n");
        emit(g,"                    if(di==0) continue;\n");
        emit(g,"                    char cand[512];\n");
        emit(g,"                    snprintf(cand,sizeof(cand),\"%%s/%%s\",dir,a0);\n");
        emit(g,"                    if(access(cand,X_OK)==0){\n");
        emit(g,"                        int i=0; while(cand[i]&&i<511){resolved[i]=cand[i];i++;}\n");
        emit(g,"                        resolved[i]=0; break;\n");
        emit(g,"                    }\n");
        emit(g,"                }\n");
        emit(g,"            }\n");
        emit(g,"        }\n");
        emit(g,"    }\n");
        emit(g,"    /* strip trailing filename, keep directory */\n");
        emit(g,"    int last=-1,i=0; while(resolved[i]){if(resolved[i]=='/')last=i; i++;}\n");
        emit(g,"    if(last>0){for(i=0;i<last;i++)s[i]=resolved[i]; s[last]=0;}\n");
        emit(g,"    else if(last==0){s[0]='/';s[1]=0;}\n");
        emit(g,"    else{s[0]=0;}\n");
        emit(g,"}\n\n");
    }

    /* ── Dict module runtime ─────────────────────────────────────── */
    if (has_dict) {
        emit(g,"/* Dict module — string-keyed hash table */\n");
        emit(g,"#define DICT_BUCKETS 256\n");
        emit(g,"typedef struct Dict_Node_s { char key[256]; char val[256]; struct Dict_Node_s *next; } Dict_Node;\n");
        emit(g,"typedef struct { Dict_Node *buckets[DICT_BUCKETS]; int _ci; Dict_Node *_cn; } Dict_Table;\n");
        emit(g,"static unsigned int Dict_hash(const char *s) {\n");
        emit(g,"    unsigned int h=5381; while(*s) h=((h<<5)+h)^(unsigned char)*s++; return h%%DICT_BUCKETS;\n");
        emit(g,"}\n");
        emit(g,"static void Dict_Init(Dict_Table *d) { memset(d,0,sizeof(*d)); }\n");
        emit(g,"static void Dict_Put(Dict_Table *d, const char *key, const char *val) {\n");
        emit(g,"    unsigned int h=Dict_hash(key);\n");
        emit(g,"    for (Dict_Node *n=d->buckets[h];n;n=n->next) {\n");
        emit(g,"        if (!strcmp(n->key,key)) { strncpy(n->val,val,255); n->val[255]=0; return; }\n");
        emit(g,"    }\n");
        emit(g,"    Dict_Node *n=(Dict_Node*)malloc(sizeof(Dict_Node));\n");
        emit(g,"    strncpy(n->key,key,255); n->key[255]=0;\n");
        emit(g,"    strncpy(n->val,val,255); n->val[255]=0;\n");
        emit(g,"    n->next=d->buckets[h]; d->buckets[h]=n;\n");
        emit(g,"}\n");
        emit(g,"static int Dict_Get(Dict_Table *d, const char *key, char *val) {\n");
        emit(g,"    for (Dict_Node *n=d->buckets[Dict_hash(key)];n;n=n->next)\n");
        emit(g,"        if (!strcmp(n->key,key)) { strncpy(val,n->val,255); val[255]=0; return 1; }\n");
        emit(g,"    val[0]=0; return 0;\n");
        emit(g,"}\n");
        emit(g,"static int Dict_Has(Dict_Table *d, const char *key) {\n");
        emit(g,"    for (Dict_Node *n=d->buckets[Dict_hash(key)];n;n=n->next)\n");
        emit(g,"        if (!strcmp(n->key,key)) return 1;\n");
        emit(g,"    return 0;\n");
        emit(g,"}\n");
        emit(g,"static void Dict_Remove(Dict_Table *d, const char *key) {\n");
        emit(g,"    unsigned int h=Dict_hash(key); Dict_Node **p=&d->buckets[h];\n");
        emit(g,"    while (*p) { if (!strcmp((*p)->key,key)) { Dict_Node *t=*p; *p=t->next; free(t); return; } p=&(*p)->next; }\n");
        emit(g,"}\n");
        emit(g,"static void Dict_Clear(Dict_Table *d) {\n");
        emit(g,"    for (int i=0;i<DICT_BUCKETS;i++) {\n");
        emit(g,"        Dict_Node *n=d->buckets[i];\n");
        emit(g,"        while (n) { Dict_Node *t=n->next; free(n); n=t; }\n");
        emit(g,"        d->buckets[i]=NULL;\n");
        emit(g,"    }\n");
        emit(g,"}\n");
        /* First(VAR d, VAR key, VAR val): BOOLEAN — init iterator, return first entry */
        emit(g,"static int Dict_First(Dict_Table *d, char *key, char *val) {\n");
        emit(g,"    d->_ci=0; d->_cn=NULL;\n");
        emit(g,"    for (int i=0;i<DICT_BUCKETS;i++) {\n");
        emit(g,"        if (d->buckets[i]) {\n");
        emit(g,"            d->_ci=i; d->_cn=d->buckets[i]->next;\n");
        emit(g,"            strncpy(key,d->buckets[i]->key,255); key[255]=0;\n");
        emit(g,"            strncpy(val,d->buckets[i]->val,255); val[255]=0;\n");
        emit(g,"            return 1;\n");
        emit(g,"        }\n");
        emit(g,"    }\n");
        emit(g,"    return 0;\n");
        emit(g,"}\n");
        /* Next(VAR d, VAR key, VAR val): BOOLEAN — advance iterator, return next entry */
        emit(g,"static int Dict_Next(Dict_Table *d, char *key, char *val) {\n");
        emit(g,"    if (d->_cn) {\n");
        emit(g,"        strncpy(key,d->_cn->key,255); key[255]=0;\n");
        emit(g,"        strncpy(val,d->_cn->val,255); val[255]=0;\n");
        emit(g,"        d->_cn=d->_cn->next; return 1;\n");
        emit(g,"    }\n");
        emit(g,"    for (int i=d->_ci+1;i<DICT_BUCKETS;i++) {\n");
        emit(g,"        if (d->buckets[i]) {\n");
        emit(g,"            d->_ci=i; d->_cn=d->buckets[i]->next;\n");
        emit(g,"            strncpy(key,d->buckets[i]->key,255); key[255]=0;\n");
        emit(g,"            strncpy(val,d->buckets[i]->val,255); val[255]=0;\n");
        emit(g,"            return 1;\n");
        emit(g,"        }\n");
        emit(g,"    }\n");
        emit(g,"    return 0;\n");
        emit(g,"}\n\n");
    }

    /* ── Zip module runtime — ZIP archive reading using zlib ─────── */
    if (has_zip) {
        emit(g,"/* Zip module — ZIP archive reading (zlib) */\n");
        emit(g,"#include <zlib.h>\n");
        emit(g,"#include <stdint.h>\n");
        emit(g,"#ifndef OBC_ZIP_TYPES_H_\n#define OBC_ZIP_TYPES_H_\n");
        emit(g,"#define ZIP_MAX_ENTRIES 2048\n");
        emit(g,"#define ZIP_MAX_NAME 512\n");
        emit(g,"typedef struct { char name[ZIP_MAX_NAME]; uint32_t cmethod; uint32_t csize; uint32_t usize; uint32_t offset; } Zip_Entry;\n");
        emit(g,"typedef struct { FILE *fp; int count; Zip_Entry entries[ZIP_MAX_ENTRIES]; } Zip_Rec;\n");
        emit(g,"typedef Zip_Rec *Zip_Archive;\n");
        emit(g,"#endif\n");
        emit(g,"static uint16_t _zip_u16(unsigned char *b){return(uint16_t)(b[0]|(b[1]<<8));}\n");
        emit(g,"static uint32_t _zip_u32(unsigned char *b){return(uint32_t)(b[0]|(b[1]<<8)|(b[2]<<16)|((uint32_t)b[3]<<24));}\n");
        emit(g,"static Zip_Archive Zip_Open(const char *path) {\n");
        emit(g,"    FILE *fp=fopen(path,\"rb\"); if(!fp) return NULL;\n");
        emit(g,"    fseek(fp,0,SEEK_END); long fsz=ftell(fp); int eocd=-1;\n");
        emit(g,"    unsigned char buf[22];\n");
        emit(g,"    for(long i=fsz-22;i>=0&&i>=fsz-65558;i--) {\n");
        emit(g,"        fseek(fp,i,SEEK_SET);\n");
        emit(g,"        if(fread(buf,1,4,fp)!=4) break;\n");
        emit(g,"        if(_zip_u32(buf)==0x06054b50u){eocd=(int)i;break;}\n");
        emit(g,"    }\n");
        emit(g,"    if(eocd<0){fclose(fp);return NULL;}\n");
        emit(g,"    fseek(fp,eocd,SEEK_SET);\n");
        emit(g,"    if(fread(buf,1,22,fp)!=22){fclose(fp);return NULL;}\n");
        emit(g,"    int nent=(int)_zip_u16(buf+8); uint32_t cdoff=_zip_u32(buf+16);\n");
        emit(g,"    Zip_Rec *z=(Zip_Rec*)calloc(1,sizeof(Zip_Rec));\n");
        emit(g,"    if(!z){fclose(fp);return NULL;}\n");
        emit(g,"    z->fp=fp; z->count=0;\n");
        emit(g,"    fseek(fp,cdoff,SEEK_SET);\n");
        emit(g,"    unsigned char cd[46];\n");
        emit(g,"    for(int i=0;i<nent&&z->count<ZIP_MAX_ENTRIES;i++) {\n");
        emit(g,"        if(fread(cd,1,46,fp)!=46) break;\n");
        emit(g,"        if(_zip_u32(cd)!=0x02014b50u) break;\n");
        emit(g,"        uint16_t nl=_zip_u16(cd+28),xl=_zip_u16(cd+30),cl=_zip_u16(cd+32);\n");
        emit(g,"        Zip_Entry *e=&z->entries[z->count++];\n");
        emit(g,"        e->cmethod=_zip_u16(cd+10); e->csize=_zip_u32(cd+20);\n");
        emit(g,"        e->usize=_zip_u32(cd+24);   e->offset=_zip_u32(cd+42);\n");
        emit(g,"        int nn=nl<ZIP_MAX_NAME-1?(int)nl:ZIP_MAX_NAME-1;\n");
        emit(g,"        if(fread(e->name,1,nn,fp)!=(size_t)nn) break;\n");
        emit(g,"        e->name[nn]=0;\n");
        emit(g,"        fseek(fp,xl+cl,SEEK_CUR);\n");
        emit(g,"    }\n");
        emit(g,"    return z;\n");
        emit(g,"}\n");
        emit(g,"static int Zip_Count(Zip_Archive z){return z?z->count:0;}\n");
        emit(g,"static void Zip_EntryName(Zip_Archive z,int i,char *name){\n");
        emit(g,"    if(z&&i>=0&&i<z->count){strncpy(name,z->entries[i].name,ZIP_MAX_NAME-1);name[ZIP_MAX_NAME-1]=0;}\n");
        emit(g,"    else name[0]=0;\n");
        emit(g,"}\n");
        emit(g,"static int Zip_EntrySize(Zip_Archive z,int i){\n");
        emit(g,"    return(z&&i>=0&&i<z->count)?(int)z->entries[i].usize:0;\n");
        emit(g,"}\n");
        emit(g,"static int Zip_Find(Zip_Archive z,const char *name){\n");
        emit(g,"    if(!z) return -1;\n");
        emit(g,"    for(int i=0;i<z->count;i++) if(!strcmp(z->entries[i].name,name)) return i;\n");
        emit(g,"    return -1;\n");
        emit(g,"}\n");
        emit(g,"static int Zip_Extract(Zip_Archive z,int idx,char *buf,int buflen){\n");
        emit(g,"    if(!z||idx<0||idx>=z->count) return -1;\n");
        emit(g,"    Zip_Entry *e=&z->entries[idx];\n");
        emit(g,"    unsigned char lfh[30];\n");
        emit(g,"    fseek(z->fp,e->offset,SEEK_SET);\n");
        emit(g,"    if(fread(lfh,1,30,z->fp)!=30) return -1;\n");
        emit(g,"    if(_zip_u32(lfh)!=0x04034b50u) return -1;\n");
        emit(g,"    fseek(z->fp,_zip_u16(lfh+26)+_zip_u16(lfh+28),SEEK_CUR);\n");
        emit(g,"    if(e->cmethod==0){\n");
        emit(g,"        int n=(int)e->csize<buflen?(int)e->csize:buflen;\n");
        emit(g,"        return(int)fread(buf,1,n,z->fp);\n");
        emit(g,"    } else if(e->cmethod==8){\n");
        emit(g,"        unsigned char *cb=(unsigned char*)malloc(e->csize);\n");
        emit(g,"        if(!cb) return -1;\n");
        emit(g,"        if(fread(cb,1,e->csize,z->fp)!=e->csize){free(cb);return -1;}\n");
        emit(g,"        z_stream s={0}; s.next_in=cb; s.avail_in=(uInt)e->csize;\n");
        emit(g,"        s.next_out=(unsigned char*)buf; s.avail_out=(uInt)buflen;\n");
        emit(g,"        if(inflateInit2(&s,-15)!=Z_OK){free(cb);return -1;}\n");
        emit(g,"        int r=inflate(&s,Z_FINISH); inflateEnd(&s); free(cb);\n");
        emit(g,"        return(r==Z_STREAM_END||r==Z_OK)?(int)s.total_out:-1;\n");
        emit(g,"    }\n");
        emit(g,"    return -1;\n");
        emit(g,"}\n");
        emit(g,"static int Zip_ExtractFile(Zip_Archive z,int idx,const char *dest){\n");
        emit(g,"    if(!z||idx<0||idx>=z->count) return 0;\n");
        emit(g,"    Zip_Entry *e=&z->entries[idx];\n");
        emit(g,"    if(e->usize==0){FILE *fp=fopen(dest,\"wb\");if(!fp)return 0;fclose(fp);return 1;}\n");
        emit(g,"    unsigned char *buf=(unsigned char*)malloc(e->usize);\n");
        emit(g,"    if(!buf) return 0;\n");
        emit(g,"    int n=Zip_Extract(z,idx,(char*)buf,(int)e->usize);\n");
        emit(g,"    if(n<0){free(buf);return 0;}\n");
        emit(g,"    FILE *fp=fopen(dest,\"wb\");\n");
        emit(g,"    if(!fp){free(buf);return 0;}\n");
        emit(g,"    int ok=((int)fwrite(buf,1,n,fp)==n);\n");
        emit(g,"    fclose(fp); free(buf); return ok;\n");
        emit(g,"}\n");
        emit(g,"static void Zip_Close(Zip_Archive z){if(z){if(z->fp)fclose(z->fp);free(z);}}\n\n");
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
            int exp = !is_main && (d->flags & FLAG_EXPORTED);
            Node *val = d->c0;
            if (val && val->kind == ND_STRING) {
                if (strlen(val->str) == 1) {
                    /* Single-char string constant: emit as char so it can be
                     * assigned to CHAR variables and array elements. */
                    char _c = val->str[0];
                    const char *_clit = (_c=='\'') ? "'\\''" : (_c=='\\') ? "'\\\\'" : NULL;
                    if (exp) {
                        if (_clit) emit(g,"static const char %s_%s = %s;\n", g->modname, d->str, _clit);
                        else emit(g,"static const char %s_%s = '%c';\n", g->modname, d->str, _c);
                    } else {
                        if (_clit) emit(g,"static const char %s = %s;\n", d->str, _clit);
                        else emit(g,"static const char %s = '%c';\n", d->str, _c);
                    }
                } else {
                /* Multi-char string: enum can't hold strings; use static const array */
                if (exp) emit(g,"static const char %s_%s[] = ", g->modname, d->str);
                else     emit(g,"static const char %s[] = ", d->str);
                emit_string_lit(g, val->str);
                emit(g,";\n");
                }
            } else if (val && val->kind == ND_REAL) {
                /* Real constant: enum can't hold floats; use static const double */
                if (exp) emit(g,"static const double %s_%s = %s;\n", g->modname, d->str, val->str);
                else     emit(g,"static const double %s = %s;\n", d->str, val->str);
            } else {
                /* Integer/char/expression: enum keeps array-size usability */
                if (exp) emit(g,"enum { %s_%s = ", g->modname, d->str);
                else     emit(g,"enum { %s = ", d->str);
                emit_expr(g, d->c0);
                emit(g," };\n");
            }
            has_consts = 1;
        }
    }
    if (has_consts) emit(g,"\n");

    /* ── Type declarations (emit_type_decl also populates type_tags) ── */
    int has_types = 0;
    for (Node *d=module->c1; d; d=d->next)
        if (d->kind==ND_TYPE_DECL) { emit_type_decl(g,d); has_types=1; }
    /* Emit _TAG_* defines for every registered record type */
    if (g_n_type_tags > 0) {
        for (int i=0;i<g_n_type_tags;i++)
            emit(g,"#define _TAG_%s %d\n", g_type_tags[i], i+1);
        emit(g,"\n");
    } else if (has_types) {
        emit(g,"\n");
    }

    /* ── Frame structs for procedures with nested procs ──────────── */
    for (Node *d=module->c1; d; d=d->next)
        if (d->kind==ND_PROC_DECL) emit_frame_struct(g,d);

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
            if (!is_builtin_module(real) && !ffi_is_registered(real))
                emit(g,"extern void %s_init(void);\n", real);
        }
        if (has_args)
            emit(g,"\nint main(int _argc, char **_argv) {\n");
        else
            emit(g,"\nint main(void) {\n");
        g->indent++;
        if (has_args) {
            iemit(g,"_args_argc = _argc;\n");
            iemit(g,"_args_argv = _argv;\n");
        }
        if (has_terminal) iemit(g,"_term_init();\n");
        for (int i=0;i<g_nimports;i++) {
            const char *real = g_import_real[i];
            if (!is_builtin_module(real) && !ffi_is_registered(real))
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
            if (!is_builtin_module(real) && !ffi_is_registered(real))
                emit(g,"extern void %s_init(void);\n", real);
        }
        emit(g,"\nvoid %s_init(void) {\n", g->modname);
        g->indent++;
        iemit(g,"static int _once = 0;\n");
        iemit(g,"if (_once) return; _once = 1;\n");
        if (has_terminal) iemit(g,"_term_init();\n");
        /* Call each user-module dependency's init */
        for (int i=0;i<g_nimports;i++) {
            const char *real = g_import_real[i];
            if (!is_builtin_module(real) && !ffi_is_registered(real))
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

    int has_dict_h = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_import_real[i],"Dict")) { has_dict_h=1; break; }
    if (has_dict_h) {
        fprintf(out,"#ifndef OBC_DICT_TYPES_H_\n#define OBC_DICT_TYPES_H_\n");
        fprintf(out,"#define DICT_BUCKETS 256\n");
        fprintf(out,"typedef struct Dict_Node_s { char key[256]; char val[256]; struct Dict_Node_s *next; } Dict_Node;\n");
        fprintf(out,"typedef struct { Dict_Node *buckets[DICT_BUCKETS]; int _ci; Dict_Node *_cn; } Dict_Table;\n");
        fprintf(out,"#endif\n\n");
    }

    int has_zip_h = 0;
    for (int i=0;i<g_nimports;i++) if (!strcmp(g_import_real[i],"Zip")) { has_zip_h=1; break; }
    if (has_zip_h) {
        fprintf(out,"#ifndef OBC_ZIP_TYPES_H_\n#define OBC_ZIP_TYPES_H_\n");
        fprintf(out,"#include <stdint.h>\n");
        fprintf(out,"#define ZIP_MAX_ENTRIES 2048\n");
        fprintf(out,"#define ZIP_MAX_NAME 512\n");
        fprintf(out,"typedef struct { char name[ZIP_MAX_NAME]; uint32_t cmethod; uint32_t csize; uint32_t usize; uint32_t offset; } Zip_Entry;\n");
        fprintf(out,"typedef struct { FILE *fp; int count; Zip_Entry entries[ZIP_MAX_ENTRIES]; } Zip_Rec;\n");
        fprintf(out,"typedef Zip_Rec *Zip_Archive;\n");
        fprintf(out,"#endif\n\n");
    }

    /* Include headers for user-imported modules */
    for (int i=0;i<g_nimports;i++) {
        const char *real = g_import_real[i];
        if (is_builtin_module(real)) continue;
        const FfiMod *ffi = ffi_lookup(real);
        if (ffi) {
            fprintf(out,"#include %s\n", ffi->header);
            for (int j = 0; j < ffi->nmaps; j++)
                fprintf(out,"#define %s_%s %s\n",
                        real, ffi->maps[j].oberon, ffi->maps[j].cname);
        } else {
            fprintf(out,"#include \"%s.h\"\n", real);
        }
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
            Node *val = d->c0;
            int exp = d->flags & FLAG_EXPORTED;
            if (val && val->kind == ND_STRING) {
                if (strlen(val->str) == 1) {
                    char _c = val->str[0];
                    const char *_clit = (_c=='\'') ? "'\\''" : (_c=='\\') ? "'\\\\'" : NULL;
                    if (exp) {
                        if (_clit) emit(g,"static const char %s_%s = %s;\n", module->str, d->str, _clit);
                        else emit(g,"static const char %s_%s = '%c';\n", module->str, d->str, _c);
                    } else {
                        if (_clit) emit(g,"static const char %s = %s;\n", d->str, _clit);
                        else emit(g,"static const char %s = '%c';\n", d->str, _c);
                    }
                } else {
                    if (exp) emit(g,"static const char %s_%s[] = ", module->str, d->str);
                    else     emit(g,"static const char %s[] = ", d->str);
                    emit_string_lit(g, val->str);
                    emit(g,";\n");
                }
            } else if (val && val->kind == ND_REAL) {
                if (exp) emit(g,"static const double %s_%s = %s;\n", module->str, d->str, val->str);
                else     emit(g,"static const double %s = %s;\n", d->str, val->str);
            } else {
                if (exp) fprintf(out,"enum { %s_%s = ", module->str, d->str);
                else     fprintf(out,"enum { %s = ", d->str);
                emit_expr(g, d->c0);
                fprintf(out," };\n");
            }
        }
    }

    /* Exported type definitions */
    for (Node *d=module->c1; d; d=d->next) {
        if (d->kind==ND_TYPE_DECL && (d->flags & FLAG_EXPORTED))
            emit_type_decl(g, d);
    }
    /* Emit prefixed _TAG_ModName_TypeName defines so that importing modules
     * can perform IS/WITH type tests on this module's exported record types. */
    for (int _ti = 0; _ti < g_n_type_tags; _ti++) {
        fprintf(out,"#define _TAG_%s_%s %d\n",
                module->str, g_type_tags[_ti], _ti + 1);
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
