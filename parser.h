#ifndef OBERON_PARSER_H
#define OBERON_PARSER_H

#include "lexer.h"

/* -----------------------------------------------------------------------
 * AST node kinds
 *
 * Child-pointer semantics are documented per kind below.
 * c0–c3 are the up-to-four subtrees; next threads sibling lists.
 * ----------------------------------------------------------------------- */
typedef enum {
    /* Module */
    ND_MODULE,      /* str=name  c0=imports  c1=decls  c2=stmts            */
    ND_IMPORT,      /* str=alias c0=IDENT(real-name) if aliased             */
                    /*   flags & FLAG_HAS_ALIAS                             */

    /* Declarations */
    ND_CONST_DECL,  /* str=name  flags=exported  c0=expr                   */
    ND_TYPE_DECL,   /* str=name  flags=exported  c0=type                   */
    ND_VAR_DECL,    /* c0=ident-list  c1=type                              */
    ND_PROC_DECL,   /* str=name  flags=exported                            */
                    /*   c0=params  c1=ret-type  c2=decls  c3=stmts        */
    ND_FPARAM,      /* flags=VAR_PARAM  c0=ident-list  c1=type             */
    ND_FIELD,       /* c0=ident-list  c1=type                              */

    /* Type descriptors */
    ND_TNAME,       /* str=name (may be "Mod.Type" qualified)              */
    ND_TARRAY,      /* c0=len-expr (NULL=open array)  c1=elem-type         */
    ND_TRECORD,     /* str=base-type (or "")  c0=fields                   */
    ND_TPOINTER,    /* c0=base-type                                        */
    ND_TPROC,       /* c0=params  c1=ret-type                              */

    /* Statements */
    ND_ASSIGN,      /* c0=lhs  c1=rhs                                      */
    ND_CALL,        /* c0=proc  c1=args                                    */
    ND_IF,          /* c0=cond  c1=then  c2=elsifs  c3=else                */
    ND_ELSIF,       /* c0=cond  c1=stmts                                   */
    ND_WHILE,       /* c0=cond  c1=body                                    */
    ND_REPEAT,      /* c0=body  c1=cond                                    */
    ND_FOR,         /* str=var  c0=from  c1=to  c2=by  c3=body            */
    ND_RETURN,      /* c0=expr (NULL = bare RETURN)                        */
    ND_CASE,        /* c0=expr  c1=clauses  c2=else                        */
    ND_CASECLAUSE,  /* c0=labels  c1=stmts                                 */
    ND_CASELABEL,   /* c0=lo  c1=hi (hi=NULL if not range)                 */

    /* Expressions / designators */
    ND_IDENT,           /* str=name  flags&FLAG_EXPORTED                   */
    ND_INTEGER,         /* ival                                            */
    ND_REAL,            /* rval  str=source text                           */
    ND_STRING,          /* str=content (no surrounding quotes)             */
    ND_CHAR,            /* ival=char-code  str=source (e.g. "0AX")        */
    ND_NIL,
    ND_TRUE,
    ND_FALSE,
    ND_NEG,             /* unary minus  c0=operand                         */
    ND_NOT,             /* ~            c0=operand                         */
    ND_ADD,             /* c0=left  c1=right                               */
    ND_SUB,
    ND_MUL,
    ND_DIVF,            /* /  (real division)                              */
    ND_DIVI,            /* DIV                                             */
    ND_MOD,
    ND_AND,             /* &                                               */
    ND_OR,
    ND_EQ,
    ND_NEQ,
    ND_LT,
    ND_LE,
    ND_GT,
    ND_GE,
    ND_IN,
    ND_IS,
    ND_DEREF,           /* ^  c0=expr                                      */
    ND_INDEX,           /* [] c0=expr  c1=index                            */
    ND_FIELD_ACCESS,    /* .  c0=expr  str=field-name                      */
    ND_TYPEGUARD,       /* () c0=expr  str=type-name                       */
    ND_SET,             /* {} c0=elements                                  */
    ND_RANGE,           /* .. c0=lo  c1=hi                                 */
} NodeKind;

/* flags bits */
#define FLAG_EXPORTED  1
#define FLAG_VAR_PARAM 2
#define FLAG_HAS_ALIAS 4

#define MAX_IDENT 128

typedef struct Node Node;
struct Node {
    NodeKind kind;
    int      line, col;
    Node    *next;            /* next sibling in a list */
    Node    *c0, *c1, *c2, *c3;
    char     str[MAX_IDENT];
    long     ival;
    double   rval;
    int      flags;
};

/* -----------------------------------------------------------------------
 * Parser
 * ----------------------------------------------------------------------- */
typedef struct {
    Lexer lex;
    Token cur;
    int   errors;
} Parser;

/* Initialise from an open file. */
void  parser_init(Parser *p, FILE *file);

/* Parse a complete MODULE; returns AST root (or NULL on fatal error). */
Node *parse_module(Parser *p);

/* Diagnostics. */
const char *node_kind_name(NodeKind k);
void        ast_print(const Node *n, int indent);

/* Reset the internal node arena (call between files). */
void        ast_free_all(void);

#endif /* OBERON_PARSER_H */
