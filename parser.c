#include "parser.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -----------------------------------------------------------------------
 * Arena allocator — 1 MB pool, reset between files
 * ----------------------------------------------------------------------- */
#define ARENA_SIZE (1 * 1024 * 1024)
static char   g_arena[ARENA_SIZE];
static size_t g_arena_used = 0;

/* -----------------------------------------------------------------------
 * Source-line store — for caret diagnostics
 * ----------------------------------------------------------------------- */
#define MAX_SRC_LINES 8192
#define MAX_SRC_SIZE  (512 * 1024)
static char  g_src_buf[MAX_SRC_SIZE];
static char *g_src_lines[MAX_SRC_LINES];
static int   g_src_nlines = 0;

static void load_source_lines(FILE *f) {
    g_src_nlines = 0;
    int n = (int)fread(g_src_buf, 1, MAX_SRC_SIZE - 1, f);
    g_src_buf[n] = '\0';
    rewind(f);
    /* Split into NUL-terminated lines, stripping \r. */
    char *p = g_src_buf;
    if (g_src_nlines < MAX_SRC_LINES) g_src_lines[g_src_nlines++] = p;
    for (int i = 0; i < n; i++) {
        if (g_src_buf[i] == '\r') { g_src_buf[i] = '\0'; continue; }
        if (g_src_buf[i] == '\n') {
            g_src_buf[i] = '\0';
            if (i + 1 <= n && g_src_nlines < MAX_SRC_LINES)
                g_src_lines[g_src_nlines++] = &g_src_buf[i + 1];
        }
    }
}

void ast_free_all(void) { g_arena_used = 0; g_src_nlines = 0; }

static Node *node_new(NodeKind kind, int line, int col) {
    size_t sz = (sizeof(Node) + 7) & ~(size_t)7;
    if (g_arena_used + sz > ARENA_SIZE) {
        fprintf(stderr, "parser: AST arena exhausted\n");
        exit(1);
    }
    Node *n = (Node *)(g_arena + g_arena_used);
    g_arena_used += sz;
    memset(n, 0, sizeof(Node));
    n->kind = kind;
    n->line = line;
    n->col  = col;
    return n;
}

/* -----------------------------------------------------------------------
 * Intrusive list helpers
 * ----------------------------------------------------------------------- */
typedef struct { Node *head, *tail; } NodeList;

static void list_add(NodeList *l, Node *n) {
    n->next = NULL;
    if (!l->head) { l->head = l->tail = n; }
    else          { l->tail->next = n; l->tail = n; }
}

/* -----------------------------------------------------------------------
 * Parser token management
 * ----------------------------------------------------------------------- */

static void next_tok(Parser *p) {
    p->cur = lexer_next(&p->lex);
}

static void parse_err(Parser *p, const char *fmt, ...) {
    va_list ap;
    int line = p->cur.line, col = p->cur.col;

    /* file:line:col: error: message */
    if (p->filename)
        fprintf(stderr, "%s:%d:%d: error: ", p->filename, line, col);
    else
        fprintf(stderr, "%d:%d: error: ", line, col);
    va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);

    /* Source line + caret, clang-style:
     *    5 | WHILE x =< 5 DO
     *      |         ^-- here
     */
    if (line >= 1 && line <= g_src_nlines) {
        const char *src = g_src_lines[line - 1];
        int plen = snprintf(NULL, 0, " %d | ", line);  /* prefix width */
        fprintf(stderr, " %d | %s\n", line, src);
        /* caret line: (plen-1) spaces + '|' + (col-1) spaces + '^-- here' */
        fprintf(stderr, "%*s|%*s^-- here\n", plen - 1, "", col - 1, "");
    }

    p->errors++;
}

/* Consume if kind matches; report error otherwise. */
static int eat(Parser *p, TokenKind k) {
    if (p->cur.kind == k) { next_tok(p); return 1; }
    parse_err(p, "expected %s, got '%s'",
              token_kind_name(k), p->cur.text);
    return 0;
}

/* Consume and return 1 if kind matches; return 0 without consuming. */
static int match(Parser *p, TokenKind k) {
    if (p->cur.kind != k) return 0;
    next_tok(p); return 1;
}

/* -----------------------------------------------------------------------
 * Forward declarations
 * ----------------------------------------------------------------------- */
static Node *parse_expr(Parser *p);
static Node *parse_type(Parser *p);
static Node *parse_stat_seq(Parser *p);
static Node *parse_decl_seq(Parser *p);

/* -----------------------------------------------------------------------
 * Identifiers
 *
 * parse_ident     — one identifier, returns ND_IDENT
 * parse_identdef  — ident with optional export marker (*)
 * parse_qualident — ident ["." ident]  for type/import contexts
 *                   returns ND_IDENT (unqualified) or str="Mod.Name"
 *
 * parse_designator uses parse_ident + postfix loop, so that
 * "token.kind" → FIELD_ACCESS rather than collapsing into a string.
 * ----------------------------------------------------------------------- */

