#ifndef OBERON_LEXER_H
#define OBERON_LEXER_H

#include <stdio.h>

/* -----------------------------------------------------------------------
 * Token kinds — covers full Oberon-07 plus common extensions.
 * ----------------------------------------------------------------------- */
typedef enum {
    TOK_EOF = 0,
    TOK_ERROR,

    /* Literals */
    TOK_IDENT,
    TOK_INTEGER,
    TOK_REAL,
    TOK_STRING,
    TOK_CHAR,       /* hex char literal: 0AX, 0X, etc. */

    /* Keywords (alphabetical) */
    TOK_ARRAY,
    TOK_BEGIN,
    TOK_BY,
    TOK_CASE,
    TOK_CONST,
    TOK_DIV,
    TOK_DO,
    TOK_ELSE,
    TOK_ELSIF,
    TOK_END,
    TOK_FALSE,
    TOK_FOR,
    TOK_IF,
    TOK_IMPORT,
    TOK_EXIT,
    TOK_IN,
    TOK_IS,
    TOK_LOOP,
    TOK_MOD,
    TOK_MODULE,
    TOK_NIL,
    TOK_OF,
    TOK_OR,
    TOK_POINTER,
    TOK_PROCEDURE,
    TOK_RECORD,
    TOK_REPEAT,
    TOK_RETURN,
    TOK_THEN,
    TOK_TO,
    TOK_TRUE,
    TOK_TYPE,
    TOK_UNTIL,
    TOK_VAR,
    TOK_WHILE,
    TOK_WITH,

    /* Operators */
    TOK_PLUS,       /* +   */
    TOK_MINUS,      /* -   */
    TOK_STAR,       /* *   */
    TOK_SLASH,      /* /   */
    TOK_AMP,        /* &   (boolean AND) */
    TOK_TILDE,      /* ~   (boolean NOT) */
    TOK_EQ,         /* =   */
    TOK_NEQ,        /* #   */
    TOK_LT,         /* <   */
    TOK_LE,         /* <=  */
    TOK_GT,         /* >   */
    TOK_GE,         /* >=  */
    TOK_ASSIGN,     /* :=  */

    /* Punctuation */
    TOK_LPAREN,     /* (   */
    TOK_RPAREN,     /* )   */
    TOK_LBRACKET,   /* [   */
    TOK_RBRACKET,   /* ]   */
    TOK_LBRACE,     /* {   */
    TOK_RBRACE,     /* }   */
    TOK_DOT,        /* .   */
    TOK_DOTDOT,     /* ..  */
    TOK_COMMA,      /* ,   */
    TOK_SEMI,       /* ;   */
    TOK_COLON,      /* :   */
    TOK_BAR,        /* |   */
    TOK_CARET,      /* ^   (pointer dereference) */
} TokenKind;

#define MAX_TOKEN_LEN 256

typedef struct {
    TokenKind kind;
    char      text[MAX_TOKEN_LEN]; /* raw source text (string content without quotes) */
    int       line;
    int       col;
    long      int_val;   /* parsed value for TOK_INTEGER and TOK_CHAR */
    double    real_val;  /* parsed value for TOK_REAL */
} Token;

typedef struct {
    FILE *file;
    int   ch;    /* current lookahead character */
    int   line;
    int   col;
} Lexer;

/* Initialise lexer from an open file.  Reads the first character. */
void        lexer_init(Lexer *lex, FILE *file);

/* Return the next token, advancing the stream. */
Token       lexer_next(Lexer *lex);

/* Human-readable name of a token kind (for diagnostics). */
const char *token_kind_name(TokenKind k);

/* Print a token to stdout (debugging). */
void        token_print(const Token *t);

#endif /* OBERON_LEXER_H */