static Node *parse_ident(Parser *p) {
    if (p->cur.kind != TOK_IDENT) {
        parse_err(p, "expected identifier, got '%s'", p->cur.text);
        Node *n = node_new(ND_IDENT, p->cur.line, p->cur.col);
        strncpy(n->str, "<missing>", MAX_IDENT - 1);
        return n;
    }
    Node *n = node_new(ND_IDENT, p->cur.line, p->cur.col);
    strncpy(n->str, p->cur.text, MAX_IDENT - 1);
    next_tok(p);
    return n;
}

static Node *parse_identdef(Parser *p) {
    Node *n = parse_ident(p);
    if (match(p, TOK_STAR)) n->flags |= FLAG_EXPORTED;
    return n;
}

/* For type names: consumes ident or ident "." ident.
 * Returns ND_IDENT with str = simple name, or str = "Mod.Name". */
static Node *parse_qualident(Parser *p) {
    Node *n = parse_ident(p);
    if (p->cur.kind == TOK_DOT) {
        /* Peek: is next token an identifier? */
        next_tok(p);
        if (p->cur.kind == TOK_IDENT) {
            char buf[MAX_IDENT];
            snprintf(buf, MAX_IDENT, "%s.%s", n->str, p->cur.text);
            strncpy(n->str, buf, MAX_IDENT - 1);
            next_tok(p);
        } else {
            parse_err(p, "expected identifier after '.'");
        }
    }
    return n;
}

/* -----------------------------------------------------------------------
 * IMPORT list
 * IMPORT [alias ":="] modname {"," [alias ":="] modname} ";"
 * ----------------------------------------------------------------------- */
static Node *parse_import_list(Parser *p) {
    eat(p, TOK_IMPORT);
    NodeList list = {0};
    do {
        if (p->cur.kind != TOK_IDENT) { parse_err(p, "expected module name"); break; }
        Node *n = node_new(ND_IMPORT, p->cur.line, p->cur.col);
        strncpy(n->str, p->cur.text, MAX_IDENT - 1);
        next_tok(p);
        if (match(p, TOK_ASSIGN)) {
            /* str holds alias; c0 holds real module name */
            n->flags |= FLAG_HAS_ALIAS;
            n->c0 = parse_ident(p);
        }
        list_add(&list, n);
    } while (match(p, TOK_COMMA));
    eat(p, TOK_SEMI);
    return list.head;
}

/* -----------------------------------------------------------------------
 * Types
 * ----------------------------------------------------------------------- */

/* IdentList = IdentDef {"," IdentDef} */
static Node *parse_ident_list(Parser *p) {
    NodeList list = {0};
    do { list_add(&list, parse_identdef(p)); } while (match(p, TOK_COMMA));
    return list.head;
}

/* FieldList = IdentList ":" Type   (may be empty — returns NULL) */
static Node *parse_field_list(Parser *p) {
    if (p->cur.kind != TOK_IDENT) return NULL;
    Node *n = node_new(ND_FIELD, p->cur.line, p->cur.col);
    n->c0 = parse_ident_list(p);
    eat(p, TOK_COLON);
    n->c1 = parse_type(p);
    return n;
}

/* FPSection = [VAR] IdentList ":" Type */
static Node *parse_fp_section(Parser *p) {
    Node *n = node_new(ND_FPARAM, p->cur.line, p->cur.col);
    if (match(p, TOK_VAR)) n->flags |= FLAG_VAR_PARAM;
    n->c0 = parse_ident_list(p);
    eat(p, TOK_COLON);
    n->c1 = parse_type(p);
    return n;
}

/* FormalPars = "(" [FPSection {";" FPSection}] ")" [":" QualIdent]
 * Writes return type into *ret_out. */
static Node *parse_formal_pars(Parser *p, Node **ret_out) {
    *ret_out = NULL;
    eat(p, TOK_LPAREN);
    NodeList list = {0};
    if (p->cur.kind != TOK_RPAREN) {
        do { list_add(&list, parse_fp_section(p)); } while (match(p, TOK_SEMI));
    }
    eat(p, TOK_RPAREN);
    if (match(p, TOK_COLON)) {
        Node *rn = node_new(ND_TNAME, p->cur.line, p->cur.col);
        Node *qi = parse_qualident(p);
        strncpy(rn->str, qi->str, MAX_IDENT - 1);
        *ret_out = rn;
    }
    return list.head;
}

/* Type = QualIdent
 *      | ARRAY [ConstExpr {"," ConstExpr}] OF Type
 *      | RECORD ["(" QualIdent ")"] {FieldList ";"} END
 *      | POINTER TO Type
 *      | PROCEDURE [FormalPars]
 */
static Node *parse_type(Parser *p) {
    int line = p->cur.line, col = p->cur.col;

    /* ARRAY ---------------------------------------------------------- */
    if (p->cur.kind == TOK_ARRAY) {
        next_tok(p);
        /* Collect dimension expressions (empty = open array) */
        Node *dims[8]; int ndims = 0;
        if (p->cur.kind != TOK_OF) {
            do {
                if (ndims < 8) dims[ndims++] = parse_expr(p);
                else { parse_expr(p); /* discard */ }
            } while (match(p, TOK_COMMA));
        }
        eat(p, TOK_OF);
        Node *elem = parse_type(p);
        /* Build nested TARRAY nodes right-to-left so that
         * ARRAY n, m OF T  ≡  ARRAY n OF (ARRAY m OF T)         */
        Node *result = elem;
        if (ndims == 0) {
            /* Open array parameter */
            Node *a = node_new(ND_TARRAY, line, col);
            a->c0 = NULL; a->c1 = result;
            result = a;
        } else {
            for (int i = ndims - 1; i >= 0; i--) {
                Node *a = node_new(ND_TARRAY, line, col);
                a->c0 = dims[i]; a->c1 = result;
                result = a;
            }
        }
        return result;
    }

    /* RECORD --------------------------------------------------------- */
    if (p->cur.kind == TOK_RECORD) {
        next_tok(p);
        Node *n = node_new(ND_TRECORD, line, col);
        if (match(p, TOK_LPAREN)) {
            Node *base = parse_qualident(p);
            strncpy(n->str, base->str, MAX_IDENT - 1);
            eat(p, TOK_RPAREN);
        }
        NodeList fields = {0};
        /* FieldList {";" FieldList} — a FieldList may be empty */
        for (;;) {
            Node *fl = parse_field_list(p);
            if (fl) list_add(&fields, fl);
            if (!match(p, TOK_SEMI)) break;
            if (p->cur.kind == TOK_END) break;
        }
        eat(p, TOK_END);
        n->c0 = fields.head;
        return n;
    }

    /* POINTER -------------------------------------------------------- */
    if (p->cur.kind == TOK_POINTER) {
        next_tok(p);
        eat(p, TOK_TO);
        Node *n = node_new(ND_TPOINTER, line, col);
        n->c0 = parse_type(p);
        return n;
    }

    /* PROCEDURE type ------------------------------------------------- */
    if (p->cur.kind == TOK_PROCEDURE) {
        next_tok(p);
        Node *n = node_new(ND_TPROC, line, col);
        if (p->cur.kind == TOK_LPAREN) {
            Node *ret = NULL;
            n->c0 = parse_formal_pars(p, &ret);
            n->c1 = ret;
        }
        return n;
    }

    /* Named type (QualIdent) ----------------------------------------- */
    Node *n = node_new(ND_TNAME, line, col);
    Node *qi = parse_qualident(p);
    strncpy(n->str, qi->str, MAX_IDENT - 1);
    return n;
}

/* -----------------------------------------------------------------------
 * Declarations
 * ----------------------------------------------------------------------- */

static Node *parse_const_decl(Parser *p) {
    Node *id = parse_identdef(p);
    Node *n  = node_new(ND_CONST_DECL, id->line, id->col);
    strncpy(n->str, id->str, MAX_IDENT - 1);
    n->flags = id->flags;
    eat(p, TOK_EQ);
    n->c0 = parse_expr(p);
    return n;
}

static Node *parse_type_decl(Parser *p) {
    Node *id = parse_identdef(p);
    Node *n  = node_new(ND_TYPE_DECL, id->line, id->col);
    strncpy(n->str, id->str, MAX_IDENT - 1);
    n->flags = id->flags;
    eat(p, TOK_EQ);
    n->c0 = parse_type(p);
    return n;
}

static Node *parse_var_decl(Parser *p) {
    Node *n = node_new(ND_VAR_DECL, p->cur.line, p->cur.col);
    n->c0 = parse_ident_list(p);
    eat(p, TOK_COLON);
    n->c1 = parse_type(p);
    return n;
}

/* ProcDecl = PROCEDURE IdentDef [FormalPars] ";" ProcBody END ident
 * ProcBody = DeclSeq [BEGIN StatSeq]                                  */
static Node *parse_proc_decl(Parser *p) {
    int line = p->cur.line, col = p->cur.col;
    eat(p, TOK_PROCEDURE);
    Node *id = parse_identdef(p);
    Node *n  = node_new(ND_PROC_DECL, line, col);
    strncpy(n->str, id->str, MAX_IDENT - 1);
    n->flags = id->flags;
    if (p->cur.kind == TOK_LPAREN) {
        Node *ret = NULL;
        n->c0 = parse_formal_pars(p, &ret);
        n->c1 = ret;
    }
    eat(p, TOK_SEMI);
    n->c2 = parse_decl_seq(p);
    if (match(p, TOK_BEGIN)) n->c3 = parse_stat_seq(p);
    eat(p, TOK_END);
    if (p->cur.kind == TOK_IDENT) {
        if (strcmp(p->cur.text, n->str) != 0)
            parse_err(p, "END %s does not match PROCEDURE %s",
                      p->cur.text, n->str);
        next_tok(p);
    }
    return n;
}

/* DeclSeq = {CONST {ConstDecl ";"} | TYPE {TypeDecl ";"} | VAR {VarDecl ";"}}
 *           {ProcDecl ";"}                                              */
static Node *parse_decl_seq(Parser *p) {
    NodeList list = {0};
    for (;;) {
        if (p->cur.kind == TOK_CONST) {
            next_tok(p);
            while (p->cur.kind == TOK_IDENT) {
                list_add(&list, parse_const_decl(p));
                eat(p, TOK_SEMI);
            }
        } else if (p->cur.kind == TOK_TYPE) {
            next_tok(p);
            while (p->cur.kind == TOK_IDENT) {
                list_add(&list, parse_type_decl(p));
                eat(p, TOK_SEMI);
            }
        } else if (p->cur.kind == TOK_VAR) {
            next_tok(p);
            while (p->cur.kind == TOK_IDENT) {
                list_add(&list, parse_var_decl(p));
                eat(p, TOK_SEMI);
            }
        } else if (p->cur.kind == TOK_PROCEDURE) {
            list_add(&list, parse_proc_decl(p));
            eat(p, TOK_SEMI);
        } else {
            break;
        }
    }
    return list.head;
}

/* -----------------------------------------------------------------------
 * Expressions
 * ----------------------------------------------------------------------- */

/* Designator = ident {"." ident | "[" Expr "]" | "^" | "(" QualIdent ")"} */
static Node *parse_designator(Parser *p) {
    Node *n = parse_ident(p);
    for (;;) {
        if (p->cur.kind == TOK_DOT) {
            next_tok(p);
            if (p->cur.kind != TOK_IDENT) {
                parse_err(p, "expected field name after '.'");
                break;
            }
            Node *fa = node_new(ND_FIELD_ACCESS, n->line, n->col);
            fa->c0 = n;
            strncpy(fa->str, p->cur.text, MAX_IDENT - 1);
            next_tok(p);
            n = fa;
        } else if (p->cur.kind == TOK_LBRACKET) {
            next_tok(p);
            Node *idx = node_new(ND_INDEX, n->line, n->col);
            idx->c0 = n;
            idx->c1 = parse_expr(p);
            n = idx;
            /* Handle m[i, j] as m[i][j] */
            while (p->cur.kind == TOK_COMMA) {
                next_tok(p);
                Node *idx2 = node_new(ND_INDEX, n->line, n->col);
                idx2->c0 = n;
                idx2->c1 = parse_expr(p);
                n = idx2;
            }
            eat(p, TOK_RBRACKET);
        } else if (p->cur.kind == TOK_CARET) {
            Node *deref = node_new(ND_DEREF, n->line, n->col);
            deref->c0 = n;
            next_tok(p);
            n = deref;
        } else {
            break;
        }
    }
    return n;
}

/* Factor = Designator [ActualPars]
 *        | number | string | char | NIL | TRUE | FALSE
 *        | "{" [SetElements] "}"
 *        | "(" Expr ")"
 *        | "~" Factor                                                    */
static Node *parse_factor(Parser *p) {
    int line = p->cur.line, col = p->cur.col;

    switch (p->cur.kind) {
    case TOK_INTEGER: {
        Node *n = node_new(ND_INTEGER, line, col);
        n->ival = p->cur.int_val;
        strncpy(n->str, p->cur.text, MAX_IDENT - 1);
        next_tok(p);
        return n;
    }
    case TOK_REAL: {
        Node *n = node_new(ND_REAL, line, col);
        n->rval = p->cur.real_val;
        strncpy(n->str, p->cur.text, MAX_IDENT - 1);
        next_tok(p);
        return n;
    }
    case TOK_STRING: {
        Node *n = node_new(ND_STRING, line, col);
        strncpy(n->str, p->cur.text, MAX_IDENT - 1);
        next_tok(p);
        return n;
    }
    case TOK_CHAR: {
        Node *n = node_new(ND_CHAR, line, col);
        n->ival = p->cur.int_val;
        strncpy(n->str, p->cur.text, MAX_IDENT - 1);
        next_tok(p);
        return n;
    }
    case TOK_NIL:   { Node *n = node_new(ND_NIL,   line, col); next_tok(p); return n; }
    case TOK_TRUE:  { Node *n = node_new(ND_TRUE,  line, col); next_tok(p); return n; }
    case TOK_FALSE: { Node *n = node_new(ND_FALSE, line, col); next_tok(p); return n; }

    case TOK_TILDE: {
        next_tok(p);
        Node *n = node_new(ND_NOT, line, col);
        n->c0 = parse_factor(p);
        return n;
    }
    case TOK_LPAREN: {
        next_tok(p);
        Node *n = parse_expr(p);
        eat(p, TOK_RPAREN);
        return n;
    }
    case TOK_LBRACE: {
        /* Set constructor: "{" [Expr [".." Expr] {"," ...}] "}" */
        next_tok(p);
        Node *n = node_new(ND_SET, line, col);
        NodeList elems = {0};
        while (p->cur.kind != TOK_RBRACE && p->cur.kind != TOK_EOF) {
            Node *lo = parse_expr(p);
            if (match(p, TOK_DOTDOT)) {
                Node *rng = node_new(ND_RANGE, lo->line, lo->col);
                rng->c0 = lo;
                rng->c1 = parse_expr(p);
                list_add(&elems, rng);
            } else {
                list_add(&elems, lo);
            }
            if (!match(p, TOK_COMMA)) break;
        }
        eat(p, TOK_RBRACE);
        n->c0 = elems.head;
        return n;
    }
    case TOK_IDENT: {
        /* Designator, then optional ActualPars if it's a function call */
        Node *d = parse_designator(p);
        if (p->cur.kind == TOK_LPAREN) {
            next_tok(p);
            Node *call = node_new(ND_CALL, d->line, d->col);
            call->c0 = d;
            NodeList args = {0};
            if (p->cur.kind != TOK_RPAREN) {
                do { list_add(&args, parse_expr(p)); } while (match(p, TOK_COMMA));
            }
            eat(p, TOK_RPAREN);
            call->c1 = args.head;
            return call;
        }
        return d;
    }
    default:
        parse_err(p, "unexpected '%s' in expression", p->cur.text);
        next_tok(p);
        return node_new(ND_INTEGER, line, col); /* dummy recovery node */
    }
}

/* Term = Factor {("*" | "/" | DIV | MOD) Factor}
 *
 * NOTE: "&" (AND) is NOT at this level — see parse_and_expr below.
 * We use C-like boolean precedence so that compiler.mod expressions like
 *   ch = ' ' OR ch = 0DX
 * parse as (ch = ' ') OR (ch = 0DX) rather than ch = (' ' OR ch).
 * Precedence (lowest → highest):
 *   OR  <  &  <  relations  <  +/-  <  MUL/DIV/MOD  <  unary  <  factor
 */
static Node *parse_term(Parser *p) {
    Node *left = parse_factor(p);
    for (;;) {
        NodeKind op;
        switch (p->cur.kind) {
        case TOK_STAR:  op = ND_MUL;  break;
        case TOK_SLASH: op = ND_DIVF; break;
        case TOK_DIV:   op = ND_DIVI; break;
        case TOK_MOD:   op = ND_MOD;  break;
        default: return left;
        }
        int ln = p->cur.line, cn = p->cur.col;
        next_tok(p);
        Node *n = node_new(op, ln, cn);
        n->c0 = left; n->c1 = parse_factor(p);
        left = n;
    }
}

/* SimpleExpr = ["+" | "-"] Term {("+" | "-") Term} */
static Node *parse_simple_expr(Parser *p) {
    int line = p->cur.line, col = p->cur.col;
    int negate = 0;
    if      (match(p, TOK_PLUS))  { /* ignore unary + */ }
    else if (match(p, TOK_MINUS)) { negate = 1; }

    Node *left = parse_term(p);
    if (negate) {
        Node *neg = node_new(ND_NEG, line, col);
        neg->c0 = left;
        left = neg;
    }
    for (;;) {
        NodeKind op;
        switch (p->cur.kind) {
        case TOK_PLUS:  op = ND_ADD; break;
        case TOK_MINUS: op = ND_SUB; break;
        default: return left;
        }
        int ln = p->cur.line, cn = p->cur.col;
        next_tok(p);
        Node *n = node_new(op, ln, cn);
        n->c0 = left; n->c1 = parse_term(p);
        left = n;
    }
}

/* RelExpr = SimpleExpr [RelOp SimpleExpr]
 * RelOp = "=" | "#" | "<" | "<=" | ">" | ">=" | IN | IS            */
static Node *parse_rel_expr(Parser *p) {
    Node *left = parse_simple_expr(p);
    NodeKind op;
    switch (p->cur.kind) {
    case TOK_EQ:  op = ND_EQ;  break;
    case TOK_NEQ: op = ND_NEQ; break;
    case TOK_LT:  op = ND_LT;  break;
    case TOK_LE:  op = ND_LE;  break;
    case TOK_GT:  op = ND_GT;  break;
    case TOK_GE:  op = ND_GE;  break;
    case TOK_IN:  op = ND_IN;  break;
    case TOK_IS:  op = ND_IS;  break;
    default:      return left;
    }
    int line = p->cur.line, col = p->cur.col;
    next_tok(p);
    Node *n = node_new(op, line, col);
    n->c0 = left; n->c1 = parse_simple_expr(p);
    return n;
}

/* AndExpr = RelExpr {"&" RelExpr} */
static Node *parse_and_expr(Parser *p) {
    Node *left = parse_rel_expr(p);
    while (p->cur.kind == TOK_AMP) {
        int ln = p->cur.line, cn = p->cur.col;
        next_tok(p);
        Node *n = node_new(ND_AND, ln, cn);
        n->c0 = left; n->c1 = parse_rel_expr(p);
        left = n;
    }
    return left;
}

/* Expr = AndExpr {OR AndExpr} */
static Node *parse_expr(Parser *p) {
    Node *left = parse_and_expr(p);
    while (p->cur.kind == TOK_OR) {
        int ln = p->cur.line, cn = p->cur.col;
        next_tok(p);
        Node *n = node_new(ND_OR, ln, cn);
        n->c0 = left; n->c1 = parse_and_expr(p);
        left = n;
    }
    return left;
}

/* -----------------------------------------------------------------------
 * Statements
 *
 * StatSeq = Statement {";" Statement}
 * Statement = Designator (":=" Expr | [ActualPars])
 *           | IF ... | WHILE ... | REPEAT ... | FOR ... | CASE ...
 *           | RETURN [Expr]
 *           | (* empty *)
 * ----------------------------------------------------------------------- */
static Node *parse_stat_seq(Parser *p) {
    NodeList list = {0};
    for (;;) {
        int line = p->cur.line, col = p->cur.col;
        Node *s = NULL;

        switch (p->cur.kind) {

        /* Assignment or procedure call */
        case TOK_IDENT: {
            Node *d = parse_designator(p);
            if (match(p, TOK_ASSIGN)) {
                s = node_new(ND_ASSIGN, line, col);
                s->c0 = d; s->c1 = parse_expr(p);
            } else {
                s = node_new(ND_CALL, line, col);
                s->c0 = d;
                if (p->cur.kind == TOK_LPAREN) {
                    next_tok(p);
                    NodeList args = {0};
                    if (p->cur.kind != TOK_RPAREN) {
                        do { list_add(&args, parse_expr(p)); }
                        while (match(p, TOK_COMMA));
                    }
                    eat(p, TOK_RPAREN);
                    s->c1 = args.head;
                }
            }
            break;
        }

        /* IF cond THEN stmts {ELSIF cond THEN stmts} [ELSE stmts] END */
        case TOK_IF: {
            next_tok(p);
            s = node_new(ND_IF, line, col);
            s->c0 = parse_expr(p);
            eat(p, TOK_THEN);
            s->c1 = parse_stat_seq(p);
            NodeList elsifs = {0};
            while (p->cur.kind == TOK_ELSIF) {
                int el = p->cur.line, ec = p->cur.col;
                next_tok(p);
                Node *ei = node_new(ND_ELSIF, el, ec);
                ei->c0 = parse_expr(p);
                eat(p, TOK_THEN);
                ei->c1 = parse_stat_seq(p);
                list_add(&elsifs, ei);
            }
            s->c2 = elsifs.head;
            if (match(p, TOK_ELSE)) s->c3 = parse_stat_seq(p);
            eat(p, TOK_END);
            break;
        }

        /* WHILE cond DO stmts END */
        case TOK_WHILE: {
            next_tok(p);
            s = node_new(ND_WHILE, line, col);
            s->c0 = parse_expr(p);
            eat(p, TOK_DO);
            s->c1 = parse_stat_seq(p);
            eat(p, TOK_END);
            break;
        }

        /* REPEAT stmts UNTIL cond */
        case TOK_REPEAT: {
            next_tok(p);
            s = node_new(ND_REPEAT, line, col);
            s->c0 = parse_stat_seq(p);
            eat(p, TOK_UNTIL);
            s->c1 = parse_expr(p);
            break;
        }

        /* FOR var ":=" from TO to [BY step] DO stmts END */
        case TOK_FOR: {
            next_tok(p);
            s = node_new(ND_FOR, line, col);
            if (p->cur.kind == TOK_IDENT) {
                strncpy(s->str, p->cur.text, MAX_IDENT - 1);
                next_tok(p);
            } else parse_err(p, "expected loop variable");
            eat(p, TOK_ASSIGN);
            s->c0 = parse_expr(p);   /* from */
            eat(p, TOK_TO);
            s->c1 = parse_expr(p);   /* to   */
            if (match(p, TOK_BY)) s->c2 = parse_expr(p); /* by */
            eat(p, TOK_DO);
            s->c3 = parse_stat_seq(p);
            eat(p, TOK_END);
            break;
        }

        /* LOOP stmts END */
        case TOK_LOOP: {
            next_tok(p);
            s = node_new(ND_LOOP, line, col);
            s->c0 = parse_stat_seq(p);
            eat(p, TOK_END);
            break;
        }

        /* EXIT */
        case TOK_EXIT: {
            next_tok(p);
            s = node_new(ND_EXIT, line, col);
            break;
        }

        /* CASE expr OF Case {"|" Case} [ELSE stmts] END
         * Case = [CaseLabelList ":" StatSeq]                            */
        case TOK_CASE: {
            next_tok(p);
            s = node_new(ND_CASE, line, col);
            s->c0 = parse_expr(p);
            eat(p, TOK_OF);
            NodeList clauses = {0};
            do {
                if (p->cur.kind == TOK_ELSE || p->cur.kind == TOK_END ||
                    p->cur.kind == TOK_EOF)  break;
                int cl = p->cur.line, cc = p->cur.col;
                Node *clause = node_new(ND_CASECLAUSE, cl, cc);
                NodeList labels = {0};
                do {
                    int ll = p->cur.line, lc = p->cur.col;
                    Node *lo = parse_expr(p);
                    Node *lbl = node_new(ND_CASELABEL, ll, lc);
                    lbl->c0 = lo;
                    if (match(p, TOK_DOTDOT)) lbl->c1 = parse_expr(p);
                    list_add(&labels, lbl);
                } while (match(p, TOK_COMMA));
                eat(p, TOK_COLON);
                clause->c0 = labels.head;
                clause->c1 = parse_stat_seq(p);
                list_add(&clauses, clause);
            } while (match(p, TOK_BAR));
            s->c1 = clauses.head;
            if (match(p, TOK_ELSE)) s->c2 = parse_stat_seq(p);
            eat(p, TOK_END);
            break;
        }

        /* WITH Guard DO stmts {"|" Guard DO stmts} [ELSE stmts] END
         * Guard = qualident ":" qualident                                  */
        case TOK_WITH: {
            next_tok(p);
            s = node_new(ND_WITH, line, col);
            NodeList clauses = {0};
            do {
                int cl = p->cur.line, cc = p->cur.col;
                Node *wc = node_new(ND_WITHCLAUSE, cl, cc);
                wc->c0 = parse_expr(p);   /* variable (qualident) */
                eat(p, TOK_COLON);
                /* type name: IDENT [. IDENT] */
                if (p->cur.kind == TOK_IDENT) {
                    char qname[MAX_IDENT]; strncpy(qname, p->cur.text, MAX_IDENT-1);
                    next_tok(p);
                    if (p->cur.kind == TOK_DOT) {
                        next_tok(p);
                        if (p->cur.kind == TOK_IDENT) {
                            snprintf(wc->str, MAX_IDENT, "%s.%s", qname, p->cur.text);
                            next_tok(p);
                        }
                    } else { strncpy(wc->str, qname, MAX_IDENT-1); }
                } else parse_err(p, "expected type name in WITH guard");
                eat(p, TOK_DO);
                wc->c1 = parse_stat_seq(p);
                list_add(&clauses, wc);
            } while (match(p, TOK_BAR));
            s->c0 = clauses.head;
            if (match(p, TOK_ELSE)) s->c1 = parse_stat_seq(p);
            eat(p, TOK_END);
            break;
        }

        /* RETURN [Expr] */
        case TOK_RETURN: {
            next_tok(p);
            s = node_new(ND_RETURN, line, col);
            /* Only parse expression if next token can start one */
            if (p->cur.kind != TOK_SEMI  && p->cur.kind != TOK_END  &&
                p->cur.kind != TOK_ELSE  && p->cur.kind != TOK_ELSIF &&
                p->cur.kind != TOK_UNTIL && p->cur.kind != TOK_EOF)
                s->c0 = parse_expr(p);
            break;
        }

        /* Empty statement or end of sequence */
        default:
            goto end_seq;
        }

        if (s) list_add(&list, s);
        if (!match(p, TOK_SEMI)) break;
    }
end_seq:
    return list.head;
}

/* -----------------------------------------------------------------------
 * Module
 * MODULE ident ";" [ImportList] DeclSeq [BEGIN StatSeq] END ident "."
 * ----------------------------------------------------------------------- */

void parser_init(Parser *p, FILE *file) {
    memset(p, 0, sizeof(*p));
    load_source_lines(file);   /* reads + rewinds */
    lexer_init(&p->lex, file);
    next_tok(p);
}

Node *parse_module(Parser *p) {
    int line = p->cur.line, col = p->cur.col;
    eat(p, TOK_MODULE);
    Node *n = node_new(ND_MODULE, line, col);
    if (p->cur.kind == TOK_IDENT) {
        strncpy(n->str, p->cur.text, MAX_IDENT - 1);
        next_tok(p);
    } else parse_err(p, "expected module name");
    eat(p, TOK_SEMI);
    if (p->cur.kind == TOK_IMPORT) n->c0 = parse_import_list(p);
    n->c1 = parse_decl_seq(p);
    if (match(p, TOK_BEGIN)) n->c2 = parse_stat_seq(p);
    eat(p, TOK_END);
    if (p->cur.kind == TOK_IDENT) {
        if (strcmp(p->cur.text, n->str) != 0)
            parse_err(p, "END %s does not match MODULE %s",
                      p->cur.text, n->str);
        next_tok(p);
    }
    eat(p, TOK_DOT);
    return n;
}

/* -----------------------------------------------------------------------
 * Diagnostics
 * ----------------------------------------------------------------------- */

const char *node_kind_name(NodeKind k) {
    switch (k) {
    case ND_MODULE:      return "MODULE";
    case ND_IMPORT:      return "IMPORT";
    case ND_CONST_DECL:  return "CONST_DECL";
    case ND_TYPE_DECL:   return "TYPE_DECL";
    case ND_VAR_DECL:    return "VAR_DECL";
    case ND_PROC_DECL:   return "PROC_DECL";
    case ND_FPARAM:      return "FPARAM";
    case ND_FIELD:       return "FIELD";
    case ND_TNAME:       return "TNAME";
    case ND_TARRAY:      return "TARRAY";
    case ND_TRECORD:     return "TRECORD";
    case ND_TPOINTER:    return "TPOINTER";
    case ND_TPROC:       return "TPROC";
    case ND_ASSIGN:      return "ASSIGN";
    case ND_CALL:        return "CALL";
    case ND_IF:          return "IF";
    case ND_ELSIF:       return "ELSIF";
    case ND_WHILE:       return "WHILE";
    case ND_REPEAT:      return "REPEAT";
    case ND_FOR:         return "FOR";
    case ND_LOOP:        return "LOOP";
    case ND_EXIT:        return "EXIT";
    case ND_RETURN:      return "RETURN";
    case ND_CASE:        return "CASE";
    case ND_CASECLAUSE:  return "CASECLAUSE";
    case ND_CASELABEL:   return "CASELABEL";
    case ND_WITH:        return "WITH";
    case ND_WITHCLAUSE:  return "WITHCLAUSE";
    case ND_IDENT:       return "IDENT";
    case ND_INTEGER:     return "INTEGER";
    case ND_REAL:        return "REAL";
    case ND_STRING:      return "STRING";
    case ND_CHAR:        return "CHAR";
    case ND_NIL:         return "NIL";
    case ND_TRUE:        return "TRUE";
    case ND_FALSE:       return "FALSE";
    case ND_NEG:         return "NEG";
    case ND_NOT:         return "NOT";
    case ND_ADD:         return "ADD";
    case ND_SUB:         return "SUB";
    case ND_MUL:         return "MUL";
    case ND_DIVF:        return "DIVF";
    case ND_DIVI:        return "DIVI";
    case ND_MOD:         return "MOD";
    case ND_AND:         return "AND";
    case ND_OR:          return "OR";
    case ND_EQ:          return "EQ";
    case ND_NEQ:         return "NEQ";
    case ND_LT:          return "LT";
    case ND_LE:          return "LE";
    case ND_GT:          return "GT";
    case ND_GE:          return "GE";
    case ND_IN:          return "IN";
    case ND_IS:          return "IS";
    case ND_DEREF:       return "DEREF";
    case ND_INDEX:       return "INDEX";
    case ND_FIELD_ACCESS:return "FIELD_ACCESS";
    case ND_TYPEGUARD:   return "TYPEGUARD";
    case ND_SET:         return "SET";
    case ND_RANGE:       return "RANGE";
    default:             return "?";
    }
}

/* Recursive tree printer — children at indent+1, siblings at same indent. */
void ast_print(const Node *n, int indent) {
    if (!n) return;
    for (int i = 0; i < indent; i++) printf("  ");
    printf("%s", node_kind_name(n->kind));
    if (n->str[0])               printf(" \"%s\"", n->str);
    if (n->kind == ND_INTEGER)   printf(" (%ld)", n->ival);
    if (n->kind == ND_CHAR)      printf(" (\\%ld)", n->ival);
    if (n->kind == ND_REAL)      printf(" (%g)", n->rval);
    if (n->flags & FLAG_EXPORTED)  printf(" *");
    if (n->flags & FLAG_VAR_PARAM) printf(" VAR");
    if (n->flags & FLAG_HAS_ALIAS) printf(" aliased");
    printf("\n");
    if (n->c0) ast_print(n->c0, indent + 1);
    if (n->c1) ast_print(n->c1, indent + 1);
    if (n->c2) ast_print(n->c2, indent + 1);
    if (n->c3) ast_print(n->c3, indent + 1);
    if (n->next) ast_print(n->next, indent);
}
